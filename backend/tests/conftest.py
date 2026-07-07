from __future__ import annotations

import asyncio
import os
from collections.abc import AsyncGenerator

import httpx
import pytest
from asyncpg import Pool, create_pool

from backend.app.core.config import get_settings

pytest_plugins = ("pytest_asyncio",)

# ── Hard limits — qualquer teste que exceder isso é morto ──────────────
GLOBAL_TIMEOUT_S = int(os.getenv("PYTEST_TIMEOUT", "5"))
ASYNC_CLIENT_TIMEOUT = httpx.Timeout(
    connect=3.0,     # 3s para conectar
    read=GLOBAL_TIMEOUT_S - 1,   # leitura morre 1s antes do pytest-timeout
    write=5.0,
    pool=3.0,        # 3s esperando pool
)


@pytest.fixture(scope="session")
async def db_pool() -> AsyncGenerator[Pool, None]:
    settings = get_settings()
    pool = await create_pool(
        settings.database_url,
        min_size=1,
        max_size=2,
        command_timeout=GLOBAL_TIMEOUT_S,
    )
    yield pool
    await pool.close()


@pytest.fixture(autouse=True)
async def _ensure_clean_state():
    """Antes de cada teste: limpa cache."""
    from backend.app.core.cache import cache
    await cache.clear()


@pytest.fixture
async def client() -> AsyncGenerator[httpx.AsyncClient, None]:
    """Cliente HTTP com timeouts hard — se travar, morre em <5s."""
    base_url = os.getenv("API_BASE_URL", "http://localhost:8000")
    async with httpx.AsyncClient(
        base_url=base_url,
        timeout=ASYNC_CLIENT_TIMEOUT,
        limits=httpx.Limits(
            max_connections=10,
            max_keepalive_connections=2,
        ),
    ) as c:
        yield c



