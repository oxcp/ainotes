import asyncio
from contextlib import asynccontextmanager
from typing import Literal
from uuid import UUID

from fastapi import FastAPI
from pydantic import BaseModel, ConfigDict, Field

from data_processing_agent.agent import DataProcessingAgent
from orchestrator_agent.agent import Orchestrator
from rag_agent.agent import RagAgent
from shared.a2a_transport import PeerRequest, mount_a2a
from shared.config import Settings
from shared.contracts import FileRef, Question, RetrievalStrategy, StudioError
from sql_agent.agent import SQLAgent


class Arguments(BaseModel):
    model_config = ConfigDict(extra="forbid")
    workspace: UUID | None = None
    conversation: UUID | None = None
    name: str | None = Field(default=None, min_length=1, max_length=100)
    file: FileRef | None = None
    file_id: UUID | None = None
    run_id: UUID | None = None
    question: Question | str | None = None
    filters: dict[str, str] = Field(default_factory=dict, max_length=8)
    strategy: RetrievalStrategy = "semantic"

    def require(self, *names: str):
        if any(getattr(self, name) is None for name in names):
            raise StudioError("INVALID_ARGUMENTS", "Missing required operation arguments.", 422)


async def dispatch_studio(service, request: PeerRequest, emit):
    args = Arguments.model_validate(request.arguments)
    op = request.operation
    if op == "workspaces":
        return await service.list_workspaces()
    if op == "create_workspace":
        args.require("name")
        return await service.create_workspace(args.name)
    args.require("workspace")
    if op == "workspace":
        return await service.get_workspace(args.workspace)
    if op in {"files", "sources", "datasets"}:
        return await service.list_data(args.workspace, op)
    if op == "file_status":
        args.require("file_id")
        return await service.file_status(args.workspace, args.file_id)
    if op == "run":
        args.require("run_id")
        return await service.get_run(args.workspace, args.run_id)
    if op == "chat":
        args.require("conversation", "question")
        if not isinstance(args.question, Question):
            raise StudioError("INVALID_ARGUMENTS", "A structured question is required.", 422)
        return await service.start(args.workspace, args.conversation, question=args.question)
    if op == "register_upload":
        args.require("conversation", "file")
        return await service.register_upload(args.workspace, args.file, args.conversation)
    raise StudioError("UNKNOWN_OPERATION", "This Agent does not support the requested operation.", 422)


def create_agent_app(
    role: Literal["orchestrator", "data-processing", "rag", "sql"], config=None, service=None
):
    settings = config or Settings()

    @asynccontextmanager
    async def lifespan(app):
        if service is None:
            from shared.database import Repository
            from shared.models import Foundry
            from shared.storage import BlobStore

            repo, model = Repository(settings), Foundry(settings)
            blob = BlobStore(settings) if role in {"orchestrator", "data-processing"} else None
            peers = []
            worker: Orchestrator | DataProcessingAgent | RagAgent | SQLAgent
            if role == "orchestrator":
                from shared.remote import RemoteDataProcessing, RemoteRag, RemoteSQL

                data, rag, sql = RemoteDataProcessing(settings), RemoteRag(settings), RemoteSQL(settings)
                peers = [data.client, rag.client, sql.client]
                assert blob is not None
                worker = Orchestrator(settings, repo, blob, model, data=data, rag=rag, sql=sql)
            elif role == "data-processing":
                assert blob is not None
                worker = DataProcessingAgent(settings, repo, blob, model)
            elif role == "rag":
                worker = RagAgent(settings, repo, model)
            else:
                worker = SQLAgent(settings, repo, model)
        else:
            worker, repo, peers = service, service.repo, []
        app.state.service = worker
        try:
            yield
        finally:
            if service is None:
                if isinstance(worker, Orchestrator):
                    await worker.close()
                else:
                    await model.close()
                    await asyncio.to_thread(repo.close)
                    if blob:
                        await asyncio.to_thread(blob.close)
                for peer in peers:
                    await peer.close()

    app = FastAPI(title=f"Studio {role} Agent", lifespan=lifespan)

    async def dispatch(request: PeerRequest, emit):
        worker = app.state.service
        if role == "orchestrator":
            return await dispatch_studio(worker, request, emit)
        args = Arguments.model_validate(request.arguments)
        args.require("workspace")
        await asyncio.to_thread(worker.repo.workspace, args.workspace)
        if role == "data-processing" and request.operation == "process":
            args.require("file")
            return (await worker.run(args.workspace, args.file, emit)).model_dump(mode="json")
        if role in {"rag", "sql"} and request.operation == ("retrieve" if role == "rag" else "query"):
            if not isinstance(args.question, str) or not 1 <= len(args.question) <= 4000:
                raise StudioError("INVALID_ARGUMENTS", "A bounded text question is required.", 422)
            emit(
                request.operation,
                "Searching documents..." if role == "rag" else "Querying structured data...",
            )
            result = (
                await worker.run(args.workspace, args.question, args.filters, args.strategy)
                if role == "rag"
                else await worker.run(args.workspace, args.question)
            )
            return result.model_dump(mode="json")
        raise StudioError("UNKNOWN_OPERATION", "This Agent does not support the requested operation.", 422)

    mount_a2a(app, settings, role, dispatch)

    @app.get("/health")
    async def health():
        return {"status": "ok", "agent": role, "scope": "process"}

    return app
