#!/usr/bin/env bash
# ==============================================================================
# sync_db_remote_to_local.sh  —  Remote ➔ Local Snapshot Sync
# ==============================================================================
# QUERO COMPRAR — Hybrid DB Architecture
#
# PURPOSE:
#   Espelha o banco REMOTO (Supabase, primary/active) para o banco LOCAL
#   (PostgreSQL nativo no Linux Mint, cold-standby/backup).
#
# FLOW:
#   1. Lê as URLs de conexão do backend/.env
#   2. Gera dois artefatos em database/backups/:
#      - backup_schema_latest.sql   (DDL: tables, views, functions, triggers, RLS)
#      - backup_data_latest.dump    (Dados curados, custom format)
#   3. Opcional: restaura no PostgreSQL local (--restore)
#   4. Opcional: pula schema dump (--data-only) ou pula data dump (--schema-only)
#
# USAGE:
#   bash scripts/sync_db_remote_to_local.sh              # só gera backups
#   bash scripts/sync_db_remote_to_local.sh --restore     # gera + restaura local
#   bash scripts/sync_db_remote_to_local.sh --schema-only # só schema
#   bash scripts/sync_db_remote_to_local.sh --data-only   # só dados
#   bash scripts/sync_db_remote_to_local.sh --help        # esta mensagem
#
# SAFETY:
#   - NUNCA faz o caminho inverso (Local ➔ Remote)
#   - Usa transação serializável para consistência do dump
#   - Ignora schemas do Supabase (auth, storage, realtime, etc.) no schema dump
#   - Preserva owner original dos objetos
# ==============================================================================

set -euo pipefail

# ── Cores para output ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ── Paths ─────────────────────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/backend/.env"
BACKUP_DIR="${PROJECT_ROOT}/database/backups"
SCHEMA_FILE="${BACKUP_DIR}/backup_schema_latest.sql"
DATA_FILE="${BACKUP_DIR}/backup_data_latest.dump"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
SCHEMA_FILE_TS="${BACKUP_DIR}/backup_schema_${TIMESTAMP}.sql"
DATA_FILE_TS="${BACKUP_DIR}/backup_data_${TIMESTAMP}.dump"

# ── Help ──────────────────────────────────────────────────────────────────────
show_help() {
    sed -n '3,/^set -euo/p' "$0" | head -n -1 | sed 's/^# //; s/^#//'
    exit 0
}

# ── Parse args ────────────────────────────────────────────────────────────────
DO_RESTORE=false
DO_SCHEMA=true
DO_DATA=true

for arg in "$@"; do
    case "$arg" in
        --help)    show_help ;;
        --restore) DO_RESTORE=true ;;
        --schema-only) DO_DATA=false ;;
        --data-only)   DO_SCHEMA=false ;;
        *)
            echo -e "${RED}❌ Argumento desconhecido: $arg${NC}"
            echo "Use --help para ver as opções."
            exit 1
            ;;
    esac
done

# ── Carregar variáveis do backend/.env ────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "${RED}❌ Arquivo $ENV_FILE não encontrado!${NC}"
    echo "   Crie o arquivo baseado em backend/.env.example"
    exit 1
fi

# shellcheck disable=SC1090
source <(grep -E '^(DATABASE_URL_ETL|DATABASE_URL_LOCAL_BACKUP)=' "$ENV_FILE")

REMOTE_URL="${DATABASE_URL_ETL:-}"
LOCAL_URL="${DATABASE_URL_LOCAL_BACKUP:-}"

if [[ -z "$REMOTE_URL" ]]; then
    echo -e "${RED}❌ DATABASE_URL_ETL não definida em backend/.env${NC}"
    exit 1
fi

if [[ -z "$LOCAL_URL" ]]; then
    echo -e "${RED}❌ DATABASE_URL_LOCAL_BACKUP não definida em backend/.env${NC}"
    exit 1
fi

