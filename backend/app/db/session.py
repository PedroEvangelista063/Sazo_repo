"""Camada de acesso a dados com failover / Alta Disponibilidade.

Estratégia de resiliência:
  - `primary`: banco remoto (ex.: Aiven).
  - `fallback`: banco local de standby (mesmo schema, dados read-only).

Circuit breaker:
  primary -> (falha de conexão) -> fallback -> (cooldown expirado) -> half-open
  -> primary (sucesso) | fallback (falha).

OBSERVAÇÃO IMPORTANTE: `asyncpg.create_pool` é LAZY — ele cria o pool sem abrir
conexão de verdade e só falha no `pool.acquire()`. Por isso, ao criar um pool
em modo primário SEGUIMOS com um probe (`SELECT 1`) via acquire; se o probe
lançar erro de conexão, fazemos failover imediato para o banco local.
"""

import asyncio
import logging
import time
from typing import Any

import asyncpg

from backend.app.core.config import get_settings

logger = logging.getLogger(__name__)

_pool: dict[str, asyncpg.Pool | None] = {"api": None, "etl": None}
_pool_lock = asyncio.Lock()

_active_mode: str = "primary"
_mode_switched_at: float = 0.0
_COOLDOWN_SECONDS = 60.0

_KIND_TIMEOUT = {"api": 120, "etl": 60}

_RESTORE_HINT = (
    " Se o motivo for indisponibilidade do banco remoto (Aiven), confira o status "
    "do serviço no console Aiven e aguarde o half-open (~60s) reconectar — não é "
    "preciso reiniciar. O cold-standby local cobre o período de indisponibilidade."
)


def get_active_mode() -> str:
    """Retorna o modo ativo atual: ``"primary"`` ou ``"fallback"``."""
    return _active_mode


# ── Resolução de URLs ───────────────────────────────────────────────────────
def _resolve_url(key: str, fallback: str) -> str:
    val = getattr(get_settings(), key, "")
    return val if val else fallback


def _primary_url() -> str:
    """Base primária: DATABASE_URL_PRIMARY, senão o `database_url` legado."""
    s = get_settings()
    return s.database_url_primary or s.database_url


def _fallback_url() -> str:
    """Base de standby: DATABASE_URL_LOCAL_BACKUP (local), senão DATABASE_URL."""
    s = get_settings()
    return s.database_url_local_backup or s.database_url


def _resolve_pool_url(kind: str) -> str:
    """URL primária para o pool (leva em conta API/ETL quando configurados)."""
    primary = _primary_url()
    if kind == "api":
        return _resolve_url("database_url_api", primary)
    if kind == "etl":
        return _resolve_url("database_url_etl", primary)
    return primary


def _url_for_current_mode(kind: str) -> str:
    if _active_mode == "fallback":
        return _fallback_url()
    return _resolve_pool_url(kind)


# ── Classificação de erros ────────────────────────────────────────────────
def _is_conn_error(exc: Exception) -> bool:
    """True para erros que indicam banco inacessível (57P03, EAUTH, recusa de
    conexão, timeout). Sem isso, erros lógicos (query) não disparam failover."""
    return isinstance(exc, (asyncpg.PostgresError, TimeoutError, OSError))


# ── Criação e verificação de pool ──────────────────────────────────────────
async def _init_pool(url: str, max_conn: int, min_conn: int, command_timeout: int) -> asyncpg.Pool:
    return await asyncpg.create_pool(
        url,
        min_size=min_conn,
        max_size=max_conn,
        command_timeout=command_timeout,
        statement_cache_size=0,  # compatível com poolers em modo transaction (ex.: pgbouncer)
    )


async def _create_verified_pool(
    url: str, max_conn: int, min_conn: int, timeout: int
) -> asyncpg.Pool:
    """Cria o pool e força um probe real (`SELECT 1`) para vencer o create_pool lazy."""
    pool = await _init_pool(url, max_conn, min_conn, timeout)
    async with pool.acquire() as conn:
        await conn.fetchval("SELECT 1")
    return pool


