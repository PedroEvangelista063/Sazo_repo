#!/usr/bin/env bash
# ==============================================================================
# smoke_staging.sh — Smoke Test do Ambiente de HOMOLOGAÇÃO (FÍSICO/LOCAL)
# ==============================================================================
# QUERO COMPRAR — Dual-Environment (FASE 3: Guardião do Portão)
#
# Verifica que o backend está de pé e que a rota de sazonalidade nacional
# responde SEM HTTP 500 e SEM status_cor nulo/"CINZA" (Regra de Ouro:
# NO GRAY / NO NULL — o Deep Fallback preenche a grade).
#
# USO:
#   bash scripts/smoke_staging.sh              # usa backend já rodando
#   SMOKE_START_BACKEND=1 bash scripts/smoke_staging.sh   # sobe backend se down
#   SMOKE_BASE_URL=http://127.0.0.1:8000 bash scripts/smoke_staging.sh
#   SKIP_STAGING_SMOKE=1 <qualquer commit>     # bypass documentado (emergência)
#
# EXIT: 0 = PASS | 1 = FAIL (aborta commit/push)
# ==============================================================================

if [ "${SKIP_STAGING_SMOKE:-0}" = "1" ]; then
    echo -e "\033[0;33m[guarda] SKIP_STAGING_SMOKE=1 — smoke de homologação ignorado.\033[0m"
    exit 0
fi

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SMOKE_BASE_URL="${SMOKE_BASE_URL:-http://127.0.0.1:8000}"
SMOKE_ANO="${SMOKE_ANO:-2025}"
SMOKE_START_BACKEND="${SMOKE_START_BACKEND:-1}"
SMOKE_WAIT="${SMOKE_WAIT:-60}"
SMOKE_PORT="${SMOKE_PORT:-8000}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
BACKEND_PID=""

cleanup() {
    if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        kill "$BACKEND_PID" 2>/dev/null || true
        wait "$BACKEND_PID" 2>/dev/null || true
        echo -e "${YELLOW}[smoke] backend temporário encerrado (PID $BACKEND_PID).${NC}"
    fi
}
trap cleanup EXIT

health_ok() {
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$SMOKE_BASE_URL/health" 2>/dev/null || echo 000)
    [ "$code" = "200" ]
}

echo -e "${YELLOW}── Smoke de Homologação (${SMOKE_BASE_URL}) ──${NC}"

if health_ok; then
    echo -e "${GREEN}[smoke] backend já responde /health — reutilizando.${NC}"
else
    if [ "${SMOKE_START_BACKEND}" = "1" ]; then
        echo -e "${YELLOW}[smoke] backend offline — subindo uvicorn temporário na porta $SMOKE_PORT...${NC}"
        # exec: o subshell vira o próprio uvicorn — o PID capturado é o do
        # processo real, garantindo kill limpo no cleanup (trap EXIT).
        (cd "$ROOT" && exec env PYTHONPATH="$ROOT" python3 -m uvicorn backend.app.main:app \
            --host 127.0.0.1 --port "$SMOKE_PORT" >/tmp/qc_smoke_backend.log 2>&1) &
        BACKEND_PID=$!
        waited=0
        until health_ok; do
            # Fail-fast: se o processo spawnado morreu (porta ocupada, import
            # error), não espera os SMOKE_WAIT inteiros — aborta com o log.
            if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
                echo -e "${RED}[smoke] ✗ backend morreu durante o boot. Últimas linhas do log:${NC}"
                tail -20 /tmp/qc_smoke_backend.log 2>/dev/null || true
                echo -e "${RED}[smoke] ✗ FAIL — banco de homologação indisponível ou startup quebrado.${NC}"
                exit 1
            fi
            sleep 2
            waited=$((waited + 2))
            if [ $waited -ge "$SMOKE_WAIT" ]; then
                echo -e "${RED}[smoke] ✗ backend não subiu em ${SMOKE_WAIT}s. Últimas linhas do log:${NC}"
                tail -15 /tmp/qc_smoke_backend.log 2>/dev/null || true
                echo -e "${RED}[smoke] ✗ FAIL — banco de homologação indisponível ou startup quebrado.${NC}"
                exit 1
            fi
        done
        echo -e "${GREEN}[smoke] backend subiu e responde /health.${NC}"
    else
        echo -e "${RED}[smoke] ✗ FAIL — backend de homologação offline em $SMOKE_BASE_URL.${NC}"
        echo -e "${RED}[smoke]   Suba o backend (npm run dev:backend) ou use SMOKE_START_BACKEND=1.${NC}"
        exit 1
    fi
fi

# ── Rota crítica: /br-sazonalidade (paginação push-down, FASE 78/79) ────────
BR_JSON=$(mktemp)
BR_CODE=$(curl -s -o "$BR_JSON" -w '%{http_code}' --max-time 90 \
    "$SMOKE_BASE_URL/api/v1/sazonalidade/br-sazonalidade?ano=$SMOKE_ANO&por_pagina=20" 2>/dev/null || echo 000)

if [ "$BR_CODE" != "200" ]; then
    echo -e "${RED}[smoke] ✗ FAIL — /br-sazonalidade respondeu HTTP $BR_CODE (esperado 200).${NC}"
    head -c 600 "$BR_JSON" 2>/dev/null || true
    rm -f "$BR_JSON"
    exit 1
fi

# ── Regra de Ouro: nenhum status_cor nulo ou CINZA na grade (NO GRAY/NO NULL)
if ! python3 - "$BR_JSON" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    payload = json.load(fh)

rows = payload.get("data", [])
cells = 0
bad = 0
for prod in rows:
    for mes in prod.get("meses", []):
        cells += 1
        sc = mes.get("status_cor")
        if sc is None or str(sc).upper() == "CINZA":
            bad += 1
            print(f"  status_cor inválido em {prod.get('produto')} mês {mes.get('mes')}: {sc!r}")

print(f"[smoke] /br-sazonalidade total={payload.get('total', '?')} produtos, {cells} células na página")
if bad:
    print(f"[smoke] ✗ {bad} célula(s) com status_cor nulo/CINZA — viola NO GRAY/NO NULL")
    sys.exit(1)
print("[smoke] ✓ 0 status_cor nulo/CINZA (NO GRAY / NO NULL OK)")
PY
then
    echo -e "${RED}[smoke] ✗ FAIL — payload da grade viola a Regra de Ouro (semáforo).${NC}"
    rm -f "$BR_JSON"
    exit 1
fi

rm -f "$BR_JSON"
echo -e "${GREEN}[smoke] ✓ PASS — backend de homologação saudável e grade semáforo íntegra.${NC}"
