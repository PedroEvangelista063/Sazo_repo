#!/bin/bash
set -e

if [ "${RUN_SCRAPER:-false}" = "true" ]; then
    echo "=== Scraper CEASA iniciando ==="
    cd /app
    mkdir -p /tmp/scraper_data
    PYTHONPATH=/app python -X utf8 -m pipeline.run_scraper_historico --concorrencia 4
    echo "=== Scraper concluido ==="
fi

echo "=== Iniciando backend FastAPI ==="
exec uvicorn backend.app.main:app --host 0.0.0.0 --port ${PORT:-8000}
