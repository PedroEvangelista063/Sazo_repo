from __future__ import annotations

import asyncio
import json
import logging

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from backend.app.core.events import broadcaster

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/stream", tags=["Stream"])

KEEPALIVE_INTERVAL = 30.0  # segundos


async def _event_generator():
    q = broadcaster.subscribe()
    try:
        yield f"event: connected\ndata: {json.dumps({'status': 'ok'})}\n\n"
        while True:
            try:
                payload = await asyncio.wait_for(q.get(), timeout=KEEPALIVE_INTERVAL)
                yield f"event: {payload['event']}\ndata: {payload['data']}\n\n"
            except asyncio.TimeoutError:
                yield ": keepalive\n\n"
    except asyncio.CancelledError:
        pass
    finally:
        broadcaster.unsubscribe(q)
        logger.debug("SSE client disconnected")


@router.get("/updates")
async def stream_updates():
    return StreamingResponse(
        _event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )
