# agent-src/Dockerfile — Chat agent image for AKS + agent-sandbox
#
# Build context is this directory (agent-src/). Produces a small, non-root
# Python image that runs the ReflectionAgent HTTP server on port 8080.
#
#   docker build -t <acr>.azurecr.io/agent-host:poc-v1 agent-src/
#   docker push  <acr>.azurecr.io/agent-host:poc-v1

# ── Stage 1: dependencies ──────────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /app
ENV PIP_ROOT_USER_ACTION=ignore
COPY requirements.txt ./
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir --target /app/deps -r requirements.txt

# ── Stage 2: runtime ───────────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

# Non-root user
RUN groupadd --gid 1000 agent && useradd --uid 1000 --gid agent --no-create-home agent

WORKDIR /app
COPY --from=builder /app/deps /app/deps
# Includes the non-secret app/.env generated before the ACR build.
COPY app/ ./app/
COPY lifecycle-hook.sh ./lifecycle-hook.sh
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
