from __future__ import annotations

import asyncio
import logging
import random
import time
from typing import Any

from pipeline.scraper.transport.resolver.captcha_params import extract_params_from_engine
from pipeline.scraper.transport.resolver.dom_observer import (
    build_recaptcha_observer_js,
    build_turnstile_observer_js,
    check_cf_clearance_cookie,
)
from pipeline.scraper.transport.resolver.solver_base import (
    BaseChallengeSolver,
    ChallengeParams,
    ChallengeResult,
    ChallengeType,
    ResolutionStatus,
)

logger = logging.getLogger(__name__)

_CHECKBOX_CLICK_JS = """
(async () => {
    const frames = document.querySelectorAll('iframe');
    for (const frame of frames) {
        const src = (frame.src || '').toLowerCase();
        if (src.includes('turnstile') || src.includes('recaptcha') || src.includes('hcaptcha')) {
            const rect = frame.getBoundingClientRect();
            const x = rect.left + rect.width / 2 + (Math.random() * 6 - 3);
            const y = rect.top + rect.height / 2 + (Math.random() * 6 - 3);
            return { found: true, x: Math.round(x), y: Math.round(y), w: Math.round(rect.width), h: Math.round(rect.height) };
        }
    }
    const turnstileDiv = document.querySelector('[class*="cf-turnstile"], .cf-turnstile, [id*="cf-turnstile"]');
    if (turnstileDiv) {
        const rect = turnstileDiv.getBoundingClientRect();
        const x = rect.left + rect.width / 2 + (Math.random() * 4 - 2);
        const y = rect.top + rect.height / 2 + (Math.random() * 4 - 2);
        return { found: true, x: Math.round(x), y: Math.round(y), w: Math.round(rect.width), h: Math.round(rect.height) };
    }
    return { found: false };
})();
"""

_INJECT_TURNSTILE_TOKEN_JS = """
(async (sitekey) => {
    if (typeof turnstile !== 'undefined' && turnstile.render) {
        const container = document.querySelector('[class*="cf-turnstile"], [id*="cf-turnstile"]');
        if (container) {
            turnstile.render(container, {
                sitekey: sitekey,
                callback: function(token) {
                    const inp = document.createElement('input');
                    inp.type = 'hidden';
                    inp.name = 'cf-turnstile-response';
                    inp.value = token;
                    container.appendChild(inp);
                },
            });
            return { method: 'render' };
        }
    }
    const existing = document.querySelector('input[name="cf-turnstile-response"]');
    if (existing) {
        const fakeToken = '0x' + Array.from({length: 40}, () =>
            Math.floor(Math.random() * 16).toString(16)).join('');
        existing.value = fakeToken;
        return { method: 'fake_token', token: fakeToken.substring(0, 20) + '...' };
    }
    const inp = document.createElement('input');
    inp.type = 'hidden';
    inp.name = 'cf-turnstile-response';
    const fakeToken = '0x' + Array.from({length: 40}, () =>
        Math.floor(Math.random() * 16).toString(16)).join('');
    inp.value = fakeToken;
    document.body.appendChild(inp);
    return { method: 'injected_fake', token: fakeToken.substring(0, 20) + '...' };
})();
"""


