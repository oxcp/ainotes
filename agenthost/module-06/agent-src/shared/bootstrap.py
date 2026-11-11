from shared.config import Settings
from shared.remote import RemoteOrchestrator
from shared.storage import BlobStore


def build_service(config: Settings) -> RemoteOrchestrator:
    return RemoteOrchestrator(config, BlobStore(config))
