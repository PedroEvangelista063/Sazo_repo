from __future__ import annotations

import asyncio
import logging
from typing import Any

logger = logging.getLogger(__name__)

_MAX_QUEUE_SIZE = 64


class EventBroadcaster:
    """Gerencia filas SSE — publish para N clientes conectados.

    Se um cliente estiver lento ou for um zumbi (desconectou sem fechar
    o socket), a fila enche e publish() ejeta o subscriber automaticamente.
    """

    def __init__(self) -> None:
        self._queues: set[asyncio.Queue[dict[str, Any]]] = set()
        self._lock = asyncio.Lock()

    def subscribe(self) -> asyncio.Queue[dict[str, Any]]:
        q: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=_MAX_QUEUE_SIZE)
        self._queues.add(q)
        return q

    def unsubscribe(self, q: asyncio.Queue[dict[str, Any]]) -> None:
        self._queues.discard(q)

    async def publish(self, event: str, data: str = "") -> None:
        payload = {"event": event, "data": data}
        dead: list[asyncio.Queue[dict[str, Any]]] = []
        async with self._lock:
            for q in self._queues:
                try:
                    q.put_nowait(payload)
                except asyncio.QueueFull:
                    logger.warning(
                        "Queue full for SSE subscriber — dropping zombie. "
                        "active_before=%d", len(self._queues)
                    )
                    dead.append(q)
            for q in dead:
                self._queues.discard(q)
        if dead:
            logger.warning("Dropped %d zombie SSE subscriber(s)", len(dead))
        logger.info("Broadcast '%s' para %d cliente(s)", event, len(self._queues))


broadcaster = EventBroadcaster()
