from importlib.resources import files

from psycopg import Connection


def apply_migrations(conn: Connection, embedding_dimensions: int) -> None:
    for migration in sorted(files(__package__).iterdir(), key=lambda path: path.name):
        if migration.name.endswith(".sql"):
            text = migration.read_text(encoding="utf-8")
            conn.execute(text.replace("__DIMENSIONS__", str(embedding_dimensions)))