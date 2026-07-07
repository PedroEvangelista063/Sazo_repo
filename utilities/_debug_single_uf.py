from __future__ import annotations

import asyncio
import logging
import sys
import time

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)

if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())


async def test_uf(uf: str):
    from pipeline.scraper.adapters.smart_router import (
        SmartCrawler2026, get_estrategia,
        AgregadorMercadoAdapter, UF_ALVOS_DEDICADOS,
    )

    print(f"\n{'='*60}")
    print(f"DIAGNOSTICO UF={uf}")
    print(f"{'='*60}")

    # 1. Estrategia
    est = get_estrategia(uf)
    print(f"\n[ESTRATEGIA] {est['tipo']}")
    if est["tipo"] == "DEDICADO":
        print(f"  Alvos: {est['alvos']}")
    else:
        print(f"  Sem CEASA dedicada -> AGREGADOR DE MERCADO")
        if uf not in UF_ALVOS_DEDICADOS:
            print(f"  Confirmado: UF {uf} NAO esta em UF_ALVOS_DEDICADOS")
        else:
            print(f"  ATENCAO: UF {uf} esta em UF_ALVOS_DEDICADOS mas estrategia diz FALLBACK")

    # 2. AgregadorMercadoAdapter
    print(f"\n[AGREGADOR] AgregadorMercadoAdapter(uf={uf})...")
    t0 = time.perf_counter()
    try:
        adp = AgregadorMercadoAdapter(uf=uf)
        items = await adp.fetch()
        elapsed = time.perf_counter() - t0
        print(f"  Tempo: {elapsed:.1f}s")
        print(f"  Resultados: {len(items)}")
        if items:
            print(f"  Primeiros 10:")
            for i, c in enumerate(items[:10]):
                print(f"    {i+1}. {c.produto_original:45s} R$ {c.preco_bruto:>7.2f} | {c.fonte}")
            ufs_encontradas = set(c.uf for c in items)
            print(f"  UFs nos resultados: {sorted(ufs_encontradas)}")
        else:
            print(f"  VAZIO — Agregador retornou 0 cotacoes para {uf}")
    except Exception as e:
        elapsed = time.perf_counter() - t0
        print(f"  FALHA ({elapsed:.1f}s): {e}")
        import traceback
        traceback.print_exc()

    # 3. SmartCrawler executar_para_ufs
    print(f"\n[CASCATA] SmartCrawler.executar_para_ufs([{uf}])...")
    t0 = time.perf_counter()
    try:
        crawler = SmartCrawler2026()
        resultados = await crawler.executar_para_ufs([uf])
        elapsed = time.perf_counter() - t0
        total = sum(len(v) for v in resultados.values())
        print(f"  Tempo: {elapsed:.1f}s")
        print(f"  UFs retornadas: {list(resultados.keys())}")
        print(f"  Total cotacoes: {total}")
        for uf_key, items in resultados.items():
            if items:
                print(f"  Exemplos {uf_key}:")
                for i, c in enumerate(items[:5]):
                    print(f"    {i+1}. {c.produto_original:45s} R$ {c.preco_bruto:>7.2f} | {c.fonte}")
    except Exception as e:
        elapsed = time.perf_counter() - t0
        print(f"  FALHA ({elapsed:.1f}s): {e}")
        import traceback
        traceback.print_exc()

    print(f"\n{'='*60}\n")


async def main():
    uf_alvo = sys.argv[1].upper() if len(sys.argv) > 1 else "GO"
    await test_uf(uf_alvo)


if __name__ == "__main__":
    asyncio.run(main())
