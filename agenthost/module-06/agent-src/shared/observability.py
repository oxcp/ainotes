import json
import logging
import time
from datetime import UTC, datetime

logger = logging.getLogger("studio")


def event(stage: str, status: str, message: str, **ids: str) -> dict:
    record = {
        "stage": stage,
        "status": status,
        "message": message,
        "timestamp": datetime.now(UTC).isoformat(),
        **ids,
    }
    logger.info(json.dumps(record))
    return record


def failure(exc: Exception, **ids: str) -> None:
    # Exception messages can contain connection strings, prompts, or access tokens.
    logger.error(json.dumps({"error_category": type(exc).__name__, **ids}))


def clock() -> float:
    return time.monotonic()
