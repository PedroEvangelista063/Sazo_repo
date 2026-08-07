#!/usr/bin/env python3
"""
disk_report.py — Relatório de uso de disco do banco (Aiven).

Mostra:
  1. Nível do NÓ (capacidade × usado × livre) via Aiven API — quando
     AIVEN_API_TOKEN + AIVEN_PROJECT + AIVEN_SERVICE estiverem definidos
     (env var ou backend/.env). AIVEN_PROJECT/SERVICE podem ser derivados
     do host da DSN (heurística; sobrescreva via env se necessário).
  2. Uso via SQL: tamanho do banco atual, soma de todos os bancos do nó,
     top N tabelas por tamanho (dados + índices) e janela temporal da
     fact_precos_mensais/sazonalidade_produto.
  3. Estimativa de crescimento mensal da fact_precos_mensais
     (bytes/linha × média de linhas/mês dos últimos 6 meses completos).

USO:
  python3 ops/disk_report.py              # relatório completo
  python3 ops/disk_report.py --top 20     # top 20 tabelas
  python3 ops/disk_report.py --db-url "postgresql://..."   # override DSN

Variáveis de ambiente (ou backend/.env):
  DATABASE_URL (ou DATABASE_URL_PRIMARY/ETL) → conexão SQL
  AIVEN_API_TOKEN + AIVEN_PROJECT + AIVEN_SERVICE → disco do nó via API

Dependências: psycopg2-binary (HTTP via stdlib urllib — zero deps extras).
Exit: 0 = OK; 1 = erro de conexão/consulta (relatório SQL falha).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import psycopg2

_CONNECT_TIMEOUT_SECONDS = 30
_API_TIMEOUT_SECONDS = 30
_PROJ = Path(__file__).resolve().parent.parent
_ENV_FILE = _PROJ / "backend" / ".env"


# ── Resolução de ambiente (env > backend/.env) ──────────────────────────────
def _strip_quotes(value: str) -> str:
    return value.strip().strip('"').strip("'")


def _read_env(keys: tuple[str, ...]) -> str | None:
    """Lê a primeira chave presente em backend/.env (parse stdlib, sem dotenv)."""
    if not _ENV_FILE.is_file():
        return None
    for key in keys:
        pattern = re.compile(rf"^\s*(?:export\s+)?{re.escape(key)}=(.*)$")
        with _ENV_FILE.open(encoding="utf-8") as fh:
            for line in fh:
                match = pattern.match(line)
                if match:
                    value = _strip_quotes(match.group(1))
                    if value:
                        return value
    return None


def _env(*keys: str) -> str | None:
    for key in keys:
        value = os.environ.get(key)
        if value:
            return _strip_quotes(value)
    return _read_env(keys)


def _resolve_dsn(cli_url: str | None) -> str:
    """Resolve a DSN: --db-url > env DATABASE_URL > backend/.env."""
    url = cli_url or _env("DATABASE_URL", "DATABASE_URL_PRIMARY", "DATABASE_URL_ETL")
    if not url:
        raise SystemExit(
            "[DISK] Nenhuma DATABASE_URL encontrada. Exporte DATABASE_URL, "
            "use --db-url ou configure backend/.env."
        )
    if "sslmode" not in url and "localhost" not in url and "127.0.0.1" not in url:
        sep = "&" if "?" in url else "?"
        url = f"{url}{sep}sslmode=require"
    return url


def _host_of(dsn: str) -> str:
    match = re.search(r"//[^@]*@([^:/?]+)", dsn)
    return match.group(1) if match else "desconhecido"


# ── Aiven API (disco do nó) ─────────────────────────────────────────────────
def _aiven_parts(host: str) -> tuple[str | None, str | None]:
    """Heurística: host 'svc-proj-node.aivencloud.com' → (service, project)."""
    core = host.split(".")[0] if ".aivencloud.com" in host else ""
    parts = core.split("-")
    if len(parts) >= 3:
        return "-".join(parts[:-2]), parts[-2]  # service, project
    return None, None


def _fetch_node_disk(host: str) -> tuple[int | None, int | None, str]:
    """Retorna (capacity_mb, used_mb, nota). None/None se indisponível."""
    token = _env("AIVEN_API_TOKEN")
    if not token:
        return None, None, "AIVEN_API_TOKEN ausente — configure para ver o disco do nó"

    guess_service, guess_project = _aiven_parts(host)
    project = _env("AIVEN_PROJECT") or guess_project
    service = _env("AIVEN_SERVICE") or guess_service
    if not project or not service:
        return (
            None,
            None,
            (
                "AIVEN_PROJECT/AIVEN_SERVICE não resolvidos (host não-Aiven ou "
                "heurística falhou) — defina-os via env"
            ),
        )

    url = (
        "https://api.aiven.io/v1/project/"
        f"{urllib.parse.quote(project)}/service/{urllib.parse.quote(service)}"
    )
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=_API_TIMEOUT_SECONDS) as resp:
            data = json.load(resp)
    # Seção do nó é estritamente não-fatal: qualquer falha de rede, HTTP ou
    # JSON inválido (página de erro/proxy) apenas vira nota no relatório.
    except urllib.error.HTTPError as exc:
        return (
            None,
            None,
            f"API Aiven HTTP {exc.code} (projeto/serviço '{project}/{service}'? token válido?)",
        )
    except (urllib.error.URLError, OSError) as exc:
        return None, None, f"API Aiven inalcançável: {exc}"
    except ValueError as exc:
        return None, None, f"API Aiven respondeu conteúdo inválido: {exc}"

    service_info = data.get("service", {})
    capacity = service_info.get("disk_space_capacity_mb")
    used = service_info.get("disk_space_used_mb")
    if capacity is None or used is None:
        return None, None, "API respondeu, mas disk_space_* não exposto neste plano"
    return int(capacity), int(used), ""


# ── SQL ──────────────────────────────────────────────────────────────────────
def _query(conn, sql: str, params: tuple | None = None) -> list[tuple]:
    with conn.cursor() as cur:
        cur.execute(sql, params or ())
        return cur.fetchall()


def _month_label(value: int) -> str:
    return f"{value // 100:04d}/{value % 100:02d}"


def _collect_sql(conn, top_n: int) -> dict:
    row = _query(
        conn,
        "SELECT pg_size_pretty(pg_database_size(current_database()))",
    )[0][0]
    row_all = _query(
        conn,
        "SELECT pg_size_pretty(sum(pg_database_size(datname))), count(*) "
        "FROM pg_database WHERE datallowconn",
    )[0]

    tables = _query(
        conn,
        """
        SELECT n.nspname || '.' || c.relname AS tabela,
               pg_total_relation_size(c.oid) AS total_bytes,
               pg_relation_size(c.oid) AS dados_bytes,
               pg_total_relation_size(c.oid) - pg_relation_size(c.oid) AS idx_bytes,
               c.reltuples::bigint AS linhas_aprox
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'm')
          AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
        ORDER BY pg_total_relation_size(c.oid) DESC
        LIMIT %s
        """,
        (top_n,),
    )

    # Janela temporal + bytes/linha + média de linhas/mês (6 meses completos).
    fact_window = _query(
        conn,
        "SELECT min(ano * 100 + mes), max(ano * 100 + mes), count(DISTINCT (ano, mes)) "
        "FROM staging.fact_precos_mensais",
    )[0]
    saz_window = _query(
        conn,
        "SELECT min(ano * 100 + mes), max(ano * 100 + mes) FROM mart.sazonalidade_produto",
    )[0]
    fact_bpr = _query(
        conn,
        """
        SELECT round(pg_total_relation_size(c.oid)::numeric / nullif(c.reltuples, 0)::numeric, 1)
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'staging' AND c.relname = 'fact_precos_mensais'
        """,
    )[0][0]
    fact_avg_month = _query(
        conn,
        """
        WITH m AS (
            SELECT ano, mes, count(*) AS cnt
            FROM staging.fact_precos_mensais
            GROUP BY ano, mes
            ORDER BY ano * 100 + mes DESC
            OFFSET 1  -- pula o mês atual (parcial)
            LIMIT 6
        )
        SELECT round(avg(cnt))
        FROM m
        """,
    )[0][0]

    return {
        "banco_atual": row,
        "todos_banco": row_all[0],
        "num_bancos": row_all[1],
        "top_tabelas": [
            {
                "tabela": t[0],
                "total": t[1],
                "dados": t[2],
                "indices": t[3],
                "linhas": t[4],
            }
            for t in tables
        ],
        "fact_janela": (
            _month_label(fact_window[0]),
            _month_label(fact_window[1]),
            fact_window[2],
        ),
        "saz_janela": (_month_label(saz_window[0]), _month_label(saz_window[1])),
        "fact_bytes_linha": fact_bpr,
        "fact_linhas_mes": fact_avg_month,
    }


# ── Relatório ────────────────────────────────────────────────────────────────
def _fmt_mb(value: int) -> str:
    """Formata um valor que JÁ ESTÁ em MB (não faz conversão)."""
    if value >= 1024:
        return f"{value / 1024:.1f} GB"
    return f"{value} MB"


def _print_report(
    sql: dict, host: str, capacity: int | None, used: int | None, api_note: str
) -> None:
    print(f"=== DISCO — {host} ===")

    print("\n[NÓ — Aiven API]")
    if capacity is not None and used is not None:
        free = capacity - used
        pct = used / capacity * 100
        status = "⚠️ CRÍTICO (>=90%)" if pct >= 90 else ("⚠️ ATENÇÃO (>=80%)" if pct >= 80 else "OK")
        print(f"  capacidade : {_fmt_mb(capacity)}")
        print(f"  usado      : {_fmt_mb(used)}  ({pct:.0f}%)  [{status}]")
        print(f"  livre      : {_fmt_mb(free)}")
    else:
        print(f"  — {api_note}")

    print("\n[BANCO — SQL]")
    print(f"  banco atual ({host}): {sql['banco_atual']}")
    print(f"  todos os bancos do nó: {sql['todos_banco']} (em {sql['num_bancos']} bancos)")

    print(f"\n[TOP {len(sql['top_tabelas'])} TABELAS]")
    print(f"  {'tabela':<46} {'total':>9} {'dados':>9} {'índices':>9} {'linhas':>12}")
    for t in sql["top_tabelas"]:
        linhas = f"{t['linhas']:,}" if t["linhas"] >= 0 else "n/d"
        print(
            f"  {t['tabela']:<46} {_fmt_mb(t['total'] // 1024 // 1024):>9} "
            f"{_fmt_mb(t['dados'] // 1024 // 1024):>9} {_fmt_mb(t['indices'] // 1024 // 1024):>9} "
            f"{linhas:>12}"
        )

    print("\n[JANELA TEMPORAL]")
    print(
        f"  fact_precos_mensais : {sql['fact_janela'][0]} .. {sql['fact_janela'][1]} "
        f"({sql['fact_janela'][2]} meses)"
    )
    print(f"  sazonalidade_produto: {sql['saz_janela'][0]} .. {sql['saz_janela'][1]}")

    if sql["fact_bytes_linha"] and sql["fact_linhas_mes"]:
        monthly_mb = sql["fact_bytes_linha"] * sql["fact_linhas_mes"] / 1_000_000
        print("\n[CRESCIMENTO ESTIMADO]")
        print(
            f"  fact_precos_mensais: ~{sql['fact_linhas_mes']:,} linhas/mês × "
            f"{sql['fact_bytes_linha']} B/linha ≈ {monthly_mb:.1f} MB/mês "
            "(até o fim da janela temporal)"
        )


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Relatório de uso de disco do banco.")
    parser.add_argument("--db-url", help="DSN do banco (override do backend/.env)")
    parser.add_argument("--top", type=int, default=12, help="Top N tabelas (padrão: 12)")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        dsn = _resolve_dsn(args.db_url)
    except SystemExit as exc:
        print(exc, file=sys.stderr)
        return 1

    try:
        conn = psycopg2.connect(dsn, connect_timeout=_CONNECT_TIMEOUT_SECONDS)
    except psycopg2.Error as exc:
        print(f"[DISK] Falha ao conectar: {exc}", file=sys.stderr)
        return 1

    try:
        sql_report = _collect_sql(conn, args.top)
    except psycopg2.Error as exc:
        print(f"[DISK] Falha na consulta: {exc}", file=sys.stderr)
        return 1
    finally:
        conn.close()

    capacity, used, api_note = _fetch_node_disk(_host_of(dsn))
    _print_report(sql_report, _host_of(dsn), capacity, used, api_note)
    return 0


if __name__ == "__main__":
    sys.exit(main())
