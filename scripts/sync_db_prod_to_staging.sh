#!/usr/bin/env bash
# ==============================================================================
# sync_db_prod_to_staging.sh — Produção (Aiven) ➔ Homologação (Físico/Local)
# ==============================================================================
# QUERO COMPRAR — Dual-Environment (FASE 4: DB Sync CLI)
#
# Espelha dados frescos da PRODUÇÃO (nuvem Aiven) no banco da HOMOLOGAÇÃO
# (servidor físico/local), preservando os schemas VITAIS de configuração
# (ops.* — ex.: ops.config_agente, auditoria) e a landing zone raw.*.
#
# FLUXO:
#   1. Lê URLs de backend/.env.production (origem) e backend/.env.staging (destino)
#      (fallback: backend/.env legado para ambos)
#   2. Dump seletivo da PRODUÇÃO: schema (sem ops/raw) + dados (sem ops/raw/logs)
#   3. Destino: verifica conectividade → DROP de staging+mart (ou TRUNCATE com
#      --truncate-only) → aplica schema → restaura dados
#   4. Validação pós-restore (contagens + SELECT 1)
#
# SEGURANÇA (Zero-Waste):
#   - Nunca toca nos schemas ops.* e raw.* do destino (config/auditoria preservados)
#   - Recusa sobrescrever um destino que NÃO seja local/físico (proteção contra
#     apagar a produção por engano) — use --force só com consciência
#   - --dry-run: valida conectividade e imprime o plano SEM alterar nada
#
# USO:
#   bash scripts/sync_db_prod_to_staging.sh --dry-run        # valida + mostra plano
#   bash scripts/sync_db_prod_to_staging.sh                  # sync completo
#   bash scripts/sync_db_prod_to_staging.sh --no-dump        # reusa backups latest
#   bash scripts/sync_db_prod_to_staging.sh --truncate-only  # TRUNCATE em vez de DROP
#   bash scripts/sync_db_prod_to_staging.sh --skip-validation
#   bash scripts/sync_db_prod_to_staging.sh --refresh-mv     # REFRESH MV no destino
#   bash scripts/sync_db_prod_to_staging.sh --help
#
# EXIT: 0 = OK | 1 = erro (conexão, validação, proteção de destino)
# ==============================================================================

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_PROD="${PROJECT_ROOT}/backend/.env.production"
ENV_STAGING="${PROJECT_ROOT}/backend/.env.staging"
ENV_LEGACY="${PROJECT_ROOT}/backend/.env"
BACKUP_DIR="${PROJECT_ROOT}/database/backups"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
SCHEMA_FILE=""
DATA_FILE=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

DRY_RUN=false
DO_DUMP=true
TRUNCATE_ONLY=false
DO_VALIDATE=true
REFRESH_MV=false
FORCE=false

show_help() {
    sed -n '3,/^set -uo/p' "$0" | head -n -1 | sed 's/^# //; s/^#//'
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --help)            show_help ;;
        --dry-run)         DRY_RUN=true ;;
        --no-dump)         DO_DUMP=false ;;
        --truncate-only)   TRUNCATE_ONLY=true ;;
        --skip-validation) DO_VALIDATE=false ;;
        --refresh-mv)      REFRESH_MV=true ;;
        --force)           FORCE=true ;;
        *)
            echo -e "${RED}❌ Argumento desconhecido: $arg${NC} (use --help)"
            exit 1
            ;;
    esac
done

mask() { echo "$1" | sed 's|:[^:@]*@|:***@|'; }

