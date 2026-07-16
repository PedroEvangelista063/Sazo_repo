import asyncio
import logging
import time
from typing import Any, Optional


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


cache = InMemoryCache()


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
