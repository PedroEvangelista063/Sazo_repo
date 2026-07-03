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
from pipeline.scraper.adapters.smart_router import SmartCrawler2026, ALVOS_CONHECIDOS

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
    "SmartCrawler2026",
    "ALVOS_CONHECIDOS",
]
