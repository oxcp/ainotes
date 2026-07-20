# agent-src/Dockerfile — POC agent image for AKS + agent-sandbox (Module 3)
#
# Build context is this directory (agent-src/). Produces a small, non-root
# Python image that runs the ReflectionAgent HTTP server on port 8080.
#
#   docker build -t <acr>.azurecr.io/agent-host:poc-v1 agent-src/
#   docker push  <acr>.azurecr.io/agent-host:poc-v1

# ── Stage 1: dependencies ──────────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir --target /app/deps -r requirements.txt

# ── Stage 2: runtime ───────────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

# Azure CLI is required by the preStop lifecycle hook (blob upload via az login).
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && curl -sL https://aka.ms/InstallAzureCLIDeb | bash \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Non-root user
RUN groupadd -r agent && useradd -r -g agent agent

WORKDIR /app
COPY --from=builder /app/deps /app/deps
COPY app/ ./app/
COPY app/.env ./app/.env
COPY lifecycle-hook.sh /app/lifecycle-hook.sh
RUN chmod +x /app/lifecycle-hook.sh

ENV PYTHONPATH="/app/deps" \
    PYTHONUNBUFFERED="1" \
    AGENT_LOG_LEVEL="INFO" \
    AGENT_PORT="8080"

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

STOPSIGNAL SIGTERM
EXPOSE 8080
USER agent

CMD ["python", "-m", "app.main"]
