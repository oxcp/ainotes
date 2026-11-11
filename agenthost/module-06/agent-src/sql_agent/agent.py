import asyncio
from uuid import UUID

import sqlglot
from sqlglot import exp

from shared.config import Settings
from shared.contracts import SQLProposal, SQLResult, StudioError
from shared.database import Repository
from shared.models import Foundry
from shared.observability import clock, event, failure
from shared.security import SAFE_FUNCTIONS, validate_sql


class SQLAgent:
    def __init__(self, config: Settings, repo: Repository, model: Foundry):
        self.config, self.repo, self.model = config, repo, model

    async def run(self, workspace: UUID, question: str) -> SQLResult:
        catalog = await asyncio.to_thread(self.repo.catalog, workspace)
        if not catalog:
            raise StudioError("NO_DATASET", "No structured dataset is available.", 422)
        prompt = (
            "Generate a single PostgreSQL SELECT using only the supplied "
            "schema. No system catalogs, mutations or unsafe functions. Use exact calculations. "
            "Workspace isolation is applied by the server. "
            "For monthly trends, group/order by year and month_number, and return a unique year-month "
            "text label using CAST(year AS text) || '-' || CASE WHEN month_number < 10 THEN '0' "
            "ELSE '' END || CAST(month_number AS text). Never collapse different years into month_name. "
            "LAG(value) OVER (ORDER BY year, month_number) is supported for previous-month comparisons; "
            "compare consecutive calendar months only and disclose gaps. Sales growth without profit "
            "growth means sales > previous sales AND profit <= previous profit, not merely lower margin. "
            "Compute margin as SUM(profit)/NULLIF(SUM(sales),0), not average row margins. "
            "Return chartable numeric columns with clear units and explicit comparison flags. "
            "Keep SQL compact and below 8000 characters; do not build elaborate coverage descriptions in SQL."
            " Use one top-level SELECT, never a top-level UNION; put unions inside a CTE. "
            "When counting condition-matching reviews from grouped counts, SUM the counts; "
            "COUNT(*) OVER counts grouped rows, not original reviews."
        )
        payload = {
            "question": question,
            "catalog": catalog,
            "supported_functions": sorted(SAFE_FUNCTIONS | {"LAG"}),
        }
        for attempt in range(2):
            proposal = await self.model.structured(prompt, payload, SQLProposal)
            try:
                statement = validate_sql(
                    proposal.sql, {d["table_name"] for d in catalog}, workspace, self.config.sql_row_limit
                )
                break
            except StudioError as exc:
                failure(exc, stage="validate_sql", workspace_id=str(workspace))
                if attempt or exc.code not in {"UNSAFE_SQL", "INVALID_SQL"}:
                    raise
                payload["previous_sql"] = proposal.sql
                payload["validation_error"] = exc.message
        start = clock()
        columns, rows = await asyncio.to_thread(self.repo.query, statement)
        event(
            "sql",
            "completed",
            "Read-only query completed",
            workspace_id=str(workspace),
            latency_ms=str(round((clock() - start) * 1000)),
            row_count=str(len(rows)),
        )
        referenced = {
            table.name for table in sqlglot.parse_one(statement, read="postgres").find_all(exp.Table)
        }
        names = [d.get("name", d["table_name"]) for d in catalog if d["table_name"] in referenced]
        warnings = [
            f"Query scope: {len(names)} catalog dataset(s): "
            + ", ".join(names)
            + ". The bounded catalog is not proof of complete uploaded-file coverage."
        ]
        if len(rows) == self.config.sql_row_limit:
            warnings.append("Results are capped at the configured row limit.")
        return SQLResult(
            sql=statement,
            columns=columns,
            rows=rows,
            row_count=len(rows),
            summary=f"Executed read-only query; returned {len(rows)} rows.",
            warnings=warnings,
        )
