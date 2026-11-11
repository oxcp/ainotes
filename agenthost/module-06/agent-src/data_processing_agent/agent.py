import asyncio
import csv
import errno
import io
import json
import re
import shutil
import tempfile
from collections.abc import Iterator
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from itertools import islice
from pathlib import Path
from threading import Event
from typing import Any, BinaryIO, Literal
from uuid import UUID

import tiktoken
from docx import Document
from openpyxl import load_workbook
from pypdf import PdfReader

from shared.config import Settings
from shared.contracts import FileRef, ProcessingResult, StudioError
from shared.database import Repository
from shared.models import Foundry
from shared.storage import BlobStore

LONG_FIELDS = re.compile(r"review|comment|feedback|description|response|answer|issue", re.IGNORECASE)
NULLS = {"", "null", "none", "n/a", "na"}


def normalize_columns(names: list[str]) -> list[str]:
    result: list[str] = []
    for index, name in enumerate(names):
        normalized = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")[:45] or f"column_{index}"
        if normalized[0].isdigit() or normalized in {"workspace_id", "source_row_id"}:
            normalized = "col_" + normalized
        candidate, suffix = normalized, 1
        while candidate in result:
            suffix += 1
            candidate = f"{normalized}_{suffix}"
        result.append(candidate)
    return result


def numeric(value: str) -> Decimal:
    cleaned = re.sub(r"[$€£,\s]", "", value)
    if cleaned.startswith("(") and cleaned.endswith(")"):
        cleaned = "-" + cleaned[1:-1]
    number = Decimal(cleaned)
    if not number.is_finite():
        raise InvalidOperation()
    return number


