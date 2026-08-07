#!/usr/bin/env bash
# =============================================================================
# QUERY DBA — Conexão segura com o PostgreSQL local do Quero Comprar
# =============================================================================
# Lê a DATABASE_URL_PRIMARY do backend/.env (gitignored) e executa queries.
# Não expõe a senha em lugar nenhum. 100% read-only por padrão.
#
# USO:
#   ./conectar_dba.sh "SELECT version();"        # executa uma query
#   ./conectar_dba.sh -f 01_health_visao_geral.sql   # executa um arquivo .sql
#   ./conectar_dba.sh -l                          # lista tabelas do banco
#   ./conectar_dba.sh -c                          # só testa a conexão
#
# Variáveis de ambiente (override):
#   DATABASE_URL_DBA="postgresql://user:pass@host:port/db" ./conectar_dba.sh ...
# =============================================================================
set -euo pipefail

# ── 1. Descobrir a URL de conexão ──────────────────────────────────────────
# Prioridade: env explícita → backend/.env (PRIMARY) → backend/.env (LOCAL_BACKUP)
if [[ -z "${DATABASE_URL_DBA:-}" ]]; then
  ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/backend/.env"
  if [[ -f "$ENV_FILE" ]]; then
    DATABASE_URL_DBA="$(grep -E '^DATABASE_URL_PRIMARY=' "$ENV_FILE" | head -1 | cut -d'=' -f2- | tr -d '"')"
    if [[ -z "$DATABASE_URL_DBA" ]]; then
      DATABASE_URL_DBA="$(grep -E '^DATABASE_URL_LOCAL_BACKUP=' "$ENV_FILE" | head -1 | cut -d'=' -f2- | tr -d '"')"
    fi
  fi
fi

if [[ -z "$DATABASE_URL_DBA" ]]; then
  echo "❌ Nenhuma URL de conexão encontrada." >&2
  echo "   Configure DATABASE_URL_DBA ou backend/.env (DATABASE_URL_PRIMARY)." >&2
  exit 1
fi

# ── 2. Sanidade: proíbe conexão remota acidental em modo de escrita ────────
if [[ "$DATABASE_URL_DBA" != *"localhost"* && "$DATABASE_URL_DBA" != *"127.0.0.1"* ]]; then
  echo "⚠️  ATENÇÃO: a URL aponta para um host REMOTO ($(echo "$DATABASE_URL_DBA" | sed 's|//[^@]*@|//***@|'))" >&2
  echo "   Este kit é para o banco LOCAL. Para o remoto use o SQL Editor do dashboard." >&2
  read -r -p "   Continuar mesmo assim? [s/N] " resp
  [[ "$resp" =~ ^[sS]$ ]] || exit 1
fi

PSQL_ARGS=(-X -v ON_ERROR_STOP=1)

# ── 3. Modos ───────────────────────────────────────────────────────────────
if [[ "$#" -eq 0 ]]; then
  echo "❌ Informe uma query ou use -f arquivo.sql" >&2
  echo "   Uso: $0 \"SELECT 1;\" | $0 -f arquivo.sql | $0 -l | $0 -c" >&2
  exit 1
fi

case "$1" in
  -c)
    echo "🩺 Testando conexão com o banco local..."
    psql "${PSQL_ARGS[@]}" "$DATABASE_URL_DBA" -t -c "SELECT '✅ Conectado! PostgreSQL ' || version();"
    ;;
  -l)
    echo "🗂️  Tabelas do banco (camadas raw/staging/mart/ops):"
    psql "${PSQL_ARGS[@]}" "$DATABASE_URL_DBA" -c \
      "SELECT schemaname || '.' || tablename AS tabela FROM pg_tables
       WHERE schemaname IN ('raw','staging','mart','ops') ORDER BY 1;"
    ;;
  -f)
    FILE="${2:?Informe o caminho do arquivo .sql}"
    [[ -f "$FILE" ]] || { echo "❌ Arquivo não encontrado: $FILE" >&2; exit 1; }
    echo "▶️  Executando $FILE ..."
    psql "${PSQL_ARGS[@]}" "$DATABASE_URL_DBA" -f "$FILE"
    ;;
  *)
    psql "${PSQL_ARGS[@]}" "$DATABASE_URL_DBA" -c "$1"
    ;;
esac
