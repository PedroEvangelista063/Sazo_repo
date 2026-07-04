from __future__ import annotations

import logging
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import Enum
from typing import Any

logger = logging.getLogger(__name__)


class ChallengeType(str, Enum):
    CLOUDFLARE_JS = "cloudflare_js"
    TURNSTILE = "turnstile"
    RECAPTCHA_V2 = "recaptcha_v2"
    RECAPTCHA_V3 = "recaptcha_v3"
    HCAPTCHA = "hcaptcha"
    DDOGUARD = "ddoguard"
    UNKNOWN = "unknown"


class ResolutionStatus(str, Enum):
    PENDING = "pending"
    RESOLVED = "resolved"
    FAILED = "failed"
    SKIPPED = "skipped"
    TIMEOUT = "timeout"


@dataclass
class ChallengeResult:
    status: ResolutionStatus = ResolutionStatus.PENDING
    challenge_type: ChallengeType = ChallengeType.UNKNOWN
    cookies: list[dict[str, Any]] = field(default_factory=list)
    user_agent: str = ""
    html: str = ""
    resolved_url: str = ""
    elapsed_ms: int = 0
    method: str = ""
    error: str = ""


@dataclass
class ChallengeParams:
    sitekey: str = ""
    action: str = ""
    page_url: str = ""
    form_action: str = ""
    challenge_type: ChallengeType = ChallengeType.UNKNOWN
    dom_snippet: str = ""
    iframe_src: str = ""
    element_id: str = ""

    @property
    def is_valid(self) -> bool:
        return bool(self.sitekey or self.challenge_type != ChallengeType.UNKNOWN)


class BaseChallengeSolver(ABC):
    name: str = "base"

    @abstractmethod
    async def can_handle(self, params: ChallengeParams) -> bool:
        ...

    @abstractmethod
    async def resolve(
        self, engine: Any, params: ChallengeParams, timeout_ms: int = 60000
    ) -> ChallengeResult:
        ...

    @abstractmethod
    async def extract_params(self, engine: Any) -> ChallengeParams:
        ...
