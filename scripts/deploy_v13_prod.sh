#!/usr/bin/env bash
# ==============================================================================
# deploy_v13_prod.sh  —  Deploy Engine Forecast V13 (implementation_plan2) em PRODUÇÃO
# ==============================================================================
# QUERO COMPRAR — Deploy do plano docs/implementation_plan2.md
#
# FLOW:
#   1. Monitora a instância Supabase até voltar ao ar
#      (recovery pós-crash de disco das tentativas anteriores)
#   2. Pré-checks: objetos v13 ausentes + tamanho do banco + contagem atual
#   3. Aplica supabase/migrations/000019  (Engine V13 + cobertura dos 74 produtos novos)
#   4. Aplica supabase/migrations/000020  (Sanduíche v7 — preserva forecast_method v13)
#   5. CALL staging.sp_executar_carga_completa()  (pipeline completo + MV refresh)
#   6. Validação da grade 2026: 660 produtos, 0 cinzas, 660/660 com 12 meses
#
# USAGE:
#   bash scripts/deploy_v13_prod.sh --apply   # monitora + aplica + valida (PADRÃO)
#   bash scripts/deploy_v13_prod.sh --check   # só monitora e reporta estado
#   bash scripts/deploy_v13_prod.sh --help
#
# SAFETY:
#   - Conexão via DATABASE_URL_ETL (pooler modo sessão :5432 — suporta
#     REFRESH MATERIALIZED VIEW CONCURRENTLY; :6543 seria transação)
#   - Migrations idempotentes (DROP IF EXISTS / CREATE OR REPLACE / IF NOT EXISTS)
#   - ON_ERROR_STOP=1: qualquer erro aborta e o log aponta o passo exato
#   - Monitor: 1 tentativa a cada 30s, até MAX_WAIT_MIN (default 60min, env override)
#   - NÃO usa o caminho Local ➔ Remote de dados (nada de dump/restore)
# ==============================================================================

set -uo pipefail

# ------------------------------------------------------------------------------
# Configuração
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/backend/.env"
MIG_019="$ROOT_DIR/supabase/migrations/000019_engine_forecast_2024_2025_v13.sql"
MIG_020="$ROOT_DIR/supabase/migrations/000020_fix_sanduiche_preserva_forecast_v13.sql"
MODE="apply"
LOGFILE="$ROOT_DIR/deploy_v13_prod.log"

# MAX_WAIT_MIN: inteiro positivo (aritmética $(( )) não aceita fracionário)
MAX_WAIT_MIN="${MAX_WAIT_MIN:-60}"
if ! [[ "$MAX_WAIT_MIN" =~ ^[0-9]+$ ]] || [ "$MAX_WAIT_MIN" -lt 1 ]; then
    echo "ERRO: MAX_WAIT_MIN deve ser inteiro >= 1 (recebido: '$MAX_WAIT_MIN')" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Help
# ------------------------------------------------------------------------------
usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# ------------------------------------------------------------------------------
# Log
# ------------------------------------------------------------------------------
log()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }
warn() { echo "[$(date '+%F %T')] AVISO: $*" | tee -a "$LOGFILE"; }
die()  { echo "[$(date '+%F %T')] ERRO: $*" | tee -a "$LOGFILE" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Argumentos
# ------------------------------------------------------------------------------
[ $# -gt 0 ] && case "$1" in
    --help|-h)            usage ;;
    --check)              MODE="check" ;;
    --apply)              MODE="apply" ;;
    *) die "Argumento desconhecido: $1 (use --help)" ;;
esac

# ------------------------------------------------------------------------------
# Pré-requisitos
# ------------------------------------------------------------------------------
[ -f "$ENV_FILE" ] || die "backend/.env não encontrado em $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

P="${DATABASE_URL_ETL:-}"
[ -n "$P" ] || die "DATABASE_URL_ETL não definida no backend/.env"
command -v psql >/dev/null 2>&1 || die "psql não encontrado no PATH"

if [ "$MODE" = "apply" ]; then
    for f in "$MIG_019" "$MIG_020"; do
        [ -f "$f" ] || die "Migration não encontrada: $f"
    done
fi

log "=== Deploy V13 — modo $MODE ==="
log "Conexão: $(echo "$P" | sed -E 's|^([a-z]+://)[^@]*@|\1***@|')"

# ------------------------------------------------------------------------------
# 1. Monitora até a instância voltar
# ------------------------------------------------------------------------------
MAX_ATTEMPTS=$(( MAX_WAIT_MIN * 2 ))   # 30s por tentativa
attempt=0
log "Monitorando instância (até ${MAX_WAIT_MIN}min, 1 tentativa/30s)..."
while ! psql "$P" -Atc "SELECT 1" >/dev/null 2>&1; do
    attempt=$(( attempt + 1 ))
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        die "Instância não voltou após ${MAX_WAIT_MIN}min. Reexecute quando estiver no ar (ou aumente MAX_WAIT_MIN)."
    fi
    [ $(( attempt % 4 )) -eq 0 ] && log "  aguardando... tentativa $attempt/$MAX_ATTEMPTS ($(date +%H:%M:%S))"
    sleep 30
done
if [ "$attempt" -gt 0 ]; then
    log "Instância no ar! (após $attempt tentativas)"
