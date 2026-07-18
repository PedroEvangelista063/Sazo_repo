import asyncio
import json
import logging
import time
from typing import Any, Optional

try:
    import redis.asyncio as aioredis

    HAS_REDIS = True
except ImportError:
    HAS_REDIS = False


logger = logging.getLogger(__name__)


class _CacheEntry:
    __slots__ = ("value", "expires_at")

    def __init__(self, value: Any, ttl: float) -> None:
        self.value = value
        self.expires_at = time.monotonic() + ttl


class InMemoryCache:
    def __init__(self) -> None:
        self._store: dict[str, _CacheEntry] = {}
        self._lock = asyncio.Lock()

    async def get(self, key: str) -> Optional[Any]:
        entry = self._store.get(key)
        if entry is None:
            return None
        if time.monotonic() > entry.expires_at:
            self._store.pop(key, None)
            return None
        return entry.value

    async def set(self, key: str, value: Any, ttl: float) -> None:
        async with self._lock:
            self._store[key] = _CacheEntry(value, ttl)

    async def clear(self) -> None:
        async with self._lock:
            self._store.clear()

    async def clear_pattern(self, pattern: str) -> None:
        async with self._lock:
            keys = [k for k in self._store if pattern in k]
            for k in keys:
                self._store.pop(k, None)


class RedisCache:
    """Cache distribuído via Redis com serialização JSON.

    Usa prefixo ``qc:`` nas chaves para namespacing.
    Falhas de conexão/operação logam warning e não quebram a request.
    """

    _KEY_PREFIX = "qc:"

    def __init__(self, redis_url: str) -> None:
        self._redis: Optional[aioredis.Redis] = None
        self._redis_url = redis_url
        self._lock = asyncio.Lock()

    async def _client(self) -> aioredis.Redis:
        if self._redis is None:
            async with self._lock:
                if self._redis is None:
                    self._redis = aioredis.from_url(
                        self._redis_url,
                        decoding_responses=True,
                    )
        return self._redis

    async def get(self, key: str) -> Optional[Any]:
        try:
            r = await self._client()
            raw = await r.get(f"{self._KEY_PREFIX}{key}")
            if raw is None:
                return None
            return json.loads(raw)
        except Exception:
            logger.warning("Redis get failed: key=%s", key, exc_info=True)
            return None

    async def set(self, key: str, value: Any, ttl: float) -> None:
        try:
            r = await self._client()
            await r.setex(
                f"{self._KEY_PREFIX}{key}",
                int(ttl),
                json.dumps(value, default=str, ensure_ascii=False),
            )
        except Exception:
            logger.warning("Redis set failed: key=%s ttl=%s", key, ttl, exc_info=True)

    async def clear(self) -> None:
        try:
            r = await self._client()
            cursor = 0
            while True:
                cursor, keys = await r.scan(cursor=cursor, match=f"{self._KEY_PREFIX}*")
                if keys:
                    await r.delete(*keys)
                if cursor == 0:
                    break
        except Exception:
            logger.warning("Redis clear failed", exc_info=True)

    async def clear_pattern(self, pattern: str) -> None:
        try:
            r = await self._client()
            cursor = 0
            while True:
                cursor, keys = await r.scan(
                    cursor=cursor, match=f"{self._KEY_PREFIX}{pattern}"
                )
                if keys:
                    await r.delete(*keys)
                if cursor == 0:
                    break
        except Exception:
            logger.warning("Redis clear_pattern failed: pattern=%s", pattern, exc_info=True)


cache: InMemoryCache | RedisCache = InMemoryCache()


def init_cache(redis_url: str) -> None:
    """Troca o cache global para Redis se ``redis_url`` for não-vazia.

    Deve ser chamada uma vez no startup da aplicação (lifespan).
    Se ``redis`` não estiver instalado ou a URL for vazia, mantém ``InMemoryCache``.
    """
    global cache
    if not redis_url:
        logger.info("Cache: InMemoryCache (sem redis_url)")
        return
    if not HAS_REDIS:
        logger.warning("Cache: redis não instalado (pip install redis) — usando InMemoryCache")
        return
    cache = RedisCache(redis_url)
    logger.info("Cache: RedisCache em %s", redis_url.replace(redis_url.split("@")[-1] if "@" in redis_url else redis_url, "***"))


async def clear_cache() -> bool:
    await cache.clear()
    return True


async def safe_set(key: str, value: Any, ttl: float) -> bool:
    """Cache set com try/except — falhas de cache nunca quebram a request."""
    try:
        await cache.set(key, value, ttl)
        return True
    except Exception:
        logger.exception("cache.set failed: key=%s ttl=%s", key, ttl)
        return False
