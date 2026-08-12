#!/usr/bin/env bash
# ==============================================================================
# guard_commit.sh — Guardião do pre-commit (FASE 3 + fast-path)
# ==============================================================================
# QUERO COMPRAR — Fail-Fast: nenhum `git commit` passa com código quebrado.
#
# Roda ANTES de cada commit:
#   1. typecheck TypeScript (tsc --noEmit) — frontend
#   2. smoke de homologação (health + /br-sazonalidade sem 500 e sem CINZA/null)
#
# FAST-PATH (evita atrito em commits que não tocam código):
#   - Só docs/JSON/MD/yml/READMEs mudaram  → smoke pulado automaticamente
#   - Nenhum .ts/.tsx do frontend mudou    → tsc pulado automaticamente
#
# O lint Python/JS dos arquivos staged é feito pelo lint-staged (chamado antes
# deste script no .husky/pre-commit) — ruff --fix + prettier.
#
# Bypasses de emergência (documentados no docs/ARQUITETURA_AMBIENTES_CI_CD.md):
#   SKIP_TSC=1            pula o typecheck (mesmo com TS alterado)
#   SKIP_STAGING_SMOKE=1  pula o smoke de homologação (mesmo com código)
#   SKIP_GUARD_COMMIT=1   desliga o guardião inteiro (emergência real)
#
# EXIT: 0 = PASS | 1 = FAIL (aborta o commit)
# ==============================================================================

if [ "${SKIP_GUARD_COMMIT:-0}" = "1" ]; then
    echo -e "\033[0;33m[guarda] SKIP_GUARD_COMMIT=1 — guardião do commit ignorado.\033[0m"
    exit 0
fi

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
FAILED=0

echo -e "\033[1;36m── Guardião do Commit (pre-commit) ──\033[0m"

# ── Detecção de escopo (fast-path) ─────────────────────────────────────────
# O commit é definido pelo INDEX (o lint-staged re-stage os fixes antes deste
# script). Escopo = apenas arquivos STAGED — WIP não stageado não força checks.
_changed_files() {
    # ACMRD inclui DELETADOS: um .ts/.py removido pode quebrar referências de
    # tipos em outros arquivos — o guard deve rodar também nesse caso.
    git -C "$ROOT" diff --cached --name-only --diff-filter=ACMRD
}

# true se TODAS as mudanças são documentais (sem código executável)
_only_docs_changed() {
    local all_safe=1 any=0 f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        any=1
        case "$f" in
            *.md|*.json|*.yml|*.yaml|*.lock|*.svg|*.png|*.csv \
            |.gitignore|Makefile|render.yaml|vercel.json|components.json) ;;
            # NOTA: *.config.ts NÃO entra aqui (é TS — precisa de tsc);
            # arquivos DELETADOS (D) entram na lista via diff-filter=ACMRD.
            *) all_safe=0 ;;
        esac
    done < <(_changed_files)
    [ "$any" = "1" ] && [ "$all_safe" = "1" ]
}

# true se NENHUM arquivo de código do frontend mudou (tsc desnecessário)
_has_frontend_code() {
    local f
    while IFS= read -r f; do
        case "$f" in
            frontend/*.ts|frontend/*.tsx) return 0 ;;
        esac
    done < <(_changed_files)
    return 1
}

# ── 1) Typecheck TypeScript ────────────────────────────────────────────────
if [ "${SKIP_TSC:-0}" = "1" ]; then
    echo -e "\033[0;33m[guarda] SKIP_TSC=1 — typecheck pulado.\033[0m"
elif ! _has_frontend_code; then
    echo -e "${CYAN}[guarda] fast-path: sem código TS/TSX alterado — tsc pulado.${NC}"
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
elif _only_docs_changed; then
    echo -e "${CYAN}[guarda] fast-path: só docs/JSON/yml mudaram — smoke de homologação pulado.${NC}"
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
