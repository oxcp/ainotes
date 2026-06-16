# Dockerfile — Module 4: OpenClaw Agent Container Image (AKS / Kata Container)
# Multi-stage build — same base image used for both ACA Sandbox (Module 3) and AKS (Module 4).

# ── Stage 1: Build ─────────────────────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir --target /app/deps -r requirements.txt

COPY src/ ./src/

# ── Stage 2: Runtime ───────────────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

# Non-root user for security
RUN groupadd -r openclaw && useradd -r -g openclaw openclaw

WORKDIR /app

COPY --from=builder /app/deps /app/deps
COPY --from=builder /app/src /app/src

# Lifecycle hook: flush state to Blob on SIGTERM (pre-termination hook)
# lifecycle-hook.sh is shared with module-03; copy it into this build context before building.
COPY lifecycle-hook.sh /app/lifecycle-hook.sh
RUN chmod +x /app/lifecycle-hook.sh

ENV PYTHONPATH="/app/deps"
ENV PYTHONUNBUFFERED="1"
ENV OPENCLAW_LOG_LEVEL="INFO"
ENV OPENCLAW_STATE_BACKEND="redis"
ENV OPENCLAW_REDIS_TTL_SECONDS="3600"
ENV OPENCLAW_BLOB_CONTAINER="openclaw-state"

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

STOPSIGNAL SIGTERM

USER openclaw

EXPOSE 8080

CMD ["python", "-m", "src.main"]
