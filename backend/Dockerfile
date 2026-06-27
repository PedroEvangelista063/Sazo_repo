FROM python:3.11-slim AS builder

RUN pip install --no-cache-dir --user uv==0.5.29

FROM python:3.11-slim

RUN groupadd --system appgroup && \
    useradd --system --gid appgroup --create-home appuser

WORKDIR /app

COPY --from=builder /root/.local /home/appuser/.local
ENV PATH=/home/appuser/.local/bin:$PATH

COPY backend/requirements.txt /app/backend/
RUN uv pip install --no-cache-dir --system -r /app/backend/requirements.txt

COPY backend/ /app/backend/

RUN chown -R appuser:appgroup /app

USER appuser

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:${PORT:-8000}/health')"

CMD uvicorn backend.app.main:app --host 0.0.0.0 --port ${PORT:-8000}
