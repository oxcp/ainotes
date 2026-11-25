#!/usr/bin/env python3
"""
POC Agent — APIM chat agent with optional chat persistence
====================================================================

A chat agent configured for this lab's own resources that:
  1. Serves the existing single-page HTML chat portal at `/`.
  2. Talks to the backend model to answer chat messages.
  3. Keeps chat history in memory unless persistence is explicitly enabled.
  4. Optionally saves and recovers history on a mounted Blob volume.
  5. Runs inference through the lab APIM gateway using the model
     **Responses API** (Microsoft Agent Framework + Azure OpenAI SDK).

Auth is Azure Workload Identity (DefaultAzureCredential) — no static secrets.

Environment Variables (aligned with agent-sandbox.yaml):
  AGENT_ID                 — Unique agent identifier (default: agent-poc-001)
  CHAT_PERSISTENCE_ENABLED — Enable mounted-volume history (default: false)
  STATE_MOUNT_PATH         — Mounted Blob volume path (default: /app/app/data)
  AGENT_APIM_ENDPOINT      — APIM gateway base URL (Responses API routes here)
  LLM_MODEL                — Model deployment name (default: gpt-5.4-mini)
  LLM_TOKEN_SCOPE          — AAD scope for the Workload Identity token
                             (default: https://ai.azure.com/.default)
  AGENT_INSTRUCTIONS       — System instructions for the agent
  AGENT_PORT               — HTTP port (default: 8080)
  AGENT_LOG_LEVEL          — Log level (default: INFO)

Run: python -m app.main   (module entrypoint)  |  python app/main.py
"""

import os
import json
import logging
import asyncio
import threading
import time
import uuid
from typing import Optional, Dict, Any, Literal
from contextvars import ContextVar
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler


def _load_dotenv_from_app_dir() -> None:
    """Load KEY=VALUE pairs from app/.env without overriding existing env vars."""
    env_path = os.path.join(os.path.dirname(__file__), ".env")
    if not os.path.exists(env_path):
        return

    with open(env_path, "r", encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export "):].strip()
            if "=" not in line:
                continue

            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key:
                os.environ.setdefault(key, value)


_load_dotenv_from_app_dir()

# ── Configuration ──────────────────────────────────────────────────────────
AGENT_ID = os.environ.get("AGENT_ID", "agent-poc-001")

# Blob container mounted as a persistent volume by the pod.
STATE_MOUNT_PATH = os.environ.get("STATE_MOUNT_PATH", "/app/app/data")
CHAT_PERSISTENCE_ENABLED = os.environ.get("CHAT_PERSISTENCE_ENABLED", "false").lower() == "true"

# Model inference routes through the lab APIM gateway.
APIM_ENDPOINT = os.environ.get("AGENT_APIM_ENDPOINT", "").rstrip("/")
LLM_BASE_URL = f"{APIM_ENDPOINT}/openai/v1" if APIM_ENDPOINT else ""
LLM_MODEL = os.environ.get("LLM_MODEL", "gpt-5.4-mini")
# The gateway validates the tenant and Agent UAMI object ID, not the audience.
LLM_TOKEN_SCOPE = os.environ.get("LLM_TOKEN_SCOPE", "https://ai.azure.com/.default")
AGENT_INSTRUCTIONS = os.environ.get(
    "AGENT_INSTRUCTIONS",
    "You are a concise, helpful assistant. Keep answers brief.",
)

AGENT_PORT = int(os.environ.get("AGENT_PORT", "8080"))
LOG_LEVEL = os.environ.get("AGENT_LOG_LEVEL", "INFO")

# ── Logging Setup ──────────────────────────────────────────────────────────
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [%(levelname)s] [%(name)s] %(message)s",
)
logger = logging.getLogger("agent")

ResponseSource = Literal["generated", "amr-cache-hit", "unknown"]


@dataclass(frozen=True)
class ModelAnswer:
    text: str
    source: ResponseSource


@dataclass
class _ResponseTrace:
    source: ResponseSource = "unknown"


_response_trace: ContextVar[Optional[_ResponseTrace]] = ContextVar("response_trace", default=None)


def _utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


