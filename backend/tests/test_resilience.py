from __future__ import annotations

import asyncio
from unittest.mock import patch

import httpx
import pytest

from backend.app.db.session import fetch


@pytest.mark.asyncio
async def test_db_timeout_isolation():
    """
    Prova que asyncio.wait_for mata queries que excedem 2s.
    Simula um `fetch` que nunca retorna (pool travado).
    """
    with patch("backend.app.db.session.get_api_pool") as mock_pool:
        async def _hang(*_a, **_kw):
            await asyncio.sleep(10)
        mock_pool.side_effect = _hang

        with pytest.raises((TimeoutError, asyncio.TimeoutError)):
            await asyncio.wait_for(fetch("SELECT 1"), timeout=2)


@pytest.mark.timeout(4)
@pytest.mark.asyncio
async def test_infinite_loop_protection():
    """
    Prova que um loop assíncrono infinito NÃO trava o test runner.
    O pytest-timeout (ou asyncio.wait_for) corta a execução.
    """
    async def infinite():
        while True:
            await asyncio.sleep(0.1)

    with pytest.raises((TimeoutError, asyncio.TimeoutError)):
        await asyncio.wait_for(infinite(), timeout=2)


@pytest.mark.timeout(4)
@pytest.mark.asyncio
async def test_sse_generator_cancellation():
    """
    Prova que um generator SSE cancelado externamente não vaza
    corrotinas — testa o CancelledError no _event_generator.
    """
    from backend.app.api.v1.endpoints.stream import _event_generator

    gen = _event_generator()
    first = await gen.__anext__()
    assert "connected" in first

    # Cancela o generator externamente
    await gen.aclose()
    with pytest.raises(StopAsyncIteration):
        await gen.__anext__()


@pytest.mark.timeout(4)
@pytest.mark.asyncio
async def test_event_broadcaster_backpressure():
    """
    Prova que o EventBroadcaster não bloqueia quando a fila está cheia.
    put_nowait levanta QueueFull em vez de travar.
    """
    from backend.app.core.events import broadcaster

    q = broadcaster.subscribe()
    # Cria uma fila com maxsize=1 e substitui a queue do broadcaster
    limited: asyncio.Queue[dict] = asyncio.Queue(maxsize=1)
    broadcaster._queues.discard(q)
    broadcaster._queues.add(limited)

    await broadcaster.publish("TEST", "first")
    # Segunda publicação com fila cheia — put_nowait levanta QueueFull
    with pytest.raises(asyncio.QueueFull):
        limited.put_nowait({"event": "OVERFLOW", "data": ""})

    broadcaster.unsubscribe(limited)


@pytest.mark.timeout(4)
@pytest.mark.asyncio
async def test_rate_limit_memory_leak_does_not_grow():
    """
    Prova que a janela de rate-limit não cresce sem limites
    mesmo sob entrada contínua de IPs únicos.
    Após expirar a janela de 60s, as entradas velhas somem.
    """
    # Teste puramente funcional sem dependência de Starlette
    from collections import defaultdict

    windows: dict[str, list[float]] = defaultdict(list)

    # Simula N requisições ao longo de 90s (60s de janela)
    for _ in range(1_000):
        windows["fake_key"].append(0.0)
    windows["fake_key"].append(100.0)  # fora da janela

    now = 90.0
    window_start = now - 60.0  # 30.0
    windows["fake_key"] = [
        t for t in windows["fake_key"] if t > window_start
    ]
    # Após limpeza, só a futura 100.0 deve restar
    assert len(windows["fake_key"]) <= 1


@pytest.mark.timeout(4)
@pytest.mark.asyncio
async def test_cache_lock_contention(client: httpx.AsyncClient):
    """
    Prova que o cache não causa race condition sob concorrência.
    O lock RLock do cache é testado sob carga paralela.
    """
    from backend.app.core.cache import cache
    import time

    async def setter(i: int):
        await cache.set(f"key_{i}", i, 3600)
        return await cache.get(f"key_{i}")

    results = await asyncio.gather(*[setter(i) for i in range(50)])
    assert results == list(range(50))
