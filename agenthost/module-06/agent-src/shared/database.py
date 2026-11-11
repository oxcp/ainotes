import json
from collections.abc import Iterable
from itertools import islice
from threading import Event
from typing import Any
from uuid import UUID, uuid4

import psycopg
from psycopg import sql
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool

from migrations import apply_migrations
from shared.config import Settings
from shared.contracts import FileRef, ProcessingResult, ReviewFilter, StudioError
from shared.database_auth import DatabaseConnectionInfo

INGEST_BATCH_SIZE = 128


def connection_info(config: Settings) -> str:
    info = DatabaseConnectionInfo(config)
    try:
        return info()
    finally:
        info.close()


def json_safe(value):
    return json.loads(json.dumps(value, default=str))


def evidence_filters(filters: dict[str, str]) -> tuple[list[str], list[str]]:
    allowed = {"filename", "document_id", "category", "product", "language", "date"}
    if set(filters) - allowed:
        raise StudioError("INVALID_FILTER", "Unsupported retrieval filter.")
    where, args = [], []
    for key, value in filters.items():
        where.append(
            f"{key}::text = %s" if key in {"filename", "document_id"} else f"metadata ->> '{key}' = %s"
        )
        args.append(value)
    return where, args


class Repository:
    def __init__(self, config: Settings):
        self.config = config
        self._connection_info = DatabaseConnectionInfo(config)
        self.pool: ConnectionPool[psycopg.Connection[dict[str, Any]]] = ConnectionPool(
            # Pool 3.3 resolves this callable when opening/replacing a connection, not once at startup.
            self._connection_info,
            min_size=1,
            max_size=6,
            timeout=10,
            kwargs={"row_factory": dict_row, "options": f"-c statement_timeout={config.sql_timeout_ms}"},
        )

    def close(self):
        self.pool.close()
        self._connection_info.close()

    def health(self):
        with self.pool.connection() as conn:
            conn.execute("SELECT 1").fetchone()

    def create_workspace(self, name: str) -> dict:
        with self.pool.connection() as conn:
            return json_safe(
                conn.execute(
                    "INSERT INTO workspaces(id,name) VALUES (%s,%s) RETURNING *",
                    (uuid4(), name),
                ).fetchone()
            )

    def workspaces(self) -> list[dict]:
        with self.pool.connection() as conn:
            return json_safe(
                conn.execute(
                    "SELECT * FROM workspaces ORDER BY created_at DESC LIMIT 100"
                ).fetchall()
            )

    def workspace(self, workspace: UUID) -> dict:
        with self.pool.connection() as conn:
            row = conn.execute(
                "SELECT * FROM workspaces WHERE id=%s", (workspace,)
            ).fetchone()
        if not row:
            raise StudioError("NOT_FOUND", "Workspace not found.", 404)
        return json_safe(row)

    def documents(self, workspace: UUID) -> list[dict]:
        with self.pool.connection() as conn:
            return json_safe(
                conn.execute(
                    "SELECT id,filename,file_type,processing_status,metadata FROM documents WHERE workspace_id=%s ORDER BY created_at DESC LIMIT 100",
                    (workspace,),
                ).fetchall()
            )

    def document(self, workspace: UUID, file_id: UUID) -> dict:
        with self.pool.connection() as conn:
            result = conn.execute(
                "SELECT * FROM documents WHERE workspace_id=%s AND id=%s", (workspace, file_id)
            ).fetchone()
        if not result:
            raise StudioError("NOT_FOUND", "File not found.", 404)
        return json_safe(result)

    def register_file(self, ref: FileRef) -> dict:
        with self.pool.connection() as conn:
            row = conn.execute(
                """INSERT INTO documents(id,workspace_id,filename,file_type,storage_uri,checksum,
                processing_status,metadata) VALUES (%s,%s,%s,%s,%s,%s,'queued',%s)
                ON CONFLICT(workspace_id,checksum) DO UPDATE SET updated_at=now() RETURNING *""",
                (
                    ref.file_id,
                    ref.workspace_id,
                    ref.filename,
                    ref.content_type,
                    ref.blob_uri,
                    ref.checksum,
                    Jsonb({"file": ref.model_dump(mode="json")}),
                ),
            ).fetchone()
        return json_safe(row)

    def failed_file(self, workspace: UUID, file_id: UUID):
        with self.pool.connection() as conn:
            conn.execute(
                "UPDATE documents SET processing_status='failed',updated_at=now() WHERE workspace_id=%s AND id=%s AND processing_status!='completed'",
                (workspace, file_id),
            )

    def catalog(self, workspace: UUID) -> list[dict]:
        with self.pool.connection() as conn:
            return json_safe(
                conn.execute(
                    "SELECT name,table_name,schema_json,row_count FROM datasets WHERE workspace_id=%s LIMIT 12",
                    (workspace,),
                ).fetchall()
            )

    def ingest(
        self,
        ref: FileRef,
        columns: list[dict],
        rows: list[dict],
        chunks: Iterable[dict],
        report: ProcessingResult,
        cancelled: Event | None = None,
    ) -> ProcessingResult:
        def check_cancelled():
            if cancelled is not None and cancelled.is_set():
                raise StudioError("INGESTION_CANCELLED", "File processing was cancelled.", 409, True)

        check_cancelled()
        with self.pool.connection() as conn, conn.transaction():
            # Bulk writes need their own bounded timeout; interactive SQL remains unchanged.
            conn.execute("SELECT set_config('statement_timeout', '30000', true)")
            current = conn.execute(
                "SELECT * FROM documents WHERE workspace_id=%s AND id=%s FOR UPDATE",
                (ref.workspace_id, ref.file_id),
            ).fetchone()
            if current is None:
                raise StudioError("NOT_FOUND", "Registered file not found.", 404)
            if current["processing_status"] == "completed":
                return ProcessingResult.model_validate(current["metadata"]["report"])
            check_cancelled()
            if columns:
                table = "ds_" + ref.file_id.hex
                allowed_types = {"bigint", "numeric", "boolean", "date", "timestamptz", "text"}
                if any(c["sql_type"] not in allowed_types for c in columns):
                    raise ValueError("Invalid inferred column type")
                definitions = [
                    sql.SQL("{} {}").format(sql.Identifier(c["name"]), sql.SQL(c["sql_type"]))
                    for c in columns
                ]
                conn.execute(
                    sql.SQL(
                        "CREATE TABLE {} (workspace_id uuid NOT NULL, source_row_id integer NOT NULL, {}, PRIMARY KEY(workspace_id,source_row_id))"
                    ).format(sql.Identifier(table), sql.SQL(",").join(definitions))
                )
                command = sql.SQL("INSERT INTO {} VALUES ({})").format(
                    sql.Identifier(table),
                    sql.SQL(",").join(sql.Placeholder() for _ in range(len(columns) + 2)),
                )
                with conn.cursor() as cur:
                    source_rows = enumerate(rows)
                    while batch := list(islice(source_rows, INGEST_BATCH_SIZE)):
                        check_cancelled()
                        cur.executemany(
                            command,
                            [
                                (ref.workspace_id, i + 1, *[row.get(c["name"]) for c in columns])
                                for i, row in batch
                            ],
                        )
                conn.execute(
                    "INSERT INTO datasets(id,workspace_id,name,source_document_id,table_name,schema_json,row_count) VALUES (%s,%s,%s,%s,%s,%s,%s)",
                    (uuid4(), ref.workspace_id, ref.filename, ref.file_id, table, Jsonb(columns), len(rows)),
                )
                report.table_name = table
            source_chunks = enumerate(chunks)
            ingested_chunks = 0
            with conn.cursor() as cur:
                while batch := list(islice(source_chunks, INGEST_BATCH_SIZE)):
                    check_cancelled()
                    reviews, documents = [], []
                    for i, chunk in batch:
                        vector = "[" + ",".join(str(float(v)) for v in chunk["embedding"]) + "]"
                        metadata = chunk.get("metadata", {})
                        if chunk.get("source_row_id") is not None:
                            reviews.append(
                                (
                                    uuid4(),
                                    ref.workspace_id,
                                    ref.file_id,
                                    chunk["source_row_id"],
                                    chunk["content"],
                                    vector,
                                    *[
                                        str(metadata[k]) if metadata.get(k) is not None else None
                                        for k in (
                                            "product",
                                            "category",
                                            "rating",
                                            "sentiment",
                                            "country",
                                            "date",
                                        )
                                    ],
                                    Jsonb(json_safe(metadata)),
                                )
                            )
                        else:
                            documents.append(
                                (
                                    uuid4(),
                                    ref.workspace_id,
                                    ref.file_id,
                                    chunk["content"],
                                    vector,
                                    chunk.get("page_number"),
                                    chunk.get("section"),
                                    i,
                                    Jsonb(metadata),
                                )
                            )
                    if reviews:
                        cur.executemany(
                            """INSERT INTO customer_reviews(id,workspace_id,source_document_id,source_row_id,
                        review_text,embedding,product,category,rating,sentiment,country,review_date,metadata)
                        VALUES (%s,%s,%s,%s,%s,%s::vector,%s,%s,%s,%s,%s,%s,%s)""",
                            reviews,
                        )
                    if documents:
                        cur.executemany(
                            """INSERT INTO document_chunks(id,workspace_id,document_id,content,embedding,
                        page_number,section_name,chunk_index,metadata) VALUES (%s,%s,%s,%s,%s::vector,%s,%s,%s,%s)""",
                            documents,
                        )
                    ingested_chunks += len(batch)
            check_cancelled()
            if len(rows) != report.rows_loaded or ingested_chunks != report.records_embedded:
                raise StudioError(
                    "INGESTION_MISMATCH", "Ingestion counts do not match the prepared file.", 500
                )
            conn.execute(
                "UPDATE documents SET processing_status='completed',metadata=metadata || %s,updated_at=now() WHERE workspace_id=%s AND id=%s",
                (Jsonb({"report": report.model_dump(mode="json")}), ref.workspace_id, ref.file_id),
            )
        return report

    def search(
        self,
        workspace: UUID,
        vector: list[float],
        filters: dict[str, str],
        *,
        filenames: list[str] | None = None,
        review_filter: ReviewFilter | None = None,
        metadata_only: bool = False,
    ) -> list[dict]:
        predicates, values = evidence_filters(filters)
        if metadata_only and (
            review_filter is None
            or review_filter.sentiment_label is None
            or (review_filter.rating_min is None and review_filter.rating_max is None)
        ):
            raise StudioError(
                "INVALID_RETRIEVAL", "Metadata-only examples require rating and sentiment constraints.", 422
            )
        where = list(predicates) if metadata_only else ["similarity_score >= %s", *predicates]
        args: list[str | float | list[str]] = (
            list(values) if metadata_only else [self.config.relevance_threshold, *values]
        )
        if filenames is not None:
            where.append("filename = ANY(%s)")
            args.append(filenames)
        if review_filter is not None:
            # CASE guards the cast for nonnumeric metadata in mixed document/review sources.
            rating = (
                "CASE WHEN metadata->>'rating' ~ '^[0-5]([.][0-9]+)?$' "
                "THEN (metadata->>'rating')::numeric END"
            )
            for value, comparison in ((review_filter.rating_min, ">="), (review_filter.rating_max, "<=")):
                if value is not None:
                    where.append(f"({rating}) {comparison} %s")
                    args.append(value)
            if review_filter.sentiment_label is not None:
                where.append("LOWER(metadata->>'sentiment_label') = %s")
                args.append(review_filter.sentiment_label)
        query = (
            """WITH evidence AS (
            SELECT c.id::text AS record_id,c.workspace_id::text,c.document_id::text,d.filename,c.content,
                   1-(c.embedding <=> %s::vector) AS similarity_score,c.page_number,c.section_name AS section,c.metadata
            FROM document_chunks c JOIN documents d ON d.id=c.document_id AND d.workspace_id=c.workspace_id
            WHERE c.workspace_id=%s
            UNION ALL
            SELECT r.id::text,r.workspace_id::text,r.source_document_id::text,d.filename,r.review_text,
                   1-(r.embedding <=> %s::vector),NULL,NULL,
                   r.metadata || jsonb_build_object('source_row_id',r.source_row_id)
            FROM customer_reviews r JOIN documents d ON d.id=r.source_document_id AND d.workspace_id=r.workspace_id
            WHERE r.workspace_id=%s)
            SELECT * FROM evidence WHERE """
            + " AND ".join(where)
            + " ORDER BY similarity_score DESC LIMIT %s"
        )
        serialized = "[" + ",".join(str(float(v)) for v in vector) + "]"
        with self.pool.connection() as conn:
            return json_safe(
                conn.execute(
                    query, (serialized, workspace, serialized, workspace, *args, self.config.top_k)
                ).fetchall()
            )

    def review_overview(self, workspace: UUID, filters: dict[str, str]) -> list[dict]:
        where, args = evidence_filters(filters)
        query = (
            """WITH evidence AS (
            SELECT r.id::text AS record_id,r.workspace_id::text,r.source_document_id::text AS document_id,
                   d.filename,r.review_text AS content,NULL::double precision AS similarity_score,
                   NULL::integer AS page_number,NULL::text AS section,r.source_row_id,
                   r.metadata || jsonb_build_object('source_row_id',r.source_row_id,
                       'ingestion_report',d.metadata->'report') AS metadata
            FROM customer_reviews r
            JOIN documents d ON d.id=r.source_document_id AND d.workspace_id=r.workspace_id
            WHERE r.workspace_id=%s AND d.processing_status='completed')
            SELECT record_id,workspace_id,document_id,filename,content,similarity_score,page_number,section,metadata
            FROM evidence WHERE """
            + (" AND ".join(where) if where else "TRUE")
            + """
            ORDER BY document_id,source_row_id,record_id LIMIT %s"""
        )
        with self.pool.connection() as conn:
            return json_safe(conn.execute(query, (workspace, *args, self.config.top_k + 1)).fetchall())

    def query(self, statement: str) -> tuple[list[str], list[dict]]:
        with self.pool.connection() as conn, conn.transaction():
            conn.execute("SET TRANSACTION READ ONLY")
            conn.execute("SELECT set_config('statement_timeout',%s,true)", (str(self.config.sql_timeout_ms),))
            with conn.cursor() as cur:
                cur.execute(statement)
                columns = [c.name for c in cur.description] if cur.description else []
                rows = cur.fetchmany(self.config.sql_row_limit)
        encoded = json_safe(rows)
        if len(json.dumps(encoded)) > 16000:
            raise StudioError("RESULT_LIMIT", "SQL result is too large; select fewer columns.", 422)
        return columns, encoded

    def save_run(self, workspace: UUID, run: dict):
        with self.pool.connection() as conn:
            conn.execute(
                """INSERT INTO agent_runs(id,workspace_id,request_id,agent_name,route,status,
                input_summary,output_summary,evidence_json,latency_ms,error) VALUES (%s,%s,%s,'orchestrator',%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT(id) DO UPDATE SET status=EXCLUDED.status,evidence_json=EXCLUDED.evidence_json""",
                (
                    run["request_id"],
                    workspace,
                    run["request_id"],
                    run.get("mode"),
                    run["status"],
                    "question or upload",
                    "bounded workflow result",
                    Jsonb(json_safe(run)),
                    run.get("latency_ms"),
                    run.get("error", {}).get("code"),
                ),
            )

    def run(self, workspace: UUID, run_id: UUID):
        with self.pool.connection() as conn:
            row = conn.execute(
                "SELECT evidence_json FROM agent_runs WHERE workspace_id=%s AND id=%s", (workspace, run_id)
            ).fetchone()
        if not row:
            raise StudioError("NOT_FOUND", "Run not found.", 404)
        return row["evidence_json"]


def migrate():
    config = Settings()
    with psycopg.connect(connection_info(config)) as conn:
        apply_migrations(conn, config.embedding_dimensions)
    print("Migration applied. Keep EMBEDDING_DIMENSIONS unchanged for this schema.")


if __name__ == "__main__":
    migrate()
