from __future__ import annotations

import logging
import re
from typing import Any

from pipeline.scraper.transport.resolver.solver_base import ChallengeParams, ChallengeType

logger = logging.getLogger(__name__)

TURNSTILE_SITEKEY_RE = re.compile(
    r'data-sitekey=["\']([^"\']+)["\']', re.IGNORECASE
)
RECAPTCHA_SITEKEY_RE = re.compile(
    r'data-sitekey=["\']([^"\']+)["\']', re.IGNORECASE
)
HCAPTCHA_SITEKEY_RE = re.compile(
    r'data-sitekey=["\']([^"\']+)["\']', re.IGNORECASE
)
TURNSTILE_ACTION_RE = re.compile(
    r'data-action=["\']([^"\']+)["\']', re.IGNORECASE
)
FORM_ACTION_RE = re.compile(
    r'<form[^>]+action=["\']([^"\']+)["\']', re.IGNORECASE
)
CF_CHALLENGE_RE = re.compile(
    r'(cf-browser-verify|challenge-platform|cdn-cgi/challenge-platform|cloudflare\.com/cdn-cgi)', re.IGNORECASE
)


async def extract_params_from_engine(engine: Any) -> ChallengeParams:
    html = ""
    page_url = ""
    try:
        html = await engine.content()
        page_url = await engine.evaluate("window.location.href")
    except Exception as e:
        logger.warning("[CaptchaParams] Failed to get page content: %s", e)
        return ChallengeParams()

    return extract_params(html, page_url)


def extract_params(html: str, page_url: str = "") -> ChallengeParams:
    params = ChallengeParams(page_url=page_url)

    params.challenge_type = _detect_challenge_type(html)

    if params.challenge_type == ChallengeType.TURNSTILE:
        params.sitekey = _extract_turnstile_sitekey(html)
        params.action = _extract_turnstile_action(html)
        params.element_id = _extract_element_id(html, "cf-turnstile")
        params.iframe_src = _extract_turnstile_iframe(params.sitekey, page_url)
    elif params.challenge_type == ChallengeType.RECAPTCHA_V2:
        params.sitekey = _extract_recaptcha_sitekey(html)
        params.element_id = _extract_element_id(html, "g-recaptcha")
    elif params.challenge_type == ChallengeType.HCAPTCHA:
        params.sitekey = _extract_hcaptcha_sitekey(html)
        params.element_id = _extract_element_id(html, "h-captcha")

    params.form_action = _extract_form_action(html, params.element_id)
    params.dom_snippet = _extract_dom_snippet(html, params.challenge_type)

    if params.sitekey:
        logger.info(
            "[CaptchaParams] %s detected | sitekey=%s | action=%s",
            params.challenge_type.value, params.sitekey[:20], params.action or "(none)",
        )
    else:
        logger.debug("[CaptchaParams] No sitekey found for %s", params.challenge_type.value)

    return params


def _detect_challenge_type(html: str) -> ChallengeType:
    if CF_CHALLENGE_RE.search(html):
        body_lower = html.lower()
        if "turnstile" in body_lower or "cf-turnstile" in body_lower:
            return ChallengeType.TURNSTILE
        return ChallengeType.CLOUDFLARE_JS

    if "recaptcha/api.js" in html.lower() or "g-recaptcha" in html.lower():
        body_lower = html.lower()
        if "data-sitekey" in html and "recaptcha" in body_lower:
            return ChallengeType.RECAPTCHA_V2
        return ChallengeType.RECAPTCHA_V3

    if "hcaptcha" in html.lower() or "h-captcha" in html.lower():
        return ChallengeType.HCAPTCHA

    return ChallengeType.UNKNOWN


def _extract_turnstile_sitekey(html: str) -> str:
    m = re.search(
        r'(?:data-sitekey|data\-cf\-sitekey)["\']?\s*[:=]\s*["\']([^"\']+)["\']', html, re.IGNORECASE
    )
    if m:
        return m.group(1)

    m = re.search(r'cf-turnstile-wrapper[^>]+sitekey["\']?\s*[:=]\s*["\']([^"\']+)', html, re.IGNORECASE)
    return m.group(1) if m else ""


def _extract_turnstile_action(html: str) -> str:
    m = TURNSTILE_ACTION_RE.search(html)
    return m.group(1) if m else ""


def _extract_recaptcha_sitekey(html: str) -> str:
    m = re.search(
        r'(?:data-sitekey|data\-recaptcha\-sitekey)["\']?\s*[:=]\s*["\']([^"\']+)["\']',
        html,
        re.IGNORECASE,
    )
    return m.group(1) if m else ""


def _extract_hcaptcha_sitekey(html: str) -> str:
    m = re.search(
        r'(?:data-sitekey)["\']?\s*[:=]\s*["\']([^"\']+)["\']', html, re.IGNORECASE
    )
    return m.group(1) if m else ""


def _extract_element_id(html: str, prefix: str) -> str:
    m = re.search(rf'<div[^>]*\bid=["\']([^"\']*{prefix}[^"\']*)["\']', html, re.IGNORECASE)
    return m.group(1) if m else f"{prefix}-widget"


def _extract_turnstile_iframe(sitekey: str, page_url: str) -> str:
    if page_url:
        from urllib.parse import urlencode, urlparse
        parsed = urlparse(page_url)
        params = urlencode({"sitekey": sitekey, "origin": f"{parsed.scheme}://{parsed.hostname}"})
        return f"https://challenges.cloudflare.com/turnstile/v0/api.js?{params}"
    return ""


def _extract_form_action(html: str, element_id: str) -> str:
    m = re.search(
        rf'<form[^>]*?id=["\']{element_id}["\'][^>]*?action=["\']([^"\']+)',
        html, re.IGNORECASE,
    )
    if m:
        return m.group(1)
    m = FORM_ACTION_RE.search(html)
    return m.group(1) if m else ""


def _extract_dom_snippet(html: str, ctype: ChallengeType) -> str:
    if ctype == ChallengeType.TURNSTILE:
        m = re.search(
            r'(<div[^>]*?cf-turnstile[^>]*?>.*?</div>)', html, re.IGNORECASE | re.DOTALL
        )
    elif ctype == ChallengeType.RECAPTCHA_V2:
        m = re.search(
            r'(<div[^>]*?g-recaptcha[^>]*?>.*?</div>)', html, re.IGNORECASE | re.DOTALL
        )
    elif ctype == ChallengeType.HCAPTCHA:
        m = re.search(
            r'(<div[^>]*?h-captcha[^>]*?>.*?</div>)', html, re.IGNORECASE | re.DOTALL
        )
    else:
        return ""
    return m.group(1)[:500] if m else ""