# ── Resolução das URLs ───────────────────────────────────────────────────────
pick_url() {
    local env_file="$1"; shift
    local key
    for key in "$@"; do
        if [ -f "$env_file" ]; then
            val=$(grep -E "^${key}=" "$env_file" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
            if [ -n "$val" ]; then
                echo "$val"
                return 0
            fi
        fi
    done
    return 1
}

PROD_URL=""
STAGING_URL=""
if [ -f "$ENV_PROD" ]; then
    PROD_URL=$(pick_url "$ENV_PROD" DATABASE_URL_ETL DATABASE_URL_PRIMARY DATABASE_URL) || true
fi
if [ -z "$PROD_URL" ]; then
    PROD_URL=$(pick_url "$ENV_LEGACY" DATABASE_URL_ETL DATABASE_URL_PRIMARY DATABASE_URL) || true
fi

if [ -f "$ENV_STAGING" ]; then
    STAGING_URL=$(pick_url "$ENV_STAGING" DATABASE_URL_PRIMARY DATABASE_URL_LOCAL_BACKUP DATABASE_URL) || true
fi
if [ -z "$STAGING_URL" ]; then
    STAGING_URL=$(pick_url "$ENV_LEGACY" DATABASE_URL_LOCAL_BACKUP DATABASE_URL_PRIMARY DATABASE_URL) || true
fi

if [ -z "$PROD_URL" ]; then
    echo -e "${RED}❌ URL de PRODUÇÃO não encontrada (backend/.env.production ou backend/.env → DATABASE_URL_ETL/PRIMARY).${NC}"
    exit 1
fi
if [ -z "$STAGING_URL" ]; then
    echo -e "${RED}❌ URL de HOMOLOGAÇÃO não encontrada (backend/.env.staging ou backend/.env → DATABASE_URL_LOCAL_BACKUP/PRIMARY).${NC}"
    exit 1
fi

# ── Proteção: destino precisa ser local/físico ───────────────────────────────
STAGING_HOST=$(echo "$STAGING_URL" | sed -n 's|.*@\([^:/]*\).*|\1|p' | tr '[:upper:]' '[:lower:]')
# host vazio (URL sem credenciais) = desconhecido → exige --force
if ! $FORCE && { [ -z "$STAGING_HOST" ] || { [ "$STAGING_HOST" != "localhost" ] && [ "$STAGING_HOST" != "127.0.0.1" ] && [ "$STAGING_HOST" != "::1" ]; }; }; then
    echo -e "${RED}❌ Destino NÃO é local/físico (host: ${STAGING_HOST:-desconhecido}). Recusando para não apagar produção.${NC}"
    echo -e "${YELLOW}   Se tiver certeza, rode com --force (documente o motivo).${NC}"
    exit 1
fi

# ── Ferramentas ──────────────────────────────────────────────────────────────
for cmd in pg_dump pg_restore psql; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}❌ $cmd não encontrado. Instale o PostgreSQL client tools.${NC}"
        exit 1
    fi
done

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  PRODUÇÃO (Aiven) ➔ HOMOLOGAÇÃO (Físico/Local)  —  DB Sync  ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo -e "  ${YELLOW}Produção:${NC}  $(mask "$PROD_URL")"
echo -e "  ${YELLOW}Homologação:${NC} $(mask "$STAGING_URL")"
[ "$DRY_RUN" = true ] && echo -e "  ${YELLOW}Modo:${NC}      ${CYAN}--dry-run (nada será alterado)${NC}"
echo ""

# ── Dry Run: conectividade + plano ───────────────────────────────────────────
connectivity_check() {
    local label="$1" url="$2"
    if psql "$url" -tAc "SELECT 1" &>/dev/null; then
        echo -e "  ${GREEN}✓ $label conectado${NC}"
        return 0
    fi
    echo -e "  ${RED}✗ $label INACESSÍVEL${NC}"
    return 1
}

if $DRY_RUN; then
    echo -e "${YELLOW}── [DRY-RUN] Validação de conectividade ──${NC}"
    OK=0
    connectivity_check "Produção (origem)" "$PROD_URL" || OK=1
    connectivity_check "Homologação (destino)" "$STAGING_URL" || OK=1
    echo ""
    echo -e "${YELLOW}── [DRY-RUN] Plano de execução ──${NC}"
    echo "  1. pg_dump --schema-only (Produção): exclui schemas ops.*, raw.* e auxiliares"
    echo "  2. pg_dump --format=custom (Produção): exclui ops.*, raw.*, logs"
    echo -e "  3. Destino: $([ "$TRUNCATE_ONLY" = true ] && echo 'TRUNCATE staging+mart (preserva schema)' || echo 'DROP SCHEMA staging+mart (recria do dump)')"
    echo "     ⚠️  NUNCA toca em: ops.* (config_agente, auditoria) e raw.* (landing zone)"
    echo "  4. pg_restore schema + dados no destino"
    [ "$REFRESH_MV" = true ] && echo "  5. REFRESH MV vw_api_produtos_sazonalidade (destino)"
    [ "$DO_VALIDATE" = true ] && echo "  5. Validação pós-restore (contagens fact/dim/MV)"
    echo ""
    if [ "$OK" = "1" ]; then
        echo -e "${RED}✗ [DRY-RUN] Conexão falhou — corrija as URLs antes de sincronizar.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ [DRY-RUN] OK — plano validado, nada foi alterado.${NC}"
    exit 0