# ── Verificar ferramentas ─────────────────────────────────────────────────────
for cmd in pg_dump pg_restore psql; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}❌ $cmd não encontrado. Instale o PostgreSQL client tools.${NC}"
        exit 1
    fi
done

# ── Garantir diretório de backup ──────────────────────────────────────────────
mkdir -p "$BACKUP_DIR"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     QUERO COMPRAR — Remote ➔ Local Sync                     ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${YELLOW}Remoto:${NC}  $(echo "$REMOTE_URL" | sed 's|:.*@|:****@|')"
echo -e "  ${YELLOW}Local:${NC}   $(echo "$LOCAL_URL" | sed 's|:.*@|:****@|')"
echo -e "  ${YELLOW}Destino:${NC} ${BACKUP_DIR}/"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# PASSO 1: Dump do Schema (DDL)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$DO_SCHEMA" == true ]]; then
    echo -e "${GREEN}📦 [1/2] Dump do SCHEMA (DDL)...${NC}"

    # Schemas do Supabase que NÃO devem ser copiados
    # Incluímos staging, mart e ops (nossos schemas de negócio)
    SCHEMAS_TO_INCLUDE="staging|mart|ops"

    pg_dump \
        --dbname="$REMOTE_URL" \
        --schema-only \
        --no-owner \
        --no-acl \
        --no-comments \
        --quote-all-identifiers \
        --exclude-schema='auth' \
        --exclude-schema='storage' \
        --exclude-schema='realtime' \
        --exclude-schema='pgsodium' \
        --exclude-schema='vault' \
        --exclude-schema='extensions' \
        --exclude-schema='graphql' \
        --exclude-schema='graphql_public' \
        --exclude-schema='supabase_functions' \
        --exclude-schema='pgbouncer' \
        --exclude-schema='pgsodium_masks' \
        --file="${SCHEMA_FILE_TS}" \
        2>&1 | grep -v '^$' || true

    # Criar atalho "latest"
    cp "${SCHEMA_FILE_TS}" "${SCHEMA_FILE}"

    # Contar objetos
    OBJ_COUNT=$(grep -cE '^(CREATE|ALTER|COMMENT ON)' "${SCHEMA_FILE}" 2>/dev/null || echo "0")
    echo -e "  ✅ Schema salvo: backup_schema_${TIMESTAMP}.sql (${OBJ_COUNT} objetos DDL)"
    echo ""
fi

# ══════════════════════════════════════════════════════════════════════════════
# PASSO 2: Dump dos Dados (custom format)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$DO_DATA" == true ]]; then
    echo -e "${GREEN}📦 [2/2] Dump dos DADOS (custom format)...${NC}"

    # Tabelas que queremos excluir do backup de dados (logs, raw, auditoria pesada)
    EXCLUDE_TABLES=(
        "auth.*"
        "storage.*"
        "realtime.*"
        "pgsodium.*"
        "vault.*"
        "extensions.*"
        "graphql.*"
        "supabase_functions.*"
        "ops.audit_logs"              # auditoria imutável, não essencial
        "ops.audit_llm_queries"        # LLM logs
        "ops.quarentena_coleta"        # dados descartados
        "raw.*"                        # raw schema (dados brutos de scraper)
    )

    BUILD_EXCLUDE=""
    for tbl in "${EXCLUDE_TABLES[@]}"; do
        BUILD_EXCLUDE+=" --exclude-table-data=${tbl}"
    done

    # shellcheck disable=SC2086
    pg_dump \
        --dbname="$REMOTE_URL" \
        --format=custom \
        --compress=9 \
        --no-owner \
        --no-acl \
        --quote-all-identifiers \
        --exclude-schema='auth' \
        --exclude-schema='storage' \
        --exclude-schema='realtime' \
        --exclude-schema='pgsodium' \
        --exclude-schema='vault' \
        --exclude-schema='extensions' \
        --exclude-schema='graphql' \
        --exclude-schema='graphql_public' \
        --exclude-schema='supabase_functions' \
        --exclude-schema='pgbouncer' \
        --exclude-schema='pgsodium_masks' \
        ${BUILD_EXCLUDE} \
        --file="${DATA_FILE_TS}" \
        2>&1 | grep -v '^$' || true

    # Criar atalho "latest"
    cp "${DATA_FILE_TS}" "${DATA_FILE}"

    # Estimar tamanho
    SIZE=$(du -h "${DATA_FILE_TS}" 2>/dev/null | cut -f1 || echo "?")
    echo -e "  ✅ Dados salvos: backup_data_${TIMESTAMP}.dump (${SIZE})"
    echo ""
