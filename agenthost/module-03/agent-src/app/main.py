#!/usr/bin/env python3
"""
POC Agent — Foundry catalog agent with Blob-persisted chat history
==================================================================

A small, clear agent for Module 3 (Solution B) that:
  1. Serves the existing single-page HTML chat portal at `/`.
  2. Talks to the backend model to answer chat messages.
  3. Registers a PERSISTENT agent in the Foundry project so it is visible and
     manageable in the Foundry agent catalog (via azure-ai-projects).
  4. Persists conversation state to Azure Blob Storage.
  5. Recovers previous conversation history from Blob on startup.
  6. Runs inference through the Module 1 APIM gateway using the model
     **Responses API** (Microsoft Agent Framework + Azure OpenAI SDK).

Auth is Azure Workload Identity (DefaultAzureCredential) — no static secrets.

Environment Variables (aligned with agent-sandbox.yaml):
  AGENT_ID                 — Unique agent identifier (default: agent-poc-001)
  AGENT_STORAGE_ACCOUNT    — Storage account for Blob state persistence
  AGENT_BLOB_CONTAINER     — Blob container for state (default: agent-state)
  FOUNDRY_PROJECT_ENDPOINT — Foundry project endpoint, e.g.
                             https://<account>.services.ai.azure.com/api/projects/<project>
  FOUNDRY_AGENT_NAME       — Persistent agent name to create/reuse in the catalog
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
from typing import Optional, Dict, Any
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler


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

# Blob state persistence (Module 1 storage account + container).
STORAGE_ACCOUNT = os.environ.get("AGENT_STORAGE_ACCOUNT", "")
BLOB_CONTAINER = os.environ.get("AGENT_BLOB_CONTAINER", "agent-state")

# Foundry project (catalog visibility) — a persistent agent is created/reused here.
FOUNDRY_PROJECT_ENDPOINT = os.environ.get("FOUNDRY_PROJECT_ENDPOINT", "").rstrip("/")
FOUNDRY_AGENT_NAME = os.environ.get("FOUNDRY_AGENT_NAME", "agenthost-reflection-agent")

# Model inference: the Responses API routes through the Module 1 APIM gateway.
APIM_ENDPOINT = os.environ.get("AGENT_APIM_ENDPOINT", "").rstrip("/")
LLM_BASE_URL = f"{APIM_ENDPOINT}/openai/v1" if APIM_ENDPOINT else ""
LLM_MODEL = os.environ.get("LLM_MODEL", "gpt-5.4-mini")
# Workload Identity token scope. The Module 1 gateway validate-jwt checks the
# issuer (tenant) only, so the Foundry data-plane scope works.
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


def _utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


# ── State Store (Azure Blob) ───────────────────────────────────────────────
class BlobStateStore:
    """Persists agent conversation state as a JSON blob (survives restarts).

    Auth: DefaultAzureCredential (Azure Workload Identity in AKS). The Module 1
    UAMI has \"Storage Blob Data Contributor\" on the storage account.
    """

    def __init__(self, agent_id: str, storage_account: str, container: str):
        self.agent_id = agent_id
        self.storage_account = storage_account
        self.container = container
        self.blob_name = f"{agent_id}.json"
        self._service = None
        self._credential = None

    def _default_state(self) -> Dict[str, Any]:
        return {
            "agent_id": self.agent_id,
            "created_at": _utcnow(),
            "resumed_at": _utcnow(),
            "reflection_count": 0,
            "history": [],  # list of {query, response, timestamp}
        }

    async def _blob_client(self):
        """Lazily create the blob client. Returns None if Blob is unavailable."""
        if not self.storage_account:
            return None
        if self._service is None:
            try:
                from azure.storage.blob.aio import BlobServiceClient
                from azure.identity.aio import DefaultAzureCredential

                self._credential = DefaultAzureCredential()
                self._service = BlobServiceClient(
                    account_url=f"https://{self.storage_account}.blob.core.windows.net",
                    credential=self._credential,
                )
                container = self._service.get_container_client(self.container)
                try:
                    await container.create_container()
                except Exception:
                    pass  # already exists
            except Exception as e:
                logger.warning(f"[Blob] Unavailable ({e}); state not persisted")
                self._service = None
                return None
        return self._service.get_blob_client(
            container=self.container, blob=self.blob_name
        )

    async def save_state(self, state: Dict[str, Any]) -> None:
        blob = await self._blob_client()
        if blob is None:
            return
        try:
            await blob.upload_blob(json.dumps(state), overwrite=True)
            logger.info(f"[Blob] State saved for {self.agent_id} "
                        f"({len(state.get('history', []))} turns)")
        except Exception as e:
            logger.error(f"[Blob] Save failed: {e}")

    async def load_state(self) -> Dict[str, Any]:
        blob = await self._blob_client()
        if blob is not None:
            try:
                stream = await blob.download_blob()
                raw = await stream.readall()
                state = json.loads(raw)
                state["resumed_at"] = _utcnow()
                logger.info(f"[Blob] State recovered for {self.agent_id}: "
                            f"{len(state.get('history', []))} turns")
                return state
            except Exception as e:
                logger.info(f"[Blob] No prior state ({e}); starting fresh")
        return self._default_state()

    async def close(self) -> None:
        try:
            if self._service is not None:
                await self._service.close()
            if self._credential is not None:
                await self._credential.close()
        except Exception:
            pass


# ── AI Client (MAF + Azure OpenAI Responses API via APIM) ──────────────────
class FoundryResponsesClient:
    """Backend AI client.

    Responsibilities:
      • Register a PERSISTENT agent in the Foundry project so it is visible and
        manageable in the Foundry agent catalog (azure-ai-projects).
      • Answer chat turns using the model **Responses API**, routed through the
        Module 1 APIM gateway, built with the Microsoft Agent Framework on top of
        the Azure OpenAI SDK. Auth: Workload Identity (DefaultAzureCredential).
    """

    def __init__(self, base_url: str, model: str, token_scope: str,
                 instructions: str, foundry_endpoint: str, foundry_agent_name: str):
        self.base_url = base_url
        self.model = model
        self.token_scope = token_scope
        self.instructions = instructions
        self.foundry_endpoint = foundry_endpoint
        self.foundry_agent_name = foundry_agent_name
        self._agent = None            # MAF agent (Responses API via APIM)
        self._credential = None       # async credential (catalog registration)
        self._project_client = None   # AIProjectClient (catalog registration)
        self._http_client = None      # httpx client (per-request token refresh)
        self._built = False

    async def _register_catalog_agent(self) -> None:
        """Create/reuse the persistent agent in the Foundry catalog (visible)."""
        if not self.foundry_endpoint:
            logger.warning("[Foundry] FOUNDRY_PROJECT_ENDPOINT unset; "
                           "skipping catalog registration")
            return
        try:
            from azure.ai.projects.aio import AIProjectClient
            from azure.identity.aio import DefaultAzureCredential
        except ImportError as e:
            logger.warning(f"[Foundry] SDK not installed ({e}); skipping catalog")
            return
        try:
            self._credential = DefaultAzureCredential()
            self._project_client = AIProjectClient(
                endpoint=self.foundry_endpoint, credential=self._credential
            )
            existing = None
            async for a in self._project_client.agents.list_agents():
                if getattr(a, "name", None) == self.foundry_agent_name:
                    existing = a
                    break
            if existing is None:
                created = await self._project_client.agents.create_agent(
                    model=self.model,
                    name=self.foundry_agent_name,
                    instructions=self.instructions,
                )
                logger.info(f"[Foundry] Created catalog agent "
                            f"'{self.foundry_agent_name}' (id={created.id})")
            else:
                logger.info(f"[Foundry] Reusing catalog agent "
                            f"'{self.foundry_agent_name}' (id={existing.id})")
        except Exception as e:
            logger.warning(f"[Foundry] Catalog registration failed: {e}")

    def _build_responses_agent(self):
        """Build a MAF agent that calls the model Responses API through APIM.

        APIM exposes the OpenAI-compatible `/openai/v1` shape, so we use the
        (non-Azure) OpenAIResponsesClient. Its api_key is a plain string and is
        NOT refreshed, while Entra (Workload Identity) tokens expire (~1h). To
        keep a long-running pod healthy we attach a custom httpx auth flow that
        injects a freshly-provided Bearer token on every request.
        """
        if not self.base_url:
            logger.warning("[AI] No APIM base_url; simulating responses")
            return None
        try:
            from agent_framework import Agent
            from agent_framework.openai import OpenAIResponsesClient
        except ImportError as e:
            logger.warning(f"[AI] agent_framework not installed ({e}); simulating")
            return None
        try:
            from azure.identity import DefaultAzureCredential, get_bearer_token_provider
            token_provider = get_bearer_token_provider(
                DefaultAzureCredential(), self.token_scope
            )
        except Exception as e:
            logger.warning(f"[AI] Workload Identity unavailable: {e}")
            return None
        try:
            client = self._make_responses_client(OpenAIResponsesClient, token_provider)
            logger.info(f"[AI] Responses agent ready (base_url={self.base_url})")
            return Agent(
                client=client,
                name=self.foundry_agent_name,
                instructions=self.instructions,
            )
        except Exception as e:
            logger.warning(f"[AI] Agent build failed: {e}")
            return None

    def _make_responses_client(self, responses_cls, token_provider):
        """OpenAI-compatible Responses client with per-request Entra token refresh.

        Preferred: wrap an AsyncOpenAI whose httpx auth injects a fresh Bearer
        token each request (get_bearer_token_provider caches + auto-refreshes).
        Fallback: pass a resolved token string as api_key (expires ~1h).
        """
        try:
            import httpx
            from openai import AsyncOpenAI

            class _EntraBearerAuth(httpx.Auth):
                def __init__(self, provider):
                    self._provider = provider

                def auth_flow(self, request):
                    request.headers["Authorization"] = f"Bearer {self._provider()}"
                    yield request

            self._http_client = httpx.AsyncClient(auth=_EntraBearerAuth(token_provider))
            async_client = AsyncOpenAI(
                base_url=self.base_url,
                api_key="workload-identity",  # placeholder; overridden by auth flow
                http_client=self._http_client,
            )
            return responses_cls(model_id=self.model, async_client=async_client)
        except Exception as e:
            logger.warning(f"[AI] async_client path unavailable ({e}); "
                           "falling back to a resolved token string")
            return responses_cls(
                model_id=self.model, base_url=self.base_url, api_key=token_provider(),
            )

    async def _ensure_agent(self):
        if self._built:
            return self._agent
        self._built = True
        await self._register_catalog_agent()   # catalog visibility
        self._agent = self._build_responses_agent()
        return self._agent

    async def reflect(self, prompt: str, conversation_history: list) -> str:
        """Answer a chat turn using recent history for context."""
        agent = await self._ensure_agent()
        if agent is None:
            return f"[Simulated] You said: {prompt}"
        try:
            from agent_framework import ChatMessage, Role

            messages = []
            for turn in conversation_history[-5:]:  # recent context
                messages.append(ChatMessage(role=Role.USER, text=turn["query"]))
                messages.append(ChatMessage(role=Role.ASSISTANT, text=turn["response"]))
            messages.append(ChatMessage(role=Role.USER, text=prompt))

            result = await agent.run(messages)
            answer = getattr(result, "text", None) or str(result)
            logger.info(f"[AI] Response: {answer[:100]}...")
            return answer
        except Exception as e:
            logger.error(f"[AI] Request failed: {e}")
            return f"[Error] {e}"

    async def close(self):
        try:
            if self._http_client is not None:
                await self._http_client.aclose()
        except Exception:
            pass
        try:
            if self._project_client is not None:
                await self._project_client.close()
        except Exception:
            pass
        try:
            if self._credential is not None:
                await self._credential.close()
        except Exception:
            pass


# ── Agent (Main Logic) ─────────────────────────────────────────────────────
class ReflectionAgent:
    """Loads state from Blob -> calls the AI client -> persists state to Blob."""

    def __init__(self, state_store: "BlobStateStore", llm_client: "FoundryResponsesClient"):
        self.state_store = state_store
        self.llm_client = llm_client
        self.state: Dict[str, Any] = {}
        self.ready = False

    async def initialize(self):
        self.state = await self.state_store.load_state()
        self.ready = True
        logger.info(f"Agent initialized. reflection_count={self.state.get('reflection_count', 0)}")

    async def reflect(self, query: str) -> Dict[str, Any]:
        logger.info(f"[Agent] Processing query: {query}")
        history = self.state.get("history", [])
        response = await self.llm_client.reflect(query, history)

        self.state.setdefault("history", []).append(
            {"query": query, "response": response, "timestamp": _utcnow()}
        )
        self.state["reflection_count"] = self.state.get("reflection_count", 0) + 1
        self.state["last_updated"] = _utcnow()
        await self.state_store.save_state(self.state)

        return {
            "agent_id": self.state.get("agent_id"),
            "query": query,
            "response": response,
            "reflection_count": self.state["reflection_count"],
            "history_length": len(self.state["history"]),
        }

    def get_state(self) -> Dict[str, Any]:
        return self.state


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
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(obj, indent=2).encode())

    def _send_html(self, status: int, html: str):
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(html.encode("utf-8"))

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
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/reflect":
            length = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(length) or b"{}")
            query = payload.get("query", "")
            # Run the coroutine on the shared asyncio loop (thread-safe).
            future = asyncio.run_coroutine_threadsafe(self.agent.reflect(query), self.loop)
            result = future.result(timeout=60)
            self._send_json(200, result)
        else:
            self._send_json(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        logger.debug(f"[HTTP] {fmt % args}")


# ── Main ───────────────────────────────────────────────────────────────────
async def main():
    logger.info("=" * 72)
    logger.info(f"Agent ID        : {AGENT_ID}")
    logger.info(f"Blob storage    : {STORAGE_ACCOUNT or '(unset)'} / {BLOB_CONTAINER}")
    logger.info(f"Foundry project : {FOUNDRY_PROJECT_ENDPOINT or '(unset)'}")
    logger.info(f"Foundry agent   : {FOUNDRY_AGENT_NAME}")
    logger.info(f"APIM base_url   : {LLM_BASE_URL or '(unset)'}")
    logger.info(f"Model           : {LLM_MODEL}")
    logger.info("=" * 72)

    state_store = BlobStateStore(AGENT_ID, STORAGE_ACCOUNT, BLOB_CONTAINER)
    ai_client = FoundryResponsesClient(
        LLM_BASE_URL, LLM_MODEL, LLM_TOKEN_SCOPE, AGENT_INSTRUCTIONS,
        FOUNDRY_PROJECT_ENDPOINT, FOUNDRY_AGENT_NAME,
    )
    agent = ReflectionAgent(state_store, ai_client)

    AgentHTTPHandler.agent = agent
    AgentHTTPHandler.loop = asyncio.get_running_loop()

    await agent.initialize()

    http_server = HTTPServer(("0.0.0.0", AGENT_PORT), AgentHTTPHandler)
    threading.Thread(target=http_server.serve_forever, daemon=True).start()
    logger.info(f"HTTP server listening on 0.0.0.0:{AGENT_PORT} "
                f"(portal / · /health /ready /state /reflect)")

    # Optional self-demo on startup (disabled by default in-cluster).
    if os.environ.get("AGENT_RUN_DEMO", "false").lower() == "true":
        logger.info("[Demo] Running startup chat cycles...")
        for q in ["What is the capital of France?", "Explain photosynthesis briefly."]:
            logger.info(json.dumps(await agent.reflect(q), indent=2))
            await asyncio.sleep(1)

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
