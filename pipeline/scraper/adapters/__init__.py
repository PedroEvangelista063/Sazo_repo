from pipeline.scraper.adapters.base import BaseAdapter, CotacaoRegional
from pipeline.scraper.adapters.factory import ScraperFactory
from pipeline.scraper.retry import retry_request
from pipeline.scraper.dispatcher import DispatcherOrquestrador
from pipeline.scraper.adapters.hortifrut.prohort import ProHortAdapter
from pipeline.scraper.adapters.hortifrut.ceasa_standard import CeasaStandardAdapter

from pipeline.scraper.adapters.legacy import (
    AgrolinkCEASAAdapter,
    HFBrasilAdapter,
    CEAGESPAdapter,
    adapter_discovery,
)

# New generation adapters (2026)
from pipeline.scraper.adapters.stealth import (
    XhrInterceptorAdapter,
    PlaywrightStealthAdapter,
    LegacyPostbackAdapter,
    BaseTargetAdapter,
    executar_adapters_playwright,
)
from pipeline.scraper.adapters.agentic_html import AgenticHtmlAdapter, coletar_multiplos_agentic
from pipeline.scraper.adapters.playwright_html import PlaywrightHtmlAdapter
from pipeline.scraper.adapters.organism_adapter import OrganismAdapter
from pipeline.scraper.adapters.google_drive_adapter import GoogleDriveAdapter
from pipeline.scraper.adapters.smart_router import SmartCrawler2026, ALVOS_CONHECIDOS
from pipeline.scraper.url_manager import (
    ColumnMapping,
    PaginationConfig,
    resolver_url_template,
    baixar_arquivo_estatico,
)

# Stealth transport layer (Fingerprint evasion engines)
from pipeline.scraper.transport import (
    BrowserConfig,
    BrowserType,
    EngineType,
    FingerprintConfig,
    StealthTransportEngine,
    PydollTransportEngine,
    PatchrightCamoufoxTransportEngine,
    create_engine,
    managed_engine,
)

# Challenge resolution (captcha, turnstile, flaresolverr)
from pipeline.scraper.transport import (
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

# Semantic extraction (NLP, NER, block detection, dynamic XPath)
from pipeline.scraper.transport import (
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

# Orchestrator (self-healing loop, JDownloader, WAF bypass)
from pipeline.scraper.transport import (
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

__all__ = [
    "BaseAdapter",
    "CotacaoRegional",
    "ScraperFactory",
    "retry_request",
    "DispatcherOrquestrador",
    "ProHortAdapter",
    "CeasaStandardAdapter",
    "AgrolinkCEASAAdapter",
    "HFBrasilAdapter",
    "CEAGESPAdapter",
    "adapter_discovery",
    "XhrInterceptorAdapter",
    "PlaywrightStealthAdapter",
    "LegacyPostbackAdapter",
    "BaseTargetAdapter",
    "executar_adapters_playwright",
    "AgenticHtmlAdapter",
    "coletar_multiplos_agentic",
    "PlaywrightHtmlAdapter",
    "OrganismAdapter",
    "GoogleDriveAdapter",
    "SmartCrawler2026",
    "ALVOS_CONHECIDOS",
    "ColumnMapping",
    "PaginationConfig",
    "resolver_url_template",
    "baixar_arquivo_estatico",
    # Stealth transport
    "BrowserConfig",
    "BrowserType",
    "EngineType",
    "FingerprintConfig",
    "StealthTransportEngine",
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
