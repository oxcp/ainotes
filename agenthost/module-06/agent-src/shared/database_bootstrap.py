"""Guest-only database migration, SQL grants and rollback-only UAMI read/write verification.

Run: python -m shared.database_bootstrap --config /app/.local/studio-runtime.json --migrate
Omit --migrate on subsequent deployments to check access without changing schema or grants.
The provider administrator API has already created the Entra role; no Graph lookup or RBAC
assignment can substitute for this SQL principal. This workshop UAMI remains a DB administrator.
"""

import argparse
from pathlib import Path
from uuid import uuid4

import psycopg
from psycopg import sql

from migrations import apply_migrations
from shared.config import Settings
from shared.database_auth import DatabaseConnectionInfo
from shared.sandbox_bootstrap import load_environment

TABLES = (
    "workspaces", "documents", "datasets", "document_chunks",
    "customer_reviews", "agent_runs", "insights",
)


def grant_access(conn, config: Settings):
    role = sql.Identifier(config.db_username)
    conn.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(
        sql.Identifier(config.db_database), role,
    ))
    # CREATE is required by ingestion's dynamic ds_<file_id> tables, not just initial migrations.
    conn.execute(sql.SQL("GRANT USAGE, CREATE ON SCHEMA public TO {}").format(role))
    conn.execute(sql.SQL(
        "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO {}"
    ).format(role))
    conn.execute(sql.SQL(
        "GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO {}"
    ).format(role))
    # These defaults apply to future objects created by this migration/runtime identity.
    conn.execute(sql.SQL(
        "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {}"
    ).format(role))
    conn.execute(sql.SQL(
        "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO {}"
    ).format(role))


def check_access(conn, config: Settings):
    if conn.execute("SELECT current_user").fetchone()[0] != config.db_username:
        raise RuntimeError("Database connection did not select the configured Agent identity")
    for table in TABLES:
        privileges = conn.execute(
            "SELECT has_table_privilege(current_user, %s, 'SELECT') "
            "AND has_table_privilege(current_user, %s, 'INSERT') "
            "AND has_table_privilege(current_user, %s, 'UPDATE') "
            "AND has_table_privilege(current_user, %s, 'DELETE')",
            (f"public.{table}",) * 4,
        ).fetchone()
        if not privileges or not privileges[0]:
            raise RuntimeError(f"Agent lacks DML privileges on public.{table}")
    if not conn.execute(
        "SELECT has_schema_privilege(current_user, 'public', 'USAGE') "
        "AND has_schema_privilege(current_user, 'public', 'CREATE')"
    ).fetchone()[0]:
        raise RuntimeError("Agent lacks schema privileges required by ingestion")
    missing_sequences = conn.execute(
        "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
        "WHERE n.nspname='public' AND c.relkind='S' "
        "AND NOT (has_sequence_privilege(current_user, c.oid, 'USAGE') "
        "AND has_sequence_privilege(current_user, c.oid, 'SELECT') "
        "AND has_sequence_privilege(current_user, c.oid, 'UPDATE'))"
    ).fetchall()
    if missing_sequences:
        raise RuntimeError("Agent lacks sequence privileges")
    # Exercise actual persistent-table DML (not only SELECT 1), then roll the transaction back.
    workspace = uuid4()
    try:
        conn.execute(
            "INSERT INTO public.workspaces(id,name) VALUES (%s,%s)",
            (workspace, "database permission probe"),
        )
        conn.execute("UPDATE public.workspaces SET name=%s WHERE id=%s", ("updated probe", workspace))
        row = conn.execute("SELECT name FROM public.workspaces WHERE id=%s", (workspace,)).fetchone()
        if not row or row[0] != "updated probe":
            raise RuntimeError("Agent database read/write probe failed")
        conn.execute("DELETE FROM public.workspaces WHERE id=%s", (workspace,))
        if conn.execute("SELECT 1 FROM public.workspaces WHERE id=%s", (workspace,)).fetchone():
            raise RuntimeError("Agent database delete probe failed")
    finally:
        conn.rollback()


def bootstrap(config: Settings, *, migrate: bool = False):
    info = DatabaseConnectionInfo(config)
    try:
        with psycopg.connect(info()) as conn:
            if migrate:
                apply_migrations(conn, config.embedding_dimensions)
                grant_access(conn, config)
                conn.commit()
            check_access(conn, config)
    finally:
        info.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--migrate", action="store_true")
    args = parser.parse_args()
    try:
        values = load_environment(args.config)
        config = Settings(_env_file=None, **{k.lower(): v for k, v in values.items()})
        bootstrap(config, migrate=args.migrate)
    except Exception:
        # Connection errors/validation values may contain credentials. Do not emit exception details.
        raise SystemExit("Database bootstrap/check failed; verify identity, provider Entra support, SQL grants and connectivity") from None
    print("Database identity DML/schema/sequence checks passed; probe changes rolled back.")


if __name__ == "__main__":
    main()
