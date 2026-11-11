CREATE EXTENSION IF NOT EXISTS vector;
CREATE TABLE IF NOT EXISTS workspaces (
 id uuid PRIMARY KEY, name text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS documents (
 id uuid PRIMARY KEY, workspace_id uuid NOT NULL REFERENCES workspaces(id),
 filename text NOT NULL, file_type text NOT NULL, storage_uri text NOT NULL, checksum text NOT NULL,
 processing_status text NOT NULL, metadata jsonb NOT NULL DEFAULT '{}',
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(workspace_id, checksum), UNIQUE(workspace_id, id)
);
CREATE TABLE IF NOT EXISTS datasets (
 id uuid PRIMARY KEY, workspace_id uuid NOT NULL REFERENCES workspaces(id), name text NOT NULL,
 source_document_id uuid NOT NULL, table_name text NOT NULL UNIQUE,
 schema_json jsonb NOT NULL, row_count integer NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(workspace_id, source_document_id) REFERENCES documents(workspace_id,id)
);
CREATE TABLE IF NOT EXISTS document_chunks (
 id uuid PRIMARY KEY, workspace_id uuid NOT NULL, document_id uuid NOT NULL,
 content text NOT NULL, embedding vector(__DIMENSIONS__) NOT NULL,
 page_number integer, section_name text, chunk_index integer NOT NULL, metadata jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(workspace_id, document_id) REFERENCES documents(workspace_id,id)
);
CREATE INDEX IF NOT EXISTS chunks_workspace ON document_chunks(workspace_id);
CREATE TABLE IF NOT EXISTS customer_reviews (
 id uuid PRIMARY KEY, workspace_id uuid NOT NULL, source_document_id uuid NOT NULL,
 source_row_id integer NOT NULL, review_text text NOT NULL, embedding vector(__DIMENSIONS__) NOT NULL,
 product text, category text, rating text, sentiment text, country text, review_date text,
 metadata jsonb NOT NULL,
 FOREIGN KEY(workspace_id, source_document_id) REFERENCES documents(workspace_id,id)
);
CREATE INDEX IF NOT EXISTS reviews_workspace ON customer_reviews(workspace_id);
CREATE TABLE IF NOT EXISTS agent_runs (
 id uuid PRIMARY KEY, workspace_id uuid NOT NULL REFERENCES workspaces(id), request_id uuid NOT NULL,
 agent_name text NOT NULL, route text, status text NOT NULL, input_summary text,
 output_summary text, evidence_json jsonb NOT NULL DEFAULT '{}', latency_ms integer, error text,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS insights (
 id uuid PRIMARY KEY, workspace_id uuid NOT NULL REFERENCES workspaces(id),
 insight_type text NOT NULL, content text NOT NULL, embedding vector(__DIMENSIONS__),
 evidence_json jsonb NOT NULL, confidence double precision,
 created_by text NOT NULL, status text NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