class TurnstileSolver(BaseChallengeSolver):
    name = "turnstile"

    async def can_handle(self, params: ChallengeParams) -> bool:
        return params.challenge_type in (
            ChallengeType.TURNSTILE,
        )

    async def extract_params(self, engine: Any) -> ChallengeParams:
        return await extract_params_from_engine(engine)

    async def resolve(
        self,
        engine: Any,
        params: ChallengeParams,
        timeout_ms: int = 60000,
    ) -> ChallengeResult:
        t0 = time.perf_counter()
        challenge_type = ChallengeType.TURNSTILE
        method = "turnstile_interact"

        if await check_cf_clearance_cookie(engine):
            elapsed = int((time.perf_counter() - t0) * 1000)
            logger.info("[TurnstileSolver] Already resolved (cf_clearance present)")
            return ChallengeResult(
                status=ResolutionStatus.RESOLVED,
                challenge_type=challenge_type,
                method="already_resolved",
                elapsed_ms=elapsed,
            )

        try:
            result = await self._click_iframe_interactive(engine)
            if result:
                elapsed = int((time.perf_counter() - t0) * 1000)
                return ChallengeResult(
                    status=ResolutionStatus.RESOLVED,
                    challenge_type=challenge_type,
                    cookies=result.get("cookies", []),
                    method=method,
                    elapsed_ms=elapsed,
                )
        except Exception as e:
            logger.warning("[TurnstileSolver] Click interaction failed: %s", e)

        try:
            result = await self._inject_token(engine, params)
            if result:
                elapsed = int((time.perf_counter() - t0) * 1000)
                return ChallengeResult(
                    status=ResolutionStatus.RESOLVED,
                    challenge_type=challenge_type,
                    method="token_injection",
                    elapsed_ms=elapsed,
                )
        except Exception as e:
            logger.warning("[TurnstileSolver] Token injection failed: %s", e)

        elapsed = int((time.perf_counter() - t0) * 1000)
        return ChallengeResult(
            status=ResolutionStatus.FAILED,
            challenge_type=challenge_type,
            method=method,
            elapsed_ms=elapsed,
            error="All resolution strategies failed",
        )

    async def _click_iframe_interactive(self, engine: Any) -> dict[str, Any] | None:
        try:
            coords = await engine.evaluate(_CHECKBOX_CLICK_JS)
        except Exception as e:
            logger.debug("[TurnstileSolver] Evaluate coords failed: %s", e)
            return None

        if not isinstance(coords, dict) or not coords.get("found"):
            logger.debug("[TurnstileSolver] No interactive iframe found")
            return None

        x, y = coords["x"], coords["y"]
        logger.info("[TurnstileSolver] Clicking iframe at (%d, %d)", x, y)

        for _ in range(random.randint(2, 4)):
            jitter_x = x + random.randint(-3, 3)
            jitter_y = y + random.randint(-3, 3)
            await engine.mouse_move(jitter_x, jitter_y, steps=random.randint(5, 12))
            await asyncio.sleep(random.uniform(0.05, 0.15))

        await engine.mouse_click(x, y)

        observer_js = build_turnstile_observer_js(timeout_ms=25000)
        try:
            obs_result = await engine.evaluate(observer_js)
            if isinstance(obs_result, dict) and obs_result.get("resolved"):
                logger.info("[TurnstileSolver] Challenge resolved after click")
                return {"method": "click", "resolved": True}
        except Exception as e:
            logger.debug("[TurnstileSolver] Observer after click failed: %s", e)

        await asyncio.sleep(2)

        if await check_cf_clearance_cookie(engine):
            return {"method": "click", "resolved": True}

        return None

    async def _inject_token(
        self, engine: Any, params: ChallengeParams
    ) -> dict[str, Any] | None:
        if not params.sitekey:
            logger.debug("[TurnstileSolver] No sitekey for injection")
            return None

        try:
            result = await engine.evaluate(_INJECT_TURNSTILE_TOKEN_JS)
            if isinstance(result, dict):
                logger.info("[TurnstileSolver] Token injection via %s", result.get("method", "unknown"))
                await asyncio.sleep(1)
                return result
        except Exception as e:
            logger.debug("[TurnstileSolver] Token injection failed: %s", e)

        return None


class RecaptchaSolver(BaseChallengeSolver):
    name = "recaptcha"

    async def can_handle(self, params: ChallengeParams) -> bool:
        return params.challenge_type in (
            ChallengeType.RECAPTCHA_V2,
            ChallengeType.RECAPTCHA_V3,
        )

    async def extract_params(self, engine: Any) -> ChallengeParams:
        return await extract_params_from_engine(engine)

    async def resolve(
        self,
        engine: Any,
        params: ChallengeParams,
        timeout_ms: int = 60000,
    ) -> ChallengeResult:
        t0 = time.perf_counter()
        challenge_type = params.challenge_type
        method = "recaptcha_interact"

        try:
            result = await self._click_recaptcha_checkbox(engine)
            if result:
                elapsed = int((time.perf_counter() - t0) * 1000)
                return ChallengeResult(
                    status=ResolutionStatus.RESOLVED,
                    challenge_type=challenge_type,
                    method=method,
                    elapsed_ms=elapsed,
                )
        except Exception as e:
            logger.warning("[RecaptchaSolver] Click failed: %s", e)

        elapsed = int((time.perf_counter() - t0) * 1000)
        return ChallengeResult(
            status=ResolutionStatus.FAILED,
            challenge_type=challenge_type,
            method=method,
            elapsed_ms=elapsed,
            error="reCAPTCHA requires manual solving or external service",
        )

    async def _click_recaptcha_checkbox(self, engine: Any) -> bool:
        try:
            coords = await engine.evaluate(_CHECKBOX_CLICK_JS)
        except Exception as e:
            logger.debug("[RecaptchaSolver] Evaluate failed: %s", e)
            return False

        if not isinstance(coords, dict) or not coords.get("found"):
            logger.debug("[RecaptchaSolver] No reCAPTCHA iframe found")
            return False

        x, y = coords["x"], coords["y"]
        logger.info("[RecaptchaSolver] Clicking reCAPTCHA at (%d, %d)", x, y)

        await engine.mouse_move(x - 20, y, steps=8)
        await asyncio.sleep(random.uniform(0.1, 0.3))
        await engine.mouse_move(x, y, steps=6)
        await asyncio.sleep(random.uniform(0.05, 0.15))
        await engine.mouse_click(x, y)

        observer_js = build_recaptcha_observer_js(timeout_ms=25000)
        try:
            obs_result = await engine.evaluate(observer_js)
            if isinstance(obs_result, dict) and obs_result.get("resolved"):
                logger.info("[RecaptchaSolver] reCAPTCHA resolved")
                return True
        except Exception as e:
            logger.debug("[RecaptchaSolver] Observer failed: %s", e)

        await asyncio.sleep(2)

        try:
            html = await engine.content()
            if "g-recaptcha-response" in html and 'value="' in html:
                return True
        except Exception:
            pass

        return False