def _pool_params(kind: str) -> tuple[int, int]:
    # FASE 2 (Dual-Environment): pool autotunado por APP_ENV via Settings.
    #   staging: pool folgado (padrão máx. 30) p/ testes de carga no físico;
    #   production: pool estrito (padrão máx. 8) p/ Aiven free/basic.
    s = get_settings()
    max_c = s.effective_pool_max_size
    min_c = max(1, min(s.effective_pool_min_size, max_c // 2))
    return max_c, min_c


# ── Mudanças de modo (circuit breaker) ────────────────────────────────────
async def _close_pools() -> None:
    for key in ("api", "etl"):
        pool = _pool.get(key)
        if pool is not None:
            try:
                await pool.close()
            except Exception:  # noqa: BLE001  # close nunca deve explodir
                logger.debug("Falha ao fechar pool %s (ignorada)", key)
            _pool[key] = None


async def _activate_fallback() -> None:
    global _active_mode, _mode_switched_at
    await _close_pools()
    _active_mode = "fallback"
    _mode_switched_at = time.monotonic()


async def _activate_primary() -> None:
    global _active_mode, _mode_switched_at
    await _close_pools()
    _active_mode = "primary"
    _mode_switched_at = time.monotonic()


def _cooldown_elapsed() -> bool:
    if _active_mode != "fallback":
        return False
    return (time.monotonic() - _mode_switched_at) >= _COOLDOWN_SECONDS


async def _build_current_pool(kind: str) -> asyncpg.Pool:
    """Cria um pool verificado para o modo ativo, com failover automático."""
    max_c, min_c = _pool_params(kind)
    timeout = _KIND_TIMEOUT.get(kind, 120)
    url = _url_for_current_mode(kind)
    try:
        return await _create_verified_pool(url, max_c, min_c, timeout)
    except Exception as exc:
        if _active_mode == "primary" and _is_conn_error(exc):
            logger.warning(
                "[FAILOVER] Nuvem inacessível. Redirecionando tráfego para Banco Local..."
                " (motivo: %s)%s",
                exc,
                _RESTORE_HINT,
            )
            await _activate_fallback()
            return await _create_verified_pool(_fallback_url(), max_c, min_c, timeout)
        raise


async def _try_recover_primary(kind: str) -> asyncpg.Pool | None:
    """Probe half-open: tenta revalidar o PRIMARY após o cooldown."""
    global _mode_switched_at
    max_c, min_c = _pool_params(kind)
    timeout = _KIND_TIMEOUT.get(kind, 120)
    try:
        pool = await _create_verified_pool(_resolve_pool_url(kind), max_c, min_c, timeout)
    except Exception as exc:
        if _is_conn_error(exc):
            _mode_switched_at = time.monotonic()  # primary ainda fora: novos cooldown
            return None
        raise
    logger.warning("[FAILOVER] Nuvem acessível novamente. Retornando ao banco remoto.")
    await _activate_primary()
    _pool[kind] = pool
    return pool


async def _get_or_create(kind: str) -> asyncpg.Pool:
    async with _pool_lock:
        # Half-open: quando em fallback e cooldown expirado, revalida o primary.
        if _cooldown_elapsed():
            recovered = await _try_recover_primary(kind)
            if recovered is not None:
                return recovered
        pool = _pool.get(kind)
        if pool is not None:
            return pool
        pool = await _build_current_pool(kind)
        _pool[kind] = pool
        return pool


# ── API pública (assinaturas preservadas) ─────────────────────────────────
async def get_api_pool() -> asyncpg.Pool:
    return await _get_or_create("api")


async def get_etl_pool() -> asyncpg.Pool:
    return await _get_or_create("etl")


async def get_pool() -> asyncpg.Pool:
    return await get_api_pool()


async def close_pools() -> None:
    async with _pool_lock:
        await _close_pools()


async def close_pool() -> None:
    await close_pools()


async def _acquire(kind: str) -> asyncpg.Connection:
    """Adquire conexão do modo atual; em erro de conexão no modo primário,
    faz failover para o banco local e tenta de novo."""
    pool = await _get_or_create(kind)
    try:
        return await pool.acquire()
    except Exception as exc:
        if _active_mode == "primary" and _is_conn_error(exc):
            logger.warning(
                "[FAILOVER] Nuvem inacessível. Redirecionando tráfego para Banco Local... "
                "(motivo: %s)%s",
                exc,
                _RESTORE_HINT,
            )
            await _activate_fallback()
            max_c, min_c = _pool_params(kind)
            timeout = _KIND_TIMEOUT.get(kind, 120)
            fallback = await _create_verified_pool(_fallback_url(), max_c, min_c, timeout)
            _pool[kind] = fallback
            return await fallback.acquire()
        raise


async def fetch(query: str, *args: Any) -> list[asyncpg.Record]:
    conn = await _acquire("api")
    try:
        return await conn.fetch(query, *args)
    finally:
        await conn.close()


async def fetchrow(query: str, *args: Any) -> asyncpg.Record | None:
    conn = await _acquire("api")
    try:
        return await conn.fetchrow(query, *args)
    finally:
        await conn.close()


async def fetch_etl(query: str, *args: Any) -> list[asyncpg.Record]:
    conn = await _acquire("etl")
    try:
        return await conn.fetch(query, *args)
    finally:
        await conn.close()


async def fetchrow_etl(query: str, *args: Any) -> asyncpg.Record | None:
    conn = await _acquire("etl")
    try:
        return await conn.fetchrow(query, *args)
    finally:
        await conn.close()
