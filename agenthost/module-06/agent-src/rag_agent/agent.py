import asyncio
from uuid import UUID

from shared.config import Settings
from shared.contracts import Evidence, RagResult, RetrievalStrategy, StudioError
from shared.database import Repository, evidence_filters
from shared.models import Foundry
from shared.retrieval import RETRIEVAL_PROMPT, RetrievalPlan, merge_evidence, retrieval_sources


class RagAgent:
    def __init__(self, config: Settings, repo: Repository, model: Foundry):
        self.config, self.repo, self.model = config, repo, model

    async def run(
        self, workspace: UUID, query: str, filters: dict[str, str], strategy: RetrievalStrategy = "semantic"
    ) -> RagResult:
        if strategy == "review_overview":
            rows = await asyncio.to_thread(self.repo.review_overview, workspace, filters)
            passages = [Evidence.model_validate(row) for row in rows]
            if any(item.workspace_id != str(workspace) for item in passages):
                raise StudioError("ISOLATION_FAILURE", "Retrieval workspace mismatch.", 500)
            truncated = len(passages) > self.config.top_k
            warnings = [
                "Overview covers stored review passages, not skipped/duplicate text. "
                "Passage counts are not review-row counts; use SQL for totals."
            ]
            if truncated:
                warnings.append(
                    f"Only the first {self.config.top_k} stored review passages are shown; "
                    "this bounded subset is not representative of the whole dataset."
                )
            return RagResult(
                status="weak" if truncated else "sufficient" if passages else "insufficient",
                results=passages[: self.config.top_k],
                top_k=self.config.top_k,
                retrieval_method=strategy,
                truncated=truncated,
                warnings=warnings,
            )
        if strategy != "semantic":
            raise StudioError("INVALID_RETRIEVAL", "Unsupported retrieval strategy.", 422)
        evidence_filters(filters)
        documents = await asyncio.to_thread(self.repo.documents, workspace)
        sources = retrieval_sources(documents, filters)
        if not sources:
            return RagResult(
                status="insufficient",
                top_k=self.config.top_k,
                warnings=[
                    "No completed source in the bounded session inventory matches the requested filters."
                ],
            )
        plan = await self.model.structured(
            RETRIEVAL_PROMPT,
            {
                "request": query,
                "sources": [
                    {
                        "source": i,
                        "family": source["family"],
                        "layout": source["layout"],
                        "example_filename": source["filenames"][0],
                    }
                    for i, source in enumerate(sources)
                ],
            },
            RetrievalPlan,
        )
        if any(search.source >= len(sources) for search in plan.searches):
            raise StudioError("INVALID_RETRIEVAL", "Retrieval plan selected an unavailable source.", 422)
        if any(
            search.metadata_only
            and (
                search.review_filter is None
                or search.review_filter.sentiment_label is None
                or (search.review_filter.rating_min is None and search.review_filter.rating_max is None)
            )
            for search in plan.searches
        ):
            raise StudioError(
                "INVALID_RETRIEVAL", "Metadata-only examples require rating and sentiment constraints.", 422
            )
        vectors = await self.model.embed([search.query for search in plan.searches])
        if len(vectors) != len(plan.searches):
            raise StudioError("EMBEDDING_SHAPE", "Retrieval embedding count mismatch.", 502)
        gate = asyncio.Semaphore(3)

        async def search_one(search, vector):
            async with gate:
                filenames = sources[search.source]["filenames"]
                rows = await asyncio.to_thread(
                    self.repo.search,
                    workspace,
                    vector,
                    filters,
                    filenames=filenames,
                    **({"review_filter": search.review_filter} if search.review_filter else {}),
                    **({"metadata_only": True} if search.metadata_only else {}),
                )
                results = [
                    Evidence.model_validate(row)
                    for row in rows
                    if search.metadata_only or row["similarity_score"] >= self.config.relevance_threshold
                ][: self.config.top_k]
                if any(
                    item.workspace_id != str(workspace) or item.filename not in filenames for item in results
                ):
                    raise StudioError("ISOLATION_FAILURE", "Retrieval workspace or source mismatch.", 500)
                return results

        batches = await asyncio.gather(
            *[search_one(search, vector) for search, vector in zip(plan.searches, vectors, strict=True)]
        )
        return merge_evidence(plan, sources, batches, self.config.top_k)
