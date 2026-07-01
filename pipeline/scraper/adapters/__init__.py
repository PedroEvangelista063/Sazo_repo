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
]
