from uuid import UUID

import sqlglot
from sqlglot import exp
from sqlglot.optimizer.scope import traverse_scope

from shared.contracts import StudioError

SAFE_FUNCTIONS = {
    "SUM",
    "AVG",
    "COUNT",
    "MIN",
    "MAX",
    "ROUND",
    "ABS",
    "COALESCE",
    "NULLIF",
    "LOWER",
    "UPPER",
    "TRIM",
    "LENGTH",
    "CAST",
    "EXTRACT",
    "DATE_TRUNC",
    "ROW_NUMBER",
    "RANK",
    "DENSE_RANK",
}


def validate_sql(statement: str, tables: set[str], workspace: UUID, limit: int) -> str:
    def reject(reason: str = "Only bounded read-only queries over approved workspace tables are allowed."):
        raise StudioError("UNSAFE_SQL", reason)

    try:
        trees = sqlglot.parse(statement, read="postgres")
    except sqlglot.errors.ParseError as exc:
        raise StudioError("INVALID_SQL", "Generated SQL could not be parsed.") from exc
    if len(trees) != 1 or not isinstance(trees[0], exp.Select):
        reject(
            "Require one top-level SELECT. Put UNION/UNION ALL inside a CTE or subquery, "
            "then SELECT from it; do not emit a top-level UNION or multiple statements."
        )
    tree = trees[0]
    assert tree is not None
    forbidden = (
        exp.Insert,
        exp.Update,
        exp.Delete,
        exp.Drop,
        exp.Create,
        exp.Alter,
        exp.Command,
        exp.Into,
        exp.Lock,
        exp.Parameter,
        exp.Placeholder,
    )
    if any(isinstance(node, forbidden) for node in tree.walk()) or len(list(tree.find_all(exp.Join))) > 3:
        reject()
    for func in tree.find_all(exp.Func):
        name = func.name.upper() if isinstance(func, exp.Anonymous) else func.sql_name().upper()
        # SQLGlot also models boolean operators as Func; their children are still checked.
        if name not in SAFE_FUNCTIONS and not isinstance(func, (exp.Case, exp.If, exp.And, exp.Or, exp.Lag)):
            reject(f"Unsupported SQL function: {name}. Use only approved functions.")
    physical: list[exp.Table] = []
    for scope in traverse_scope(tree):
        for source in scope.sources.values():
            if isinstance(source, exp.Table):
                if source.catalog or source.db or source.name not in tables:
                    reject()
                physical.append(source)
    if not physical:
        reject()
    for table in physical:
        alias = table.alias_or_name
        inner = (
            exp.select("*")
            .from_(exp.to_table(table.name))
            .where(exp.column("workspace_id").eq(exp.Literal.string(str(workspace))))
        )
        table.replace(inner.subquery(alias=alias))
    requested_limit = tree.args.get("limit")
    if requested_limit is not None:
        value = requested_limit.expression
        if not isinstance(value, exp.Literal) or not value.is_int or int(value.this) < 0:
            reject()
        limit = min(limit, int(value.this))
    tree.set("limit", exp.Limit(expression=exp.Literal.number(limit)))
    tree.set("offset", None)
    return tree.sql(dialect="postgres")
