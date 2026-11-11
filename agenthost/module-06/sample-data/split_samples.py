"""Split local workshop inputs without Azure/model calls or changes to the originals."""

import argparse
import csv
import hashlib
import json
from pathlib import Path

from pypdf import PdfReader, PdfWriter

from data_processing_agent.agent import extract, iter_chunk_sections
from shared.config import Settings


def chunk_upper_bound(path: Path, config: Settings) -> int:
    sections, columns, rows, _ = extract(path.read_bytes(), path.name, config)
    count = sum(1 for _ in iter_chunk_sections(sections, config))
    for row in rows:
        for column in columns:
            if column["embed"]:
                count += sum(
                    1 for _ in iter_chunk_sections([{"content": str(row[column["name"]] or "")}], config)
                )
    return count


def split_samples(
    source: Path,
    output: Path,
    *,
    csv_rows: int = 2000,
    pdf_pages: int = 20,
    max_bytes: int = 5_000_000,
    max_chunks: int = 4500,
) -> dict:
    if min(csv_rows, pdf_pages, max_bytes, max_chunks) < 1:
        raise ValueError("All limits must be positive.")
    inputs = sorted(
        path for path in source.iterdir() if path.is_file() and path.suffix.lower() in {".pdf", ".csv"}
    )
    if not inputs:
        raise ValueError("No PDF or CSV inputs found.")
    if output.exists():
        raise FileExistsError(
            "Output directory already exists; choose a new directory to preserve its files."
        )
    config = Settings(
        _env_file=None,
        _env_prefix="STUDIO_SPLIT_",
        db_password="offline-only",
        llm_model="unused",
        embedding_model="unused",
        max_rows=100_000,
        max_chunks=200_000,
    )
    output.mkdir(parents=True)
    manifest = {
        "csv_rows_per_part": csv_rows,
        "pdf_pages_per_part": pdf_pages,
        "max_bytes": max_bytes,
        "max_embedding_chunk_upper_bound": max_chunks,
        "sources": [],
    }
    for path in inputs:
        entry = {
            "source": path.name,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "bytes": path.stat().st_size,
            "parts": [],
        }
        manifest["sources"].append(entry)
        if path.suffix.lower() == ".csv":
            with path.open(encoding="utf-8-sig", newline="") as stream:
                reader = csv.reader(stream)
                header, rows = next(reader), list(reader)
            if not header or not rows or any(len(row) != len(header) for row in rows):
                raise ValueError(f"{path.name}: expected a header and consistently shaped logical CSV rows.")
            entry["rows"] = len(rows)
            total, step, unit = len(rows), csv_rows, "rows"

            def write_part(target, start, end):
                with target.open("w", encoding="utf-8-sig", newline="") as stream:
                    writer = csv.writer(stream)
                    writer.writerow(header)
                    writer.writerows(rows[start:end])
                with target.open(encoding="utf-8-sig", newline="") as stream:
                    check = csv.reader(stream)
                    if next(check) != header or list(check) != rows[start:end]:
                        raise ValueError(f"{target.name}: CSV round-trip changed field values.")
        else:
            pdf = PdfReader(path)
            if pdf.is_encrypted:
                raise ValueError(f"{path.name}: encrypted PDFs must be decrypted before splitting.")
            entry["pages"] = len(pdf.pages)
            total, step, unit = len(pdf.pages), pdf_pages, "pages"

            def write_part(target, start, end):
                writer = PdfWriter()
                writer.append(pdf, pages=(start, end), import_outline=False)
                writer.add_metadata({"/SourceFile": path.name, "/SourcePages": f"{start + 1}-{end}"})
                writer.write(target)
                check = PdfReader(target)
                if len(check.pages) != end - start:
                    raise ValueError(f"{target.name}: page count changed.")
                for original, copied in zip(pdf.pages[start:end], check.pages, strict=True):
                    left, right = original.get_contents(), copied.get_contents()
                    if (left.get_data() if left is not None else b"") != (
                        right.get_data() if right is not None else b""
                    ) or tuple(original.mediabox) != tuple(copied.mediabox):
                        raise ValueError(f"{target.name}: PDF page content or dimensions changed.")

        def save(start, end):
            target = output / f"{path.stem}-{unit}-{start + 1:06d}-{end:06d}{path.suffix}"
            write_part(target, start, end)
            size = target.stat().st_size
            chunks = chunk_upper_bound(target, config)
            if size > max_bytes or chunks > max_chunks:
                target.unlink()
                if end - start == 1:
                    raise ValueError(f"{path.name}: a single {unit[:-1]} exceeds the configured budget.")
                middle = (start + end) // 2
                save(start, middle)
                save(middle, end)
                return
            entry["parts"].append(
                {
                    "file": target.name,
                    "start": start + 1,
                    "end": end,
                    unit: end - start,
                    "bytes": size,
                    "embedding_chunk_upper_bound": chunks,
                    "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
                }
            )

        for start in range(0, total, step):
            save(start, min(start + step, total))
        if sum(part[unit] for part in entry["parts"]) != total:
            raise ValueError(f"{path.name}: split coverage does not match the source.")
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError(f"{path.name}: source changed while splitting.")
    (output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return manifest


def main():
    sample_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        type=Path,
        default=sample_dir / "raw",
        help="Original PDF/CSV directory (default: %(default)s)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=sample_dir / "upload-parts",
        help="New output directory; must not exist (default: %(default)s)",
    )
    parser.add_argument("--csv-rows", type=int, default=2000)
    parser.add_argument("--pdf-pages", type=int, default=20)
    parser.add_argument("--max-bytes", type=int, default=5_000_000)
    parser.add_argument("--max-chunks", type=int, default=4500)
    args = parser.parse_args()
    manifest = split_samples(
        args.source,
        args.output,
        csv_rows=args.csv_rows,
        pdf_pages=args.pdf_pages,
        max_bytes=args.max_bytes,
        max_chunks=args.max_chunks,
    )
    for source in manifest["sources"]:
        print(f"{source['source']}: {len(source['parts'])} upload files")
    print(f"Verified files and manifest: {args.output.resolve()}")


if __name__ == "__main__":
    main()
