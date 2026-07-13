"""Testa DiscoveryEngine com Playwright + Bing real."""

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from pipeline.scraper.discovery_engine import DiscoveryEngine


async def test():
    engine = DiscoveryEngine()
    resultados = await engine.buscar("PR", 2024, 6)
    print(f"Discovery PR 2024/06: {len(resultados)} resultados")
    for r in resultados:
        url = r["payload_bruto"]["url"]
        print(f"  {url}")


asyncio.run(test())
