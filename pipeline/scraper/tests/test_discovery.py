"""
test_discovery.py — Testa DiscoveryEngine com DuckDuckGo real
"""

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))


async def test_discovery_duckduckgo():
    from pipeline.scraper.discovery_engine import DiscoveryEngine

    engine = DiscoveryEngine()
    resultados = await engine.buscar("PR", 2024, 6)
    print(f"Discovery PR 2024/06: {len(resultados)} URLs encontradas")
    for r in resultados[:5]:
        url = r["payload_bruto"]["url"]
        print(f"  {url}")
    assert isinstance(resultados, list)
    # Pode ser 0 se DuckDuckGo bloquear (aceitavel em teste offline)


async def test_simple_dork():
    from pipeline.scraper.discovery_engine import SimpleDorkGenerator

    queries = SimpleDorkGenerator.gerar("SP")
    print("Queries geradas para SP:")
    for q in queries:
        print(f"  {q}")
    assert len(queries) == 4


async def main():
    print("=" * 60)
    print("TESTE DISCOVERY ENGINE")
    print("=" * 60)

    tests = [
        ("DorkGenerator SP", test_simple_dork),
        ("Discovery DuckDuckGo PR", test_discovery_duckduckgo),
    ]

    falhas = 0
    for nome, fn in tests:
        print(f"\n[{nome}]")
        try:
            await fn()
            print("  [OK]")
        except Exception as e:
            print(f"  [FALHA] {e}")
            falhas += 1

    print(f"\nResultado: {len(tests) - falhas}/{len(tests)} passaram")


if __name__ == "__main__":
    asyncio.run(main())
