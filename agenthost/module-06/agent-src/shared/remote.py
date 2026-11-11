import asyncio
from uuid import UUID

from shared.a2a_transport import PeerClient
from shared.config import Settings
from shared.contracts import FileRef, ProcessingResult, Question, RagResult, RetrievalStrategy, SQLResult
from shared.storage import BlobStore


class RemoteDataProcessing:
    def __init__(self, config: Settings, client: PeerClient | None = None):
        self.client = client or PeerClient(config, "data-processing", config.data_processing_url)

    async def run(self, workspace: UUID, ref: FileRef, emit) -> ProcessingResult:
        result = await self.client.call(
            "process",
            {
                "workspace": str(workspace),
                "file": ref.model_dump(mode="json"),
            },
            emit,
        )
        return ProcessingResult.model_validate(result)


class RemoteRag:
    def __init__(self, config: Settings, client: PeerClient | None = None):
        self.client = client or PeerClient(config, "rag", config.rag_url)

    async def run(
        self,
        workspace: UUID,
        question: str,
        filters: dict[str, str],
        strategy: RetrievalStrategy = "semantic",
    ) -> RagResult:
        result = await self.client.call(
            "retrieve",
            {
                "workspace": str(workspace),
                "question": question,
                "filters": filters,
                **({"strategy": strategy} if strategy != "semantic" else {}),
            },
        )
        return RagResult.model_validate(result)


class RemoteSQL:
    def __init__(self, config: Settings, client: PeerClient | None = None):
        self.client = client or PeerClient(config, "sql", config.sql_url)

    async def run(self, workspace: UUID, question: str) -> SQLResult:
        result = await self.client.call(
            "query",
            {
                "workspace": str(workspace),
                "question": question,
            },
        )
        return SQLResult.model_validate(result)


class RemoteOrchestrator:
    def __init__(self, config: Settings, blob: BlobStore, client: PeerClient | None = None):
        self.blob = blob
        self.client = client or PeerClient(config, "orchestrator", config.orchestrator_url)

    async def get_workspace(self, workspace):
        return await self.client.call("workspace", {"workspace": str(workspace)})

    async def create_workspace(self, name):
        return await self.client.call("create_workspace", {"name": name})

    async def list_workspaces(self):
        return await self.client.call("workspaces", {})

    async def list_data(self, workspace, kind):
        return await self.client.call(kind, {"workspace": str(workspace)})

    async def file_status(self, workspace, file_id):
        return await self.client.call(
            "file_status", {"workspace": str(workspace), "file_id": str(file_id)}
        )

    async def upload(self, workspace, name, mime, data, conversation):
        await self.get_workspace(workspace)
        ref = await asyncio.to_thread(self.blob.upload, workspace, name, mime, data)
        return await self.client.call(
            "register_upload",
            {
                "workspace": str(workspace),
                "file": ref.model_dump(mode="json"),
                "conversation": str(conversation),
            },
        )

    async def start(self, workspace, conversation, question: Question):
        return await self.client.call(
            "chat",
            {
                "workspace": str(workspace),
                "conversation": str(conversation),
                "question": question.model_dump(mode="json"),
            },
        )

    async def get_run(self, workspace, run_id):
        return await self.client.call("run", {"workspace": str(workspace), "run_id": str(run_id)})

    async def close(self):
        await self.client.close()
        await asyncio.to_thread(self.blob.close)
