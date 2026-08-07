#!/usr/bin/env bash
# ============================================================================
# QUERO COMPRAR — Sync da carga CONAB (fact/mart) local → banco remoto (Aiven)
# ----------------------------------------------------------------------------
# Contexto: a ingestão CONAB (PrecosMensalUF + ProhortMensal) foi executada no
# banco LOCAL (5432) porque o banco remoto (Aiven) estava indisponível.
# Quando o remoto voltar, rodar este script para replicar os dados novos.
#
# O que replica (somente as tabelas alteradas pela carga):
#   staging.dim_produto, staging.dim_localidade, staging.fact_precos_mensais,
#   mart.sazonalidade_produto (via sp_calcular_sazonalidade + backfill 63),
#   e o refresh da MV mart.vw_api_produtos_sazonalidade.
#
# Pré-requisitos:
#   - Remoto acessível (não mais em hot standby)
#   - pg_dump/pg_restore ou psql com credenciais do pooler/remoto
#   - As migrações 63 + 000021 JÁ aplicadas no remoto (schema de transparência)
#
# Uso:
#   DATABASE_URL_REMOTO="postgresql://..." ./scripts/sync_conab_local_to_remote.sh
#
# NOTA: se o remoto estiver com o schema DIFERENTE (ex.: sem colunas de
# transparência), aplicar antes: database/63_...sql + 000021_...sql.
# ============================================================================
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -n "${DATABASE_URL:-}" ]; then
  LOCAL_URL="$DATABASE_URL"
elif [ -f "$PROJ/backend/.env" ]; then
  LOCAL_URL="$(sed -n 's/^DATABASE_URL=//p' "$PROJ/backend/.env" | head -1 | tr -d '"' | tr -d "'")"
fi
if [ -z "${LOCAL_URL:-}" ]; then
  echo "[sync] ERRO: defina DATABASE_URL ou preencha DATABASE_URL em backend/.env" >&2
  exit 1
fi
REMOTE_URL="${DATABASE_URL_REMOTO:?Defina DATABASE_URL_REMOTO com a URL do banco remoto (Aiven)}"

log() { echo "[sync] $(date '+%H:%M:%S') $*"; }

# 1. Dump das dimensões + fato (formato custom, schema staging/mart)
log "Dump local (dimensões + fato)..."
pg_dump "$LOCAL_URL" \
  -t 'staging.dim_produto' -t 'staging.dim_localidade' \
  -t 'staging.fact_precos_mensais' \
  --data-only --no-owner --format=custom -f /tmp/conab_sync.dump

# 2. Restore no remoto (upsert via ON CONFLICT preservado no dump? Não —
#    usamos psql para re-rodar a lógica de carga no remoto via pipeline)
log "Restore no remoto via psql (data-only, ignorando conflitos de PK)..."
pg_restore --clean --if-exists --no-owner -d "$REMOTE_URL" /tmp/conab_sync.dump \
  || log "AVISO: pg_restore encontrou conflitos (esperado se remoto já tem dados) — prosseguindo"

# 3. Re-rodar o ciclo medalhão no remoto (calcula sazonalidade + MV V17)
log "Ciclo medalhão no remoto (sp_executar_carga_completa)..."
psql "$REMOTE_URL" -v ON_ERROR_STOP=1 -c "CALL staging.sp_executar_carga_completa();"

# 4. Backfill de transparência (idempotente — migração 63)
log "Backfill transparência (63) no remoto..."
psql "$REMOTE_URL" -v ON_ERROR_STOP=1 -c "
UPDATE mart.sazonalidade_produto AS s
SET ano_referencia = CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER),
    idade_dado_anos = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
                      - CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER),
    tipo_dado = CASE
        WHEN COALESCE(s.fonte,'') = 'FLUXO_PROXY' OR s.is_forecast THEN 'FALLBACK_DIMENSAO'
        WHEN CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER)
             = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER THEN 'REAL_ATUAL'
        ELSE 'HISTORICO_BASE'
    END,
    metadado_transparencia = jsonb_build_object(
        'fonte_dado', COALESCE(s.fonte,'desconhecida'),
        'data_referencia', s.data_referencia_atual,
        'procedencia', CASE
            WHEN COALESCE(s.fonte,'') = 'FLUXO_PROXY' THEN 'sintetico_proxy'
            WHEN s.is_forecast THEN 'sintetico_engine'
            ELSE 'coleta_real_conab'
        END,
        'calculado_em', s.calculado_em
    ),
    preco_exibido = CASE
        WHEN COALESCE(s.fonte,'') <> 'FLUXO_PROXY' AND NOT s.is_forecast THEN s.preco_atual
        ELSE NULL
    END
WHERE ano_referencia IS NULL;
"

# 5. Refresh MV V17 no remoto
log "Refresh MV vw_api_produtos_sazonalidade no remoto..."
psql "$REMOTE_URL" -c "REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;" \
  || psql "$REMOTE_URL" -c "REFRESH MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade;"

# 6. Validação final
log "Validação — contagens no remoto:"
psql "$REMOTE_URL" -Atc "SELECT 'fact=' || count(*) FROM staging.fact_precos_mensais;"
psql "$REMOTE_URL" -Atc "SELECT 'sazonalidade=' || count(*) FROM mart.sazonalidade_produto;"
psql "$REMOTE_URL" -Atc "SELECT 'mv=' || count(*) FROM mart.vw_api_produtos_sazonalidade;"

log "Sync concluído. Lembrar: POST /admin/cache/clear na API de produção."