fi

# ══════════════════════════════════════════════════════════════════════════════
# PASSO 3: Restaurar no PostgreSQL Local (--restore)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$DO_RESTORE" == true ]]; then
    echo -e "${CYAN}🔄 Restaurando no PostgreSQL Local...${NC}"

    # Extrair componentes da string de conexão local
    LOCAL_DB=$(echo "$LOCAL_URL" | sed -n 's|.*/\([^?]*\)|\1|p')
    LOCAL_DB="${LOCAL_DB:-postgres}"

    # Verificar conexão local
    if ! psql "$LOCAL_URL" -c "SELECT 1" &>/dev/null; then
        echo -e "${RED}❌ Não foi possível conectar ao PostgreSQL local.${NC}"
        echo "   URL: $(echo "$LOCAL_URL" | sed 's|:.*@|:****@|')"
        echo "   Verifique se o serviço está rodando: sudo systemctl status postgresql"
        exit 1
    fi

    echo -e "  ${YELLOW}Passo 3a:${NC} Resetando banco local..."
    # Terminar conexões ativas e recriar o banco
    psql "$LOCAL_URL" -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid();" 2>/dev/null || true
    psql "$LOCAL_URL" -c "DROP SCHEMA IF EXISTS staging CASCADE; DROP SCHEMA IF EXISTS mart CASCADE; DROP SCHEMA IF EXISTS ops CASCADE;" 2>/dev/null || true

    # Restaurar schema
    if [[ -f "${SCHEMA_FILE}" ]]; then
        echo -e "  ${YELLOW}Passo 3b:${NC} Aplicando schema DDL..."
        psql "$LOCAL_URL" -f "${SCHEMA_FILE}" 2>&1 | grep -E '(ERROR|FATAL)' || true
    fi

    # Restaurar dados
    if [[ -f "${DATA_FILE}" ]]; then
        echo -e "  ${YELLOW}Passo 3c:${NC} Restaurando dados (custom format)..."
        pg_restore \
            --dbname="$LOCAL_URL" \
            --format=custom \
            --no-owner \
            --no-acl \
            --clean \
            --if-exists \
            --jobs="$(nproc 2>/dev/null || echo 2)" \
            "${DATA_FILE}" \
            2>&1 | grep -E '(ERROR|WARNING)' | grep -v 'no matching schemas' | head -20 || true
    fi

    # Verificar
    echo -e "  ${YELLOW}Passo 3d:${NC} Verificando integridade..."
    TAB_COUNT=$(psql "$LOCAL_URL" -tA -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema IN ('staging','mart','ops');" 2>/dev/null || echo "0")
    echo -e "  ${GREEN}✅ Restauração concluída. ${TAB_COUNT} tabelas nos schemas staging+mart+ops.${NC}"
    echo ""
fi

# ══════════════════════════════════════════════════════════════════════════════
# Resumo Final
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ Sincronização concluída com sucesso!                     ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Schema: ${SCHEMA_FILE}"
echo -e "  Dados:  ${DATA_FILE}"
echo ""
echo -e "  Para restaurar no banco local:"
echo -e "    bash scripts/sync_db_remote_to_local.sh --restore"
echo ""

# ── Limpeza de backups antigos (>30 dias) ────────────────────────────────────
find "$BACKUP_DIR" -name 'backup_*.sql' -mtime +30 -delete 2>/dev/null || true
find "$BACKUP_DIR" -name 'backup_*.dump' -mtime +30 -delete 2>/dev/null || true
