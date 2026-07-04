from __future__ import annotations

import asyncio
import logging
from typing import Any

logger = logging.getLogger(__name__)

_OBSERVER_JS = """
(async () => {
    const CHALLENGE_SELECTORS = [
        'input[name="cf-turnstile-response"]',
        'textarea#g-recaptcha-response',
        'textarea[name="g-recaptcha-response"]',
        'input[name="h-captcha-response"]',
        'textarea[name="h-captcha-response"]',
        'input[name="cf-response"]',
        '#cf-please-wait',
        '#challenge-stage',
    ];

    const checkResolved = () => {
        for (const sel of CHALLENGE_SELECTORS) {
            const el = document.querySelector(sel);
            if (el && el.value && el.value.length > 10) {
                return { resolved: true, selector: sel, value: el.value.substring(0, 20) + '...' };
            }
        }
        const cfChrome = document.querySelector('#cf-please-wait, #challenge-stage');
        if (cfChrome && cfChrome.style.display === 'none') {
            return { resolved: true, selector: 'cf-challenge-hidden', value: '' };
        }
        const loadingChrome = document.getElementById('challenge-stage');
        if (!loadingChrome && !document.querySelector('[class*="cf-"], [class*="challenge-"]')) {
            const turnstileResponse = document.querySelector(
                'input[name="cf-turnstile-response"], input[name="cf-response"]'
            );
            if (turnstileResponse && turnstileResponse.value) {
                return { resolved: true, selector: 'turnstile-injected', value: turnstileResponse.value.substring(0, 20) + '...' };
            }
        }
        return { resolved: false };
    };

    const initial = checkResolved();
    if (initial.resolved) return initial;

    return new Promise((resolve) => {
        const observer = new MutationObserver(() => {
            const state = checkResolved();
            if (state.resolved) {
                observer.disconnect();
                resolve(state);
            }
        });

        observer.observe(document.body || document.documentElement, {
            childList: true,
            subtree: true,
            attributes: true,
            attributeFilter: ['value', 'style', 'class', 'data-status'],
        });

        const cfResponseInterval = setInterval(() => {
            const state = checkResolved();
            if (state.resolved) {
                clearInterval(cfResponseInterval);
                observer.disconnect();
                resolve(state);
            }
        }, 200);

        setTimeout(() => {
            clearInterval(cfResponseInterval);
            observer.disconnect();
            resolve({ resolved: false, error: 'timeout' });
        }, TIMEOUT_MS);
    });
})();
"""

_COOKIE_CHECK_JS = """
(() => {
    const check = 'cf_clearance';
    const cookies = document.cookie.split(';').map(c => c.trim());
    for (const c of cookies) {
        if (c.startsWith(check + '=') || c.startsWith('__cfuid=')) {
            return { found: true, cookie: c };
        }
    }
    return { found: false };
})();
"""


async def wait_for_challenge_resolution(
    engine: Any,
    timeout_ms: int = 60000,
    poll_interval_ms: int = 300,
) -> dict[str, Any]:
    js = _OBSERVER_JS.replace("TIMEOUT_MS", str(timeout_ms))

    for attempt in range(3):
        try:
            result = await engine.evaluate(js)
            if isinstance(result, dict) and result.get("resolved"):
                logger.info(
                    "[DOMObserver] Challenge resolved via %s",
                    result.get("selector", "unknown"),
                )
                return result
        except Exception as e:
            logger.debug("[DOMObserver] Evaluate attempt %d failed: %s", attempt + 1, e)

        await asyncio.sleep(poll_interval_ms / 1000)

    logger.warning("[DOMObserver] Challenge resolution timed out after %dms", timeout_ms)
    return {"resolved": False, "error": "timeout"}


async def check_cf_clearance_cookie(
    engine: Any,
) -> bool:
    try:
        result = await engine.evaluate(_COOKIE_CHECK_JS)
        if isinstance(result, dict) and result.get("found"):
            logger.info("[DOMObserver] cf_clearance cookie present")
            return True
    except Exception as e:
        logger.debug("[DOMObserver] Cookie check failed: %s", e)

    try:
        cookies = await engine.get_cookies()
        for c in cookies:
            name = c.get("name", "")
            if name in ("cf_clearance", "__cfuid"):
                logger.info("[DOMObserver] cf_clearance cookie found via API")
                return True
    except Exception as e:
        logger.debug("[DOMObserver] Cookie API check failed: %s", e)

    return False


async def is_challenge_page(engine: Any) -> bool:
    try:
        html = await engine.content()
        body = html.lower()
        indicators = [
            "cf-browser-verify",
            "cdn-cgi/challenge-platform",
            "just a moment",
            "checking your browser",
            "verifying you are human",
            "enable javascript",
            "cloudflare",
            "attention required",
        ]
        return any(ind in body for ind in indicators)
    except Exception:
        return False


def build_turnstile_observer_js(timeout_ms: int = 30000) -> str:
    return f"""
(async () => {{
    const checkToken = () => {{
        const inp = document.querySelector(
            'input[name="cf-turnstile-response"], input[name="cf-response"], ' +
            'input[data-cf-turnstile-response]'
        );
        if (inp && inp.value && inp.value.length > 10) {{
            return inp.value;
        }}
        return null;
    }};

    const existing = checkToken();
    if (existing) return {{ resolved: true, token: existing.substring(0, 30) }};

    return new Promise((resolve) => {{
        const observer = new MutationObserver(() => {{
            const token = checkToken();
            if (token) {{
                observer.disconnect();
                clearTimeout(timer);
                resolve({{ resolved: true, token: token.substring(0, 30) }});
            }}
        }});
        observer.observe(document.documentElement, {{
            childList: true,
            subtree: true,
            attributes: true,
        }});
        const timer = setTimeout(() => {{
            observer.disconnect();
            resolve({{ resolved: false, error: 'timeout' }});
        }}, {timeout_ms});
    }});
}})();
"""


def build_recaptcha_observer_js(timeout_ms: int = 30000) -> str:
    return f"""
(async () => {{
    const checkResponse = () => {{
        const ta = document.querySelector(
            'textarea#g-recaptcha-response, textarea[name="g-recaptcha-response"]'
        );
        if (ta && ta.value && ta.value.length > 10) {{
            return ta.value;
        }}
        return null;
    }};

    const existing = checkResponse();
    if (existing) return {{ resolved: true, token: existing.substring(0, 30) }};

    return new Promise((resolve) => {{
        const observer = new MutationObserver(() => {{
            const token = checkResponse();
            if (token) {{
                observer.disconnect();
                clearTimeout(timer);
                resolve({{ resolved: true, token: token.substring(0, 30) }});
            }}
        }});
        observer.observe(document.documentElement, {{
            childList: true,
            subtree: true,
            attributes: true,
            attributeFilter: ['value'],
        }});
        const timer = setTimeout(() => {{
            observer.disconnect();
            resolve({{ resolved: false, error: 'timeout' }});
        }}, {timeout_ms});
    }});
}})();
"""