fi

mkdir -p "$BACKUP_DIR"

# ── Dump seletivo da PRODUÇÃO ────────────────────────────────────────────────
EXCLUDE_SCHEMAS=(
    --exclude-schema='auth' --exclude-schema='storage' --exclude-schema='realtime'
    --exclude-schema='pgsodium' --exclude-schema='vault' --exclude-schema='extensions'
    --exclude-schema='graphql' --exclude-schema='graphql_public'
    --exclude-schema='pgbouncer' --exclude-schema='pgsodium_masks'
    --exclude-schema='raw' --exclude-schema='ops'
)

if $DO_DUMP; then
    echo -e "${GREEN}📦 [1/2] Dump seletivo da PRODUÇÃO...${NC}"
    SCHEMA_FILE="${BACKUP_DIR}/prod2staging_schema_${TIMESTAMP}.sql"
    DATA_FILE="${BACKUP_DIR}/prod2staging_data_${TIMESTAMP}.dump"

    # shellcheck disable=SC2086
    pg_dump \
        --dbname="$PROD_URL" \
        --schema-only --no-owner --no-acl --no-comments --quote-all-identifiers \
        "${EXCLUDE_SCHEMAS[@]}" \
        --file="$SCHEMA_FILE" 2>/dev/null || {
            echo -e "${RED}❌ Falha no dump de schema.${NC}"; exit 1; }

    BUILD_EXCLUDE=""
    for tbl in ops.audit_logs ops.audit_llm_queries ops.quarentena_coleta ops.config_agente raw.coleta_bruta; do
        BUILD_EXCLUDE+=" --exclude-table-data=${tbl}"
    done
    # shellcheck disable=SC2086
    pg_dump \
        --dbname="$PROD_URL" \
        --format=custom --compress=9 --no-owner --no-acl --quote-all-identifiers \
        "${EXCLUDE_SCHEMAS[@]}" \
        ${BUILD_EXCLUDE} \
        --file="$DATA_FILE" 2>/dev/null || {
            echo -e "${RED}❌ Falha no dump de dados.${NC}"; exit 1; }

    # Hardening: nunca prosseguir com dump vazio/truncado (evita destruir a
    # homologação com schema incompleto após erro transiente de origem).
    if [ ! -s "$SCHEMA_FILE" ] || [ ! -s "$DATA_FILE" ]; then
        echo -e "${RED}❌ Dump de produção veio VAZIO — abortando antes de tocar no destino.${NC}"
        exit 1
    fi

    cp "$SCHEMA_FILE" "${BACKUP_DIR}/prod2staging_schema_latest.sql"
    cp "$DATA_FILE" "${BACKUP_DIR}/prod2staging_data_latest.dump"
    echo -e "  ✅ Schema: $(basename "$SCHEMA_FILE") ($(du -h "$SCHEMA_FILE" | cut -f1))"
    echo -e "  ✅ Dados:  $(basename "$DATA_FILE") ($(du -h "$DATA_FILE" | cut -f1))"
else
    SCHEMA_FILE="${BACKUP_DIR}/prod2staging_schema_latest.sql"
    DATA_FILE="${BACKUP_DIR}/prod2staging_data_latest.dump"
    if [ ! -f "$SCHEMA_FILE" ] || [ ! -f "$DATA_FILE" ]; then
        echo -e "${RED}❌ --no-dump exige backups latest existentes. Rode sem --no-dump primeiro.${NC}"
        exit 1
    fi
    echo -e "${YELLOW}♻️  Reutilizando backups latest (--no-dump).${NC}"
fi

