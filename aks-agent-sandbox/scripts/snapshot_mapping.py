"""Persist local Sandbox-to-snapshot associations, scoped to their source identity."""
import json
import os
from pathlib import Path
import sys
import tempfile


FIELDS = ("context", "namespace", "sandbox", "sandbox_uid", "snapshot")


def read_mapping(path: Path) -> list[dict[str, str]]:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return []
    records = json.loads(text)
    if not isinstance(records, list) or any(
        not isinstance(record, dict)
        or any(not isinstance(record.get(field), str) or not record[field] for field in FIELDS)
        for record in records
    ):
        raise ValueError(f"Invalid snapshot mapping: {path}")
    keys = [(record["context"], record["namespace"], record["sandbox"]) for record in records]
    if len(set(keys)) != len(keys):
        raise ValueError(f"Duplicate Sandbox entries in snapshot mapping: {path}")
    return records


def record_snapshot(path: Path, context: str, source: dict, snapshot: str) -> None:
    metadata = source["metadata"]
    record = {
        "context": context,
        "namespace": metadata["namespace"],
        "sandbox": metadata["name"],
        "sandbox_uid": metadata["uid"],
        "snapshot": snapshot,
    }
    if any(not isinstance(value, str) or not value for value in record.values()):
        raise ValueError("Snapshot mapping requires a context, source namespace/name/UID and snapshot name.")
    records = read_mapping(path)
    key = ("context", "namespace", "sandbox")
    records = [item for item in records if any(item[field] != record[field] for field in key)]
    records.append(record)
    _write_mapping(path, records)


def remove_namespace_mappings(path: Path, context: str, namespace: str) -> list[dict[str, str]]:
    records = read_mapping(path)
    removed = [item for item in records if item["context"] == context and item["namespace"] == namespace]
    if removed:
        _write_mapping(path, [item for item in records if item not in removed])
    return removed


def _write_mapping(path: Path, records: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as output:
            temporary = Path(output.name)
            json.dump(records, output, ensure_ascii=False, indent=2)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        record_snapshot(Path(sys.argv[1]), sys.argv[2],
                        json.loads(Path(sys.argv[3]).read_text(encoding="utf-8")), sys.argv[4])
    except (OSError, ValueError, KeyError) as error:
        print(f"ERROR: Cannot record snapshot mapping: {error}", file=sys.stderr)
        sys.exit(1)
