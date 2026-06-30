FROM python:3.11-slim AS builder

RUN pip install --no-cache-dir --user uv==0.5.29

FROM python:3.11-slim

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    gcc libxml2 libxslt1-dev && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd --system appgroup && \
    useradd --system --gid appgroup --create-home appuser

WORKDIR /app

COPY --from=builder /root/.local /home/appuser/.local
ENV PATH=/home/appuser/.local/bin:$PATH

COPY backend/requirements.txt /app/backend/
RUN uv pip install --no-cache-dir --system -r /app/backend/requirements.txt

COPY backend/ /app/backend/
COPY pipeline/ /app/pipeline/

COPY backend/start.sh /app/start.sh
RUN chmod +x /app/start.sh

RUN chown -R appuser:appgroup /app

USER appuser

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:${PORT:-8000}/health')"

CMD ./start.sh
