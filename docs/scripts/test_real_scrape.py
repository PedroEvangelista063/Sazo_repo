from __future__ import annotations

import asyncio
import logging
import sys
import traceback

from pipeline.scraper.transport import SelfHealingOrganism, BrowserConfig, EngineType
from pipeline.scraper.adapters.organism_adapter import OrganismAdapter

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
    stream=sys.stdout,
)
# Silence verbose loggers
logging.getLogger("pipeline.scraper.transport.orchestrator.main_organism").setLevel(logging.WARNING)
logging.getLogger("pipeline.scraper.transport.resolver").setLevel(logging.INFO)
logging.getLogger("pipeline.scraper.transport.semantic").setLevel(logging.INFO)
logging.getLogger("pipeline.scraper.adapters.organism_adapter").setLevel(logging.INFO)
logging.getLogger("pipeline.scraper.transport.engine").setLevel(logging.INFO)
logging.getLogger("pipeline.scraper.transport.semantic.extraction_engine").setLevel(logging.DEBUG)

URLS = [
    "https://www.ceasape.org.br/cotacao/hortalicas?data=06%2F01%2F2025",
    "https://calculadorarural.com.br/ceasa",
    "https://ceasagrandeabc.com.br/",
    "https://www.noticiasagricolas.com.br/cotacoes/",
    "https://www.ceasa.pr.gov.br/Pagina/Cotacao-Diaria-de-Precos",
    "https://ceasa.rs.gov.br/cotacao-de-precos/",
    "https://www.ceasa.sc.gov.br/index.php/cotacao-de-precos/produtos-lista",
    "https://www.rj.gov.br/ceasa/Cota%C3%A7%C3%A3o",
]

URL_TIMEOUT_S = 60


async def test_url(organism: SelfHealingOrganism, url: str, idx: int, ano: int = 2025, mes: int = 6) -> dict:
    result = {"url": url, "idx": idx, "success": False, "count": 0, "names": [], "error": ""}
    try:
        adapter = OrganismAdapter(
            organism=organism, url=url, uf="", municipio="", fonte=url,
            ano=ano, mes=mes,
        )
        items = await asyncio.wait_for(adapter.execute(), timeout=URL_TIMEOUT_S)
        result["success"] = True
        result["count"] = len(items)
        result["names"] = [c.produto_original for c in items[:3]]
    except asyncio.TimeoutError:
        result["error"] = f"TIMEOUT after {URL_TIMEOUT_S}s"
    except Exception as e:
        tb = traceback.format_exc()
        lines = tb.splitlines()
        short_tb = "\n".join(lines[-6:]) if len(lines) > 6 else tb
        result["error"] = f"{type(e).__name__}: {e}\n{short_tb}"
    return result


async def main():
    organism = SelfHealingOrganism(
        base_browser_config=BrowserConfig(
            engine=EngineType.PATCHRIGHT,
            headless=True,
            page_load_timeout_ms=60000,
        ),
        identity_pool_size=2,
        max_retries_per_url=1,
        cooldown_after_failure_s=10,
    )

    try:
        for idx, url in enumerate(URLS, 1):
            print(f"\n{'='*80}")
            print(f"[{idx}/{len(URLS)}] {url}")
            print(f"{'='*80}")

            res = await test_url(organism, url, idx)

            status = "OK" if res["success"] else "FAIL"
            print(f"  Status:   {status}")
            print(f"  Items:    {res['count']}")
            if res["names"]:
                print(f"  Top-3:    {res['names']}")
            if res["error"]:
                print(f"  Error:    {res['error'][:300]}")
    finally:
        await organism.close()
        print("\n" + "=" * 80)
        print("Organism closed. Done.")


if __name__ == "__main__":
    asyncio.run(main())
