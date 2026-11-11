import logging
import time
from collections import deque
from contextlib import asynccontextmanager
from pathlib import Path
from uuid import UUID, uuid4

from fastapi import FastAPI, File, Form, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from shared.a2a_transport import mount_a2a
from shared.agent_service import dispatch_studio
from shared.bootstrap import build_service
from shared.config import Settings
from shared.contracts import Question, StudioError
from shared.observability import failure


class WorkspaceInput(BaseModel):
    name: str = Field(min_length=1, max_length=100)


def create_app(config: Settings | None = None, service=None) -> FastAPI:
    settings = config or Settings()

    @asynccontextmanager
    async def lifespan(app):
        logging.basicConfig(level=logging.INFO, format="%(message)s")
        app.state.service = service or build_service(settings)
        yield
        await app.state.service.close()

    app = FastAPI(title="Product Launch Studio", lifespan=lifespan)
    if settings.a2a_api_key is not None:

        async def dispatch(request, emit):
            if request.operation not in {
                "chat",
                "run",
                "workspace",
                "workspaces",
                "create_workspace",
                "files",
                "sources",
                "datasets",
                "file_status",
            }:
                raise StudioError("UNKNOWN_OPERATION", "Chat does not accept this peer operation.", 422)
            return await dispatch_studio(app.state.service, request, emit)

        mount_a2a(app, settings, "chat", dispatch)
    calls: deque[float] = deque()

    def error_response(request, code, message, status, retryable=False):
        return JSONResponse(
            status_code=status,
            content={
                "code": code,
                "message": message,
                "request_id": getattr(request.state, "request_id", str(uuid4())),
                "retryable": retryable,
                "details": {},
            },
        )

    @app.middleware("http")
    async def security(request: Request, call_next):
        request.state.request_id = str(uuid4())
        if request.url.path.startswith("/api"):
            now = time.monotonic()
            while calls and calls[0] < now - 60:
                calls.popleft()
            if len(calls) >= settings.requests_per_minute and request.method == "POST":
                return error_response(request, "RATE_LIMIT", "Request rate exceeded; retry later.", 429, True)
            if request.method == "POST":
                calls.append(now)
            limit = settings.max_upload_bytes + 65536 if request.url.path.endswith("/files") else 32000
            length = request.headers.get("content-length", "")
            if request.method == "POST" and (not length.isdigit() or int(length) > limit):
                return error_response(
                    request, "REQUEST_SIZE", "Content-Length is required and must fit the limit.", 413
                )
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self'; style-src 'self'; frame-ancestors 'none'; object-src 'none'"
        )
        return response

    @app.exception_handler(StudioError)
    async def studio_error(request: Request, exc: StudioError):
        failure(exc, request_id=request.state.request_id)
        return error_response(request, exc.code, exc.message, exc.status, exc.retryable)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request: Request, exc: RequestValidationError):
        return error_response(request, "INVALID_REQUEST", "Request fields are invalid.", 422)

    @app.exception_handler(Exception)
    async def unexpected_error(request: Request, exc: Exception):
        failure(exc, request_id=getattr(request.state, "request_id", "unknown"))
        return error_response(
            request, "SERVICE_ERROR", "A service operation failed. Check server diagnostics.", 503, True
        )

    def svc(request):
        return request.app.state.service

    @app.get("/health")
    async def health():
        return {"status": "ok", "scope": "process", "note": "Does not verify Azure dependency readiness."}

    @app.post("/api/workspaces", status_code=201)
    async def create_workspace(body: WorkspaceInput, request: Request):
        return await svc(request).create_workspace(body.name)

    @app.get("/api/workspaces")
    async def workspaces(request: Request):
        return await svc(request).list_workspaces()

    @app.get("/api/workspaces/{workspace_id}")
    async def workspace(workspace_id: UUID, request: Request):
        return await svc(request).get_workspace(workspace_id)

    @app.post("/api/workspaces/{workspace_id}/files", status_code=202)
    async def upload(
        workspace_id: UUID, request: Request, file: UploadFile = File(...), conversation_id: UUID = Form(...)
    ):
        data = await file.read(settings.max_upload_bytes + 1)
        return await svc(request).upload(
            workspace_id,
            file.filename or "",
            file.content_type or "",
            data,
            conversation_id,
        )

    @app.get("/api/workspaces/{workspace_id}/files")
    @app.get("/api/workspaces/{workspace_id}/sources")
    async def files(workspace_id: UUID, request: Request):
        return await svc(request).list_data(workspace_id, "files")

    @app.get("/api/workspaces/{workspace_id}/datasets")
    async def datasets(workspace_id: UUID, request: Request):
        return await svc(request).list_data(workspace_id, "datasets")

    @app.get("/api/workspaces/{workspace_id}/files/{file_id}/status")
    async def file_status(workspace_id: UUID, file_id: UUID, request: Request):
        return await svc(request).file_status(workspace_id, file_id)

    @app.post("/api/workspaces/{workspace_id}/chat", status_code=202)
    async def chat(workspace_id: UUID, body: Question, request: Request):
        return await svc(request).start(
            workspace_id, body.conversation_id, question=body
        )

    @app.get("/api/workspaces/{workspace_id}/runs/{run_id}")
    async def run(workspace_id: UUID, run_id: UUID, request: Request):
        return await svc(request).get_run(workspace_id, run_id)

    static = Path(__file__).parent / "static"
    app.mount("/static", StaticFiles(directory=static), name="static")

    @app.get("/")
    async def index():
        return FileResponse(static / "index.html")

    return app
