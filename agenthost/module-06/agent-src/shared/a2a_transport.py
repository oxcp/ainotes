import asyncio
import hmac
import json
from collections import OrderedDict
from collections.abc import Awaitable, Callable
from typing import Any
from uuid import uuid4

import httpx
from a2a.client import A2ACardResolver, Client, ClientConfig, ClientFactory
from a2a.helpers import new_task_from_user_message
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.context import ServerCallContext
from a2a.server.events import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes.agent_card_routes import create_agent_card_routes
from a2a.server.routes.common import ServerCallContextBuilder
from a2a.server.routes.jsonrpc_routes import create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore, TaskStore, TaskUpdater
from a2a.types import (
    AgentCapabilities,
    AgentCard,
    AgentInterface,
    AgentSkill,
    HTTPAuthSecurityScheme,
    Message,
    Part,
    Role,
    SecurityRequirement,
    SecurityScheme,
    SendMessageRequest,
    StringList,
    TaskState,
)
from a2a.utils.errors import TaskNotCancelableError
from fastapi import FastAPI, Request
from google.protobuf.json_format import MessageToDict, ParseDict
from google.protobuf.struct_pb2 import Value
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from starlette.responses import JSONResponse

from shared.config import Settings
from shared.contracts import StudioError
from shared.observability import failure

SKILLS = {
    "chat": ["studio"],
    "orchestrator": ["studio"],
    "data-processing": ["process"],
    "rag": ["retrieve"],
    "sql": ["query"],
}
Emit = Callable[[str, str], None]
Dispatch = Callable[["PeerRequest", Emit], Awaitable[Any]]


class PeerRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    operation: str = Field(min_length=1, max_length=40)
    arguments: dict[str, Any] = Field(default_factory=dict)


def peer_key(config: Settings) -> str:
    if config.a2a_api_key is None:
        raise ValueError("A2A_API_KEY is required for independent Agent services")
    return config.a2a_api_key.get_secret_value()


def data_part(value: dict) -> Part:
    # Protobuf Value represents numbers as doubles. JSON text preserves exact SQL integers.
    return Part(
        data=ParseDict({"json": json.dumps(value, ensure_ascii=False)}, Value()),
        media_type="application/json",
    )


def read_part(part: Part) -> dict:
    if not part.HasField("data"):
        raise StudioError("INVALID_A2A", "Expected an A2A structured data part.", 422)
    envelope = MessageToDict(part.data)
    if not isinstance(envelope, dict) or set(envelope) != {"json"} or not isinstance(envelope["json"], str):
        raise StudioError("INVALID_A2A", "Expected the Studio JSON envelope.", 422)
    try:
        value = json.loads(envelope["json"])
    except json.JSONDecodeError as exc:
        raise StudioError("INVALID_A2A", "Invalid JSON in A2A data.", 422) from exc
    if not isinstance(value, dict):
        raise StudioError("INVALID_A2A", "Expected a JSON object in A2A data.", 422)
    return value


def agent_card(role: str, config: Settings) -> AgentCard:
    return AgentCard(
        name=f"studio-{role}",
        description=f"Product Launch Studio {role} Agent; independently hosted sandbox service.",
        version="0.2.0",
        supported_interfaces=[
            AgentInterface(
                url=config.a2a_public_url.rstrip("/") + "/a2a",
                protocol_binding="JSONRPC",
                protocol_version="1.0",
            )
        ],
        capabilities=AgentCapabilities(streaming=True),
        default_input_modes=["application/json"],
        default_output_modes=["application/json"],
        skills=[
            AgentSkill(id=skill, name=skill, description=f"Studio {skill} contract.", tags=["studio", role])
            for skill in SKILLS[role]
        ],
        security_schemes={
            "peer": SecurityScheme(
                http_auth_security_scheme=HTTPAuthSecurityScheme(
                    scheme="Bearer", bearer_format="workshop-peer-key"
                )
            )
        },
        security_requirements=[SecurityRequirement(schemes={"peer": StringList()})],
    )


class PeerContext(ServerCallContextBuilder):
    def build(self, request: Request) -> ServerCallContext:
        return ServerCallContext(state={"headers": dict(request.headers)})


