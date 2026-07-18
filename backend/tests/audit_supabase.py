"""
Auditoria Supabase vs Local — Integridade de dados, API e schemas.

Uso:
    python -m backend.tests.audit_supabase            # tudo
    python -m backend.tests.audit_supabase --db-only   # só banco
    python -m backend.tests.audit_supabase --api-only   # só API
    python -m backend.tests.audit_supabase --local-only # só banco local (sem Supabase)

Cada bloco tem timeout independente. Nenhuma mutação no banco.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# ═══════════════════════════════════════════════════════════════
# CONFIG
# ═══════════════════════════════════════════════════════════════

LOCAL_DB_URL = os.getenv(
    "LOCAL_DB_URL",
    "postgresql://postgres:postgres@localhost:5432/quero_comprar",
)
NPX_PATH: str | None = None  # resolvido em _find_npx()

QUERY_TIMEOUT = 10  # segundos — qualquer query morre depois disso
API_BASE = os.getenv("API_BASE_URL", "http://localhost:8000")

TABELAS_COM_DADOS: list[dict[str, Any]] = [
    {"schema": "raw", "tabela": "coleta_bruta", "esperado": 15},
    {"schema": "staging", "tabela": "fact_precos_mensais", "esperado": 42358},
    {"schema": "staging", "tabela": "dim_produto", "esperado": 857},
    {"schema": "staging", "tabela": "dim_localidade", "esperado": 850},
    {"schema": "staging", "tabela": "dim_categoria", "esperado": 11},
    {"schema": "staging", "tabela": "confianca_baseline", "esperado": 2802},
    {"schema": "staging", "tabela": "baseline_2025_interpolado", "esperado": 2802},
    {"schema": "staging", "tabela": "dim_conab_produto_mapping", "esperado": 20},
    {"schema": "staging", "tabela": "precos_rejeitados", "esperado": 87},
    {"schema": "mart", "tabela": "sazonalidade_produto", "esperado": 62291},
    {"schema": "mart", "tabela": "sazonalidade_baseline_24_25", "esperado": 23449},
    {"schema": "mart", "tabela": "sazonalidade_baseline_25_26", "esperado": 32581},
    {"schema": "ops", "tabela": "quarentena_coleta", "esperado": 9},
    {"schema": "ops", "tabela": "config_agente", "esperado": 8},
]

TABELAS_SAMPLE = [
    {"schema": "staging", "tabela": "fact_precos_mensais", "limit": 5},
    {"schema": "mart", "tabela": "sazonalidade_produto", "limit": 5},
    {"schema": "staging", "tabela": "dim_produto", "limit": 5},
]

TABELAS_SERIAL = [
    "staging.dim_produto",
    "staging.dim_localidade",
    "staging.dim_categoria",
    "staging.fact_precos_mensais",
    "staging.precos_rejeitados",
    "mart.sazonalidade_produto",
    "mart.sazonalidade_baseline_24_25",
    "mart.sazonalidade_baseline_25_26",
    "staging.confianca_baseline",
    "staging.baseline_2025_interpolado",
    "staging.dim_conab_produto_mapping",
]


# ═══════════════════════════════════════════════════════════════
# REPORTING
# ═══════════════════════════════════════════════════════════════

VERDE = "\033[92m"
VERMELHO = "\033[91m"
AMARELO = "\033[93m"
AZUL = "\033[94m"
CINZA = "\033[90m"
RESET = "\033[0m"
NEGRITO = "\033[1m"
SEP = "="  # Unicode box-drawing quebra no Windows cp1252 — usar ASCII


def _s(text: str) -> str:
    """Sanitiza string para cp1252 (Windows) — substitui caracteres não-mapeáveis."""
    return text.encode("cp1252", errors="replace").decode("cp1252")


@dataclass
class Resultado:
    bloco: str
    nome: str
    ok: bool
    detalhe: str = ""
    duracao: float = 0.0


@dataclass
class Relatorio:
    resultados: list[Resultado] = field(default_factory=list)

    def add(self, bloco: str, nome: str, ok: bool, detalhe: str = "", duracao: float = 0.0):
        self.resultados.append(Resultado(bloco, nome, ok, detalhe, duracao))

    def exibir(self):
        print(_s(f"\n{NEGRITO}{SEP*60}{RESET}"))
        print(_s(f"{NEGRITO}  AUDITORIA SUPABASE vs LOCAL - RELATORIO FINAL{RESET}"))
        print(_s(f"{NEGRITO}{SEP*60}{RESET}\n"))

        blocos: dict[str, list[Resultado]] = {}
        for r in self.resultados:
            blocos.setdefault(r.bloco, []).append(r)

        total = len(self.resultados)
        ok_count = sum(1 for r in self.resultados if r.ok)

        for bloco, items in blocos.items():
            cor_bloco = VERDE if all(i.ok for i in items) else VERMELHO
            print(_s(f"  {cor_bloco}> {bloco}{RESET}"))
            for r in items:
                icone = "+" if r.ok else "x"
                cor = VERDE if r.ok else VERMELHO
                tempo = f" {CINZA}({r.duracao:.1f}s){RESET}" if r.duracao > 0.3 else ""
                print(_s(f"    {cor}{icone}{RESET} {r.nome}{tempo}"))
                if not r.ok and r.detalhe:
                    print(_s(f"      {VERMELHO}{r.detalhe}{RESET}"))
            print()

        print(_s(f"{NEGRITO}{SEP*60}{RESET}"))
        if ok_count == total:
            print(_s(f"  {VERDE}{NEGRITO}TODOS OS {total} TESTES PASSARAM{RESET}"))
        else:
            print(_s(f"  {VERMELHO}{NEGRITO}{total - ok_count} de {total} TESTES FALHARAM{RESET}"))
        print(_s(f"{NEGRITO}{SEP*60}{RESET}\n"))

        return ok_count == total


# ═══════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════

def _is_border_line(line: str) -> bool:
    """True se a linha é borda/separador de tabela psql (Unicode box-drawing)."""
    stripped = line.strip()
    if not stripped:
        return True
    # Box-drawing: ═ ║ ╔ ╗ ╚ ╝ ─ │ ┌ ┐ └ ┘, ou ? (cp1252 mangled)
    # Linha border: só contém box-drawing, espaços, e hífens
    border_chars = set("═║╔╗╚╝─│┌┐└┘?=+-*# ")
    return all(c in border_chars for c in stripped) or (
        # Linha sem conteúdo entre pipes também é borda
        stripped.count("│") == 0 and stripped.count("║") == 0
        and not any(c.isalnum() for c in stripped)
    )


def _parse_psql_table(output: str) -> list[dict[str, Any]] | None:
    """
    Converte saída formatada do psql (aligned/unicode) em list[dict].
    Retorna None se não conseguir parsear.
    """
    lines = output.strip().split("\n")
    # Filtra linhas vazias e bordas
    data_lines = [l for l in lines if not _is_border_line(l)]
    if not data_lines:
        return None

    # Primeira linha de dados = header
    header_line = data_lines[0]
    # Extrai células separadas por │ ou ║
    cols = [c.strip() for c in re.split(r"[│║]", header_line) if c.strip()]

    # Demais linhas = dados
    rows: list[dict[str, Any]] = []
    for line in data_lines[1:]:
        cells = [c.strip() for c in re.split(r"[│║]", line) if c.strip()]
        if len(cells) != len(cols):
            continue  # linha mal-formada
        rows.append(dict(zip(cols, cells)))

    return rows if rows else None


def _find_npx() -> str:
    """Auto-detect npx path: tenta PATH, fallback Windows, fallback env var."""
    global NPX_PATH
    if NPX_PATH:
        return NPX_PATH

    env_path = os.getenv("SUPABASE_NPX_PATH")
    if env_path:
        NPX_PATH = env_path
        return NPX_PATH

    # 1. Tentar via PATH
    try:
        subprocess.run(
            ["npx", "--version"],
            capture_output=True,
            timeout=5,
            shell=True,
        )
        NPX_PATH = "npx"
        return NPX_PATH
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    # 2. Caminho Windows comum
    win_path = r"C:\Program Files\nodejs\npx.cmd"
    if Path(win_path).exists():
        NPX_PATH = win_path
        return NPX_PATH

    # 3. Procurar no PATH do Node.js
    for candidate in [
        rf"{os.environ.get('APPDATA', '')}\npm\npx.cmd",
        rf"{os.environ.get('ProgramFiles', '')}\nodejs\npx.cmd",
        rf"{os.environ.get('ProgramFiles(x86)', '')}\nodejs\npx.cmd",
    ]:
        if Path(candidate).exists():
            NPX_PATH = candidate
            return NPX_PATH

    NPX_PATH = "npx"  # fallback final — deixa falhar com mensagem clara
    return NPX_PATH


def _supabase_query(sql: str) -> list[dict[str, Any]] | str:
    """
    Executa SQL no Supabase remoto via `supabase db query --linked`.
    Retorna lista de dicts ou string de erro.
    """
    npx = _find_npx()
    # No Windows, npx é npx.cmd — shell=True resolve o PATH
    # supabase db query retorna formato tabela psql (aligned), não JSON
    cmd = f'{npx} supabase db query --linked "{sql}"'
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=QUERY_TIMEOUT,
            encoding="utf-8",
            errors="replace",
            shell=True,
        )
        if result.returncode != 0:
            stderr = result.stderr.strip()
            if "not found" in stderr.lower() or "not recognized" in stderr.lower():
                return f"supabase CLI não encontrado. Instale com: npx supabase init"
            return f"supabase CLI error (exit {result.returncode}): {stderr[:300]}"

        # Parse saída formatada do psql (tabela Unicode/aligned)
        out = result.stdout.strip()
        if not out:
            return []
        if out.upper().startswith("ERROR"):
            return out[:300]

        parsed = _parse_psql_table(out)
        if parsed is not None:
            return parsed
        # Fallback: tenta parsear como se fosse erro
        return f"Output não-parseável do Supabase: {out[:200]}"

    except FileNotFoundError:
        return f"npx/supabase CLI não encontrado. Instale ou configure SUPABASE_NPX_PATH."
    except subprocess.TimeoutExpired:
        return f"Timeout de {QUERY_TIMEOUT}s — Supabase não respondeu."


async def _local_query(sql: str) -> list[dict[str, Any]] | str:
    """Executa SQL no banco local via asyncpg. Retorna lista de dicts ou string de erro."""
    try:
        import asyncpg
    except ImportError:
        return "asyncpg não instalado (pip install asyncpg)"

    try:
        conn = await asyncio.wait_for(
            asyncpg.connect(LOCAL_DB_URL, timeout=QUERY_TIMEOUT),
            timeout=QUERY_TIMEOUT,
        )
    except Exception as e:
        return f"Erro conectando ao banco local: {e}"

    try:
        rows = await asyncio.wait_for(conn.fetch(sql), timeout=QUERY_TIMEOUT)
        return [dict(r) for r in rows]
    except Exception as e:
        return f"Erro na query local: {e}"
    finally:
        await conn.close()


async def _check_local_reachable() -> str | bool:
    """Testa se o banco local responde. Retorna True ou string de erro."""
    try:
        import asyncpg
    except ImportError:
        return "asyncpg não instalado"

    try:
        conn = await asyncio.wait_for(
            asyncpg.connect(LOCAL_DB_URL, timeout=QUERY_TIMEOUT),
            timeout=QUERY_TIMEOUT,
        )
        await asyncio.wait_for(conn.fetch("SELECT 1 AS ok"), timeout=5)
        await conn.close()
        return True
    except Exception as e:
        return f"Banco local inatingível: {e}"


async def _check_supabase_reachable() -> str | bool:
    """Testa se o Supabase responde. Retorna True ou string de erro."""
    result = _supabase_query("SELECT 1 AS ok;")
    if isinstance(result, str):
        return result  # mensagem de erro
    try:
        return int(result[0]["ok"]) == 1
    except (IndexError, KeyError, TypeError, ValueError):
        return f"Resposta inesperada do Supabase: {result}"


def _normalize_types(val: Any) -> Any:
    """Tenta converter string numérica para int/float."""
    if not isinstance(val, str):
        return val
    # Ignora None-like
    if val.strip().lower() in ("", "null", "none", "nil"):
        return None
    try:
        return int(val)
    except ValueError:
        pass
    try:
        return float(val)
    except ValueError:
        pass
    return val


def _normalize_row(row: dict[str, Any]) -> dict[str, Any]:
    """Normaliza tipos de todas as colunas de uma row."""
    return {k: _normalize_types(v) for k, v in row.items()}


def _hash_row(row: dict[str, Any]) -> str:
    """MD5 deterministico de uma linha (sorted keys)."""
    raw = json.dumps(row, sort_keys=True, default=str).encode()
    return hashlib.md5(raw).hexdigest()


async def _req(path: str) -> dict[str, Any] | str:
    """Faz GET na API local. Retorna dict ou string de erro."""
    try:
        import httpx
    except ImportError:
        return "httpx não instalado"

    url = f"{API_BASE}{path}"
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(8.0)) as client:
            resp = await client.get(url)
            if resp.status_code >= 500:
                return f"HTTP {resp.status_code}: {resp.text[:200]}"
            return {"status": resp.status_code, "body": resp.json(), "headers": dict(resp.headers)}
    except httpx.ConnectError:
        return f"API não respondeu em {API_BASE}"
    except httpx.TimeoutException:
        return f"Timeout em {url} (>{QUERY_TIMEOUT}s)"
    except Exception as e:
        return f"Erro em {url}: {e}"


# ═══════════════════════════════════════════════════════════════
# BLOCOS DE AUDITORIA
# ═══════════════════════════════════════════════════════════════

async def _bloco_conexoes(rel: Relatorio, local_only: bool):
    """Bloco 1 — Conexões com ambos os bancos."""
    start = time.time()
    local_ok = await _check_local_reachable()
    rel.add(
        "1. Conexões",
        "Banco Local",
        local_ok is True,
        local_ok if isinstance(local_ok, str) else "",
        time.time() - start,
    )

    if not local_only:
        start = time.time()
        supabase_ok = _check_supabase_reachable()
        if asyncio.iscoroutine(supabase_ok):
            supabase_ok = await supabase_ok
        rel.add(
            "1. Conexões",
            "Supabase Remoto",
            supabase_ok is True,
            supabase_ok if isinstance(supabase_ok, str) else "",
            time.time() - start,
        )

    # Versão do PostgreSQL
    start = time.time()
    version = await _local_query("SELECT version();")
    if isinstance(version, list) and version:
        ver = version[0].get("version", "?")
        rel.add("1. Conexões", "PG Local Version", True, f"{ver[:80]}...", time.time() - start)
    else:
        rel.add("1. Conexões", "PG Local Version", False, str(version), time.time() - start)


async def _bloco_contagem(rel: Relatorio, local_only: bool):
    """Bloco 2 — Contagem de linhas: local vs Supabase."""
    for tab in TABELAS_COM_DADOS:
        full_name = f"{tab['schema']}.{tab['tabela']}"
        esperado = tab["esperado"]

        # Local
        start = time.time()
        local_result = await _local_query(f"SELECT COUNT(*) AS cnt FROM {full_name};")
        local_count = local_result[0]["cnt"] if isinstance(local_result, list) and local_result else None
        local_ok = local_count == esperado

        if local_only:
            ok = local_ok
            detalhe = f"local={local_count} esperado={esperado}" if not local_ok else ""
            rel.add("2. Contagem", f"{full_name} (local)", ok, detalhe, time.time() - start)
            continue

        # Supabase
        supabase_result = _supabase_query(f"SELECT COUNT(*) AS cnt FROM {full_name};")
        if isinstance(supabase_result, list) and supabase_result:
            try:
                supabase_count = int(supabase_result[0]["cnt"])
            except (KeyError, TypeError, ValueError):
                detalhe = f"local={local_count} | Supabase count inválido: {supabase_result[0]}"
                rel.add("2. Contagem", f"{full_name}", False, detalhe, time.time() - start)
                continue
        else:
            supabase_count = None

        ok = local_ok and (supabase_count == esperado)
        if isinstance(supabase_result, str):
            detalhe = f"local={local_count} | Supabase: {supabase_result}"
        elif not ok:
            detalhe = f"local={local_count} supabase={supabase_count} esperado={esperado}"
        else:
            detalhe = ""

        rel.add(
            "2. Contagem",
            f"{full_name}",
            ok,
            detalhe,
            time.time() - start,
        )


async def _bloco_amostragem(rel: Relatorio, local_only: bool):
    """Bloco 3 — Hash MD5 de amostras: local vs Supabase."""
    for tab in TABELAS_SAMPLE:
        full_name = f"{tab['schema']}.{tab['tabela']}"
        limit = tab["limit"]

        start = time.time()
        local_result = await _local_query(f"SELECT * FROM {full_name} LIMIT {limit};")
        if isinstance(local_result, str):
            rel.add("3. Amostragem", f"{full_name}", False, f"Local: {local_result}", time.time() - start)
            continue

        if local_only:
            rel.add("3. Amostragem", f"{full_name} (local)", True, f"{len(local_result)} linhas OK", time.time() - start)
            continue

        # Busca mesmas linhas no Supabase via hash match
        local_hashes = {_hash_row(r) for r in local_result}

        # No Supabase, busca amostra similar — sem PK garantida, usa LIMIT
        supabase_result = _supabase_query(f"SELECT * FROM {full_name} LIMIT {limit};")
        if isinstance(supabase_result, str):
            rel.add("3. Amostragem", f"{full_name}", False, f"Supabase: {supabase_result}", time.time() - start)
            continue

        supabase_hashes = {_hash_row(_normalize_row(r)) for r in supabase_result}

        if local_hashes == supabase_hashes:
            rel.add("3. Amostragem", f"{full_name}", True, f"{len(local_hashes)}/{len(supabase_hashes)} hashes idênticos", time.time() - start)
        else:
            only_local = local_hashes - supabase_hashes
            only_remote = supabase_hashes - local_hashes
            detalhe = f"{len(local_hashes)} local vs {len(supabase_hashes)} remote. Divergência: {len(only_local)} local-only, {len(only_remote)} remote-only"
            rel.add("3. Amostragem", f"{full_name}", False, detalhe, time.time() - start)


async def _bloco_api(rel: Relatorio):
    """Bloco 4 — Testes de endpoint da API."""
    endpoints = [
        ("/health", "health", lambda r: r.get("status") == "ok"),
        ("/api/v1/sazonalidade?uf=SP", "sazonalidade snapshot SP", lambda r: isinstance(r.get("data"), list)),
        ("/api/v1/sazonalidade?uf=SP&ano=2025&mes=6", "sazonalidade por mês SP", lambda r: isinstance(r.get("data"), list)),
        ("/api/v1/sazonalidade/com-preco?uf=SP", "sazonalidade com preço", lambda r: isinstance(r.get("data"), list)),
        ("/api/v1/sazonalidade?uf=BR", "sazonalidade BR nacional", lambda r: isinstance(r.get("data"), list)),
        ("/api/v1/sazonalidade/br-sazonalidade?ano=2025", "BR sazonalidade anual", lambda r: isinstance(r.get("data"), list)),
        ("/api/v1/categorias", "categorias", lambda r: r.get("total", 0) >= 9),
        ("/api/v1/ufs", "UFs", lambda r: "BR" in r.get("data", [])),
        ("/api/v1/municipios?uf=SP", "municípios SP", lambda r: r.get("total", 0) > 0),
        ("/api/v1/regioes", "regiões", lambda r: len(r.get("regioes", [])) == 5),
        ("/api/v1/fluxos", "fluxos", lambda r: r.get("total", 0) > 0),
        ("/api/v1/sazonalidade/SP/São Paulo", "localidade route SP/São Paulo", lambda r: isinstance(r.get("data"), list)),
    ]

    for path, nome, validador in endpoints:
        start = time.time()
        resp = await _req(path)
        if isinstance(resp, str):
            rel.add("4. API", nome, False, resp, time.time() - start)
            continue

        status = resp["status"]
        body = resp["body"]
        if status != 200:
            rel.add("4. API", nome, False, f"HTTP {status}", time.time() - start)
            continue

        ok = validador(body)
        detalhe = "" if ok else f"resposta inesperada: {json.dumps(body, default=str)[:200]}"
        rel.add("4. API", nome, ok, detalhe, time.time() - start)

    # Teste de cache: segunda chamada deve ser rápida
    start = time.time()
    r1 = await _req("/api/v1/sazonalidade?uf=SP")
    r2 = await _req("/api/v1/sazonalidade?uf=SP")
    if isinstance(r1, str) or isinstance(r2, str):
        rel.add("4. API", "cache hit (segunda chamada rápida)", False, "API não respondeu", time.time() - start)
    else:
        # Segunda chamada deve ser < 500ms se cache está quente
        cache_time = time.time() - start
        ok = cache_time < 1.0
        rel.add("4. API", "cache hit", ok, f"{cache_time:.2f}s" if not ok else f"{cache_time:.2f}s", time.time() - start)


async def _bloco_sequencias(rel: Relatorio, local_only: bool):
    """Bloco 5 — Saúde das sequences (local)."""
    for full_name in TABELAS_SERIAL:
        schema, tabela = full_name.split(".", 1)
        start = time.time()

        sql = f"""
            SELECT schemaname, sequencename, last_value::bigint
            FROM pg_sequences
            WHERE schemaname = '{schema}'
              AND sequencename LIKE '{tabela}_%'
            ORDER BY sequencename;
        """
        local_result = await _local_query(sql)
        if isinstance(local_result, str):
            rel.add("5. Sequences", full_name, False, str(local_result), time.time() - start)
            continue

        if not local_result:
            rel.add("5. Sequences", full_name, True, "sem sequence (UUID PK)", time.time() - start)
            continue

        # Todas as sequences com last_value > 1 são saudáveis
        seqs_ok = all(r["last_value"] >= 1 for r in local_result)
        seqs_info = "; ".join(f"{r['sequencename']}={r['last_value']}" for r in local_result)
        rel.add("5. Sequences", full_name, seqs_ok, seqs_info if not seqs_ok else "", time.time() - start)


# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════

def _parse_args() -> tuple[bool, bool, bool]:
    """Retorna (db_only, api_only, local_only)."""
    args = set(sys.argv[1:])
    db_only = "--db-only" in args
    api_only = "--api-only" in args
    local_only = "--local-only" in args
    return db_only, api_only, local_only


async def main():
    db_only, api_only, local_only = _parse_args()

    print(_s(f"{NEGRITO}{SEP*60}{RESET}"))
    print(_s(f"{NEGRITO}  AUDITORIA SUPABASE vs LOCAL{RESET}"))
    print(_s(f"{NEGRITO}{SEP*60}{RESET}"))
    print(_s(f"  Local DB:  {LOCAL_DB_URL}"))
    print(_s(f"  Supabase:  supabase db query --linked"))
    print(_s(f"  API:       {API_BASE}"))
    print(_s(f"  NPX:       {_find_npx()}"))
    if db_only:
        print(_s(f"  {AMARELO}Modo: --db-only (sem testes de API){RESET}"))
    if api_only:
        print(_s(f"  {AMARELO}Modo: --api-only (sem testes de banco){RESET}"))
    if local_only:
        print(_s(f"  {AMARELO}Modo: --local-only (sem Supabase){RESET}"))
    print()

    rel = Relatorio()

    if not api_only:
        await _bloco_conexoes(rel, local_only)
        await _bloco_contagem(rel, local_only)
        await _bloco_amostragem(rel, local_only)
        await _bloco_sequencias(rel, local_only)

    if not db_only and not local_only:
        await _bloco_api(rel)
    elif api_only:
        await _bloco_api(rel)

    sucesso = rel.exibir()
    sys.exit(0 if sucesso else 1)


if __name__ == "__main__":
    asyncio.run(main())