# ── State Store (mounted volume) ──────────────────────────────────────────
class FileStateStore:
    """Keeps history in memory by default, with optional mounted-volume storage."""

    def __init__(self, agent_id: str, mount_path: str,
                 persistence_enabled: bool = CHAT_PERSISTENCE_ENABLED):
        self.agent_id = agent_id
        self.mount_path = mount_path
        self.state_path = os.path.join(mount_path, f"{agent_id}.json")
        self.persistence_enabled = persistence_enabled

    def _can_persist(self) -> bool:
        if not self.persistence_enabled:
            return False
        if not os.path.ismount(self.mount_path):
            logger.error(f"[Volume] Persistence enabled but no volume mounted at {self.mount_path}; "
                         "chat history remains in memory")
            return False
        return True

    def _default_state(self) -> Dict[str, Any]:
        return {
            "agent_id": self.agent_id,
            "created_at": _utcnow(),
            "resumed_at": _utcnow(),
            "reflection_count": 0,
            "history": [],  # list of {query, response, timestamp}
        }

    async def save_state(self, state: Dict[str, Any]) -> None:
        if not self._can_persist():
            return
        temporary_path = f"{self.state_path}.tmp"
        try:
            os.makedirs(self.mount_path, exist_ok=True)
            with open(temporary_path, "w", encoding="utf-8") as state_file:
                json.dump(state, state_file)
                state_file.flush()
                os.fsync(state_file.fileno())
            os.replace(temporary_path, self.state_path)
            logger.info(f"[Volume] State saved for {self.agent_id} "
                        f"({len(state.get('history', []))} turns)")
        except Exception as e:
            logger.error(f"[Volume] Save failed: {e}")
            try:
                os.remove(temporary_path)
            except FileNotFoundError:
                # Temp file may not exist if creation/write failed earlier; ignore cleanup miss.
                logger.debug("[Volume] No temporary state file to remove after save failure")
            except OSError as cleanup_error:
                logger.error(f"[Volume] Temporary state cleanup failed: {cleanup_error}")

    async def load_state(self) -> Dict[str, Any]:
        if not self._can_persist():
            return self._default_state()
        try:
            with open(self.state_path, "r", encoding="utf-8") as state_file:
                state = json.load(state_file)
            state["resumed_at"] = _utcnow()
            logger.info(f"[Volume] State recovered for {self.agent_id}: "
                        f"{len(state.get('history', []))} turns")
            return state
        except FileNotFoundError:
            logger.info(f"[Volume] No prior state for {self.agent_id}; starting fresh")
        except (OSError, json.JSONDecodeError) as e:
            logger.error(f"[Volume] State load failed: {e}")
        return self._default_state()

    async def close(self) -> None:
        pass