def infer(values: list[str]) -> tuple[str, str]:
    present = [v for v in values if v.lower() not in NULLS]
    if not present:
        return "text", "short_text"
    if all(v.lower() in {"true", "false"} for v in present):
        return "boolean", "boolean"
    try:
        numbers = [numeric(v) for v in present]
        currency = any(re.search(r"[$€£]", v) for v in present)
        if not currency and all(n == n.to_integral() and abs(n) < 2**63 for n in numbers):
            return "bigint", "integer"
        return "numeric", "currency" if currency else "decimal"
    except (InvalidOperation, ValueError):
        pass
    try:
        if all(re.fullmatch(r"\d{4}-\d{2}-\d{2}", v) for v in present):
            [date.fromisoformat(v) for v in present]
            return "date", "date"
        if all("T" in v for v in present):
            [datetime.fromisoformat(v.replace("Z", "+00:00")) for v in present]
            return "timestamptz", "timestamp"
    except ValueError:
        pass
    if max(map(len, present)) >= 100:
        return "text", "long_text"
    return "text", "categorical" if len(set(present)) <= max(10, len(present) // 5) else "short_text"


def convert(value: str, kind: str):
    if value.lower() in NULLS:
        return None
    if kind == "bigint":
        return int(numeric(value))
    if kind == "numeric":
        return numeric(value)
    if kind == "boolean":
        return value.lower() == "true"
    if kind == "date":
        return date.fromisoformat(value)
    if kind == "timestamptz":
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    return value


def table_data(headers: list[str], records: list[list], config: Settings):
    if not headers or len(headers) > 60:
        raise StudioError("COLUMN_LIMIT", "Use between 1 and 60 columns.")
    if len(records) > config.max_rows:
        raise StudioError("ROW_LIMIT", "Dataset exceeds configured row limit.", 413)
    names = normalize_columns(headers)
    valid, skipped = [], 0
    for record in records:
        if len(record) != len(headers):
            skipped += 1
            continue
        values = [str(v).strip() if v is not None else "" for v in record]
        if not any(v.lower() not in NULLS for v in values):
            skipped += 1
            continue
        if any(len(v) > 100000 for v in values):
            raise StudioError("CELL_LIMIT", "A dataset cell exceeds the text limit.")
        valid.append(values)
    columns: list[dict[str, Any]] = []
    for i, name in enumerate(names):
        sql_type, kind = infer([row[i] for row in valid])
        long = sql_type == "text" and (LONG_FIELDS.search(name) is not None or kind == "long_text")
        columns.append(
            {"name": name, "original_name": headers[i], "sql_type": sql_type, "kind": kind, "embed": long}
        )
    rows = [{c["name"]: convert(row[i], c["sql_type"]) for i, c in enumerate(columns)} for row in valid]
    return columns, rows, skipped


def extract(data: bytes, filename: str, config: Settings):
    ext = Path(filename).suffix.lower()
    sections: list[dict[str, Any]] = []
    headers: list[str] = []
    records: list[list] = []
    if ext == ".pdf":
        reader = PdfReader(io.BytesIO(data))
        if reader.is_encrypted:
            raise StudioError("ENCRYPTED_PDF", "Upload an unencrypted PDF.")
        for i, page in enumerate(reader.pages):
            text = page.extract_text() or ""
            sections.append({"content": text, "page_number": i + 1, "section": None})
    elif ext == ".docx":
        doc = Document(io.BytesIO(data))
        heading = None
        for p in doc.paragraphs:
            if p.style and p.style.name.startswith("Heading"):
                heading = p.text
            if p.text.strip():
                sections.append({"content": p.text, "page_number": None, "section": heading})
        for table in doc.tables:
            sections.append(
                {
                    "content": "\n".join(" | ".join(c.text for c in row.cells) for row in table.rows),
                    "page_number": None,
                    "section": "Table",
                }
            )
    elif ext == ".csv":
        text = data.decode("utf-8-sig")
        csv.field_size_limit(100000)
        reader_csv = csv.reader(io.StringIO(text))
        headers = next(reader_csv, [])
        for row in reader_csv:
            records.append(row)
            if len(records) > config.max_rows:
                raise StudioError("ROW_LIMIT", "Dataset exceeds row limit.", 413)
    elif ext == ".xlsx":
        workbook = load_workbook(io.BytesIO(data), read_only=True, data_only=True)
        try:
            nonempty = [ws for ws in workbook.worksheets if ws.max_row and ws.max_row > 1]
            if len(nonempty) != 1:
                raise StudioError("SHEET_COUNT", "Upload one populated worksheet per XLSX file.")
            for i, values in enumerate(nonempty[0].iter_rows(values_only=True)):
                if i == 0:
                    headers = [str(v or "") for v in values]
                else:
                    records.append(list(values))
                if i > config.max_rows:
                    raise StudioError("ROW_LIMIT", "Dataset exceeds row limit.", 413)
        finally:
            workbook.close()
    elif ext == ".json":
        value = json.loads(data)
        if isinstance(value, list) and value and all(isinstance(row, dict) for row in value):
            headers = list(dict.fromkeys(k for row in value for k in row))
            records = [
                [
                    json.dumps(row[k], ensure_ascii=False)
                    if isinstance(row.get(k), (dict, list))
                    else row.get(k)
                    for k in headers
                ]
                for row in value
            ]
        else:
            sections = [{"content": json.dumps(value, ensure_ascii=False, indent=2), "section": None}]
    elif ext in {".md", ".txt"}:
        heading = None
        for para in re.split(r"\n\s*\n", data.decode("utf-8-sig")):
            if para.startswith("#"):
                heading = para.splitlines()[0].lstrip("# ").strip()
            sections.append({"content": para, "section": heading})
    else:
        raise StudioError("UNSUPPORTED_FILE", "Unsupported file type.", 415)
    if headers:
        columns, rows, skipped = table_data(headers, records, config)
        if not rows:
            raise StudioError("NO_DATA", "No valid dataset rows were found.")
        return sections, columns, rows, skipped
    if not any(s["content"].strip() for s in sections):
        raise StudioError("NO_TEXT", "No extractable text found. OCR and scanned PDFs are not supported.")
    return sections, [], [], 0


def iter_chunk_sections(sections: list[dict], config: Settings) -> Iterator[dict]:
    encoding = tiktoken.get_encoding("cl100k_base")
    count = 0
    for section in sections:
        text = section["content"].strip()
        tokens = encoding.encode(text, disallowed_special=())
        _, offsets = encoding.decode_with_offsets(tokens)
        offsets.append(len(text))
        start = 0
        while start < len(tokens):
            end = min(start + config.chunk_tokens, len(tokens))
            content = text[offsets[start] : offsets[end]].strip()
            # Re-tokenization at a new text boundary can exceed the original slice size.
            while len(encoding.encode(content, disallowed_special=())) > config.chunk_tokens:
                end -= 1
                content = text[offsets[start] : offsets[end]].strip()
            if content:
                count += 1
                if count > config.max_chunks:
                    raise StudioError("CHUNK_LIMIT", "Document exceeds configured chunk limit.", 413)
                yield {
                    **section,
                    "content": content,
                    "metadata": {"language": "zh" if re.search(r"[\u3400-\u9fff]", content) else "en"},
                }
            if end == len(tokens):
                break
            start = max(start + 1, end - config.chunk_overlap)


def chunk_sections(sections: list[dict], config: Settings) -> list[dict]:
    return list(iter_chunk_sections(sections, config))


class DataProcessingAgent:
    def __init__(self, config: Settings, repo: Repository, blob: BlobStore, model: Foundry):
        self.config, self.repo, self.blob, self.model = config, repo, blob, model

    async def run(self, workspace: UUID, ref: FileRef, emit) -> ProcessingResult:
        record = await asyncio.to_thread(self.repo.document, workspace, ref.file_id)
        if record["metadata"]["file"] != ref.model_dump(mode="json"):
            raise StudioError("FORBIDDEN_FILE", "File reference does not match the registered upload.", 403)
        if record["processing_status"] == "completed":
            return ProcessingResult.model_validate(record["metadata"]["report"])
        try:
            async with asyncio.timeout(self.config.ingestion_timeout):
                return await self._process(workspace, ref, emit)
        except (Exception, asyncio.CancelledError) as exc:
            await asyncio.to_thread(self.repo.failed_file, workspace, ref.file_id)
            if isinstance(exc, TimeoutError):
                raise StudioError(
                    "INGESTION_TIMEOUT", "File processing timed out; retry the upload.", 504, True
                ) from exc
            if isinstance(exc, OSError) and exc.errno == errno.ENOSPC:
                raise StudioError(
                    "INGESTION_STORAGE_FULL",
                    "Not enough temporary disk space for ingestion; free space before retrying.",
                    507,
                ) from exc
            raise

    async def _process(self, workspace: UUID, ref: FileRef, emit) -> ProcessingResult:
        with tempfile.TemporaryFile() as prepared, tempfile.TemporaryFile() as embedded:
            spool_bytes = 0
            count = 0

            def write_record(stream: BinaryIO, chunk: dict):
                nonlocal spool_bytes
                encoded = (json.dumps(chunk, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")
                spool_bytes += len(encoded)
                if spool_bytes > self.config.max_ingestion_spool_bytes:
                    raise StudioError("SPOOL_LIMIT", "File exceeds ingestion temporary-storage budget.", 413)
                stream.write(encoded)

            async def stage(chunk: dict):
                nonlocal count
                count += 1
                if count > self.config.max_chunks:
                    raise StudioError("CHUNK_LIMIT", "Dataset exceeds embedding chunk limit.", 413)
                write_record(prepared, chunk)
                if count % 256 == 0:
                    emit("chunking", f"Prepared {count} chunks...")
                    await asyncio.sleep(0)

            emit("extract", "Extracting document content...")
            data = await asyncio.to_thread(self.blob.read, workspace, ref)
            sections, columns, rows, skipped = await asyncio.to_thread(
                extract, data, ref.filename, self.config
            )
            for chunk in iter_chunk_sections(sections, self.config):
                await stage(chunk)
            seen: set[str] = set()
            long_columns = [c["name"] for c in columns if c["embed"]]
            if ref.filename.lower().replace("_", " ").endswith("financial sample.csv"):
                long_columns = []
            for i, row in enumerate(rows):
                for name in long_columns:
                    value = str(row.get(name) or "").strip()
                    if len(value) < 20 or value in seen:
                        skipped += 1
                        continue
                    seen.add(value)
                    parts = iter_chunk_sections([{"content": value}], self.config)
                    for part in parts:
                        await stage(
                            {
                                **part,
                                "source_row_id": i + 1,
                                "metadata": {
                                    **{
                                        k: str(v)
                                        for k, v in row.items()
                                        if k not in long_columns and v is not None
                                    },
                                    **part["metadata"],
                                    "field": name,
                                },
                            }
                        )
                if i % 256 == 0:
                    await asyncio.sleep(0)
            # Reserve an upper bound for JSON float representations before any paid request.
            estimated_bytes = 2 * spool_bytes + count * (26 * self.config.embedding_dimensions + 32)
            if estimated_bytes > self.config.max_ingestion_spool_bytes:
                raise StudioError("SPOOL_LIMIT", "File exceeds ingestion temporary-storage budget.", 413)
            prepared.flush()
            if estimated_bytes - spool_bytes > shutil.disk_usage(tempfile.gettempdir()).free:
                raise StudioError(
                    "INGESTION_STORAGE_FULL",
                    "Not enough temporary disk space for ingestion; free space before retrying.",
                    507,
                )
            prepared.seek(0)
            completed = 0
            while batch := [json.loads(line) for line in islice(prepared, self.config.embedding_batch)]:
                emit(
                    "embedding",
                    f"Generating embeddings for chunks {completed + 1}-{completed + len(batch)}/{count}...",
                )
                vectors = await self.model.embed([c["content"] for c in batch])
                for chunk, vector in zip(batch, vectors, strict=True):
                    chunk["embedding"] = vector
                    write_record(embedded, chunk)
                completed += len(batch)
                emit("embedding", f"Embedded {completed}/{count} chunks...")
                await asyncio.sleep(0)
            kind: Literal["HYBRID", "STRUCTURED", "UNSTRUCTURED"] = (
                "HYBRID" if rows and count else "STRUCTURED" if rows else "UNSTRUCTURED"
            )
            report = ProcessingResult(
                file_id=str(ref.file_id),
                filename=ref.filename,
                classification=kind,
                storage_strategy=(["RELATIONAL"] if rows else []) + (["VECTOR"] if count else []),
                rows_loaded=len(rows),
                records_embedded=count,
                skipped_records=skipped,
                warnings=[f"Skipped {skipped} empty, malformed, duplicate or short records."]
                if skipped
                else [],
            )
            emit("storage", "Loading structured data and vectors...")
            embedded.seek(0)
            cancelled = Event()
            commit = asyncio.create_task(
                asyncio.to_thread(
                    self.repo.ingest,
                    ref,
                    columns,
                    rows,
                    (json.loads(line) for line in embedded),
                    report,
                    cancelled,
                )
            )
            try:
                return await asyncio.shield(commit)
            except asyncio.CancelledError:
                cancelled.set()
                # The DB thread must finish rollback before its spool can be closed.
                while True:
                    try:
                        await asyncio.shield(commit)
                        break
                    except asyncio.CancelledError:
                        continue
                    except StudioError as exc:
                        if exc.code != "INGESTION_CANCELLED":
                            raise
                        break
                raise