class RecentTaskStore(TaskStore):
    def __init__(self, limit: int):
        self.store = InMemoryTaskStore()
        self.completed: OrderedDict[str, ServerCallContext] = OrderedDict()
        self.limit = limit
        self.lock = asyncio.Lock()

    async def save(self, task, context):
        async with self.lock:
            await self.store.save(task, context)
            if task.status.state in {
                TaskState.TASK_STATE_COMPLETED,
                TaskState.TASK_STATE_FAILED,
                TaskState.TASK_STATE_CANCELED,
            }:
                self.completed[task.id] = context
                while len(self.completed) > self.limit:
                    task_id, ctx = self.completed.popitem(last=False)
                    await self.store.delete(task_id, ctx)

    async def get(self, task_id, context):
        return await self.store.get(task_id, context)

    async def list(self, params, context):
        return await self.store.list(params, context)

    async def delete(self, task_id, context):
        async with self.lock:
            self.completed.pop(task_id, None)
            await self.store.delete(task_id, context)


class Executor(AgentExecutor):
    def __init__(self, config: Settings, dispatch: Dispatch):
        self.config, self.dispatch = config, dispatch
        self.capacity = asyncio.Semaphore(4)

    async def execute(self, context: RequestContext, event_queue: EventQueue):
        message = context.message
        if message is None:
            raise StudioError("INVALID_A2A", "A request message is required.", 422)
        task = context.current_task or new_task_from_user_message(message)
        await event_queue.enqueue_event(task)
        updater = TaskUpdater(event_queue, task.id, task.context_id)
        await updater.start_work()
        progress: asyncio.Queue[tuple[str, str] | None] = asyncio.Queue()

        def emit(stage: str, message: str):
            progress.put_nowait((stage, message))

        async def run():
            try:
                if len(message.parts) != 1:
                    raise StudioError("INVALID_A2A", "Exactly one structured request part is required.", 422)
                request = PeerRequest.model_validate(read_part(message.parts[0]))
                timeout = (
                    self.config.ingestion_timeout + 60
                    if request.operation == "process"
                    else self.config.request_timeout
                )
                async with asyncio.timeout(timeout):
                    async with self.capacity:
                        result = await self.dispatch(request, emit)
                return {"result": result}
            finally:
                progress.put_nowait(None)

        operation = asyncio.create_task(run())
        try:
            while (item := await progress.get()) is not None:
                await updater.update_status(
                    TaskState.TASK_STATE_WORKING,
                    Message(
                        message_id=str(uuid4()),
                        role=Role.ROLE_AGENT,
                        parts=[data_part({"stage": item[0], "message": item[1]})],
                    ),
                )
            result = await operation
            await updater.add_artifact([data_part(result)], name="result")
            await updater.complete()
        except Exception as exc:
            failure(exc, stage="a2a_execute", request_id=message.message_id)
            error = (
                exc
                if isinstance(exc, StudioError)
                else StudioError(
                    "INVALID_A2A" if isinstance(exc, ValidationError) else "PEER_FAILED",
                    "Invalid peer request."
                    if isinstance(exc, ValidationError)
                    else "Agent operation failed.",
                    422 if isinstance(exc, ValidationError) else 502,
                )
            )
            await updater.add_artifact(
                [
                    data_part(
                        {
                            "error": {
                                "code": error.code,
                                "message": error.message,
                                "status": error.status,
                                "retryable": error.retryable,
                            }
                        }
                    )
                ],
                name="error",
            )
            await updater.failed()
        finally:
            if not operation.done():
                operation.cancel()
            await asyncio.gather(operation, return_exceptions=True)

    async def cancel(self, context: RequestContext, event_queue: EventQueue):
        raise TaskNotCancelableError("This workshop does not support explicit task cancellation.")


