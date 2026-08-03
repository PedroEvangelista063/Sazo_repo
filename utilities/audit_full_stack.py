#!/usr/bin/env python3
"""Auditoria full-stack — integridade do banco PRIMARY/fallback + API + frontend.

Verifica, sem expor segredos (lê URLs do backend/.env):
  1. Banco PRIMARY  (local) — conexão, contagens-chave, MV populada, frescor
  2. Banco FALLBACK (remoto) — conexão e leituras (funciona mesmo em read-only)
  3. API            — /health (db_mode) e 1 endpoint, se o backend estiver no ar
  4. Frontend       — roda `npm test` (vitest) em frontend/

USO:
    python3 utilities/audit_full_stack.py            # tudo
    python3 utilities/audit_full_stack.py --no-api   # pula checagem da API
    python3 utilities/audit_full_stack.py --no-frontend  # pula vitest

Exit 0 = tudo OK; exit 1 = alguma checagem falhou.
"""

import argparse
import asyncio
import subprocess
import sys
from pathlib import Path

import asyncpg

PROJ = Path(__file__).resolve().parent.parent
ENV_PATH = PROJ / "backend" / ".env"
API_HEALTH = "http://127.0.0.1:8000/health"
API_SAMPLE = "http://127.0.0.1:8000/api/v1/sazonalidade/br-sazonalidade?ano=2025"

KEY_COUNTS = [
    ("mart", "sazonalidade_produto"),
    ("mart", "vw_api_produtos_sazonalidade"),
    ("staging", "fact_precos_mensais"),
    ("ops", "audit_logs"),
]


def load_env():
    env = {}
    if ENV_PATH.exists():
        for line in ENV_PATH.read_text().splitlines():
            line = line.strip()
            if line and "=" in line and not line.startswith("#"):
                k, _, v = line.partition("=")
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


async def check_db(label: str, dsn: str, expect_db: str) -> list[str]:
    out = [f"[{label}] {dsn.split('@')[-1][:45]}"]
    try:
        c = await asyncpg.connect(dsn, timeout=15)
        db = await c.fetchval("SELECT current_database()")
        out.append(f"  banco: {db} ({'OK' if db == expect_db else 'DIFERENTE do esperado'})")
        for sch, tbl in KEY_COUNTS:
            try:
                n = await c.fetchval(f'SELECT count(*) FROM "{sch}"."{tbl}"')
                out.append(f"  {sch}.{tbl}: {n}")
            except Exception as e:  # noqa: BLE001
                out.append(f"  {sch}.{tbl}: ERRO {str(e)[:60]}")
        # frescor
        try:
            r = await c.fetchrow(
                "SELECT max(ano) AS a, max(mes) AS m FROM mart.sazonalidade_produto"
            )
            out.append(f"  frescor sazonalidade: ano={r['a']} mes={r['m']}")
        except Exception as e:  # noqa: BLE001
            out.append(f"  frescor sazonalidade: indisponível ({str(e)[:50]})")
        await c.close()
        return out
    except Exception as e:  # noqa: BLE001
        out.append(f"  ERRO de conexão: {type(e).__name__}: {str(e)[:90]}")
        return out


def check_api() -> list[str]:
    import urllib.error
    import urllib.request

    out = ["[API localhost:8000]"]
    try:
        with urllib.request.urlopen(API_HEALTH, timeout=5) as r:
            body = r.read().decode()
            out.append(f"  /health HTTP {r.status}: {body[:60]}")
        with urllib.request.urlopen(API_SAMPLE, timeout=15) as r:
            body = r.read().decode()
            import json

            total = json.loads(body).get("total", "?")
            out.append(f"  /br-sazonalidade?ano=2025 HTTP {r.status}: total={total}")
    except urllib.error.HTTPError as e:
        out.append(f"  ERRO HTTP {e.code}: {e.read()[:80]}")
    except Exception as e:  # noqa: BLE001
        out.append(f"  API fora do ar (ignorável se backend não está rodando): {str(e)[:70]}")
    return out


def check_frontend() -> list[str]:
    out = ["[Frontend vitest]"]
    try:
        r = subprocess.run(
            ["npm", "test"],
            cwd=PROJ / "frontend",
            capture_output=True,
            text=True,
            timeout=180,
            check=False,
        )
        tail = r.stdout.strip().splitlines()
        relevant = [
            ln for ln in tail if "Test Files" in ln or "Tests " in ln or "passed" in ln.lower()
        ][-2:]
        out.append("  " + " | ".join(relevant) if relevant else "  (sem resumo)")
        out.append(f"  exit={r.returncode} {'OK' if r.returncode == 0 else 'FALHOU'}")
    except Exception as e:  # noqa: BLE001
        out.append(f"  ERRO: {str(e)[:80]}")
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--no-api", action="store_true")
    parser.add_argument("--no-frontend", action="store_true")
    args = parser.parse_args()

    env = load_env()
    primary = env.get("DATABASE_URL_PRIMARY") or env.get("DATABASE_URL")
    fallback = env.get("DATABASE_URL_FALLBACK")
    if not primary:
        print("ERRO: DATABASE_URL_PRIMARY não encontrada em backend/.env")
        return 1

    sections = []
    sections.append(asyncio.run(check_db("PRIMARY (local)", primary, "quero_comprar")))
    if fallback:
        sections.append(asyncio.run(check_db("FALLBACK (remoto)", fallback, "defaultdb")))
    else:
        sections.append(["[FALLBACK] não configurado (DATABASE_URL_FALLBACK vazio) — aviso"])

    if not args.no_api:
        sections.append(check_api())
    if not args.no_frontend:
        sections.append(check_frontend())

    print("=" * 60)
    print("AUDITORIA FULL-STACK — quero_comprar_vg")
    print("=" * 60)
    failed = False
    for sec in sections:
        for line in sec:
            print(line)
        if any("FALHOU" in ln or "ERRO" in ln or "DIFERENTE" in ln for ln in sec):
            failed = True
    print("=" * 60)
    print("RESULTADO:", "❌ falha(s) encontrada(s)" if failed else "✅ tudo OK")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
