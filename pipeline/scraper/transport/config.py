from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class BrowserType(str, Enum):
    CHROMIUM = "chromium"
    FIREFOX = "firefox"
    WEBKIT = "webkit"


class EngineType(str, Enum):
    PYDOLL = "pydoll"
    PATCHRIGHT = "patchright"
    CAMOUFOX = "camoufox"


@dataclass
class FingerprintConfig:
    webrtc_spoof: bool = True
    canvas_spoof: bool = True
    audio_spoof: bool = True
    webgl_spoof: bool = True
    fonts_spoof: bool = True
    geolocation_spoof: bool = True
    timezone_spoof: bool = True
    locale_spoof: bool = True

    dynamic_ua: bool = True
    custom_ua: str | None = None

    tls_ja3_override: str | None = None

    viewport: dict[str, int] = field(default_factory=lambda: {"width": 1280, "height": 720})
    locale: str = "pt-BR"
    timezone: str = "America/Sao_Paulo"
    geolocation: dict[str, float] | None = None

    extensions_paths: list[str] = field(default_factory=list)

    proxy: str | None = None
    extra_args: list[str] = field(default_factory=list)

    hardware_concurrency: int = 8
    device_memory: int = 8


@dataclass
class BrowserConfig:
    engine: EngineType = EngineType.PYDOLL
    browser: BrowserType = BrowserType.CHROMIUM
    fingerprint: FingerprintConfig = field(default_factory=FingerprintConfig)
    headless: bool = True
    page_load_timeout_ms: int = 60000
    navigation_timeout_ms: int = 30000
    debug: bool = False
    storage_state_path: str | None = None
    extra_launch_args: dict[str, Any] = field(default_factory=dict)