else
    log "Instância no ar! (conexão imediata)"
fi

# ------------------------------------------------------------------------------
# 2. Pré-checks (read-only)
# ------------------------------------------------------------------------------
log "--- Pré-checks ---"
db_size=$(psql "$P" -Atc "SELECT pg_size_pretty(pg_database_size(current_database()))" 2>/dev/null || echo "n/d")
log "Tamanho do banco: $db_size"

n_saz=$(psql "$P" -Atc "SELECT count(*) FROM mart.sazonalidade_produto" 2>/dev/null || echo "n/d")
log "mart.sazonalidade_produto: $n_saz linhas"

v13_obj=$(psql "$P" -Atc "SELECT to_regclass('mart.sazonalidade_baseline_ponderada')" 2>/dev/null || echo "n/d")
log "baseline_ponderada (esperado vazio/NULL antes do deploy): $v13_obj"

if [ "$MODE" = "check" ]; then
    log "--- Modo --check: estado reportado, nada foi alterado ---"
    exit 0
fi

# ------------------------------------------------------------------------------
# 3. Migration 000019 — Engine V13 + produtos novos
# ------------------------------------------------------------------------------
log "--- Aplicando migration 000019 (Engine V13 + 74 produtos novos) ---"
out=$(psql "$P" -v ON_ERROR_STOP=1 -f "$MIG_019" 2>&1)
rc=$?
echo "$out" | grep -aE 'NOTA|ERRO|ERROR|erro' | tail -20
echo "$out" | grep -aqE 'ERRO|ERROR|erro' && die "Migration 000019 falhou (exit $rc) — ver log $LOGFILE"
[ $rc -eq 0 ] || die "Migration 000019 falhou (exit $rc) — ver log $LOGFILE"
log "000019 OK — verifique os NOTA acima (12 lotes + baseline ponderada)"

# ------------------------------------------------------------------------------
# 4. Migration 000020 — Sanduíche v7 (preserva forecast_method v13)
# ------------------------------------------------------------------------------
log "--- Aplicando migration 000020 (Sanduíche v7) ---"
psql "$P" -v ON_ERROR_STOP=1 -f "$MIG_020" 2>&1 | tail -5 \
    || die "Migration 000020 falhou (ver log $LOGFILE)"
log "000020 OK"

# ------------------------------------------------------------------------------
# 5. Pipeline completo
# ------------------------------------------------------------------------------
log "--- CALL staging.sp_executar_carga_completa() (pipeline completo + MV) ---"
out=$(psql "$P" -v ON_ERROR_STOP=1 -c "CALL staging.sp_executar_carga_completa();" 2>&1)
rc=$?
echo "$out" | grep -aE 'NOTA|ERRO|ERROR|erro' | tail -25
echo "$out" | grep -aqE 'ERRO|ERROR|erro' && die "Pipeline sp_executar_carga_completa falhou (exit $rc) — ver log $LOGFILE"
[ $rc -eq 0 ] || die "Pipeline sp_executar_carga_completa falhou (exit $rc) — ver log $LOGFILE"
log "Pipeline completo OK"

# ------------------------------------------------------------------------------
# 6. Validação da grade 2026
# ------------------------------------------------------------------------------
log "--- Validação da grade 2026 ---"
log "Grade:"
psql "$P" -Atc "
    WITH r AS (SELECT * FROM mart.fn_br_nacional_sazonalidade(2026, NULL, 1))
    SELECT '  produtos=' || count(DISTINCT produto)
        || ' celulas=' || count(*)
        || ' cinzas=' || count(*) FILTER (WHERE status_cor IS NULL)
    FROM r" | tee -a "$LOGFILE"

log "Completude (12/12):"
psql "$P" -Atc "
    WITH r AS (SELECT produto, mes FROM mart.fn_br_nacional_sazonalidade(2026, NULL, 1)),
    por_prod AS (SELECT produto, count(DISTINCT mes) AS n FROM r GROUP BY produto)
    SELECT '  completos=' || count(*) FILTER (WHERE n = 12)
        || ' incompletos=' || count(*) FILTER (WHERE n < 12)
    FROM por_prod" | tee -a "$LOGFILE"

log "Distribuição forecast_method 2026 (ANCHOR/PROXY_CATEGORIA/LOCF devem aparecer):"
psql "$P" -Atc "
    SELECT '  ' || COALESCE(forecast_method, 'REAL') || ': ' || count(*)
    FROM mart.sazonalidade_produto WHERE ano = 2026
    GROUP BY 1 ORDER BY 2 DESC" | tee -a "$LOGFILE"

log "Baseline ponderada (esperado ~82k linhas, 0 cinzas):"
psql "$P" -Atc "
    SELECT '  linhas=' || count(*)
        || ' cinzas=' || count(*) FILTER (WHERE status_cor_ponderado IS NULL OR forecast_method IS NULL)
        || ' produtos=' || count(DISTINCT id_produto)
    FROM mart.sazonalidade_baseline_ponderada" | tee -a "$LOGFILE"

# ------------------------------------------------------------------------------
# Fim
# ------------------------------------------------------------------------------
log "=== Deploy V13 concluído com sucesso! Log completo: $LOGFILE ==="