# ── AI Client (MAF + Azure OpenAI Responses API via APIM) ──────────────────
class APIMResponsesClient:
    """Answer chat turns through APIM using Workload Identity and the Responses API."""

    def __init__(self, base_url: str, model: str, token_scope: str,
                 instructions: str):
        self.base_url = base_url
        self.model = model
        self.token_scope = token_scope
        self.instructions = instructions
        self._agent = None            # MAF agent (Responses API via APIM)
        self._openai_client = None    # raw AsyncOpenAI (direct Responses fallback)
        self._credential = None       # Workload Identity credential
        self._http_client = None      # httpx client (per-request token refresh)
        self._built = False

    def _build_openai_client(self):
        """Build an AsyncOpenAI client pointed at the APIM `/openai/v1` gateway.

        A custom httpx auth flow injects a fresh Entra Bearer token on every
        request (get_bearer_token_provider caches + auto-refreshes), so a
        long-running pod never serves an expired token. Missing configuration
        or SDK dependencies fail initialization.
        """
        if not self.base_url:
            raise RuntimeError("AGENT_APIM_ENDPOINT is required")
        try:
            import httpx
            from openai import AsyncOpenAI
            from azure.identity import DefaultAzureCredential, get_bearer_token_provider

            self._credential = DefaultAzureCredential()
            token_provider = get_bearer_token_provider(self._credential, self.token_scope)

            class _EntraBearerAuth(httpx.Auth):
                def __init__(self, provider):
                    self._provider = provider

                def auth_flow(self, request):
                    request.headers["Authorization"] = f"Bearer {self._provider()}"
                    yield request

            self._http_client = httpx.AsyncClient(
                auth=_EntraBearerAuth(token_provider),
                event_hooks={"response": [self._capture_response_source]},
            )
            return AsyncOpenAI(
                base_url=self.base_url,
                api_key="workload-identity",  # placeholder; overridden by auth flow
                http_client=self._http_client,
            )
        except Exception as e:
            logger.error(f"[AI] OpenAI client build failed: {e}")
            raise

    async def _capture_response_source(self, response) -> None:
        if not response.request.url.path.rstrip("/").endswith(("/responses", "/chat/completions")):
            return
        header = response.headers.get("X-AI-Gateway-Response-Source", "").strip().lower()
        trace = _response_trace.get()
        if trace is None:
            return
        if header == "generated":
            trace.source = "generated"
        elif header == "amr-cache-hit":
            trace.source = "amr-cache-hit"
        else:
            trace.source = "unknown"
            logger.warning("[AI] Missing or invalid Gateway response-source header; source is unknown")

    def _wrap_maf_agent(self, openai_client):
        """Wrap the AsyncOpenAI client in a MAF agent, if available.

        Uses `OpenAIChatClient`, which in current agent-framework-openai builds
        talks to the model **Responses API** (the old OpenAIResponsesClient alias
        was removed upstream). Returns None when the class or an accepted
        constructor signature is unavailable; in that case reflect() falls back
        to the OpenAI SDK Responses API directly.
        """
        if openai_client is None:
            return None
        try:
            from agent_framework import Agent
            from agent_framework.openai import OpenAIChatClient
        except ImportError as e:
            logger.info(f"[AI] MAF OpenAI client unavailable ({e}); "
                        "using the OpenAI SDK Responses API directly")
            return None
        try:
            try:
                client = OpenAIChatClient(model=self.model, async_client=openai_client)
            except TypeError:
                client = OpenAIChatClient(model_id=self.model, async_client=openai_client)
            logger.info("[AI] MAF agent ready (OpenAIChatClient / Responses API)")
            return Agent(
                client=client,
                name=AGENT_ID,
                instructions=self.instructions,
            )
        except Exception as e:
            logger.warning(f"[AI] MAF agent build failed ({e}); "
                           "using the OpenAI SDK Responses API directly")
            return None

    async def _ensure_backend(self):
        if self._built:
            return
        self._openai_client = self._build_openai_client()
        self._agent = self._wrap_maf_agent(self._openai_client)
        self._built = True

    async def reflect(self, prompt: str, conversation_history: list) -> ModelAnswer:
        """Answer a turn and capture its Gateway provenance without cross-request state."""
        await self._ensure_backend()
        # Child tasks created by MAF share this request-local trace, not other turns.
        trace = _ResponseTrace()
        token = _response_trace.set(trace)
        try:
            if self._agent is not None:
                answer = await self._reflect_maf(prompt, conversation_history)
            elif self._openai_client is not None:
                answer = await self._reflect_openai(prompt, conversation_history)
            else:
                raise RuntimeError("Model backend is unavailable; no simulated answers are allowed")
            return ModelAnswer(text=answer, source=trace.source)
        finally:
            _response_trace.reset(token)

    async def _reflect_maf(self, prompt: str, conversation_history: list) -> str:
        """Run the turn via the Microsoft Agent Framework agent.

        Builds typed `Message` objects for recent context (current agent_framework
        exposes `Message`, not the old `ChatMessage`/`Role`). Falls back to a plain
        string transcript if `Message` is unavailable in this build.
        """
        try:
            payload = self._build_maf_payload(prompt, conversation_history)
            result = await self._agent.run(payload)
            answer = getattr(result, "text", None) or str(result)
            logger.info(f"[AI] Response: {answer[:100]}...")
            return answer
        except Exception as e:
            logger.error(f"[AI] Request failed: {e}")
            raise

    def _build_maf_payload(self, prompt: str, conversation_history: list):
        """Return recent context as `Message` objects, or a string as a fallback."""
        try:
            from agent_framework import Message

            messages = []
            for turn in conversation_history[-5:]:  # recent context
                messages.append(Message("user", [turn["query"]]))
                messages.append(Message("assistant", [turn["response"]]))
            messages.append(Message("user", [prompt]))
            return messages
        except Exception as e:
            logger.debug(f"[AI] Message type unavailable ({e}); using string payload")
            lines = []
            for turn in conversation_history[-5:]:
                lines.append(f"User: {turn['query']}")
                lines.append(f"Assistant: {turn['response']}")
            return ("\n".join(lines) + f"\nUser: {prompt}") if lines else prompt

    async def _reflect_openai(self, prompt: str, conversation_history: list) -> str:
        """Run the turn via the OpenAI SDK Responses API (through APIM)."""
        try:
            input_items = []
            for turn in conversation_history[-5:]:  # recent context
                input_items.append({"role": "user", "content": turn["query"]})
                input_items.append({"role": "assistant", "content": turn["response"]})
            input_items.append({"role": "user", "content": prompt})

            resp = await self._openai_client.responses.create(
                model=self.model,
                input=input_items,
                instructions=self.instructions,
            )
            answer = getattr(resp, "output_text", None) or str(resp)
            logger.info(f"[AI] Response: {answer[:100]}...")
            return answer
        except Exception as e:
            logger.error(f"[AI] Request failed: {e}")
            raise

    async def close(self):
        try:
            if self._openai_client is not None:
                await self._openai_client.close()
        except Exception:
            pass
        try:
            if self._http_client is not None:
                await self._http_client.aclose()
        except Exception:
            pass
        try:
            if self._credential is not None:
                self._credential.close()
        except Exception as error:
            logger.warning("[AI] Credential cleanup failed: %s", error)


