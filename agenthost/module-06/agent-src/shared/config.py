from pathlib import Path
from typing import Literal
from urllib.parse import urlsplit

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")
    db_provider: Literal["horizondb", "postgresql"] = "horizondb"
    db_endpoint: str = "localhost"
    db_port: int = Field(default=5432, ge=1, le=65535)
    db_database: str = "postgres"
    db_username: str = "studio"
    # Password remains the default for local/alternate deployments. Entra never uses DB_PASSWORD.
    db_auth_mode: Literal["password", "entra"] = "password"
    db_password: SecretStr = SecretStr("")
    db_ssl_mode: str = "require"
    azure_client_id: str = ""
    azure_tenant_id: str = ""
    blob_backend: str = "local"
    local_blob_path: Path = Path(".local/data")
    azure_storage_account_url: str = ""
    azure_storage_container: str = "data"
    foundry_project_endpoint: str = ""
    agent_apim_endpoint: str = ""
    foundry_openai_base_url: str = ""
    foundry_embedding_base_url: str = ""
    llm_model: str = Field(min_length=1)
    embedding_model: str = Field(min_length=1)
    embedding_dimensions: int = Field(default=1536, ge=1, le=4096)
    llm_token_scope: str = "https://ai.azure.com/.default"
    embedding_token_scope: str = "https://ai.azure.com/.default"
    foundry_api_version: str = "v1"
    a2a_api_key: SecretStr | None = None
    a2a_public_url: str = "http://127.0.0.1:8080"
    orchestrator_url: str = "http://127.0.0.1:8081"
    data_processing_url: str = "http://127.0.0.1:8082"
    rag_url: str = "http://127.0.0.1:8083"
    sql_url: str = "http://127.0.0.1:8084"
    max_upload_bytes: int = Field(default=20_000_000, ge=1)
    max_rows: int = Field(default=50_000, ge=1, le=100_000)
    max_chunks: int = Field(default=100_000, ge=1, le=200_000)
    max_ingestion_spool_bytes: int = Field(default=4_294_967_296, ge=1, le=8_589_934_592)
    ingestion_timeout: float = Field(default=7200, gt=0, le=86400)
    chunk_tokens: int = Field(default=400, ge=64, le=1000)
    chunk_overlap: int = Field(default=60, ge=0)
    embedding_batch: int = Field(default=32, ge=1, le=128)
    top_k: int = Field(default=5, ge=1, le=5)
    relevance_threshold: float = Field(default=0.4, ge=-1, le=1)
    sql_row_limit: int = Field(default=100, ge=1, le=500)
    sql_timeout_ms: int = Field(default=5000, ge=100, le=30000)
    worker_timeout: float = Field(default=120, gt=0)
    request_timeout: float = Field(default=600, gt=0)
    max_model_context: int = Field(default=24000, ge=1000, le=100000)
    max_runs: int = Field(default=200, ge=1)
    requests_per_minute: int = Field(default=60, ge=1)

    @model_validator(mode="after")
    def validate_settings(self):
        if self.db_auth_mode == "password" and not self.db_password.get_secret_value():
            raise ValueError("DB_PASSWORD is required for password authentication")
        if self.db_auth_mode == "entra" and (not self.azure_client_id or self.db_ssl_mode == "disable"):
            raise ValueError("Entra database authentication requires AZURE_CLIENT_ID and TLS")
        if self.chunk_overlap >= self.chunk_tokens:
            raise ValueError("Chunk overlap must be smaller than chunk size")
        if self.blob_backend not in {"azure", "local"}:
            raise ValueError("BLOB_BACKEND must be azure or local")
        if self.db_ssl_mode not in {"require", "verify-ca", "verify-full", "disable"}:
            raise ValueError("Unsupported SSL mode")
        if self.db_ssl_mode == "disable" and self.db_endpoint not in {
            "localhost",
            "127.0.0.1",
            "db",
        }:
            raise ValueError("TLS is required outside local development")
        if self.a2a_api_key is not None and len(self.a2a_api_key.get_secret_value()) < 24:
            raise ValueError("A2A_API_KEY must have at least 24 characters")
        for endpoint in (
            self.a2a_public_url,
            self.orchestrator_url,
            self.data_processing_url,
            self.rag_url,
            self.sql_url,
        ):
            url = urlsplit(endpoint)
            if (
                url.scheme not in {"http", "https"}
                or not url.hostname
                or url.username
                or url.password
                or url.query
                or url.fragment
            ):
                raise ValueError(
                    "A2A endpoints must be HTTP(S) base URLs without credentials, query or fragment"
                )
        if self.azure_storage_container != "data":
            raise ValueError("This workshop requires the private data container")
        if self.blob_backend == "azure" and not self.azure_storage_account_url.startswith("https://"):
            raise ValueError("Azure storage account HTTPS URL is required")
        if self.foundry_api_version != "v1":
            raise ValueError("This adapter uses the Foundry OpenAI v1 API")
        return self
