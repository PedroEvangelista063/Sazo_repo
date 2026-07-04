from __future__ import annotations

import asyncio
import logging
import random
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any

from pipeline.scraper.transport import (
    BrowserConfig,
    ChallengeRouter,
    EngineType,
    FingerprintConfig,
    ResolutionStatus,
    SemanticExtractionEngine,
    StealthTransportEngine,
)
from pipeline.scraper.transport.orchestrator.jdownloader_bridge import JDownloaderBridge
from pipeline.scraper.transport.orchestrator.waf_bypass import WafBypassInterceptor
from pipeline.scraper.transport.semantic.block_detector import BlockDetector
from pipeline.scraper.transport.semantic.interaction_executor import InteractionExecutor
from pipeline.scraper.transport.semantic.models import ExtractionResult, InteractionStep

logger = logging.getLogger(__name__)


class OrganismState(str, Enum):
    IDLE = "idle"
    NAVIGATING = "navigating"
    EXTRACTING = "extracting"
    RESOLVING_CHALLENGE = "resolving_challenge"
    ROTATING_IDENTITY = "rotating_identity"
    BYPASSING_WAF = "bypassing_waf"
    DOWNLOADING = "downloading"
    FAILED = "failed"
    COOLDOWN = "cooldown"


@dataclass
class HarvestResult:
    url: str = ""
    success: bool = False
    extraction: ExtractionResult | None = None
    state_history: list[str] = field(default_factory=list)
    attempts: int = 0
    total_elapsed_ms: int = 0
    error: str = ""
    identity_rotations: int = 0
    waf_bypass_attempts: int = 0
    challenge_solved: bool = False
    downloads_enqueued: int = 0


@dataclass
class IdentityProfile:
    fingerprint: FingerprintConfig
    label: str = "default"