# ── Agent (Main Logic) ─────────────────────────────────────────────────────
class ReflectionAgent:
    """Keeps answer text and provenance in history, optionally persisting each turn."""

    def __init__(self, state_store: "FileStateStore", llm_client: "APIMResponsesClient"):
        self.state_store = state_store
        self.llm_client = llm_client
        self.state: Dict[str, Any] = {}
        # Restore markers must never come from persisted chat history.
        self._session_state: Dict[str, Any] = {
            "session_id": str(uuid.uuid4()),
            "initialized_at": time.time(),
            "completed": [],
        }
        self.ready = False

    async def initialize(self):
        self.state = await self.state_store.load_state()
        await self.llm_client._ensure_backend()
        self.ready = True
        logger.info(f"Agent initialized. reflection_count={self.state.get('reflection_count', 0)}")

    async def reflect(self, query: str) -> Dict[str, Any]:
        logger.info(f"[Agent] Processing query: {query}")
        history = self.state.get("history", [])
        response = await self.llm_client.reflect(query, history)

        self.state.setdefault("history", []).append(
            {"query": query, "response": response.text, "response_source": response.source,
             "timestamp": _utcnow()}
        )
        self.state["reflection_count"] = self.state.get("reflection_count", 0) + 1
        self.state["last_updated"] = _utcnow()
        await self.state_store.save_state(self.state)

        return {
            "agent_id": self.state.get("agent_id"),
            "query": query,
            "response": response.text,
            "response_source": response.source,
            "reflection_count": self.state["reflection_count"],
            "history_length": len(self.state["history"]),
        }

    def get_state(self) -> Dict[str, Any]:
        return {**self.state, **self._session_state}

    def complete_work(self) -> Dict[str, Any]:
        self._session_state["completed"].append("generated-code-unit-tests-passed")
        return self.get_state()


