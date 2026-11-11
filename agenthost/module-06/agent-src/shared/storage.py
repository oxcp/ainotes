import hashlib
import io
import re
import zipfile
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import quote
from uuid import UUID, uuid4

from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings

from shared.config import Settings
from shared.contracts import FileRef, StudioError

MIMES = {
    ".pdf": {"application/pdf"},
    ".docx": {"application/vnd.openxmlformats-officedocument.wordprocessingml.document"},
    ".xlsx": {"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
    ".csv": {"text/csv", "application/vnd.ms-excel"},
    ".json": {"application/json"},
    ".md": {"text/markdown", "text/plain"},
    ".txt": {"text/plain"},
}


def validate_file(name: str, mime: str, data: bytes, limit: int) -> str:
    if not name or len(name) > 180 or re.search(r"[/\\:\x00-\x1f]", name) or name in {".", ".."}:
        raise StudioError("INVALID_FILENAME", "Use a plain filename without paths.")
    ext = Path(name).suffix.lower()
    if ext not in MIMES or mime not in MIMES[ext]:
        raise StudioError("UNSUPPORTED_FILE", "File extension or MIME type is unsupported.", 415)
    if not data or len(data) > limit:
        raise StudioError("FILE_SIZE", "File is empty or exceeds the upload limit.", 413)
    if ext == ".pdf" and not data.startswith(b"%PDF-"):
        raise StudioError("INVALID_FILE", "The file is not a PDF.")
    if ext in {".docx", ".xlsx"}:
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                entries = archive.infolist()
                if len(entries) > 10000 or sum(e.file_size for e in entries) > limit * 5:
                    raise StudioError("ARCHIVE_LIMIT", "Office archive exceeds expansion limits.")
                for item in entries:
                    if (
                        "\\" in item.filename
                        or item.filename.startswith("/")
                        or ".." in item.filename.split("/")
                    ):
                        raise StudioError("ARCHIVE_PATH", "Unsafe Office archive path.")
                required = "word/document.xml" if ext == ".docx" else "xl/workbook.xml"
                if required not in archive.namelist():
                    raise StudioError("INVALID_FILE", "Office document type does not match extension.")
        except zipfile.BadZipFile as exc:
            raise StudioError("INVALID_FILE", "Invalid Office document.") from exc
    return ext


class BlobStore:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.root = settings.local_blob_path.resolve()
        self.credential = DefaultAzureCredential() if settings.blob_backend == "azure" else None
        self.client = (
            BlobServiceClient(settings.azure_storage_account_url, credential=self.credential)
            if self.credential
            else None
        )

    def key(self, ref: FileRef) -> str:
        return f"{ref.workspace_id}/{ref.file_id}/original"

    def uri(self, ref: FileRef) -> str:
        base = (
            self.settings.azure_storage_account_url.rstrip("/") + "/data" if self.client else "local://data"
        )
        return f"{base}/{self.key(ref)}"

    def upload(self, workspace: UUID, name: str, mime: str, data: bytes) -> FileRef:
        validate_file(name, mime, data, self.settings.max_upload_bytes)
        ref = FileRef(
            file_id=uuid4(),
            workspace_id=workspace,
            filename=name,
            content_type=mime,
            size_bytes=len(data),
            checksum=hashlib.sha256(data).hexdigest(),
            blob_uri="",
        )
        ref.blob_uri = self.uri(ref)
        if self.client:
            self.client.get_blob_client("data", self.key(ref)).upload_blob(
                data,
                overwrite=False,
                content_settings=ContentSettings(content_type=mime),
                metadata={
                    "workspace_id": str(workspace),
                    "file_id": str(ref.file_id),
                    "filename": quote(name, safe=""),
                    "checksum": ref.checksum,
                    "content_type": mime,
                    "uploaded_at": datetime.now(UTC).isoformat(),
                },
            )
        else:
            dest = self.root / self.key(ref)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
        return ref

    def read(self, workspace: UUID, ref: FileRef) -> bytes:
        if ref.workspace_id != workspace or ref.blob_uri != self.uri(ref):
            raise StudioError("FORBIDDEN_FILE", "File does not belong to this workspace.", 403)
        if self.client:
            data = (
                self.client.get_blob_client("data", self.key(ref))
                .download_blob(offset=0, length=self.settings.max_upload_bytes + 1)
                .readall()
            )
        else:
            data = (self.root / self.key(ref)).read_bytes()
        if len(data) != ref.size_bytes or hashlib.sha256(data).hexdigest() != ref.checksum:
            raise StudioError("CHECKSUM_MISMATCH", "Stored file integrity check failed.")
        validate_file(ref.filename, ref.content_type, data, self.settings.max_upload_bytes)
        return data

    def close(self):
        if self.client:
            self.client.close()
        if self.credential:
            self.credential.close()
