from __future__ import annotations

import asyncio
import functools
import logging
import random
from typing import Any, Callable, TypeVar

logger = logging.getLogger(__name__)

F = TypeVar("F", bound=Callable[..., Any])


def retry_request(
    retries: int = 3,
    delay: float = 5.0,
    backoff: float = 2.0,
    max_delay: float = 120.0,
    jitter: bool = True,
    exceptions: tuple[type[Exception], ...] = (
        ConnectionError,
        TimeoutError,
        asyncio.TimeoutError,
        OSError,
    ),
) -> Callable[[F], F]:
    def decorator(func: F) -> F:
        @functools.wraps(func)
        async def wrapper(*args: Any, **kwargs: Any) -> Any:
            last_exc: Exception | None = None
            current_delay = delay
            for attempt in range(1, retries + 1):
                try:
                    result = await func(*args, **kwargs)
                    if attempt > 1:
                        logger.info("%s recuperou apos %d tentativas", func.__name__, attempt)
                    return result
                except exceptions as e:
                    last_exc = e
                    if attempt < retries:
                        jitter_val = (
                            random.uniform(0.7, 1.3) * current_delay if jitter else current_delay
                        )
                        logger.warning(
                            "%s tentativa %d/%d falhou: %s. Retentando em %.1fs...",
                            func.__name__,
                            attempt,
                            retries,
                            e,
                            jitter_val,
                        )
                        await asyncio.sleep(jitter_val)
                        current_delay = min(current_delay * backoff, max_delay)
                    else:
                        logger.error(
                            "%s esgotou %d tentativas. Ultimo erro: %s",
                            func.__name__,
                            retries,
                            e,
                        )
            if last_exc:
                raise last_exc
            return None

        return wrapper  # type: ignore

    return decorator
