#!/usr/bin/env bash
# Backup do PostgreSQL local (quero_comprar) — pg_dump -Fc.
#
# Lê a DSN de DATABASE_URL_PRIMARY (ou DATABASE_URL) do backend/.env, ou da env
# var DATABASE_URL. Gera um dump compactado com timestamp em database/backups/
# (diretório gitignored — ver .gitignore) e mantém apenas os últimos K backups.
#
# USO:
#   utilities/backup_local_db.sh                  # backup + retenção padrão (5)
#   BACKUP_KEEP=10 utilities/backup_local_db.sh   # reter 10
#   DATABASE_URL="postgresql://..." utilities/backup_local_db.sh  # override DSN
#
# Exit 0 = OK; exit 1 = erro (DSN ausente, pg_dump falhou, etc).
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$PROJ/backend/.env"
OUT_DIR="${BACKUP_DIR:-$PROJ/database/backups}"
KEEP="${BACKUP_KEEP:-5}"

# ── Resolve DSN ──────────────────────────────────────────────────────────────
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

# ── Backup ───────────────────────────────────────────────────────────────────
mkdir -p "$OUT_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/quero_comprar-$TS.dump"
echo "==> pg_dump → $OUT"
pg_dump "$DSN" -Fc --no-owner --no-privileges -f "$OUT"
SIZE="$(du -h "$OUT" | cut -f1)"

# ── Retenção: mantém apenas os últimos K ────────────────────────────────────
COUNT="$(ls -1 "$OUT_DIR"/quero_comprar-*.dump 2>/dev/null | wc -l)"
if [ "$COUNT" -gt "$KEEP" ]; then
  ls -1t "$OUT_DIR"/quero_comprar-*.dump | tail -n "+$((KEEP + 1))" | xargs -r rm -f
  echo "   (removidos backups antigos além dos $KEEP mais recentes)"
fi

echo "OK: $OUT ($SIZE) — $KEEP backups mais recentes mantidos em $OUT_DIR"