# ── Restore no destino (homologação física) ──────────────────────────────────
echo -e "${GREEN}🔄 [2/2] Aplicando no destino (homologação)...${NC}"
if ! psql "$STAGING_URL" -tAc "SELECT 1" &>/dev/null; then
    echo -e "${RED}❌ Homologação inacessível — verifique o PostgreSQL local.${NC}"
    exit 1
fi

if $TRUNCATE_ONLY; then
    echo -e "  ${YELLOW}TRUNCATE de staging.* e mart.* (preserva schema)...${NC}"
    # fix: %I.%I recebe (schemaname, tablename) — antes usava o tablename nos
    # dois placeholders ("TRUNCATE TABLE \"tabela\".\"tabela\"" -> relation não
    # existe) e o erro era engolido pelo grep || true.
    psql "$STAGING_URL" -v ON_ERROR_STOP=1 -c \
        "DO \$\$ DECLARE r record; BEGIN
           FOR r IN SELECT schemaname, tablename FROM pg_tables
                    WHERE schemaname IN ('staging','mart') LOOP
             EXECUTE format('TRUNCATE TABLE %I.%I CASCADE', r.schemaname, r.tablename);
           END LOOP;
         END \$\$;" >/dev/null 2>&1 || {
            echo -e "${RED}❌ TRUNCATE falhou no destino.${NC}"; exit 1; }
else
    echo -e "  ${YELLOW}DROP de schemas staging+mart (ops.* e raw.* preservados)...${NC}"
    psql "$STAGING_URL" -v ON_ERROR_STOP=1 -c \
        "DROP SCHEMA IF EXISTS staging CASCADE; DROP SCHEMA IF EXISTS mart CASCADE;" \
        >/dev/null 2>&1 || { echo -e "${RED}❌ Falha no DROP dos schemas do destino.${NC}"; exit 1; }
fi

echo -e "  ${YELLOW}Aplicando schema (DDL)...${NC}"
psql "$STAGING_URL" -v ON_ERROR_STOP=1 -f "$SCHEMA_FILE" >/dev/null 2>&1 || {
    echo -e "${RED}❌ Falha ao aplicar schema no destino.${NC}"; exit 1; }

echo -e "  ${YELLOW}Restaurando dados...${NC}"
pg_restore --dbname="$STAGING_URL" --format=custom --no-owner --no-acl \
    --clean --if-exists --jobs="$(nproc 2>/dev/null || echo 2)" \
    "$DATA_FILE" >/dev/null 2>&1 || {
        echo -e "${YELLOW}⚠️  pg_restore terminou com avisos (comuns: objetos já existentes). Verifique contagens na validação.${NC}"; }

if $REFRESH_MV; then
    echo -e "  ${YELLOW}REFRESH MV (destino)...${NC}"
    psql "$STAGING_URL" -v ON_ERROR_STOP=1 -c \
        "REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade" \
        >/dev/null 2>&1 || echo -e "${YELLOW}⚠️  REFRESH MV falhou (a MV já veio populada do dump).${NC}"
fi

# ── Validação pós-restore ────────────────────────────────────────────────────
if $DO_VALIDATE; then
    echo -e "  ${YELLOW}Validando integridade...${NC}"
    psql "$STAGING_URL" -tA -c "
        SELECT 'fact_precos_mensais=' || COUNT(*) FROM staging.fact_precos_mensais
        UNION ALL SELECT 'dim_produto=' || COUNT(*) FROM staging.dim_produto
        UNION ALL SELECT 'sazonalidade_produto=' || COUNT(*) FROM mart.sazonalidade_produto
        UNION ALL SELECT 'mv_vw_api=' || COUNT(*) FROM mart.vw_api_produtos_sazonalidade;" 2>/dev/null \
        | while read -r linha; do echo -e "    ${GREEN}$linha${NC}"; done
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ Sync Produção ➔ Homologação concluído com sucesso!       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo -e "  Homologação agora com dados frescos de produção."
echo -e "  Schemas preservados no destino: ops.* (config/auditoria) e raw.*"
echo -e "  Backups: ${BACKUP_DIR}/prod2staging_*_${TIMESTAMP}.*"
echo -e "  Próximo passo: purge do cache da API (POST /api/v1/admin/cache/clear)"
echo ""
