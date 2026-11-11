FROM python:3.13-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1 TIKTOKEN_CACHE_DIR=/opt/tiktoken
COPY . .
RUN pip install --no-cache-dir . && python -c "import tiktoken; tiktoken.get_encoding('cl100k_base')" && useradd --uid 10001 --create-home studio && mkdir -p /app/.local/data && chown -R studio:studio /app/.local
USER 10001
EXPOSE 8080
CMD ["uvicorn", "rag_agent.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080"]
