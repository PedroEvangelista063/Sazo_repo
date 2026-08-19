#!/usr/bin/env bash
# ============================================================================
# run_boletim_pipeline.sh — Orquestra o pipeline de Boletins Logísticos CONAB
# (scraper → extração → carga → validação) de forma IDEMPOTENTE.
# ----------------------------------------------------------------------------
# Etapas:
#   1. Scraper   python -m pipeline.scraper.micro_engines.boletim_logistico_engine
#      (baixa/verifica PDFs; já existentes → "existente", sem re-download)
#   2. Extração  python -m pipeline.pdf_extractor.run_extract
#      (gera extracted/<slug>.json + resumo_extracao.json; idempotente)
#   3. Carga     python -m pipeline.load_boletins_fluxo
#      (UPSERT ON CONFLICT dedup_hash em staging.fact_fluxo_logistico)
#   4. Validação ops/gera_relatorio_validacao.py
#      (relatorio_validacao.json + .md no staging dir)
#   5. Hook ETL-done  POST {API_BASE}/_internal/etl-done (opcional/tolerante)
#
# DSN (ordem): DATABASE_URL_ETL > DATABASE_URL_LOCAL_BACKUP > fallback local
#   postgresql://postgres:postgres_dev_local@localhost:5432/quero_comprar
#   (env vars apenas — backend/.env NÃO é lido; lá DATABASE_URL_ETL é o Aiven)
#
# USO:
#   ops/run_boletim_pipeline.sh
#   DATABASE_URL_ETL="postgresql://..." ops/run_boletim_pipeline.sh
#   API_BASE_URL=http://10.0.0.5:8000 ops/run_boletim_pipeline.sh
#   SKIP_ETL_HOOK=1 ops/run_boletim_pipeline.sh   # não chama o hook interno
#
# Cron (mensal, ~dia 25 após publicação do boletim):
#   0 6 * * * cd /path/to/repo && ./ops/run_boletim_pipeline.sh >> logs/boletim.log 2>&1
#
# Exit 0 = todas as etapas ok; exit 1 = qualquer etapa falhou (set -euo pipefail).
# ============================================================================
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-$PROJ/.venv/bin/python}"
STAGING_DIR="${STAGING_DIR:-$PROJ/pipeline/data/conab_boletins_staging}"
ENV_FILE="$PROJ/backend/.env"
API_BASE="${API_BASE_URL:-http://localhost:8000}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail() { log "ERRO: $*"; exit 1; }

# ── 1. Resolve DSN (env vars > fallback local; mesma ordem do loader) ────────
# NÃO lê backend/.env: DATABASE_URL_ETL lá aponta para o Aiven (remoto), onde
# as migrations 84/85 ainda não foram aplicadas. Para apontar para outro banco,
# exporte a variável (ex.: DATABASE_URL_ETL="postgresql://..." ./ops/run_boletim_pipeline.sh).
DSN="${DATABASE_URL_ETL:-${DATABASE_URL_LOCAL_BACKUP:-}}"
if [ -z "$DSN" ]; then
  DSN="postgresql://postgres:postgres_dev_local@localhost:5432/quero_comprar"
fi
log "DSN resolvido (host destino da carga)."

[ -x "$PYTHON" ] || fail "Python do repo não encontrado: $PYTHON"
mkdir -p "$STAGING_DIR"

# ── 2. Scraper (idempotente) ─────────────────────────────────────────────────
log "Etapa 1/4 — scraper (boletins CONAB)..."
"$PYTHON" -m pipeline.scraper.micro_engines.boletim_logistico_engine \
  --anos 2025 2026 --staging-dir "$STAGING_DIR"

# ── 3. Extração (idempotente) ────────────────────────────────────────────────
log "Etapa 2/4 — extração PDF→JSON..."
"$PYTHON" -m pipeline.pdf_extractor.run_extract --staging-dir "$STAGING_DIR"

# ── 4. Carga (UPSERT idempotente) ────────────────────────────────────────────
log "Etapa 3/4 — carga em staging.fact_fluxo_logistico..."
"$PYTHON" -m pipeline.load_boletins_fluxo \
  --extracted-dir "$STAGING_DIR/extracted" --dsn "$DSN"

# ── 5. Relatório de validação ────────────────────────────────────────────────
log "Etapa 4/4 — relatório de validação..."
"$PYTHON" "$PROJ/ops/gera_relatorio_validacao.py" \
  --staging-dir "$STAGING_DIR" --dsn "$DSN"

# ── 6. Hook ETL-done (opcional, tolerante) ───────────────────────────────────
# Existe POST /api/v1/_internal/etl-done em backend/app/api/v1/endpoints/internal.py
# (router registrado sob api_v1_prefix; sem body, requer X-API-Key se configurada).
if [ "${SKIP_ETL_HOOK:-0}" != "1" ]; then
  KEY=""
  if [ -f "$ENV_FILE" ]; then
    KEY="$(sed -n 's/^INTERNAL_API_KEY=//p' "$ENV_FILE" | head -1 | tr -d '"' | tr -d "'")"
  fi
  URL="$API_BASE/api/v1/_internal/etl-done"
  if [ -n "$KEY" ]; then
    HTTP="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL" \
      -H "X-API-Key: $KEY" -H 'Content-Type: application/json' -d '{}' || true)"
  else
    HTTP="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL" \
      -H 'Content-Type: application/json' -d '{}' || true)"
  fi
  if [ "$HTTP" = "200" ]; then
    log "Hook ETL-done chamado com sucesso (HTTP 200)."
  else
    log "Aviso: hook ETL-done retornou HTTP $HTTP — API interna offline ou "
    log "chave ausente. Ignorado (o pipeline em si já concluiu)."
  fi
else
  log "Hook ETL-done desabilitado (SKIP_ETL_HOOK=1)."
fi

log "Pipeline concluído. Relatórios:"
log "  $STAGING_DIR/relatorio_validacao.json"
log "  $STAGING_DIR/relatorio_validacao.md"