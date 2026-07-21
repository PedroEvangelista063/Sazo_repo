import asyncio
from typing import Any

import asyncpg
from backend.app.core.config import get_settings

_pool_api: asyncpg.Pool | None = None
_pool_etl: asyncpg.Pool | None = None
_pool_lock = asyncio.Lock()


def _resolve_url(key: str, fallback: str) -> str:
    val = getattr(get_settings(), key, "")
    return val if val else fallback


async def _init_pool(url: str, max_conn: int, min_conn: int, command_timeout: int) -> asyncpg.Pool:
    return await asyncpg.create_pool(
        url,
        min_size=min_conn,
        max_size=max_conn,
        command_timeout=command_timeout,
        statement_cache_size=0,  # required for Supabase PgBouncer (transaction mode)
    )


async def get_api_pool() -> asyncpg.Pool:
    global _pool_api
    if _pool_api is None:
        async with _pool_lock:
            if _pool_api is None:  # double-checked locking
                settings = get_settings()
                url = _resolve_url("database_url_api", settings.database_url)
                max_c = min(settings.pool_max_size, 50)
                min_c = min(settings.pool_min_size, max_c // 2)
                _pool_api = await _init_pool(url, max_c, min_c, 120)
    return _pool_api


async def get_etl_pool() -> asyncpg.Pool:
    global _pool_etl
    if _pool_etl is None:
        async with _pool_lock:
            if _pool_etl is None:  # double-checked locking
                settings = get_settings()
                url = _resolve_url("database_url_etl", settings.database_url)
                max_c = min(settings.pool_max_size, 50)
                min_c = min(settings.pool_min_size, max_c // 2)
                _pool_etl = await _init_pool(url, max_c, min_c, 60)
    return _pool_etl


async def get_pool() -> asyncpg.Pool:
    return await get_api_pool()


async def close_pools() -> None:
    global _pool_api, _pool_etl
    if _pool_api:
        await _pool_api.close()
        _pool_api = None
    if _pool_etl:
        await _pool_etl.close()
        _pool_etl = None


async def close_pool() -> None:
    await close_pools()


async def fetch(query: str, *args: Any) -> list[asyncpg.Record]:
    pool = await get_api_pool()
    async with pool.acquire() as conn:
        return await conn.fetch(query, *args)


async def fetchrow(query: str, *args: Any) -> asyncpg.Record | None:
    pool = await get_api_pool()
    async with pool.acquire() as conn:
        return await conn.fetchrow(query, *args)


async def fetch_etl(query: str, *args: Any) -> list[asyncpg.Record]:
    pool = await get_etl_pool()
    async with pool.acquire() as conn:
        return await conn.fetch(query, *args)


async def fetchrow_etl(query: str, *args: Any) -> asyncpg.Record | None:
    pool = await get_etl_pool()
    async with pool.acquire() as conn:
        return await conn.fetchrow(query, *args)
