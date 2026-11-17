import asyncio
import re
from uuid import UUID

import psycopg
import sqlglot
from sqlglot import exp
from sqlglot.optimizer.scope import traverse_scope

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
            "When given the current user request plus a planner goal, preserve the current request's "
            "statistical scope and predicates; perform only its structured-data operations. "
            "For report themes compared with review examples plus rating/sentiment statistics, return "
            "the requested rating/sentiment distributions, not invented keyword-based theme classifiers. "
            "Only use lexical theme counts when explicitly requested; label them as keyword matches, "
            "never semantic support/contradiction. Sentiment labels alone do not measure agreement with "
            "a report or theme, and different keyword sets cannot establish relative theme strength. "
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
            "COUNT(*) OVER counts grouped rows, not original reviews. "
            "In each aggregate SELECT, every nonaggregated selected expression must be grouped. "
            "Compute grouped totals in a CTE, then ratios/window comparisons in an outer SELECT; "
            "do not mix ungrouped detail columns with aggregates or nest aggregates at the same level. "
            "For independent review and financial summaries, aggregate each source family separately; "
            "never join unrelated datasets or use one population as another's denominator. "
            "For financial totals plus qualitative customer needs/report trends, compute only the "
            "requested financial totals; RAG supplies review/report text. Do not add unsolicited "
            "sentiment counts, low-rating proxies or risk/issue/problem keyword counts. "
            "Never label customer-review rows as reports, even through CTE names, aliases or literal "
            "analysis_section labels. Derive each metric from its actual catalog source, not a "
            "similar-looking schema. Negative sentiment is not the same as a low rating. "
            "A non-null review field establishes only potential text availability, not retrieved "
            "quotation evidence, customer needs or a complaint theme. "
            "A single result may combine independent summaries through UNION ALL inside a CTE, with an "
            "explicit analysis_section label, matching column types and NULLs for inapplicable measures. "
            "Keep metric names/units distinct and minimize metrics to those needed by the question. "
            "Use actual catalog filenames, fields and types; a family name is not an exact source filename."
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
            except StudioError as exc:
                failure(exc, stage="validate_sql", workspace_id=str(workspace))
                if attempt or exc.code not in {"UNSAFE_SQL", "INVALID_SQL"}:
                    raise
                payload["previous_sql"] = proposal.sql
                payload["validation_error"] = exc.message
                continue
            start = clock()
            try:
                columns, rows = await asyncio.to_thread(self.repo.query, statement)
                break
            except psycopg.Error as exc:
                sqlstate = exc.sqlstate or ""
                if not re.fullmatch(r"[0-9A-Z]{5}", sqlstate):
                    sqlstate = "unavailable"
                failure(exc, stage="sql_execute", workspace_id=str(workspace), sqlstate=sqlstate)
                if not attempt and sqlstate == "42803":
                    payload["previous_sql"] = proposal.sql
                    payload["validation_error"] = (
                        "PostgreSQL SQLSTATE 42803: grouping error. Correct the aggregate structure: "
                        "group every nonaggregated selected expression, aggregate each source in its "
                        "own CTE, and compute ratios/window comparisons in an outer SELECT. Preserve "
                        "the requested metrics and independent populations. Return a corrected SELECT."
                    )
                    continue
                raise StudioError(
                    "SQL_EXECUTION_FAILED",
                    f"Read-only SQL execution failed (SQLSTATE {sqlstate}). "
                    "No query results were returned; check the SQL worker and database diagnostics.",
                    502,
                ) from exc
        event(
            "sql",
            "completed",
            "Read-only query completed",
            workspace_id=str(workspace),
            latency_ms=str(round((clock() - start) * 1000)),
            row_count=str(len(rows)),
        )
        referenced = {
            source.name
            for scope in traverse_scope(sqlglot.parse_one(statement, read="postgres"))
            for source in scope.sources.values()
            if isinstance(source, exp.Table)
        }
        source_datasets = {
            d["table_name"]: d.get("name", d["table_name"])
            for d in catalog if d["table_name"] in referenced
        }
        names = list(source_datasets.values())
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
            source_datasets=source_datasets,
        )
