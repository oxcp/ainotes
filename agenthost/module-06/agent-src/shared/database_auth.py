"""PostgreSQL connection parameters with a fresh UAMI token for each physical connection."""

from azure.identity import ManagedIdentityCredential
from psycopg.conninfo import make_conninfo

from shared.config import Settings

POSTGRES_TOKEN_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"


class DatabaseConnectionInfo:
    def __init__(self, config: Settings):
        self.config = config
        # Explicit UAMI selection avoids silently using a developer login or a service-principal secret.
        self.credential = (
            ManagedIdentityCredential(client_id=config.azure_client_id)
            if config.db_auth_mode == "entra"
            else None
        )

    def __call__(self) -> str:
        password = (
            self.credential.get_token(POSTGRES_TOKEN_SCOPE).token
            if self.credential is not None
            else self.config.db_password.get_secret_value()
        )
        return make_conninfo(
            host=self.config.db_endpoint,
            port=self.config.db_port,
            dbname=self.config.db_database,
            user=self.config.db_username,
            password=password,
            sslmode=self.config.db_ssl_mode,
            connect_timeout=10,
        )

    def close(self):
        if self.credential is not None:
            self.credential.close()
