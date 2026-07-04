from __future__ import annotations

import logging
import time
import uuid
from typing import Any

import httpx

from pipeline.scraper.transport.resolver.solver_base import (
    BaseChallengeSolver,
    ChallengeParams,
    ChallengeResult,
    ChallengeType,
    ResolutionStatus,
)

logger = logging.getLogger(__name__)


class FlareSolverrConnector(BaseChallengeSolver):
    """Async connector to FlareSolverr running locally via Docker.

    FlareSolverr solves Cloudflare JS challenges, DDoS-Guard, and similar
    browser-check challenges by executing the page in a real headless browser
    and returning the solved HTML + cookies.

    Default endpoint: http://localhost:8191/v1
    """

    name = "flaresolverr"

    def __init__(
        self,
        endpoint: str = "http://localhost:8191/v1",
        session_ttl_minutes: int = 5,
        max_timeout_ms: int = 90000,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._endpoint = endpoint.rstrip("/")
        self._session_ttl = session_ttl_minutes
        self._max_timeout = max_timeout_ms
        self._client = client or httpx.AsyncClient(timeout=httpx.Timeout(120.0))
        self._session_id: str | None = None
        self._last_cookies: list[dict[str, Any]] = []

    async def can_handle(self, params: ChallengeParams) -> bool:
        return params.challenge_type in (
            ChallengeType.CLOUDFLARE_JS,
            ChallengeType.DDOGUARD,
            ChallengeType.UNKNOWN,
        )

    async def _request(
        self, payload: dict[str, Any]
    ) -> dict[str, Any]:
        try:
            resp = await self._client.post(self._endpoint, json=payload)
            resp.raise_for_status()
            data: dict[str, Any] = resp.json()
            return data
        except httpx.TimeoutException:
            logger.error("[FlareSolverr] Request timed out")
            return {"status": "error", "message": "timeout"}
        except httpx.HTTPStatusError as e:
            logger.error("[FlareSolverr] HTTP %s: %s", e.response.status_code, e.response.text[:200])
            return {"status": "error", "message": str(e)}
        except Exception as e:
            logger.error("[FlareSolverr] Connection failed: %s", e)
            return {"status": "error", "message": str(e)}

    async def create_session(self) -> str:
        self._session_id = str(uuid.uuid4())
        payload = {
            "cmd": "sessions.create",
            "session": self._session_id,
            "session_ttl_minutes": self._session_ttl,
        }
        await self._request(payload)
        logger.info("[FlareSolverr] Session %s created", self._session_id)
        return self._session_id

    async def destroy_session(self) -> None:
        if not self._session_id:
            return
        payload = {
            "cmd": "sessions.destroy",
            "session": self._session_id,
        }
        await self._request(payload)
        logger.info("[FlareSolverr] Session %s destroyed", self._session_id)
        self._session_id = None

    async def solve_url(
        self,
        url: str,
        user_agent: str | None = None,
        return_raw_html: bool = True,
    ) -> ChallengeResult:
        t0 = time.perf_counter()

        payload: dict[str, Any] = {
            "cmd": "request.get",
            "url": url,
            "maxTimeout": self._max_timeout,
            "returnRawHtml": return_raw_html,
        }

        if user_agent:
            payload["userAgent"] = user_agent

        if self._session_id:
            payload["session"] = self._session_id
        else:
            await self.create_session()
            payload["session"] = self._session_id

        logger.info("[FlareSolverr] Solving %s (session=%s)", url[:80], self._session_id)
        data = await self._request(payload)

        elapsed = int((time.perf_counter() - t0) * 1000)

        if data.get("status") != "ok":
            error_msg = data.get("message", data.get("error", "unknown"))
            logger.error("[FlareSolverr] Failed to solve %s: %s", url[:80], error_msg)
            return ChallengeResult(
                status=ResolutionStatus.FAILED,
                challenge_type=ChallengeType.CLOUDFLARE_JS,
                method="flaresolverr",
                elapsed_ms=elapsed,
                error=error_msg,
            )

        solution = data.get("solution", {})
        self._last_cookies = solution.get("cookies", [])
        response_ua = solution.get("userAgent", user_agent or "")
        response_html = solution.get("response", "")
        response_url = solution.get("url", url)

        logger.info(
            "[FlareSolverr] Solved in %dms | status=%s | ua=%s",
            elapsed,
            solution.get("status", 0),
            response_ua[:60],
        )

        return ChallengeResult(
            status=ResolutionStatus.RESOLVED,
            challenge_type=ChallengeType.CLOUDFLARE_JS,
            cookies=self._last_cookies,
            user_agent=response_ua,
            html=response_html,
            resolved_url=response_url,
            method="flaresolverr",
            elapsed_ms=elapsed,
        )

    async def inject_cookies_to_engine(self, engine: Any) -> int:
        if not self._last_cookies:
            return 0
        try:
            page_url = await engine.evaluate("window.location.href")
            domain = _extract_domain(page_url) if page_url else ""

            formatted = []
            for c in self._last_cookies:
                formatted.append({
                    "name": c.get("name", ""),
                    "value": c.get("value", ""),
                    "domain": c.get("domain", domain),
                    "path": c.get("path", "/"),
                    "httpOnly": c.get("httpOnly", False),
                    "secure": c.get("secure", True),
                    "sameSite": c.get("sameSite", "Lax"),
                })
            await engine.set_cookies(formatted)
            logger.info("[FlareSolverr] %d cookies injected into browser", len(formatted))
            return len(formatted)
        except Exception as e:
            logger.warning("[FlareSolverr] Cookie injection failed: %s", e)
            return 0

    async def resolve(
        self,
        engine: Any,
        params: ChallengeParams,
        timeout_ms: int = 60000,
    ) -> ChallengeResult:
        url = params.page_url
        if not url:
            try:
                url = await engine.evaluate("window.location.href")
            except Exception:
                url = ""
        if not url:
            return ChallengeResult(
                status=ResolutionStatus.FAILED,
                challenge_type=params.challenge_type,
                method="flaresolverr",
                error="No URL to resolve",
            )

        ua = None
        try:
            ua = await engine.evaluate("navigator.userAgent")
        except Exception:
            pass

        result = await self.solve_url(url, user_agent=ua)
        return result

    async def extract_params(self, engine: Any) -> ChallengeParams:
        return ChallengeParams(challenge_type=ChallengeType.CLOUDFLARE_JS)

    async def health_check(self) -> bool:
        try:
            resp = await self._client.get(self._endpoint.replace("/v1", ""), timeout=5.0)
            return resp.status_code < 500
        except Exception:
            return False

    async def close(self) -> None:
        if self._session_id:
            await self.destroy_session()
        await self._client.aclose()


def _extract_domain(url: str) -> str:
    from urllib.parse import urlparse
    parsed = urlparse(url)
    return parsed.hostname or ""