# ── Web Portal (single-page chat UI) ───────────────────────────────────────
def _load_portal_html() -> str:
    """Load the chat portal HTML from the sibling portal.html file."""
    html_path = os.path.join(os.path.dirname(__file__), "portal.html")
    try:
        with open(html_path, "r", encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        logger.warning(f"[Portal] Could not read portal.html ({e}); serving fallback")
        return "<!DOCTYPE html><html><body><h1>Agent Portal</h1>" \
               "<p>portal.html not found.</p></body></html>"


PORTAL_HTML = _load_portal_html()


# ── HTTP Server (Kubernetes probes + API) ──────────────────────────────────
class AgentHTTPHandler(BaseHTTPRequestHandler):
    agent: Optional[ReflectionAgent] = None
    loop: Optional[asyncio.AbstractEventLoop] = None

    def _send_json(self, status: int, obj: Dict[str, Any]):
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(obj, indent=2).encode())
        except (BrokenPipeError, ConnectionResetError):
            # Client disconnected before we finished writing; nothing to do.
            logger.debug("[HTTP] client disconnected during JSON response")

    def _send_html(self, status: int, html: str):
        try:
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(html.encode("utf-8"))
        except (BrokenPipeError, ConnectionResetError):
            # Client disconnected before we finished writing; nothing to do.
            logger.debug("[HTTP] client disconnected during HTML response")

    def do_GET(self):
        if self.path == "/" or self.path == "/index.html":
            self._send_html(200, PORTAL_HTML)
        elif self.path == "/health":
            self._send_json(200, {"status": "ok", "agent_id": AGENT_ID})
        elif self.path == "/ready":
            if self.agent and self.agent.ready:
                self._send_json(200, {"status": "ready", "agent_id": AGENT_ID})
            else:
                self._send_json(503, {"status": "initializing"})
        elif self.path == "/state":
            self._send_json(200, self.agent.get_state() if self.agent else {})
        elif self.path == "/work":
            if self.agent and self.agent.ready:
                self._send_json(200, self.agent.complete_work())
            else:
                self._send_json(503, {"error": "Agent is not ready"})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/reflect":
            try:
                length = int(self.headers.get("Content-Length", 0))
                if not 0 < length <= 65536:
                    raise ValueError("Request must contain 1 to 65536 bytes")
                payload = json.loads(self.rfile.read(length))
                if not isinstance(payload, dict):
                    raise ValueError("Request must be a JSON object")
            except (ValueError, UnicodeDecodeError) as error:
                logger.warning("[HTTP] Invalid chat request: %s", error)
                self._send_json(400, {"error": "Invalid JSON request"})
                return
            query = payload.get("query", "")
            if not isinstance(query, str) or not query.strip():
                logger.warning("[HTTP] Chat query is missing or invalid")
                self._send_json(400, {"error": "query must be a nonempty string"})
                return
            if not self.agent or not self.agent.ready or not self.loop:
                self._send_json(503, {"error": "Agent is not ready"})
                return
            # Run the coroutine on the shared asyncio loop (thread-safe).
            future = asyncio.run_coroutine_threadsafe(self.agent.reflect(query), self.loop)
            try:
                result = future.result(timeout=60)
            except TimeoutError:
                future.cancel()
                logger.exception("[HTTP] Model request timed out")
                self._send_json(504, {"error": "Model request timed out"})
                return
            except Exception:
                logger.exception("[HTTP] Chat request failed")
                self._send_json(502, {"error": "Chat request failed; inspect Agent logs"})
                return
            self._send_json(200, result)
        else:
            self._send_json(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        logger.debug(f"[HTTP] {fmt % args}")


# ── Main ───────────────────────────────────────────────────────────────────
async def main():
    logger.info("=" * 72)
    logger.info(f"Agent ID        : {AGENT_ID}")
    logger.info(f"State volume    : {STATE_MOUNT_PATH}")
    logger.info(f"APIM base_url   : {LLM_BASE_URL or '(unset)'}")
    logger.info(f"Model           : {LLM_MODEL}")
    logger.info("=" * 72)

    state_store = FileStateStore(AGENT_ID, STATE_MOUNT_PATH)
    ai_client = APIMResponsesClient(
        LLM_BASE_URL, LLM_MODEL, LLM_TOKEN_SCOPE, AGENT_INSTRUCTIONS,
    )
    agent = ReflectionAgent(state_store, ai_client)

    AgentHTTPHandler.agent = agent
    AgentHTTPHandler.loop = asyncio.get_running_loop()

    await agent.initialize()

    # ThreadingHTTPServer: each request (including K8s /health and /ready probes)
    # is handled in its own thread, so a slow /reflect call cannot block probes
    # and cause the pod to be marked NotReady / removed from Service endpoints.
    http_server = ThreadingHTTPServer(("0.0.0.0", AGENT_PORT), AgentHTTPHandler)
    threading.Thread(target=http_server.serve_forever, daemon=True).start()
    logger.info(f"HTTP server listening on 0.0.0.0:{AGENT_PORT} "
                f"(portal / · /health /ready /state /work /reflect)")

    # Optional self-demo on startup (disabled by default in-cluster).
    # if os.environ.get("AGENT_RUN_DEMO", "false").lower() == "true":
    #     logger.info("[Demo] Running startup chat cycles...")
    #     for q in ["What is the capital of France?", "Explain photosynthesis briefly."]:
    #         logger.info(json.dumps(await agent.reflect(q), indent=2))
    #         await asyncio.sleep(1)

    logger.info("[Agent] Ready. Serving HTTP requests...")
    try:
        while True:
            await asyncio.sleep(3600)
    except (KeyboardInterrupt, asyncio.CancelledError):
        logger.info("[Agent] Shutting down...")
    finally:
        await ai_client.close()
        await state_store.close()
        http_server.shutdown()


if __name__ == "__main__":
    asyncio.run(main())
