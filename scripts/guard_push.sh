#!/usr/bin/env bash
# ==============================================================================
# guard_push.sh — Garantia Final do pre-push (FASE 3)
# ==============================================================================
# QUERO COMPRAR — Fail-Fast: nenhum `git push` envia código quebrado para o
# remoto (GitHub → Vercel/Render faria deploy de código quebrado).
#
# Roda ANTES de cada push:
#   1. guard_commit (typecheck + smoke de homologação)
#   2. suíte de testes do backend (pytest)
#   3. suíte de testes do frontend (vitest)
#
# Bypass de emergência: SKIP_PUSH_TESTS=1 (pula apenas a suíte de testes;
# o guard_commit sempre roda — use SKIP_GUARD_COMMIT=1 + SKIP_PUSH_TESTS=1
# apenas em emergência real e documente no commit).
#
# EXIT: 0 = PASS | 1 = FAIL (aborta o push)
# ==============================================================================

if [ "${SKIP_GUARD_PUSH:-0}" = "1" ]; then
    echo -e "\033[0;33m[guarda] SKIP_GUARD_PUSH=1 — guardião do push ignorado.\033[0m"
    exit 0
fi

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
FAILED=0

echo -e "\033[1;35m── Garantia Final (pre-push) ──\033[0m"

# ── 1) Guardião do commit (typecheck + smoke) ───────────────────────────────
if ! bash "$ROOT/scripts/guard_commit.sh"; then
    echo -e "${RED}[guarda] ✗ guard_commit falhou — push ABORTADO.${NC}"
    FAILED=1
fi

# ── 2) Suíte de testes integrados ───────────────────────────────────────────
if [ "${SKIP_PUSH_TESTS:-0}" = "1" ]; then
    echo -e "\033[0;33m[guarda] SKIP_PUSH_TESTS=1 — suíte de testes pulada.\033[0m"
elif [ "$FAILED" = "0" ]; then
    echo -e "\033[0;36m[guarda] pytest (backend/tests)...\033[0m"
    if ! (cd "$ROOT" && python3 -m pytest backend/tests -q --no-header 2>&1 | tail -25); then
        echo -e "${RED}[guarda] ✗ testes do backend falharam.${NC}"
        FAILED=1
    fi

    echo -e "\033[0;36m[guarda] vitest (frontend)...\033[0m"
    if ! (cd "$ROOT/frontend" && npx vitest run 2>&1 | tail -25); then
        echo -e "${RED}[guarda] ✗ testes do frontend falharam.${NC}"
        FAILED=1
    fi
fi

if [ "$FAILED" = "1" ]; then
    echo -e "${RED}[guarda] ✗ PORTÃO FECHADO — push bloqueado. Corrija e tente novamente.${NC}"
    exit 1
fi

echo -e "${GREEN}[guarda] ✓ PORTÃO ABERTO — push liberado.${NC}"
