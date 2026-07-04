from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

from pipeline.scraper.transport.config import BrowserConfig, BrowserType, EngineType, FingerprintConfig
from pipeline.scraper.transport.engine import StealthTransportEngine, PageProxy
from pipeline.scraper.transport.pydoll_engine import PydollTransportEngine
from pipeline.scraper.transport.patchright_engine import PatchrightCamoufoxTransportEngine

# Challenge resolution layer
from pipeline.scraper.transport.resolver import (
    ChallengeRouter,
    ChallengeType,
    ChallengeResult,
    ChallengeParams,
    ResolutionStatus,
    FlareSolverrConnector,
    TurnstileSolver,
    RecaptchaSolver,
    is_challenge_page,
    check_cf_clearance_cookie,
    wait_for_challenge_resolution,
)

# Semantic extraction layer (NLP, NER, block detection, dynamic XPath)
from pipeline.scraper.transport.semantic import (
    SemanticExtractionEngine,
    BlockDetector,
    NERExtractor,
    DynamicXPathSelector,
    ExtractionResult,
    ExtractedEntity,
    BlockDetectionResult,
    BlockType,
    EntityLabel,
    PriceEntity,
    DateEntity,
    TableCandidate,
)

# Orchestrator layer (self-healing loop, JDownloader, WAF bypass)
from pipeline.scraper.transport.orchestrator import (
    SelfHealingOrganism,
    HarvestResult,
    OrganismState,
    IdentityProfile,
    JDownloaderBridge,
    DownloadCandidate,
    JDownloaderStatus,
    WafBypassInterceptor,
    WafBypassResult,
    BypassAttempt,
    EncodingStrategy,
    XmlPayloadStyle,
)

logger = logging.getLogger(__name__)


def create_engine(config: BrowserConfig) -> StealthTransportEngine:
    if config.engine == EngineType.PYDOLL:
        return PydollTransportEngine(config)
    elif config.engine == EngineType.PATCHRIGHT:
        return PatchrightCamoufoxTransportEngine(config)
    elif config.engine == EngineType.CAMOUFOX:
        cfg = BrowserConfig(
            engine=EngineType.PATCHRIGHT,
            browser=BrowserType.FIREFOX,
            fingerprint=config.fingerprint,
            headless=config.headless,
            page_load_timeout_ms=config.page_load_timeout_ms,
            navigation_timeout_ms=config.navigation_timeout_ms,
            debug=config.debug,
            storage_state_path=config.storage_state_path,
            extra_launch_args=config.extra_launch_args,
        )
        logger.info("[Transport] CAMOUFOX mapped to PATCHRIGHT with Firefox browser type")
        return PatchrightCamoufoxTransportEngine(cfg)
    raise ValueError(f"Unknown engine: {config.engine}")


@asynccontextmanager
async def managed_engine(config: BrowserConfig) -> AsyncIterator[StealthTransportEngine]:
    engine = create_engine(config)
    try:
        await engine.start()
        yield engine
    finally:
        await engine.stop()


__all__ = [
    "BrowserConfig",
    "BrowserType",
    "EngineType",
    "FingerprintConfig",
    "StealthTransportEngine",
    "PageProxy",
    "PydollTransportEngine",
    "PatchrightCamoufoxTransportEngine",
    "create_engine",
    "managed_engine",
    # Challenge resolution
    "ChallengeRouter",
    "ChallengeType",
    "ChallengeResult",
    "ChallengeParams",
    "ResolutionStatus",
    "FlareSolverrConnector",
    "TurnstileSolver",
    "RecaptchaSolver",
    "is_challenge_page",
    "check_cf_clearance_cookie",
    "wait_for_challenge_resolution",
    # Semantic extraction
    "SemanticExtractionEngine",
    "BlockDetector",
    "NERExtractor",
    "DynamicXPathSelector",
    "ExtractionResult",
    "ExtractedEntity",
    "BlockDetectionResult",
    "BlockType",
    "EntityLabel",
    "PriceEntity",
    "DateEntity",
    "TableCandidate",
    # Orchestrator
    "SelfHealingOrganism",
    "HarvestResult",
    "OrganismState",
    "IdentityProfile",
    "JDownloaderBridge",
    "DownloadCandidate",
    "JDownloaderStatus",
    "WafBypassInterceptor",
    "WafBypassResult",
    "BypassAttempt",
    "EncodingStrategy",
    "XmlPayloadStyle",
]
