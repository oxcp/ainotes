#!/usr/bin/env python3
"""Standalone LangGraph business-analysis service for Modules 3 and 4."""

import asyncio
import json
import logging
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Optional

from .analysis_workflow import (
    BusinessAnalysisWorkflow,
    HorizonDBRepository,
    OpenAIResponsesModel,
)


def _load_dotenv_from_app_dir() -> None:
    env_path = os.path.join(os.path.dirname(__file__), ".env")
    if not os.path.exists(env_path):
        return
    with open(env_path, "r", encoding="utf-8") as env_file:
        for raw_line in env_file:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.removeprefix("export ").split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


_load_dotenv_from_app_dir()

AGENT_ID = os.environ.get("AGENT_ID", "business-analysis-agent")
AGENT_PORT = int(os.environ.get("AGENT_PORT", "8080"))
LOG_LEVEL = os.environ.get("AGENT_LOG_LEVEL", "INFO")

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [%(levelname)s] [%(name)s] %(message)s",
)
logger = logging.getLogger("business-analysis")


class BusinessAnalysisService:
    def __init__(self) -> None:
        self._repository = HorizonDBRepository(os.environ.get("WRITE_DATABASE_URL", ""))
        self._model = OpenAIResponsesModel("AGENT_APIM_ENDPOINT", "LLM_MODEL")
        self._workflow = BusinessAnalysisWorkflow(self._model, self._repository)
        self.history: list[dict[str, str]] = []
        self.ready = False

    async def initialize(self) -> None:
        await self._repository.open()
        self.ready = True
        logger.info("HorizonDB and LangGraph workflow are ready")

    async def analyze(self, requirement: str, business_data: str) -> dict[str, Any]:
        result = await self._workflow.run(requirement, business_data)
        history_item = {
            "query": requirement,
            "response": result["final_report"],
            "analysis_id": result["analysis_id"],
        }
        self.history.append(history_item)
        return {
            "agent_id": AGENT_ID,
            "analysis_id": result["analysis_id"],
            "response": result["final_report"],
            "final_report": result["final_report"],
            "review": result["review"],
        }

    async def close(self) -> None:
        await self._model.close()
        await self._repository.close()


def _load_portal_html() -> str:
    html_path = os.path.join(os.path.dirname(__file__), "portal.html")
    try:
        with open(html_path, "r", encoding="utf-8") as html_file:
            return html_file.read()
    except OSError as error:
        logger.warning("Could not read portal.html: %s", error)
        return "<!DOCTYPE html><html><body><h1>Business Analysis</h1></body></html>"


PORTAL_HTML = _load_portal_html()


class AgentHTTPHandler(BaseHTTPRequestHandler):
    service: Optional[BusinessAnalysisService] = None
    loop: Optional[asyncio.AbstractEventLoop] = None

    def _send_json(self, status: int, value: Any) -> None:
        body = json.dumps(value, ensure_ascii=False, indent=2).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            logger.debug("Client disconnected during JSON response")

    def _send_html(self, status: int, html: str) -> None:
        body = html.encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            logger.debug("Client disconnected during HTML response")

    def do_GET(self) -> None:
        if self.path in ("/", "/index.html"):
            self._send_html(200, PORTAL_HTML)
        elif self.path == "/health":
            self._send_json(200, {"status": "ok", "agent_id": AGENT_ID})
        elif self.path == "/ready":
            ready = bool(self.service and self.service.ready)
            self._send_json(200 if ready else 503, {"status": "ready" if ready else "initializing"})
        elif self.path == "/state":
            history = self.service.history if self.service else []
            self._send_json(200, {"agent_id": AGENT_ID, "history": history})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path not in ("/analyze", "/reflect"):
            self._send_json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 5 * 1024 * 1024:
                raise ValueError("Request body must be between 1 byte and 5 MB")
            payload = json.loads(self.rfile.read(length))
            requirement = str(payload.get("requirement") or payload.get("query") or "").strip()
            business_data = str(payload.get("business_data") or "").strip()
            if not requirement or not business_data:
                raise ValueError("requirement and business_data are required")
            if self.service is None or self.loop is None:
                raise RuntimeError("Service is not initialized")
            future = asyncio.run_coroutine_threadsafe(
                self.service.analyze(requirement, business_data), self.loop
            )
            self._send_json(200, future.result(timeout=180))
        except (ValueError, json.JSONDecodeError) as error:
            self._send_json(400, {"error": str(error)})
        except TimeoutError:
            self._send_json(504, {"error": "Analysis timed out"})
        except Exception as error:
            logger.exception("Analysis request failed")
            self._send_json(500, {"error": str(error)})

    def log_message(self, fmt: str, *args: Any) -> None:
        logger.debug("[HTTP] %s", fmt % args)


async def main() -> None:
    service = BusinessAnalysisService()
    AgentHTTPHandler.service = service
    AgentHTTPHandler.loop = asyncio.get_running_loop()
    await service.initialize()

    http_server = ThreadingHTTPServer(("0.0.0.0", AGENT_PORT), AgentHTTPHandler)
    threading.Thread(target=http_server.serve_forever, daemon=True).start()
    logger.info("Business analysis service listening on 0.0.0.0:%s", AGENT_PORT)
    try:
        while True:
            await asyncio.sleep(3600)
    except (KeyboardInterrupt, asyncio.CancelledError):
        logger.info("Shutting down")
    finally:
        http_server.shutdown()
        await service.close()


if __name__ == "__main__":
    asyncio.run(main())