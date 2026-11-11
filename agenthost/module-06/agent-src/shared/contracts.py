from enum import StrEnum
from typing import Annotated, Any, Literal
from uuid import UUID, uuid4

from pydantic import BaseModel, ConfigDict, Field, model_validator


class Contract(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Mode(StrEnum):
    DIRECT = "DIRECT"
    RAG = "RAG"
    SQL = "SQL"
    HYBRID = "HYBRID"


class FileRef(Contract):
    file_id: UUID = Field(default_factory=uuid4)
    workspace_id: UUID
    filename: str
    content_type: str
    size_bytes: int
    blob_uri: str
    checksum: str


class Question(Contract):
    conversation_id: UUID = Field(default_factory=uuid4)
    message: str = Field(min_length=1, max_length=4000)
    recent_context: list[str] = Field(default_factory=list, max_length=6)
    filters: dict[str, str] = Field(default_factory=dict, max_length=8)


RetrievalStrategy = Literal["semantic", "review_overview"]


class Plan(Contract):
    mode: Mode
    reason: str = Field(max_length=1000)
    rag_goal: str = Field(default="", max_length=4000)
    sql_goal: str = Field(default="", max_length=4000)
    rag_strategy: RetrievalStrategy = "semantic"
    chart_intent: Literal["auto", "requested", "none"] = "auto"


class SQLProposal(Contract):
    sql: str = Field(min_length=1, max_length=8000)


class Evidence(Contract):
    record_id: str
    workspace_id: str
    document_id: str
    filename: str
    content: str
    similarity_score: float | None
    page_number: int | None = None
    section: str | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)


class RagResult(Contract):
    status: Literal["sufficient", "weak", "insufficient", "conflicting"]
    results: list[Evidence] = Field(default_factory=list, max_length=12)
    top_k: int = 5
    retrieval_method: RetrievalStrategy = "semantic"
    truncated: bool = False
    warnings: list[str] = Field(default_factory=list)


class ReviewFilter(Contract):
    rating_min: float | None = Field(default=None, ge=0, le=5)
    rating_max: float | None = Field(default=None, ge=0, le=5)
    sentiment_label: Literal["negative", "neutral", "positive"] | None = None

    @model_validator(mode="after")
    def valid_range(self):
        if self.rating_min is not None and self.rating_max is not None and self.rating_min > self.rating_max:
            raise ValueError("Invalid rating range")
        return self


class SQLResult(Contract):
    sql: str
    columns: list[str]
    rows: list[dict[str, Any]]
    row_count: int
    summary: str
    warnings: list[str] = Field(default_factory=list)


class ProcessingResult(Contract):
    file_id: str
    filename: str
    classification: Literal["UNSTRUCTURED", "STRUCTURED", "HYBRID", "UNSUPPORTED"]
    storage_strategy: list[str]
    table_name: str | None = None
    rows_loaded: int = 0
    records_embedded: int = 0
    skipped_records: int = 0
    warnings: list[str] = Field(default_factory=list)
    status: str = "completed"


ChartKind = Literal["bar", "line", "pie", "table"]
ChartText = Annotated[str, Field(strict=True, min_length=1, max_length=200)]
ChartNumber = Annotated[float, Field(strict=True, allow_inf_nan=False, ge=-1e15, le=1e15)]


class ChartRequest(Contract):
    """The model selects source cells, never supplies chart values or executable markup."""

    kind: ChartKind
    title: ChartText
    source: Literal["sql", "rag", "processing", "user", "document"]
    label_column: ChartText
    value_columns: list[ChartText] = Field(min_length=1, max_length=4)
    row_indices: list[Annotated[int, Field(strict=True, ge=0)]] = Field(min_length=1, max_length=40)
    series_column: ChartText | None = None


class ChartSelection(Contract):
    charts: list[ChartRequest] = Field(max_length=4)
    reason: str = Field(default="", max_length=500)


class DocumentQuote(Contract):
    record_id: ChartText
    quote: str = Field(min_length=1, max_length=1200)


class DocumentChartCell(Contract):
    record_id: ChartText
    value_text: str = Field(min_length=1, max_length=40)
    occurrence: Annotated[int, Field(strict=True, ge=0)] = 0


class DocumentChartRow(Contract):
    label: ChartText
    cells: list[DocumentChartCell] = Field(min_length=1, max_length=4)


class DocumentChartTable(Contract):
    label_column: ChartText
    value_columns: list[ChartText] = Field(min_length=1, max_length=4)
    unit: str = Field(min_length=1, max_length=40)
    scope: str = Field(min_length=1, max_length=100)
    rows: list[DocumentChartRow] = Field(min_length=1, max_length=40)
    partition_record_id: ChartText | None = None


class DocumentChartExtraction(Contract):
    table: DocumentChartTable | None
    reason: str = Field(max_length=500)


class ChartCitation(DocumentQuote):
    filename: str = Field(min_length=1, max_length=1024)
    page_number: int | None = None


class ChartSeries(Contract):
    name: ChartText
    values: list[ChartNumber] = Field(min_length=1, max_length=40)


class ChartSpec(Contract):
    kind: ChartKind
    title: ChartText
    source: ChartText
    label_column: ChartText
    labels: list[ChartText] = Field(min_length=1, max_length=40)
    series: list[ChartSeries] = Field(min_length=1, max_length=4)
    citations: list[ChartCitation] = Field(default_factory=list, max_length=160)

    @model_validator(mode="after")
    def valid_series(self):
        if any(len(s.values) != len(self.labels) for s in self.series):
            raise ValueError("Chart series must match label count")
        if len({s.name for s in self.series}) != len(self.series):
            raise ValueError("Chart series names must be unique")
        if self.kind == "pie" and (
            len(self.series) != 1
            or any(v < 0 for v in self.series[0].values)
            or sum(self.series[0].values) <= 0
        ):
            raise ValueError("Pie charts require one nonnegative series with positive sum")
        return self


class Answer(Contract):
    retrieved_evidence: str = Field(default="", max_length=4000)
    calculated_facts: str = Field(default="", max_length=4000)
    interpretation: str = Field(max_length=6000)
    recommendations: str = Field(default="", max_length=4000)
    limitations: str = Field(default="", max_length=4000)
    citation_ids: list[str] = Field(default_factory=list, max_length=12)


class Review(Contract):
    status: Literal["approved", "revise", "blocked"]
    unsupported_claims: list[str] = Field(default_factory=list, max_length=10)
    conflicts: list[str] = Field(default_factory=list, max_length=10)
    required_changes: list[str] = Field(default_factory=list, max_length=10)
    notes: list[str] = Field(default_factory=list, max_length=10)
    chart_issues: list[Annotated[str, Field(max_length=500)]] = Field(default_factory=list, max_length=10)


class StudioError(Exception):
    def __init__(self, code: str, message: str, status: int = 400, retryable: bool = False):
        super().__init__(message)
        self.code, self.message, self.status, self.retryable = code, message, status, retryable
