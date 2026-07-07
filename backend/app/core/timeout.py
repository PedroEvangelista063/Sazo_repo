from __future__ import annotations

import asyncio
import logging

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.status import HTTP_504_GATEWAY_TIMEOUT

logger = logging.getLogger(__name__)


class TimeoutMiddleware(BaseHTTPMiddleware):
    """
    Middleware que envolve cada request em asyncio.wait_for.

    Se o endpoint travar (loop infinito, I/O bloqueante, deadlock),
    o middleware captura o TimeoutError e retorna 504 antes que
    o worker do Uvicorn congele.

    A ordem no stack importa: coloque AFTER CORS, BEFORE rate-limit
    para que requests lentos sejam podados antes de consumir rate-limit.
    """

    def __init__(self, app, timeout_seconds: float = 29.0):
        super().__init__(app)
        self._timeout = timeout_seconds

    async def dispatch(self, request: Request, call_next):
        if request.method == "OPTIONS":
            return await call_next(request)

        path = request.url.path
        if path in ("/health", "/docs", "/openapi.json", "/redoc"):
            return await call_next(request)

        try:
            return await asyncio.wait_for(
                call_next(request),
                timeout=self._timeout,
            )
        except asyncio.TimeoutError:
            logger.warning(
                "Timeout de %.1fs atingido em %s %s",
                self._timeout,
                request.method,
                path,
            )
            return JSONResponse(
                status_code=HTTP_504_GATEWAY_TIMEOUT,
                content={
                    "error": "request_timeout",
                    "message": (
                        f"O servidor demorou mais de {self._timeout:.0f}s "
                        "para processar esta requisição. Tente novamente "
                        "com filtros mais específicos."
                    ),
                },
            )
