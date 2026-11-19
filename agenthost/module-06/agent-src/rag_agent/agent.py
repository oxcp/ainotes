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
        payload = {
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
        }

        def validate_plan(plan: RetrievalPlan):
            if any(search.source >= len(sources) for search in plan.searches):
                raise StudioError("INVALID_RETRIEVAL", "Retrieval plan selected an unavailable source.", 422)
            if any(
                search.metadata_only
                and (
                    search.review_filter is None
                    or not search.review_filter.model_dump(exclude_none=True)
                )
                for search in plan.searches
            ):
                raise StudioError(
                    "INVALID_RETRIEVAL",
                    "Metadata-only examples require rating or sentiment constraints.", 422,
                )

        plan = await self.model.structured(RETRIEVAL_PROMPT, payload, RetrievalPlan)
        validate_plan(plan)
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
        empty = [
            i for i, batch in enumerate(batches) if not batch and not plan.searches[i].metadata_only
        ]
        retried = []
        if empty:
            corrected = await self.model.structured(
                RETRIEVAL_PROMPT
                + "\nThe indexed empty_searches returned no passages. Correct ONLY those searches, "
                "once: remove filenames, schema/output/statistics wording from semantic queries. "
                "Keep search count/order, source indices and review_filter values EXACTLY unchanged. "
                "Keep successful searches unchanged. For generic rating/sentiment examples with no "
                "specific experience/topic requirement, use metadata_only=true; for a requested topic "
                "retain metadata_only=false and improve the topic wording. Do not broaden topics "
                "just to obtain results. Leave a search unchanged if no faithful correction is needed.",
                {**payload, "previous_plan": plan.model_dump(), "empty_searches": empty},
                RetrievalPlan,
            )
            validate_plan(corrected)
            if len(corrected.searches) != len(plan.searches) or any(
                before.source != after.source
                or before.review_filter != after.review_filter
                or (i not in empty and before != after)
                for i, (before, after) in enumerate(zip(plan.searches, corrected.searches))
            ):
                raise StudioError(
                    "INVALID_RETRIEVAL", "Retrieval correction changed the original search scope.", 422
                )
            retried = [i for i in empty if plan.searches[i] != corrected.searches[i]]
            if retried:
                vectors = await self.model.embed([corrected.searches[i].query for i in retried])
                if len(vectors) != len(retried):
                    raise StudioError("EMBEDDING_SHAPE", "Retrieval embedding count mismatch.", 502)
                results = await asyncio.gather(
                    *[search_one(corrected.searches[i], vector) for i, vector in zip(retried, vectors, strict=True)]
                )
                for i, batch in zip(retried, results, strict=True):
                    batches[i] = batch
                plan = corrected
        result = merge_evidence(plan, sources, batches, self.config.top_k)
        if retried:
            result.warnings.insert(
                0,
                f"Empty searches {retried} were retried once with corrected retrieval queries; "
                "source and review metadata constraints were preserved. Topic searches retain "
                "the relevance threshold; metadata-only examples do not establish dominant themes.",
            )
        return result
