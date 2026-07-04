from __future__ import annotations

from pipeline.scraper.transport.resolver.challenge_router import ChallengeRouter
from pipeline.scraper.transport.resolver.dom_observer import (
    build_recaptcha_observer_js,
    build_turnstile_observer_js,
    check_cf_clearance_cookie,
    is_challenge_page,
    wait_for_challenge_resolution,
)
from pipeline.scraper.transport.resolver.flaresolverr import FlareSolverrConnector
from pipeline.scraper.transport.resolver.solver_base import (
    BaseChallengeSolver,
    ChallengeParams,
    ChallengeResult,
    ChallengeType,
    ResolutionStatus,
)
from pipeline.scraper.transport.resolver.turnstile import RecaptchaSolver, TurnstileSolver

__all__ = [
    "ChallengeRouter",
    "FlareSolverrConnector",
    "TurnstileSolver",
    "RecaptchaSolver",
    "BaseChallengeSolver",
    "ChallengeParams",
    "ChallengeResult",
    "ChallengeType",
    "ResolutionStatus",
    "is_challenge_page",
    "check_cf_clearance_cookie",
    "wait_for_challenge_resolution",
    "build_turnstile_observer_js",
    "build_recaptcha_observer_js",
]
