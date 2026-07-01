import time
import hashlib
from collections import defaultdict
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.status import HTTP_429_TOO_MANY_REQUESTS


class RateLimitMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, requests_per_minute: int = 60):
        super().__init__(app)
        self._requests_per_minute = requests_per_minute
        self._windows: dict[str, list[float]] = defaultdict(list)

    async def dispatch(self, request: Request, call_next):
        if request.method == "OPTIONS":
            return await call_next(request)

        if request.url.path in ("/health", "/docs", "/openapi.json", "/redoc"):
            return await call_next(request)

        client_ip = request.client.host if request.client else "unknown"
        key = hashlib.md5(client_ip.encode()).hexdigest()
        now = time.monotonic()
        window_start = now - 60.0

        self._windows[key] = [t for t in self._windows[key] if t > window_start]

        if len(self._windows[key]) >= self._requests_per_minute:
            return JSONResponse(
                status_code=HTTP_429_TOO_MANY_REQUESTS,
                content={
                    "error": "rate_limit_exceeded",
                    "message": "Muitas requisições. Aguarde e tente novamente.",
                },
            )

        self._windows[key].append(now)
        return await call_next(request)
