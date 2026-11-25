#!/usr/bin/env bash
# Build the chat agent remotely; no local Docker daemon is required.
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/common.sh"

# ── Validate the build reference and discover the lab registry ────────────────
lab_step 1/3 "Validate the build reference and discover the lab registry"
[[ "$IMAGE_REPOSITORY" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] || die "Use a lowercase ACR image repository."
[[ "$IMAGE_TAG" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]] || die "Invalid image tag."
load_outputs

# ── Prepare image defaults, build Linux x86-64 and publish to ACR ──────────────
lab_step 2/3 "Prepare app environment, build Linux x86-64 and publish to ACR"
required APIM_GATEWAY_URL
echo "Regenerating agent-src/app/.env from .env.example with the deployed APIM gateway URL."
cp "$ROOT/agent-src/app/.env.example" "$ROOT/agent-src/app/.env"
python3 - "$ROOT/agent-src/app/.env" <<'PY'
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
configuration = path.read_text(encoding="utf-8")
assert "<API_BASE_URL>" in configuration, "App .env.example must contain <API_BASE_URL>"
path.write_text(
    configuration.replace("<API_BASE_URL>", os.environ["APIM_GATEWAY_URL"]),
    encoding="utf-8",
)
PY

echo "[$(date '+%H:%M:%S')] Building $ACR_LOGIN_SERVER/$IMAGE_REPOSITORY:$IMAGE_TAG on ACR Tasks; live build and push logs follow."
(
  cd "$ROOT"
  az acr build \
    --registry "$ACR_NAME" \
    --platform linux/amd64 \
    --image "${IMAGE_REPOSITORY}:${IMAGE_TAG}" \
    agent-src/
)

echo "Build completed. Resolving the published image digest..."
digest="$(az acr repository show \
  --name "$ACR_NAME" \
  --image "${IMAGE_REPOSITORY}:${IMAGE_TAG}" \
  --query digest \
  --output tsv)"
export IMAGE_DIGEST="$digest"

# ── Save the immutable image only after a successful build and digest lookup ──
lab_step 3/3 "Save the immutable image after a successful build and digest lookup"
python3 - "$ROOT/.lab/image.json" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

digest = os.environ["IMAGE_DIGEST"].strip()
assert re.fullmatch(r"sha256:[a-f0-9]{64}", digest), "ACR did not return a valid image digest"
image = f'{os.environ["ACR_LOGIN_SERVER"]}/{os.environ["IMAGE_REPOSITORY"]}@{digest}'
record = {
    "resource_group": os.environ["RESOURCE_GROUP"],
    "cluster": os.environ["CLUSTER_NAME"],
    "image": image,
    "tag": os.environ["IMAGE_TAG"],
}
path = Path(sys.argv[1])
temporary = path.with_suffix(".tmp")
temporary.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
temporary.replace(path)
print(f"Built image: {image}")
PY
