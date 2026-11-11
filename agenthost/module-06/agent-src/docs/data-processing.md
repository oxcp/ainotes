# Data processing

> 🌐 语言 / Language: **English** | [中文](data-processing_CN.md)

Upload validates extension, MIME, filename, size and Office ZIP structure. Originals are stored under
`data/<workspace UUID>/<file UUID>/original` with a SHA-256 checksum. The registered file reference, workspace,
stored bytes and checksum are revalidated before processing.

- PDF: text extraction per page; encrypted/scanned PDFs fail explicitly. OCR is not implemented.
- DOCX: paragraph headings and table text; page numbers are not invented.
- MD/TXT: paragraph boundaries and Markdown headings.
- JSON: arrays of objects become relational datasets; other JSON becomes searchable text.
- CSV/XLSX: normalized unique column names, preserved original names, conservative all-row type inference.
  Types include integer, decimal, currency, Boolean, ISO date/timestamp, categorical and text.
  Ambiguous dates remain text. XLSX supports one populated worksheet; formulas use cached values.

Numeric financial rows are stored relationally, never embedded. Named review/description/comment fields or long
text fields are embedded and linked by `source_row_id` to their dataset table. Empty/short/duplicate text is skipped
and counted. Distinct rows retain relational identity even when duplicate review vectors are skipped.

Chunking uses cl100k_base tokens, default 400 tokens with 60 overlap, respecting extracted paragraph/page boundaries.
Foundry embeddings are batched; the same deployment and dimension are used at ingest and query time.
In the cloud both paths use Module-01 APIM's Module-06-provisioned `/foundry/openai/v1/embeddings`
operation with `https://ai.azure.com/.default`; neither silently falls back to a direct account endpoint.
Metadata preserves document ID, filename via the documents join, checksum/Blob URI in the document record,
page/section, language (simple Chinese/English heuristic), row and business fields.
Repeated PDF headers/footers are not automatically removed; verify source quality during the workshop.

Ingestion is committed in one database transaction. A document row lock and unique `(workspace_id,checksum)` prevent
duplicate committed datasets. Failures roll back rows/vectors and mark the document failed. Original Blob uploads
may remain after processing failure or duplicate submission; retention cleanup must account for orphan originals.

Semantic RAG plans bounded searches over the current completed-file inventory, including source families
such as split files. It performs exact cosine search across document chunks and review vectors with mandatory
workspace/source filters, optional metadata predicates and a relevance threshold. Results are merged,
deduplicated and bounded by `TOP_K` (default five).
Rating/sentiment conditions are enforced as metadata predicates, not merely embedded as search text.
An explicitly constrained metadata-only sample requires both a rating bound and a sentiment label; it
bypasses the similarity threshold but retains workspace/source/metadata filters.

`review_overview` instead reads a bounded set of stored review passages without semantic search.
It reports truncation; neither passage counts nor selected examples represent complete review-row totals
or sentiment distributions. Use SQL over the selected datasets for those statistics.
Full-text/DiskANN indexing is an extension, not required for this bounded workshop dataset.
Similarity is not proof of relevance; final review checks evidence and conflicting claims.