class SelfHealingOrganism:
    """Master orchestrator — joins Phases 1-4 into a self-healing loop.

    Pipeline per URL:
      1. Extract with current identity
      2. If WAF/challenge blocks → resolve (FlareSolverr → Turnstile → reCAPTCHA)
      3. If resolver fails → rotate fingerprint (new UA, viewport, spoof profile)
      4. If rotation fails → try WAF bypass (XML payload encoding)
      5. If all fail → circuit break, cooldown, report
      6. Detect heavy downloads → enqueue in JDownloader
    """

    def __init__(
        self,
        base_browser_config: BrowserConfig | None = None,
        flaresolverr_endpoint: str | None = None,
        spacy_model: str | None = None,
        jdownloader_email: str = "",
        jdownloader_password: str = "",
        jdownloader_device: str = "",
        watch_folder: str = "",
        identity_pool_size: int = 3,
        max_retries_per_url: int = 3,
        cooldown_after_failure_s: int = 30,
    ) -> None:
        self._base_config = base_browser_config or BrowserConfig(
            engine=EngineType.PATCHRIGHT,
            headless=True,
        )
        self._flaresolverr_endpoint = flaresolverr_endpoint
        self._spacy_model = spacy_model
        self._jd_email = jdownloader_email
        self._jd_password = jdownloader_password
        self._jd_device = jdownloader_device
        self._watch_folder = watch_folder
        self._identity_pool_size = max(identity_pool_size, 1)
        self._max_retries = max_retries_per_url
        self._cooldown_s = cooldown_after_failure_s

        self._identity_pool: list[IdentityProfile] = []
        self._current_identity_idx = 0
        self._engine: StealthTransportEngine | None = None
        self._challenge_router: ChallengeRouter | None = None
        self._semantic_engine: SemanticExtractionEngine | None = None
        self._block_detector: BlockDetector | None = None
        self._waf_bypass: WafBypassInterceptor | None = None
        self._jdownloader: JDownloaderBridge | None = None
        self._state = OrganismState.IDLE
        self._global_stats: dict[str, int] = {
            "total_harvests": 0,
            "success": 0,
            "failed": 0,
            "identity_rotations": 0,
            "challenges_solved": 0,
            "waf_bypasses": 0,
            "downloads_enqueued": 0,
        }

        self._build_identity_pool()

    def _build_identity_pool(self) -> None:
        viewports = [
            {"width": 1280, "height": 720},
            {"width": 1366, "height": 768},
            {"width": 1920, "height": 1080},
            {"width": 1440, "height": 900},
            {"width": 1536, "height": 864},
        ]
        locales = ["pt-BR", "en-US", "pt-PT", "es-ES"]
        timezones = [
            "America/Sao_Paulo",
            "America/New_York",
            "America/Lisbon",
            "Europe/Madrid",
        ]

        for i in range(self._identity_pool_size):
            vp = viewports[i % len(viewports)]
            fp = FingerprintConfig(
                webrtc_spoof=True,
                canvas_spoof=True,
                audio_spoof=True,
                webgl_spoof=True,
                geolocation_spoof=True,
                timezone_spoof=True,
                locale_spoof=True,
                dynamic_ua=True,
                custom_ua=None,
                viewport=vp,
                locale=locales[i % len(locales)],
                timezone=timezones[i % len(timezones)],
                geolocation={"lat": -23.5505 + random.uniform(-5, 5), "lng": -46.6333 + random.uniform(-5, 5)},
                hardware_concurrency=random.choice([4, 8, 8, 12]),
                device_memory=random.choice([4, 8, 8, 16]),
            )
            self._identity_pool.append(
                IdentityProfile(fingerprint=fp, label=f"identity_{i}")
            )

        logger.info(
            "[Organism] %d identity profiles built", len(self._identity_pool)
        )

    def _get_current_config(self) -> BrowserConfig:
        profile = self._identity_pool[self._current_identity_idx]
        return BrowserConfig(
            engine=self._base_config.engine,
            browser=self._base_config.browser,
            fingerprint=profile.fingerprint,
            headless=self._base_config.headless,
            page_load_timeout_ms=self._base_config.page_load_timeout_ms,
            navigation_timeout_ms=self._base_config.navigation_timeout_ms,
            debug=self._base_config.debug,
        )

    async def _ensure_engine(self) -> StealthTransportEngine:
        if self._engine and self._engine.running:
            return self._engine

        config = self._get_current_config()
        if self._engine:
            await self._engine.stop()

        from pipeline.scraper.transport import create_engine

        self._engine = create_engine(config)
        await self._engine.start()
        return self._engine

    async def _ensure_components(self) -> None:
        if self._challenge_router is None:
            self._challenge_router = ChallengeRouter(
                flaresolverr_endpoint=self._flaresolverr_endpoint
            )

        if self._semantic_engine is None:
            self._semantic_engine = SemanticExtractionEngine(
                spacy_model=self._spacy_model, use_vader=True
            )

        if self._block_detector is None:
            self._block_detector = BlockDetector(use_vader=True)

        if self._waf_bypass is None:
            self._waf_bypass = WafBypassInterceptor(
                block_detector=self._block_detector
            )

        if self._jdownloader is None:
            self._jdownloader = JDownloaderBridge(
                myjdownloader_email=self._jd_email,
                myjdownloader_password=self._jd_password,
                device_name=self._jd_device,
                watch_folder=self._watch_folder,
            )

        await self._jdownloader.connect()

    def _rotate_identity(self) -> None:
        self._current_identity_idx = (self._current_identity_idx + 1) % len(
            self._identity_pool
        )
        self._global_stats["identity_rotations"] += 1
        profile = self._identity_pool[self._current_identity_idx]
        logger.info(
            "[Organism] Rotated to %s (vp=%s tz=%s locale=%s)",
            profile.label,
            profile.fingerprint.viewport,
            profile.fingerprint.timezone,
            profile.fingerprint.locale,
        )

    async def harvest(
        self,
        url: str,
        check_downloads: bool = True,
        pre_actions: list[InteractionStep] | None = None,
    ) -> HarvestResult:
        t0 = time.perf_counter()
        result = HarvestResult(url=url)
        self._global_stats["total_harvests"] += 1

        await self._ensure_components()
        engine = await self._ensure_engine()

        for attempt in range(1, self._max_retries + 1):
            result.attempts = attempt
            result.state_history.append(f"attempt_{attempt}")

            self._state = OrganismState.NAVIGATING

            try:
                cr_result = await self._challenge_router.navigate_with_resolution(
                    engine=engine,
                    url=url,
                    max_retries=1,
                    flaresolverr_first=True,
                    resolution_timeout_ms=90000,
                )

                if cr_result.status == ResolutionStatus.RESOLVED:
                    result.challenge_solved = True
                    self._global_stats["challenges_solved"] += 1
                    logger.info(
                        "[Organism] Challenge resolved via %s", cr_result.method
                    )
                elif cr_result.status == ResolutionStatus.FAILED:
                    logger.warning(
                        "[Organism] Challenge resolution failed: %s", cr_result.error
                    )

            except Exception as e:
                logger.warning("[Organism] Navigation/challenge error: %s", e)

            if pre_actions:
                self._state = OrganismState.EXTRACTING
                executor = InteractionExecutor(engine)
                await executor.execute(pre_actions)
                # Wait for network idle after interactions
                try:
                    await engine.wait_for_selector("body", timeout=3000)
                except Exception:
                    pass
                await asyncio.sleep(0.5)

            self._state = OrganismState.EXTRACTING

            try:
                extraction = await self._semantic_engine.analyze_from_engine(engine)
                result.extraction = extraction
            except Exception as e:
                logger.error("[Organism] Extraction failed: %s", e)
                extraction = ExtractionResult()

            block = extraction.block_detection
            if block and block.is_blocked:
                self._state = OrganismState.RESOLVING_CHALLENGE
                logger.info(
                    "[Organism] Block detected: type=%s confidence=%.2f rotate=%s",
                    block.block_type.value if block.block_type else "?",
                    block.confidence,
                    block.trigger_rotation,
                )
                result.state_history.append(f"blocked_{block.block_type.value}")

                if attempt < self._max_retries:
                    if block.trigger_rotation:
                        self._state = OrganismState.ROTATING_IDENTITY
                        self._rotate_identity()
                        engine = await self._ensure_engine()
                        result.identity_rotations += 1

                    if attempt == self._max_retries - 1:
                        self._state = OrganismState.BYPASSING_WAF
                        bypass_result = await self._waf_bypass.smart_bypass(
                            url=url, headers={}
                        )
                        if bypass_result.success:
                            self._global_stats["waf_bypasses"] += 1
                            result.waf_bypass_attempts += 1
                            result.state_history.append("waf_bypass_ok")
                        else:
                            result.state_history.append("waf_bypass_fail")

                    continue

            download_links = await self._detect_downloads(engine, url)
            if download_links:
                self._state = OrganismState.DOWNLOADING
                enqueued = await self._jdownloader.auto_enqueue_heavy(
                    download_links, source_url=url
                )
                result.downloads_enqueued = enqueued
                if enqueued:
                    self._global_stats["downloads_enqueued"] += enqueued

            if extraction and extraction.entities:
                result.success = True
                self._global_stats["success"] += 1
                result.total_elapsed_ms = int((time.perf_counter() - t0) * 1000)
                self._state = OrganismState.IDLE
                return result

            if attempt < self._max_retries:
                wait = attempt * 2.0
                logger.info("[Organism] Retry %d/%d in %.1fs", attempt, self._max_retries, wait)
                await asyncio.sleep(wait)

        self._state = OrganismState.FAILED
        self._global_stats["failed"] += 1
        result.total_elapsed_ms = int((time.perf_counter() - t0) * 1000)
        result.error = f"Failed after {self._max_retries} attempts"

        return result

    async def _detect_downloads(
        self, engine: Any, source_url: str
    ) -> list[str]:
        download_links: list[str] = []
        try:
            links_js = await engine.evaluate(
                "Array.from(document.querySelectorAll('a[href]')).map(a => a.href)"
            )
            if isinstance(links_js, list):
                for link in links_js:
                    if isinstance(link, str) and JDownloaderBridge.is_download_link(link):
                        download_links.append(link)
        except Exception:
            pass

        try:
            html = await engine.content()
            from pipeline.scraper.transport.orchestrator.jdownloader_bridge import (
                _RE_HEAVY_FILE,
                _RE_TEMP_TOKEN,
            )

            for pattern in (_RE_HEAVY_FILE, _RE_TEMP_TOKEN):
                for match in pattern.finditer(html):
                    link = match.group().strip()
                    if link.startswith("http"):
                        download_links.append(link)
        except Exception:
            pass

        return list(set(download_links))

    async def harvest_batch(
        self, urls: list[str], max_concurrency: int = 3
    ) -> list[HarvestResult]:
        semaphore = asyncio.Semaphore(max_concurrency)
        results: list[HarvestResult] = []

        async def _worker(url: str) -> HarvestResult:
            async with semaphore:
                return await self.harvest(url)

        for coro in asyncio.as_completed([_worker(u) for u in urls]):
            try:
                result = await coro
                results.append(result)
            except Exception as e:
                logger.error("[Organism] Batch worker failed: %s", e)

        return results

    async def report(self) -> dict[str, Any]:
        challenge_stats = {}
        waf_stats = {}
        jd_status = None

        if self._challenge_router:
            challenge_stats = self._challenge_router.stats
        if self._waf_bypass:
            waf_stats = self._waf_bypass.stats
        if self._jdownloader:
            jd_status = await self._jdownloader.status()

        return {
            "state": self._state.value,
            "current_identity": self._identity_pool[
                self._current_identity_idx
            ].label,
            "global_stats": dict(self._global_stats),
            "challenge_router": challenge_stats,
            "waf_bypass": waf_stats,
            "jdownloader": {
                "connected": jd_status.connected if jd_status else False,
                "device": jd_status.device_name if jd_status else "",
                "queue": jd_status.queue_count if jd_status else 0,
            }
            if jd_status
            else {"connected": False},
            "spacy_available": self._semantic_engine.spacy_available
            if self._semantic_engine
            else False,
            "vader_available": self._semantic_engine.vader_available
            if self._semantic_engine
            else False,
        }

    async def close(self) -> None:
        if self._engine:
            await self._engine.stop()
        if self._challenge_router:
            await self._challenge_router.close()
        if self._waf_bypass:
            await self._waf_bypass.close()
        if self._jdownloader:
            await self._jdownloader.close()
        self._state = OrganismState.IDLE
        logger.info("[Organism] All resources released")
