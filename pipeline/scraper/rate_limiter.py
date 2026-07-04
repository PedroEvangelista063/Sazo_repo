from __future__ import annotations

import asyncio
import logging
from urllib.parse import urlparse

logger = logging.getLogger(__name__)


class RateLimiter:
    def __init__(self, max_concorrencia_por_dominio: int = 3):
        self._semaphores: dict[str, asyncio.Semaphore] = {}
        self._max = max_concorrencia_por_dominio

    def _extrair_dominio(self, url: str) -> str:
        try:
            if not url.startswith(("http://", "https://")):
                url = "https://" + url
            parsed = urlparse(url)
            host = parsed.hostname or ""
            if host.startswith("www."):
                host = host[4:]
            return host or url
        except Exception:
            return url

    def para_dominio(self, url: str) -> asyncio.Semaphore:
        dominio = self._extrair_dominio(url)
        if dominio not in self._semaphores:
            self._semaphores[dominio] = asyncio.Semaphore(self._max)
            logger.debug("[RateLimiter] Novo domínio: %s (max=%d)", dominio, self._max)
        return self._semaphores[dominio]

    def status(self) -> dict[str, int]:
        return {
            dom: sem._value  # type: ignore[attr-defined]
            for dom, sem in self._semaphores.items()
        }