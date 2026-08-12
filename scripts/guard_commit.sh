#!/usr/bin/env bash
# ==============================================================================
# guard_commit.sh — Guardião do pre-commit (FASE 3)
# ==============================================================================
# QUERO COMPRAR — Fail-Fast: nenhum `git commit` passa com código quebrado.
#
# Roda ANTES de cada commit:
#   1. typecheck TypeScript (tsc --noEmit) — frontend
#   2. smoke de homologação (health + /br-sazonalidade sem 500 e sem CINZA/null)
#
# O lint Python/JS dos arquivos staged é feito pelo lint-staged (chamado antes
# deste script no .husky/pre-commit) — ruff --fix + prettier.
#
# Bypasses de emergência (documentados no docs/ARQUITETURA_AMBIENTES_CI_CD.md):
#   SKIP_TSC=1            pula o typecheck
#   SKIP_STAGING_SMOKE=1  pula o smoke de homologação
#
# EXIT: 0 = PASS | 1 = FAIL (aborta o commit)
# ==============================================================================

if [ "${SKIP_GUARD_COMMIT:-0}" = "1" ]; then
    echo -e "\033[0;33m[guarda] SKIP_GUARD_COMMIT=1 — guardião do commit ignorado.\033[0m"
    exit 0
fi

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
FAILED=0

echo -e "\033[1;36m── Guardião do Commit (pre-commit) ──\033[0m"

# ── 1) Typecheck TypeScript ────────────────────────────────────────────────
if [ "${SKIP_TSC:-0}" = "1" ]; then
    echo -e "\033[0;33m[guarda] SKIP_TSC=1 — typecheck pulado.\033[0m"
else
    echo -e "\033[0;36m[guarda] tsc --noEmit (frontend)...\033[0m"
    if (cd "$ROOT/frontend" && npx tsc --noEmit); then
        echo -e "${GREEN}[guarda] ✓ typecheck OK.${NC}"
    else
        echo -e "${RED}[guarda] ✗ typecheck falhou — corrija os erros de tipagem antes do commit.${NC}"
        FAILED=1
    fi
fi

# ── 2) Smoke de homologação ─────────────────────────────────────────────────
if [ "${SKIP_STAGING_SMOKE:-0}" = "1" ]; then
    echo -e "\033[0;33m[guarda] SKIP_STAGING_SMOKE=1 — smoke de homologação pulado.\033[0m"
else
    if ! bash "$ROOT/scripts/smoke_staging.sh"; then
        echo -e "${RED}[guarda] ✗ smoke de homologação falhou — commit ABORTADO.${NC}"
        FAILED=1
    fi
fi

if [ "$FAILED" = "1" ]; then
    echo -e "${RED}[guarda] ✗ PORTÃO FECHADO — corrija os itens acima e tente novamente.${NC}"
    exit 1
fi

echo -e "${GREEN}[guarda] ✓ PORTÃO ABERTO — commit liberado.${NC}"
