from __future__ import annotations

import asyncio
import logging
import time
from typing import Any

from pipeline.scraper.transport.resolver.captcha_params import extract_params_from_engine
from pipeline.scraper.transport.resolver.dom_observer import is_challenge_page
from pipeline.scraper.transport.resolver.flaresolverr import FlareSolverrConnector
from pipeline.scraper.transport.resolver.solver_base import (
    BaseChallengeSolver,
    ChallengeParams,
    ChallengeResult,
    ResolutionStatus,
)
from pipeline.scraper.transport.resolver.turnstile import RecaptchaSolver, TurnstileSolver

logger = logging.getLogger(__name__)


class ChallengeRouter:
    """Orchestrates challenge detection and resolution across multiple solvers.

    Resolution pipeline:
      1. Navigate → detect challenge
      2. If CF JS/DDoS: try FlareSolverr (session-based, inject cookies)
      3. If Turnstile: try browser-based click → token injection
      4. If reCAPTCHA: try checkbox click (audio/image requires external service)
      5. Fallback: return FAILED status for manual inspection
    """

    def __init__(
        self,
        flaresolverr_endpoint: str | None = None,
    ) -> None:
        self._solvers: list[BaseChallengeSolver] = [
            TurnstileSolver(),
            RecaptchaSolver(),
        ]
        self._flaresolverr: FlareSolverrConnector | None = None
        if flaresolverr_endpoint:
            self._flaresolverr = FlareSolverrConnector(endpoint=flaresolverr_endpoint)
        self._stats: dict[str, int] = {
            "total": 0,
            "resolved": 0,
            "failed": 0,
            "skipped": 0,
        }

    @property
    def stats(self) -> dict[str, int]:
        return dict(self._stats)

    async def navigate_with_resolution(
        self,
        engine: Any,
        url: str,
        *,
        max_retries: int = 2,
        flaresolverr_first: bool = True,
        wait_until: str = "domcontentloaded",
        navigation_timeout_ms: int = 60000,
        resolution_timeout_ms: int = 90000,
    ) -> ChallengeResult:
        t0 = time.perf_counter()

        for attempt in range(max_retries + 1):
            logger.info(
                "[ChallengeRouter] Attempt %d/%d: navigating to %s",
                attempt + 1, max_retries + 1, url[:80],
            )

            try:
                await engine.navigate(url, wait_until=wait_until, timeout=navigation_timeout_ms)
            except Exception as e:
                logger.warning("[ChallengeRouter] Navigation failed: %s", e)
                await asyncio.sleep(2)
                continue

            await asyncio.sleep(1)

            is_challenge = await is_challenge_page(engine)

            if not is_challenge:
                try:
                    params = await extract_params_from_engine(engine)
                    if params.challenge_type.value == "unknown":
                        self._stats["total"] += 1
                        self._stats["skipped"] += 1
                        elapsed = int((time.perf_counter() - t0) * 1000)
                        return ChallengeResult(
                            status=ResolutionStatus.SKIPPED,
                            method="no_challenge",
                            elapsed_ms=elapsed,
                        )
                    is_challenge = True
                except Exception as e:
                    logger.debug("[ChallengeRouter] Param extraction failed: %s", e)

            if not is_challenge:
                self._stats["total"] += 1
                self._stats["skipped"] += 1
                elapsed = int((time.perf_counter() - t0) * 1000)
                return ChallengeResult(
                    status=ResolutionStatus.SKIPPED,
                    method="no_challenge",
                    elapsed_ms=elapsed,
                )

            logger.info("[ChallengeRouter] Challenge detected on attempt %d", attempt + 1)
            result = await self._resolve_all(
                engine, url, flaresolverr_first, resolution_timeout_ms
            )

            if result.status == ResolutionStatus.RESOLVED:
                self._stats["total"] += 1
                self._stats["resolved"] += 1
                return result

            if attempt < max_retries:
                wait_time = (attempt + 1) * 3
                logger.info(
                    "[ChallengeRouter] Retrying in %ds (attempt %d/%d)",
                    wait_time, attempt + 1, max_retries,
                )
                await asyncio.sleep(wait_time)

        self._stats["total"] += 1
        self._stats["failed"] += 1
        elapsed = int((time.perf_counter() - t0) * 1000)
        return ChallengeResult(
            status=ResolutionStatus.FAILED,
            method="all_retries_exhausted",
            elapsed_ms=elapsed,
            error=f"Failed after {max_retries + 1} attempts",
        )

    async def _resolve_all(
        self,
        engine: Any,
        url: str,
        flaresolverr_first: bool,
        timeout_ms: int,
    ) -> ChallengeResult:
        try:
            params = await extract_params_from_engine(engine)
        except Exception as e:
            logger.warning("[ChallengeRouter] Param extraction: %s", e)
            params = ChallengeParams(page_url=url)

        if flaresolverr_first and self._flaresolverr:
            if await self._flaresolverr.health_check():
                if await self._flaresolverr.can_handle(params):
                    logger.info("[ChallengeRouter] Trying FlareSolverr...")
                    result = await self._flaresolverr.resolve(engine, params, timeout_ms)
                    if result.status == ResolutionStatus.RESOLVED:
                        injected = await self._flaresolverr.inject_cookies_to_engine(engine)
                        if injected > 0:
                            logger.info("[ChallengeRouter] FlareSolverr + cookie injection succeeded")
                        try:
                            await engine.navigate(
                                url, wait_until="domcontentloaded",
                                timeout=self._flaresolverr._max_timeout,
                            )
                            await asyncio.sleep(2)
                        except Exception as e:
                            logger.debug("[ChallengeRouter] Re-navigation after FS: %s", e)
                        return result
                    logger.warning("[ChallengeRouter] FlareSolverr failed: %s", result.error)
            else:
                logger.warning(
                    "[ChallengeRouter] FlareSolverr at %s is not reachable",
                    self._flaresolverr._endpoint,
                )

        for solver in self._solvers:
            if await solver.can_handle(params):
                logger.info("[ChallengeRouter] Trying %s...", solver.name)
                result = await solver.resolve(engine, params, timeout_ms)
                if result.status == ResolutionStatus.RESOLVED:
                    return result
                logger.warning("[ChallengeRouter] %s failed: %s", solver.name, result.error)

        return ChallengeResult(
            status=ResolutionStatus.FAILED,
            challenge_type=params.challenge_type,
            method="all_solvers_exhausted",
            error=f"No solver could handle {params.challenge_type}",
        )

    async def resolve_challenge(
        self,
        engine: Any,
        timeout_ms: int = 60000,
    ) -> ChallengeResult:
        try:
            params = await extract_params_from_engine(engine)
        except Exception as e:
            return ChallengeResult(
                status=ResolutionStatus.FAILED,
                method="param_extraction_failed",
                error=str(e),
            )

        if not params.is_valid:
            return ChallengeResult(
                status=ResolutionStatus.SKIPPED,
                method="no_params_found",
            )

        for solver in self._solvers:
            if await solver.can_handle(params):
                result = await solver.resolve(engine, params, timeout_ms)
                return result

        return ChallengeResult(
            status=ResolutionStatus.FAILED,
            challenge_type=params.challenge_type,
            method="no_solver",
            error=f"No solver for {params.challenge_type}",
        )

    async def health_check(self) -> dict[str, Any]:
        status: dict[str, Any] = {
            "flaresolverr": False,
            "solvers": [s.name for s in self._solvers],
            "stats": self._stats,
        }
        if self._flaresolverr:
            status["flaresolverr"] = await self._flaresolverr.health_check()
            status["flaresolverr_endpoint"] = self._flaresolverr._endpoint
        return status

    async def close(self) -> None:
        if self._flaresolverr:
            await self._flaresolverr.close()
