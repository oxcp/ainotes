#!/usr/bin/env python3
"""
POC Agent — Simple Reflection Loop with LLM Integration
=======================================================

A lightweight, stateful agent designed to run inside a kubernetes-sigs
`agent-sandbox` Sandbox pod on AKS (Module 3, Solution B).

It can run the agent in two modes (AGENT_MODE):
  • foundry (default) — creates a **persistent agent in the Foundry project**
    via the Foundry Agent Service; it appears in the Foundry portal's Agents list.
  • gateway — calls the Foundry model through the Module 1 APIM AI gateway using
    the Microsoft Agent Framework `OpenAIChatClient` (NOT visible in the portal).

Either way it serves a small web **portal** at `/` for interactive chat.

Features:
  • Simple agentic loop: read query -> agent.run -> save state -> return result
  • Foundry Agent Service persistent agent (portal-visible) OR APIM gateway
  • Authorization: Bearer token / Azure Workload Identity (DefaultAzureCredential)
  • Redis hot state + automatic recovery on pod restart (hibernate / resume)
  • Web portal at / + Kubernetes probes: /health (liveness), /ready (readiness)

Environment Variables (aligned with agent-sandbox.yaml):
  AGENT_ID                — Unique agent identifier (default: agent-poc-001)
  AGENT_STATE_BACKEND     — 'redis' or 'memory' (default: memory)
  AGENT_REDIS_CONNECTION  — Redis connection string (host:port,password=..,ssl=True)
  AGENT_REDIS_TTL_SECONDS — State TTL in Redis (default: 3600)
  AGENT_MODE              — 'foundry' (portal-visible) or 'gateway' (default: foundry)
  FOUNDRY_PROJECT_ENDPOINT— Foundry project endpoint (foundry mode), e.g.
                            https://<account>.services.ai.azure.com/api/projects/<project>
  FOUNDRY_AGENT_NAME      — Persistent agent name to create/reuse in the project
  AGENT_APIM_ENDPOINT     — APIM gateway base URL (gateway mode); app appends /openai/v1
  LLM_BASE_URL            — Full client base_url (gateway mode); overrides AGENT_APIM_ENDPOINT
  LLM_API_KEY             — Static Bearer token (gateway mode; empty = Workload Identity)
  LLM_TOKEN_SCOPE         — AAD scope for the Workload Identity token (gateway mode)
                            (default: https://ai.azure.com/.default)
  LLM_MODEL               — Model deployment name (default: gpt-5.4-mini)
  AGENT_INSTRUCTIONS      — System instructions for the agent
  AGENT_PORT              — HTTP port (default: 8080)
  AGENT_LOG_LEVEL         — Log level (default: INFO)

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

# ── Configuration ──────────────────────────────────────────────────────────
AGENT_ID = os.environ.get("AGENT_ID", "agent-poc-001")
STATE_BACKEND = os.environ.get("AGENT_STATE_BACKEND", "memory")  # 'redis' or 'memory'
REDIS_CONNECTION = os.environ.get("AGENT_REDIS_CONNECTION", "localhost:6379")
REDIS_TTL_SECONDS = int(os.environ.get("AGENT_REDIS_TTL_SECONDS", "3600"))

# Agent Framework OpenAIChatClient base_url (calls the Foundry model through the
# APIM gateway). Prefer explicit LLM_BASE_URL, else derive from the gateway base.
_APIM_ENDPOINT = os.environ.get("AGENT_APIM_ENDPOINT", "").rstrip("/")
LLM_BASE_URL = os.environ.get("LLM_BASE_URL") or (
    f"{_APIM_ENDPOINT}/openai/v1" if _APIM_ENDPOINT else ""
)
LLM_API_KEY = os.environ.get("LLM_API_KEY", "")
# Token scope for Workload Identity. The Module 1 gateway validate-jwt only checks
# the issuer (tenant), not the audience, so the Foundry data-plane scope works.
LLM_TOKEN_SCOPE = os.environ.get("LLM_TOKEN_SCOPE", "https://ai.azure.com/.default")
LLM_MODEL = os.environ.get("LLM_MODEL", "gpt-5.4-mini")
AGENT_INSTRUCTIONS = os.environ.get(
    "AGENT_INSTRUCTIONS",
    "You are a concise, helpful reflection agent. Keep answers brief.",
)

# Mode: 'foundry' creates a PERSISTENT agent in the Foundry project (visible in
# the Foundry portal -> Agents); 'gateway' uses the APIM gateway (not portal-visible).
AGENT_MODE = os.environ.get("AGENT_MODE", "foundry").strip().lower()
FOUNDRY_PROJECT_ENDPOINT = os.environ.get("FOUNDRY_PROJECT_ENDPOINT", "").rstrip("/")
FOUNDRY_AGENT_NAME = os.environ.get("FOUNDRY_AGENT_NAME", "agenthost-reflection-agent")

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


# ── State Store (Abstract) ─────────────────────────────────────────────────
class StateStore:
    """Base class for agent state persistence."""

    async def save_state(self, state: Dict[str, Any]) -> None:
        raise NotImplementedError

    async def load_state(self) -> Dict[str, Any]:
        raise NotImplementedError

    async def close(self) -> None:
        pass

    def _default_state(self) -> Dict[str, Any]:
        return {
            "agent_id": AGENT_ID,
            "created_at": _utcnow(),
            "resumed_at": _utcnow(),
            "reflection_count": 0,
            "history": [],  # list of {query, response, timestamp}
        }


class InMemoryStateStore(StateStore):
    """Simple in-memory state store (good for local dev; not persistent)."""

    def __init__(self):
        self.state: Dict[str, Any] = {}

    async def save_state(self, state: Dict[str, Any]) -> None:
        self.state = state
        logger.debug("[InMemory] State saved")

    async def load_state(self) -> Dict[str, Any]:
        return self.state or self._default_state()


class RedisStateStore(StateStore):
    """Redis-backed state store (survives pod restart / hibernate-resume)."""

    def __init__(self, agent_id: str, connection_string: str, ttl_seconds: int):
        self.agent_id = agent_id
        self.connection_string = connection_string
        self.ttl_seconds = ttl_seconds
        self.redis = None
        self.key = f"agent:state:{agent_id}"

    async def _connect(self):
        """Lazy Redis connection. Parses 'host:port,password=..,ssl=True'."""
        if self.redis is not None:
            return
        try:
            import redis.asyncio as aioredis

            parts = self.connection_string.split(",")
            host, port_str = parts[0].split(":")
            port = int(port_str)

            options: Dict[str, Any] = {}
            for part in parts[1:]:
                if "=" in part:
                    k, v = part.split("=", 1)
                    k, v = k.strip(), v.strip()
                    if v.lower() in ("true", "false"):
                        options[k] = v.lower() == "true"
                    else:
                        options[k] = v

            logger.info(f"[Redis] Connecting to {host}:{port} (ssl={options.get('ssl', False)})")
            self.redis = aioredis.Redis(
                host=host,
                port=port,
                password=options.get("password"),
                ssl=options.get("ssl", False),
                decode_responses=True,
            )
            await self.redis.ping()
            logger.info("[Redis] Connection successful")
        except Exception as e:
            logger.error(f"[Redis] Connection failed: {e}. Falling back to in-memory.")
            self.redis = None

    async def save_state(self, state: Dict[str, Any]) -> None:
        await self._connect()
        if self.redis:
            try:
                await self.redis.set(self.key, json.dumps(state), ex=self.ttl_seconds)
                logger.info(f"[Redis] State saved for {self.agent_id} (ttl={self.ttl_seconds}s)")
            except Exception as e:
                logger.error(f"[Redis] Save failed: {e}")
        else:
            logger.warning("[Redis] Unavailable; state not persisted")

    async def load_state(self) -> Dict[str, Any]:
        await self._connect()
        if self.redis:
            try:
                raw = await self.redis.get(self.key)
                if raw:
                    state = json.loads(raw)
                    state["resumed_at"] = _utcnow()
                    logger.info(
                        f"[Redis] State loaded for {self.agent_id}: "
                        f"{len(state.get('history', []))} messages, "
                        f"reflection_count={state.get('reflection_count', 0)}"
                    )
                    return state
            except Exception as e:
                logger.error(f"[Redis] Load failed: {e}")
        return self._default_state()

    async def close(self):
        if self.redis:
            await self.redis.aclose()


# ── LLM Client (Microsoft Agent Framework) ─────────────────────────────────
class LLMClient:
    """Runs a Foundry model via the **Microsoft Agent Framework**.

    Two modes (AGENT_MODE):
      • foundry  — creates/reuses a PERSISTENT agent in the Foundry project via the
        Foundry Agent Service (agent_framework.azure.AzureAIAgentClient). The agent
        shows up in the Foundry portal's Agents list. Auth: DefaultAzureCredential
        (Workload Identity in AKS; needs the "Azure AI User" role on the project).
      • gateway  — calls the model through the Module 1 APIM gateway
        (agent_framework.openai.OpenAIChatClient). NOT visible in the portal.
    """

    def __init__(self, mode: str, base_url: str, api_key: str, model: str,
                 token_scope: str, instructions: str,
                 foundry_endpoint: str, foundry_agent_name: str):
        self.mode = mode
        self.base_url = base_url
        self.static_key = api_key
        self.model = model
        self.token_scope = token_scope
        self.instructions = instructions
        self.foundry_endpoint = foundry_endpoint
        self.foundry_agent_name = foundry_agent_name
        self._agent = None            # lazy agent_framework.Agent
        self._credential = None       # async credential (foundry mode)
        self._project_client = None   # AIProjectClient (foundry mode)
        self._built = False

    async def _ensure_agent(self):
        """Lazily build the agent (foundry or gateway). None => simulate."""
        if self._built:
            return self._agent
        self._built = True
        if self.mode == "foundry":
            self._agent = await self._build_foundry_agent()
        else:
            self._agent = self._build_gateway_agent()
        return self._agent

    async def _build_foundry_agent(self):
        """Create/reuse a persistent Foundry agent (visible in the portal)."""
        if not self.foundry_endpoint:
            logger.warning("[LLM] FOUNDRY_PROJECT_ENDPOINT not set; simulating")
            return None
        try:
            from agent_framework import Agent
            from agent_framework.azure import AzureAIAgentClient
            from azure.ai.projects.aio import AIProjectClient
            from azure.identity.aio import DefaultAzureCredential
        except ImportError as e:
            logger.warning(f"[LLM] Foundry SDKs not installed ({e}); simulating")
            return None
        try:
            self._credential = DefaultAzureCredential()
            self._project_client = AIProjectClient(
                endpoint=self.foundry_endpoint, credential=self._credential
            )
            # Reuse an existing agent by name, else create a new persistent one.
            agent_meta = None
            async for a in self._project_client.agents.list_agents():
                if getattr(a, "name", None) == self.foundry_agent_name:
                    agent_meta = a
                    break
            if agent_meta is None:
                agent_meta = await self._project_client.agents.create_agent(
                    model=self.model,
                    name=self.foundry_agent_name,
                    instructions=self.instructions,
                )
                logger.info(f"[LLM] Created Foundry agent '{self.foundry_agent_name}' "
                            f"(id={agent_meta.id}) — visible in the Foundry portal")
            else:
                logger.info(f"[LLM] Reusing Foundry agent '{self.foundry_agent_name}' "
                            f"(id={agent_meta.id})")
            chat_client = AzureAIAgentClient(
                project_client=self._project_client, agent_id=agent_meta.id
            )
            return Agent(client=chat_client, name=self.foundry_agent_name)
        except Exception as e:
            logger.warning(f"[LLM] Foundry agent setup failed: {e}; simulating")
            return None

    def _build_gateway_agent(self):
        """Build an APIM-gateway-backed agent (not visible in the portal)."""
        if not self.base_url:
            logger.warning("[LLM] no gateway base_url; simulating")
            return None
        try:
            from agent_framework import Agent
            from agent_framework.openai import OpenAIChatClient
        except ImportError:
            logger.warning("[LLM] agent_framework not installed; will simulate")
            return None

        # api_key: static token string, or a callable token provider (Workload
        # Identity). Both are sent as Authorization: Bearer by the client.
        if self.static_key:
            api_key: Any = self.static_key
        else:
            try:
                from azure.identity import DefaultAzureCredential, get_bearer_token_provider
                api_key = get_bearer_token_provider(
                    DefaultAzureCredential(), self.token_scope
                )
            except Exception as e:
                logger.warning(f"[LLM] Workload Identity unavailable: {e}")
                return None
        try:
            client = OpenAIChatClient(
                model=self.model, base_url=self.base_url, api_key=api_key,
            )
            logger.info(f"[LLM] Gateway agent ready (base_url={self.base_url})")
            return Agent(
                client=client,
                name="reflection-agent",
                instructions=self.instructions,
                default_options={"store": False},
            )
        except Exception as e:
            logger.warning(f"[LLM] Agent build failed: {e}")
            return None

    async def reflect(self, prompt: str, conversation_history: list) -> str:
        """Run the agent with recent conversation context."""
        agent = await self._ensure_agent()
        if agent is None:
            logger.warning("[LLM] No agent available; simulating response")
            return f"[Simulated] Thinking about: {prompt}"

        # Build the message list (recent turns + the new prompt).
        from agent_framework import ChatMessage, Role

        messages = []
        for turn in conversation_history[-3:]:  # last 3 turns for context
            messages.append(ChatMessage(role=Role.USER, text=turn["query"]))
            messages.append(ChatMessage(role=Role.ASSISTANT, text=turn["response"]))
        messages.append(ChatMessage(role=Role.USER, text=prompt))

        try:
            logger.info(f"[LLM] agent.run (mode={self.mode}, model={self.model})")
            result = await agent.run(messages)
            answer = getattr(result, "text", None) or str(result)
            logger.info(f"[LLM] Response: {answer[:100]}...")
            return answer
        except Exception as e:
            logger.error(f"[LLM] Request failed: {e}")
            return f"[Error] {e}"

    async def close(self):
        """Release the Foundry project client / credential (foundry mode)."""
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
    """Loads state -> calls LLM (Bearer auth) -> persists state -> returns result."""

    def __init__(self, state_store: StateStore, llm_client: LLMClient):
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
PORTAL_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Agent Portal</title>
<style>
  :root { --bg:#0f172a; --panel:#1e293b; --accent:#38bdf8; --user:#2563eb; --bot:#334155; --text:#e2e8f0; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:system-ui,Segoe UI,Arial,sans-serif; background:var(--bg); color:var(--text); height:100vh; display:flex; flex-direction:column; }
  header { padding:12px 20px; background:var(--panel); display:flex; align-items:center; gap:12px; border-bottom:1px solid #334155; }
  header h1 { font-size:16px; margin:0; font-weight:600; }
  header .meta { margin-left:auto; font-size:12px; color:#94a3b8; }
  #chat { flex:1; overflow-y:auto; padding:20px; display:flex; flex-direction:column; gap:12px; }
  .msg { max-width:80%; padding:10px 14px; border-radius:12px; line-height:1.45; white-space:pre-wrap; word-wrap:break-word; }
  .user { align-self:flex-end; background:var(--user); border-bottom-right-radius:2px; }
  .bot  { align-self:flex-start; background:var(--bot); border-bottom-left-radius:2px; }
  .role { font-size:11px; opacity:.7; margin-bottom:2px; }
  footer { padding:14px 20px; background:var(--panel); border-top:1px solid #334155; display:flex; gap:10px; }
  #q { flex:1; padding:12px 14px; border-radius:10px; border:1px solid #475569; background:#0b1220; color:var(--text); font-size:14px; }
  #q:focus { outline:none; border-color:var(--accent); }
  button { padding:0 20px; border:none; border-radius:10px; background:var(--accent); color:#0f172a; font-weight:600; cursor:pointer; }
  button:disabled { opacity:.5; cursor:not-allowed; }
</style>
</head>
<body>
  <header>
    <h1>&#129302; Agent Portal</h1>
    <span class="meta" id="meta">connecting…</span>
  </header>
  <div id="chat"></div>
  <footer>
    <input id="q" placeholder="Ask the agent…" autocomplete="off" />
    <button id="send">Send</button>
  </footer>
<script>
  const chat = document.getElementById('chat');
  const meta = document.getElementById('meta');
  const q = document.getElementById('q');
  const send = document.getElementById('send');

  function add(role, text) {
    const div = document.createElement('div');
    div.className = 'msg ' + (role === 'user' ? 'user' : 'bot');
    div.innerHTML = '<div class="role">' + (role === 'user' ? 'You' : 'Agent') + '</div>';
    div.appendChild(document.createTextNode(text));
    chat.appendChild(div);
    chat.scrollTop = chat.scrollHeight;
  }

  async function loadState() {
    try {
      const r = await fetch('/state');
      const s = await r.json();
      meta.textContent = (s.agent_id || 'agent') + ' · reflections: ' + (s.reflection_count || 0);
      (s.history || []).forEach(h => { add('user', h.query); add('bot', h.response); });
    } catch (e) { meta.textContent = 'state unavailable'; }
  }

  async function ask() {
    const text = q.value.trim();
    if (!text) return;
    add('user', text);
    q.value = '';
    send.disabled = true; q.disabled = true;
    try {
      const r = await fetch('/reflect', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ query: text })
      });
      const res = await r.json();
      add('bot', res.response ?? JSON.stringify(res));
      meta.textContent = (res.agent_id || 'agent') + ' · reflections: ' + (res.reflection_count || 0);
    } catch (e) { add('bot', '[Error] ' + e); }
    send.disabled = false; q.disabled = false; q.focus();
  }

  send.addEventListener('click', ask);
  q.addEventListener('keydown', e => { if (e.key === 'Enter') ask(); });
  loadState();
</script>
</body>
</html>"""


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
    logger.info(f"Agent ID       : {AGENT_ID}")
    logger.info(f"State backend  : {STATE_BACKEND}")
    logger.info(f"Agent mode     : {AGENT_MODE}")
    if AGENT_MODE == "foundry":
        logger.info(f"Foundry project: {FOUNDRY_PROJECT_ENDPOINT or '(unset)'}")
        logger.info(f"Foundry agent  : {FOUNDRY_AGENT_NAME}")
    else:
        logger.info(f"LLM base_url    : {LLM_BASE_URL}")
    logger.info(f"LLM model      : {LLM_MODEL}")
    logger.info("=" * 72)

    state_store: StateStore = (
        RedisStateStore(AGENT_ID, REDIS_CONNECTION, REDIS_TTL_SECONDS)
        if STATE_BACKEND == "redis"
        else InMemoryStateStore()
    )
    llm_client = LLMClient(
        AGENT_MODE, LLM_BASE_URL, LLM_API_KEY, LLM_MODEL, LLM_TOKEN_SCOPE,
        AGENT_INSTRUCTIONS, FOUNDRY_PROJECT_ENDPOINT, FOUNDRY_AGENT_NAME,
    )
    agent = ReflectionAgent(state_store, llm_client)

    AgentHTTPHandler.agent = agent
    AgentHTTPHandler.loop = asyncio.get_running_loop()

    await agent.initialize()

    http_server = HTTPServer(("0.0.0.0", AGENT_PORT), AgentHTTPHandler)
    threading.Thread(target=http_server.serve_forever, daemon=True).start()
    logger.info(f"HTTP server listening on 0.0.0.0:{AGENT_PORT} "
                f"(portal / · /health /ready /state /reflect)")

    # Optional self-demo on startup (disabled by default in-cluster).
    if os.environ.get("AGENT_RUN_DEMO", "false").lower() == "true":
        logger.info("[Demo] Running startup reflection cycles...")
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
        await llm_client.close()
        await state_store.close()
        http_server.shutdown()


if __name__ == "__main__":
    asyncio.run(main())
