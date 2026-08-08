"""Bootstrap do banco local de standby (fallback).

Quando o failover ativa o modo `fallback`, o banco local precisa ter o schema
mínimo para servir consultas. Este módulo:

  1. Inspeciona o banco local (via to_regclass na MV mart ou contagem de tabelas).
  2. Se vazio, aplica o dump de schema de referência
     (``database/backups/backup_schema_latest.sql``) usando o binário ``psql``
     com ``-v ON_ERROR_STOP=1`` (multi-statement do pg_dump não vai bem por
     ``asyncpg`` sem particionar o arquivo).
  3. NUNCA derruba o startup: se a inspeção ou a aplicação falharem, apenas
     registra no log e a aplicação segue online (o health relata o modo ativo).
"""

import asyncio
import logging
import os
import shutil
import subprocess
from pathlib import Path

import asyncpg

from backend.app.core.config import get_settings

logger = logging.getLogger(__name__)

_BOOTSTRAP_LOCK = asyncio.Lock()
_BOOTSTRAPPED = False

_PSQL_BIN = "/usr/bin/psql"
_PSQL_TIMEOUT_SECONDS = 120
_CONNECT_TIMEOUT_SECONDS = 20


def _repo_root() -> Path:
    """Raiz do repositório a partir deste arquivo (backend/app/db/...)."""
    return Path(__file__).resolve().parents[3]


def _fallback_url() -> str:
    s = get_settings()
    return s.database_url_local_backup or s.database_url


async def ensure_mv_refresh_log(pool) -> None:
    """Garante a tabela ``audit.mv_refresh_log`` (DDL idempotente).

    Fonte permission-safe do ``X-Last-Refresh``: a esteira ETL grava o
    timestamp de cada REFRESH da MV aqui, porque Aiven nega
    ``pg_stat_file`` para os papéis padrão. Nunca quebra o startup.
    """
    try:
        await pool.execute(
            "CREATE SCHEMA IF NOT EXISTS audit; "
            "CREATE TABLE IF NOT EXISTS audit.mv_refresh_log ("
            "  mv_name text PRIMARY KEY,"
            "  refreshed_at timestamptz NOT NULL DEFAULT now()"
            ")"
        )
        logger.info("[BOOTSTRAP] audit.mv_refresh_log garantida.")
    except Exception as exc:  # noqa: BLE001  # metadata opcional: nunca quebra o startup
        logger.warning("[BOOTSTRAP] Não foi possível criar audit.mv_refresh_log: %s", exc)


def _resolve_schema_path() -> Path | None:
    s = get_settings()
    p = Path(s.bootstrap_schema_path)
    if not p.is_absolute():
        p = _repo_root() / p
    if not p.exists():
        logger.warning("[BOOTSTRAP] Dump de schema de referência não encontrado: %s", p)
        return None
    return p


async def _local_db_has_schema() -> bool:
    """True se o banco local já possui a MV mart ou tabelas base."""
    url = _fallback_url()
    try:
        conn = await asyncio.wait_for(
            asyncpg.connect(url, timeout=15, statement_cache_size=0),
            timeout=_CONNECT_TIMEOUT_SECONDS,
        )
    except Exception as exc:  # noqa: BLE001  # conectividade é imprevisível
        logger.warning("[BOOTSTRAP] Não foi possível inspecionar o banco local: %s", exc)
        return False
    try:
        mv = await conn.fetchval("SELECT to_regclass('mart.vw_api_produtos_sazonalidade')")
        if mv is not None:
            return True
        tables = await conn.fetchval(
            "SELECT count(*) FROM information_schema.tables "
            "WHERE table_schema IN ('public', 'mart', 'ops', 'staging', 'raw')"
        )
        return bool(tables and tables > 0)
    finally:
        await conn.close()


def _apply_schema_via_psql(url: str, schema_path: Path) -> bool:
    """Aplica o dump (multi-statement) via psql com ON_ERROR_STOP=1. Timeout 120s."""
    psql = shutil.which("psql") or _PSQL_BIN
    if not os.path.exists(psql):
        logger.error("[BOOTSTRAP] Binário psql não encontrado: %s", psql)
        return False
    cmd = [psql, url, "-v", "ON_ERROR_STOP=1", "-f", str(schema_path), "-q"]
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=_PSQL_TIMEOUT_SECONDS, check=False
        )
    except subprocess.TimeoutExpired:
        logger.error(
            "[BOOTSTRAP] Timeout ao aplicar schema (limite de %ds).", _PSQL_TIMEOUT_SECONDS
        )
        return False
    if proc.returncode != 0:
        logger.error(
            "[BOOTSTRAP] Falha ao aplicar schema (exit=%d): %s",
            proc.returncode,
            (proc.stderr or proc.stdout)[-2000:],
        )
        return False
    return True


async def run_bootstrap_once() -> bool:
    """Verifica e, se necessário, aplica o schema no banco local. No máximo uma vez por processo."""
    global _BOOTSTRAPPED
    async with _BOOTSTRAP_LOCK:
        if _BOOTSTRAPPED:
            return True
        _BOOTSTRAPPED = True

    schema = _resolve_schema_path()
    if schema is None:
        return False

    if await _local_db_has_schema():
        logger.info("[BOOTSTRAP] Banco local já possui schema — bootstrap ignorado.")
        return True

    logger.info("[BOOTSTRAP] Banco local vazio. Aplicando schema a partir do dump de referência...")
    ok = await asyncio.to_thread(_apply_schema_via_psql, _fallback_url(), schema)
    if ok:
        logger.info("[BOOTSTRAP] Schema aplicado com sucesso no banco local.")
    else:
        logger.error(
            "[BOOTSTRAP] Falha ao aplicar schema — a aplicação segue online, "
            "mas o banco local pode estar incompleto."
        )
    return ok
