from __future__ import annotations

import asyncio
import logging
import sys

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)


async def dry_run():
    alvos = ["ceagesp", "cepea", "ceasa_es"]
    logger.info("=" * 60)
    logger.info("DRY-RUN SPRINT 2 — APENAS CEAGESP, CEPEA, CEASA-ES")
    logger.info("(modo dry-run: sem gravacao em banco)")
    logger.info("=" * 60)

    from pipeline.scraper.adapters.smart_router import SmartCrawler2026, ALVOS_CONHECIDOS

    crawler = SmartCrawler2026()
    resultados = await crawler.executar_alvos(alvos)

    print()
    print("=" * 60)
    print("RESULTADO POR ALVO (Dry-Run)")
    print("=" * 60)
    for alvo in alvos:
        config = ALVOS_CONHECIDOS.get(alvo, {})
        url = config.get("url", "N/A")
        items = resultados.get(url, [])
        fonte = items[0].fonte if items else "---"
        print()
        print(f"  [{alvo.upper()}] {fonte}")
        print(f"  URL: {url}")
        print(f"  Produtos: {len(items)}")
        if items:
            print(f"  Fonte: {items[0].fonte}")
            print(f"  Amostra (primeiros 10):")
            for i, item in enumerate(items[:10]):
                print(f"    {i+1}. {item.produto_original:40s} R$ {item.preco_bruto:>8.2f}")
            if len(items) > 10:
                print(f"    ... e mais {len(items) - 10} produtos")
        print()

    total_geral = sum(len(v) for v in resultados.values())
    print("=" * 60)
    print(f"  TOTAL GERAL: {total_geral} produtos")
    print("=" * 60)


if __name__ == "__main__":
    if sys.platform == "win32":
        loop = asyncio.ProactorEventLoop()
        asyncio.set_event_loop(loop)
    else:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
    try:
        loop.run_until_complete(dry_run())
    finally:
        loop.close()
