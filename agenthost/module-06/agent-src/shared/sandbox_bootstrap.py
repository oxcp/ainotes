"""ACA guest entrypoint: await atomic configuration delivery, then exec exactly one Agent."""

import json
import os
import sys
import time
from pathlib import Path

PACKAGES = {
    "chat": "chat_agent",
    "orchestrator": "orchestrator_agent",
    "data-processing": "data_processing_agent",
    "rag": "rag_agent",
    "sql": "sql_agent",
}
CONFIG_PATH = Path("/app/.local/studio-runtime.json")


def load_environment(path: Path) -> dict[str, str]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or any(
        not isinstance(k, str) or not isinstance(v, str) for k, v in value.items()
    ):
        raise ValueError("Sandbox configuration must be a string-to-string environment object")
    return value


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in PACKAGES:
        raise SystemExit("Provide exactly one valid Agent role")
    deadline = time.monotonic() + 600
    while not CONFIG_PATH.exists():
        if time.monotonic() >= deadline:
            raise SystemExit("Sandbox configuration was not delivered within 600 seconds")
        time.sleep(1)
    os.environ.update(load_environment(CONFIG_PATH))
    if sys.platform == "linux":
        if os.getuid() == 0:
            os.setgroups([])
            os.setgid(10001)
            os.setuid(10001)
        if os.getuid() != 10001:
            raise SystemExit("Sandbox Agent must run as UID 10001")
    else:
        raise SystemExit("The ACA guest bootstrap requires Linux")
    os.chdir("/app")
    os.execv(
        sys.executable,
        [
            sys.executable,
            "-m",
            "uvicorn",
            PACKAGES[sys.argv[1]] + ".app:create_app",
            "--factory",
            "--host",
            "0.0.0.0",
            "--port",
            "8080",
        ],
    )


if __name__ == "__main__":
    main()