def mount_a2a(app: FastAPI, config: Settings, role: str, dispatch: Dispatch):
    key = peer_key(config)
    card = agent_card(role, config)
    handler = DefaultRequestHandler(
        agent_executor=Executor(config, dispatch),
        task_store=RecentTaskStore(config.max_runs),
        agent_card=card,
    )
    app.router.routes.extend(create_agent_card_routes(card))
    app.router.routes.extend(create_jsonrpc_routes(handler, "/a2a", context_builder=PeerContext()))

    @app.middleware("http")
    async def authenticate_peer(request: Request, call_next):
        if request.url.path in {"/a2a", "/.well-known/agent-card.json"}:
            header = request.headers.get("authorization", "")
            if not hmac.compare_digest(header.encode(), ("Bearer " + key).encode()):
                return JSONResponse(
                    {"code": "UNAUTHORIZED", "message": "Valid peer credentials required."}, 401
                )
            length = request.headers.get("content-length", "")
            if request.method == "POST" and (not length.isdigit() or int(length) > 65536):
                return JSONResponse(
                    {"code": "REQUEST_SIZE", "message": "Peer request exceeds size limit."}, 413
                )
        return await call_next(request)


class PeerClient:
    def __init__(self, config: Settings, role: str, endpoint: str, http: httpx.AsyncClient | None = None):
        self.config, self.role, self.endpoint = config, role, endpoint.rstrip("/")
        self.http = http or httpx.AsyncClient(
            timeout=httpx.Timeout(
                max(config.request_timeout, config.ingestion_timeout + 60)
                if role == "data-processing"
                else config.request_timeout,
                connect=10,
            ),
            headers={"Authorization": "Bearer " + peer_key(config)},
            follow_redirects=False,
        )
        self.http.headers["A2A-Version"] = "1.0"
        self.client: Client | None = None
        self.lock = asyncio.Lock()

    async def discover(self):
        async with self.lock:
            if self.client is not None:
                return self.client
            card = await A2ACardResolver(self.http, self.endpoint).get_agent_card()
            expected = self.endpoint + "/a2a"
            if (
                card.name != "studio-" + self.role
                or not set(SKILLS[self.role]) <= {skill.id for skill in card.skills}
                or not card.capabilities.streaming
                or len(card.supported_interfaces) != 1
                or card.supported_interfaces[0].url != expected
                or card.supported_interfaces[0].protocol_binding != "JSONRPC"
                or card.supported_interfaces[0].protocol_version != "1.0"
            ):
                raise StudioError(
                    "INVALID_AGENT_CARD", "Peer identity, skills or endpoint do not match configuration.", 502
                )
            self.client = ClientFactory(
                ClientConfig(httpx_client=self.http, streaming=True, supported_protocol_bindings=["JSONRPC"])
            ).create(card)
            return self.client

    async def call(self, operation: str, arguments: dict, emit: Emit | None = None):
        try:
            timeout = (
                self.config.ingestion_timeout + 120 if operation == "process" else self.config.request_timeout
            )
            async with asyncio.timeout(timeout):
                client = await self.discover()
                request = SendMessageRequest(
                    message=Message(
                        message_id=str(uuid4()),
                        role=Role.ROLE_USER,
                        parts=[
                            data_part(
                                PeerRequest(
                                    operation=operation, arguments=arguments
                                ).model_dump()
                            )
                        ],
                    )
                )
                response = None
                terminal = None
                async for update in client.send_message(request):
                    if update.HasField("status_update"):
                        status = update.status_update.status
                        terminal = status.state
                        if emit and status.HasField("message"):
                            for part in status.message.parts:
                                value = read_part(part)
                                emit(value["stage"], value["message"])
                    if update.HasField("artifact_update"):
                        parts = update.artifact_update.artifact.parts
                        if len(parts) != 1:
                            raise StudioError("INVALID_A2A", "Peer returned an invalid result artifact.", 502)
                        response = read_part(parts[0])
                if response and "error" in response:
                    error = response["error"]
                    raise StudioError(
                        error["code"], error["message"], int(error["status"]), error["retryable"]
                    )
                if terminal != TaskState.TASK_STATE_COMPLETED or response is None or "result" not in response:
                    raise StudioError("INCOMPLETE_A2A", "Peer did not complete its task.", 502)
                return response["result"]
        except StudioError:
            raise
        except TimeoutError:
            raise
        except Exception as exc:
            failure(exc, stage="a2a_client", agent=self.role)
            raise StudioError(
                "PEER_UNAVAILABLE", f"{self.role} Agent is unavailable or returned invalid A2A.", 503, True
            ) from exc

    async def close(self):
        await self.http.aclose()
