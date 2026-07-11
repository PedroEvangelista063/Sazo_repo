from __future__ import annotations

import asyncio
import logging
from abc import ABC, abstractmethod
from typing import Any

import httpx

from pipeline.scraper.circuit_breaker import CircuitBreaker

logger = logging.getLogger(__name__)

MAX_PAGES = 50
HTTPX_TIMEOUT_SEC = 15.0
SEMAPHORE_LIMIT = 3


class BaseMicroEngine(ABC):
    """
    Micro-motor focado e burro: extrai o payload bruto e joga na cesta.
    Sem lógica de negócio — apenas colheita.
    """

    def __init__(self) -> None:
        self._semaphore = asyncio.Semaphore(SEMAPHORE_LIMIT)
        self._circuit_breaker = CircuitBreaker(
            nome=self.__class__.__name__,
            failure_threshold=5,
            recovery_timeout_s=120.0,
        )
        self._client = httpx.AsyncClient(timeout=httpx.Timeout(HTTPX_TIMEOUT_SEC))

    @abstractmethod
    async def extract(self, url: str, ano: int, mes: int) -> dict[str, Any]:
        """
        Retorna dict no formato da raw.coleta_bruta:
            {"fonte_id": str, "payload_bruto": dict, "competencia": str}
        """

    async def _fetch(self, url: str) -> dict[str, Any]:
        if self._circuit_breaker.esta_aberto:
            raise RuntimeError(f"CircuitBreaker aberto para {self.__class__.__name__}")

        async with self._semaphore:
            try:
                resp = await self._client.get(url, follow_redirects=True)
                resp.raise_for_status()
                self._circuit_breaker.registrar_sucesso()
                return {
                    "status_code": resp.status_code,
                    "headers": dict(resp.headers),
                    "body": resp.text,
                }
            except Exception as exc:
                self._circuit_breaker.registrar_falha()
                logger.warning("[%s] Falha ao fetch %s: %s", self.__class__.__name__, url, exc)
                raise

    async def close(self) -> None:
        await self._client.aclose()

    async def __aenter__(self) -> "BaseMicroEngine":
        return self

    async def __aexit__(self, *args: Any) -> None:
        await self.close()
