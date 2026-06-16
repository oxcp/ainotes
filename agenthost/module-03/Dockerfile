# Dockerfile — Module 3: OpenClaw Agent Container Image
# Multi-stage build for a lean production image.

# ── Stage 1: Build ─────────────────────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /app

# Install build dependencies
COPY requirements.txt ./
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir --target /app/deps -r requirements.txt

# Copy application source
COPY src/ ./src/

# ── Stage 2: Runtime ───────────────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

# Non-root user for security
RUN groupadd -r openclaw && useradd -r -g openclaw openclaw

WORKDIR /app

# Copy installed dependencies and application code
COPY --from=builder /app/deps /app/deps
COPY --from=builder /app/src /app/src

# Lifecycle hook script (executed on SIGTERM for scale-to-zero state flush)
COPY lifecycle-hook.sh /app/lifecycle-hook.sh
RUN chmod +x /app/lifecycle-hook.sh

ENV PYTHONPATH="/app/deps"
ENV PYTHONUNBUFFERED="1"
ENV OPENCLAW_LOG_LEVEL="INFO"
ENV OPENCLAW_STATE_BACKEND="redis"
ENV OPENCLAW_REDIS_TTL_SECONDS="3600"
ENV OPENCLAW_BLOB_CONTAINER="openclaw-state"

# Health check endpoint
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

# Signal handler: run lifecycle hook on SIGTERM before container stops
STOPSIGNAL SIGTERM

USER openclaw

EXPOSE 8080

CMD ["python", "-m", "src.main"]
