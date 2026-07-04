from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from enum import Enum, auto

logger = logging.getLogger(__name__)


class CircuitState(Enum):
    CLOSED = auto()
    OPEN = auto()
    HALF_OPEN = auto()


@dataclass
class CircuitBreaker:
    nome: str
    failure_threshold: int = 5
    recovery_timeout_s: float = 120.0
    window_s: float = 60.0

    _state: CircuitState = CircuitState.CLOSED
    _failures: list[float] = field(default_factory=list)
    _last_failure_time: float = 0.0
    _opened_at: float = 0.0
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    @property
    def esta_aberto(self) -> bool:
        if self._state == CircuitState.CLOSED:
            return False

        if self._state == CircuitState.OPEN:
            if time.monotonic() - self._opened_at >= self.recovery_timeout_s:
                self._state = CircuitState.HALF_OPEN
                logger.info("[CB %s] OPEN → HALF_OPEN (timeout %.0fs)", self.nome, self.recovery_timeout_s)
                return False
            return True

        return False

    def registrar_falha(self) -> None:
        agora = time.monotonic()
        self._failures.append(agora)
        self._failures = [t for t in self._failures if agora - t <= self.window_s]
        self._last_failure_time = agora

        if len(self._failures) >= self.failure_threshold:
            self._state = CircuitState.OPEN
            self._opened_at = agora
            logger.warning(
                "[CB %s] CLOSED → OPEN: %d falhas em %.0fs",
                self.nome, len(self._failures), self.window_s,
            )

    def registrar_sucesso(self) -> None:
        if self._state == CircuitState.HALF_OPEN:
            self._state = CircuitState.CLOSED
            self._failures.clear()
            logger.info("[CB %s] HALF_OPEN → CLOSED (sucesso)", self.nome)

    def reset(self) -> None:
        self._state = CircuitState.CLOSED
        self._failures.clear()
        self._last_failure_time = 0.0
        self._opened_at = 0.0
        logger.info("[CB %s] reset manual", self.nome)

    def status_dict(self) -> dict:
        return {
            "nome": self.nome,
            "state": self._state.name,
            "failures_window": len(self._failures),
            "threshold": self.failure_threshold,
            "opened_at": self._opened_at,
        }