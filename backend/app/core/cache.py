import time
import threading
from typing import Any, Optional


class _CacheEntry:
    __slots__ = ("value", "expires_at")

    def __init__(self, value: Any, ttl: float) -> None:
        self.value = value
        self.expires_at = time.monotonic() + ttl


class InMemoryCache:
    def __init__(self) -> None:
        self._store: dict[str, _CacheEntry] = {}
        self._lock = threading.RLock()

    def get(self, key: str) -> Optional[Any]:
        entry = self._store.get(key)
        if entry is None:
            return None
        if time.monotonic() > entry.expires_at:
            self._store.pop(key, None)
            return None
        return entry.value

    def set(self, key: str, value: Any, ttl: float) -> None:
        with self._lock:
            self._store[key] = _CacheEntry(value, ttl)

    def clear(self) -> None:
        with self._lock:
            self._store.clear()

    def clear_pattern(self, pattern: str) -> None:
        with self._lock:
            keys = [k for k in self._store if pattern in k]
            for k in keys:
                self._store.pop(k, None)


cache = InMemoryCache()


async def clear_cache() -> bool:
    cache.clear()
    return True
