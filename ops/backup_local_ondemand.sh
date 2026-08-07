#!/usr/bin/env bash
# ============================================================================
# backup_local_ondemand.sh — Motor de Backup LOCAL sob demanda (BYOB).
# ----------------------------------------------------------------------------
# Gera um backup INTEGRAL do banco via pg_dump (formato plain SQL) comprimido
# em .sql.gz, nomeado com timestamp exato (backup_prd_YYYYMMDD_HHMM.sql.gz),
# no diretório estritamente LOCAL database/backups_locais/ (gitignored).
#
# Schemas de plataforma (auth/storage/realtime) são excluídos por convenção do
# projeto (ver database/summary.md) — protege contra falhas/permissão caso o
# script seja apontado para outro provedor; no Aiven eles não existem (inofensivo).
#
# Não dependemos dos backups automáticos da plataforma: este é o nosso próprio
# backup, executado manualmente e sob demanda.
#
# ⚠️ PROTOCOLO DE ACIONAMENTO:
#    - LOCAL (manual): somente comando explícito "Executar Backup Local".
#    - NUVEM: automação SOMENTE via Cron Job nativo do Render (render.yaml).
#      PROIBIDO cron no GitHub Actions ou background process. No Render o
#      disco é efêmero: DELETE_AFTER_UPLOAD=1 remove o .sql.gz local após o
#      upload confirmado (HTTP 200) no Object Storage (ops/storage.py).
#
# USO:
#   ops/backup_local_ondemand.sh                              # DSN do backend/.env
#   DATABASE_URL="postgresql://..." ops/backup_local_ondemand.sh  # override DSN
#   BACKUP_DIR=/mnt/disco_externo ops/backup_local_ondemand.sh    # override destino
#
# Exit 0 = OK; exit 1 = erro (DSN ausente, pg_dump/gzip falhou, integridade).
# ============================================================================
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$PROJ/backend/.env"
OUT_DIR="${BACKUP_DIR:-$PROJ/database/backups_locais}"

# ── 1. Resolve DSN (env var > backend/.env: PRIMARY > DATABASE_URL) ─────────
DSN="${DATABASE_URL:-}"
if [ -z "$DSN" ] && [ -f "$ENV_FILE" ]; then
  DSN="$(sed -n 's/^DATABASE_URL_PRIMARY=//p' "$ENV_FILE" | head -1 | tr -d '"' | tr -d "'")"
  if [ -z "$DSN" ]; then
    DSN="$(sed -n 's/^DATABASE_URL=//p' "$ENV_FILE" | head -1 | tr -d '"' | tr -d "'")"
  fi
fi
if [ -z "$DSN" ]; then
  echo "ERRO: DATABASE_URL não definida (env var nem backend/.env)" >&2
  exit 1
fi

# ── 2. Destino local + arquivo com timestamp exato ──────────────────────────
mkdir -p "$OUT_DIR"
TS="$(date +%Y%m%d_%H%M)"
OUT="$OUT_DIR/backup_prd_$TS.sql.gz"
TMP="$OUT.tmp"
trap 'rm -f "$TMP"' EXIT

HOST_LABEL="$(printf '%s' "$DSN" | sed -E 's#//[^@/]*@#//***@#')"
echo "==> pg_dump (backup integral) → $OUT"
echo "    origem: $HOST_LABEL"

# pg_dump imprime o dump no stdout; mensagens de progresso vão para stderr.
pg_dump "$DSN" --no-owner --no-privileges --no-acl \
    --exclude-schema=auth --exclude-schema=storage --exclude-schema=realtime \
    | gzip -c > "$TMP"
mv "$TMP" "$OUT"

# ── 3. Valida a integridade do .sql.gz ──────────────────────────────────────
gzip -t "$OUT"
SIZE="$(du -h "$OUT" | cut -f1)"
echo "OK: $OUT ($SIZE)"

# ── 4. Upload imediato para Object Storage (se configurado) ────────────────
#    ops/storage.py lê credenciais do ambiente/backend/.env (nunca hardcoded).
#    Exit 0 = configurado; 2 = não configurado (skip); 1/outro = erro → falha ALTA
#    (no Render, tratar erro como "não configurado" = perda silenciosa de backup).
#    Nota: `&& ... || ...` cria contexto condicional — evita o set -e matar o
#    script quando o check retorna exit != 0 (ex: 2 = não configurado).
python3 "$PROJ/ops/storage.py" check >/dev/null 2>&1 && STORAGE_RC=0 || STORAGE_RC=$?
if [ "$STORAGE_RC" -eq 0 ]; then
  if python3 "$PROJ/ops/storage.py" upload "$OUT"; then
    echo "    ☁ upload OK no Object Storage"
    if [ "${DELETE_AFTER_UPLOAD:-0}" = "1" ]; then
      rm -f "$OUT"
      echo "    🗑 arquivo temporário removido do disco (Render ephemeral)"
    fi
  else
    echo "    ⚠ upload FALHOU — arquivo mantido em $OUT (revise credenciais do storage)" >&2
    exit 1
  fi
elif [ "$STORAGE_RC" -eq 2 ]; then
  echo "    ℹ storage não configurado — backup mantido apenas localmente"
else
  echo "    ⚠ storage.py falhou (exit $STORAGE_RC) — upload NÃO confirmado; arquivo mantido em $OUT" >&2
  exit 1
fi
echo "    Backup é SOB DEMANDA / Render cron — nada automático em CI."
