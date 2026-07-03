from __future__ import annotations

import asyncio
import logging
from typing import Any

logger = logging.getLogger(__name__)


class EventBroadcaster:
    """Gerencia filas SSE — publish para N clientes conectados."""

    def __init__(self) -> None:
        self._queues: set[asyncio.Queue[dict[str, Any]]] = set()
        self._lock = asyncio.Lock()

    def subscribe(self) -> asyncio.Queue[dict[str, Any]]:
        q: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self._queues.add(q)
        return q

    def unsubscribe(self, q: asyncio.Queue[dict[str, Any]]) -> None:
        self._queues.discard(q)

    async def publish(self, event: str, data: str = "") -> None:
        payload = {"event": event, "data": data}
        async with self._lock:
            for q in self._queues:
                q.put_nowait(payload)
        logger.info("Broadcast '%s' para %d cliente(s)", event, len(self._queues))


broadcaster = EventBroadcaster()
