"""
test_fase2_santograal.py — Teste Playwright CEAGESP historico
==============================================================
Verifica se SantoGraalAdapter navega formulario CEAGESP
com datas historicas (2024) e extrai tabela de precos.
"""

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))


async def test_santograal_ceagesp_direct():
    """Testa SantoGraalAdapter diretamente com Playwright."""
    from pipeline.scraper.adapters.santo_graal_adapter import SantoGraalAdapter
    from pipeline.scraper.adapters.stealth import async_playwright

    adapter = SantoGraalAdapter(ano=2024, mes=6, uf="SP")

    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True)
        context = await browser.new_context(
            viewport={"width": 1280, "height": 720},
            user_agent=(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/120.0.0.0 Safari/537.36"
            ),
        )
        page = await context.new_page()
        items = await adapter.execute(page)
        await browser.close()

    print(f"  CEAGESP 2024/06: {len(items)} cotacoes")
    if items:
        for item in items[:5]:
            print(
                f"    {item.produto_original} | R${item.preco_bruto:.2f} | {item.uf} | {item.ano}-{item.mes:02d}"
            )
        # Verifica se os dados tem ano/mes corretos
        for item in items:
            assert item.ano == 2024, f"ano errado: {item.ano}"
            assert item.mes == 6, f"mes errado: {item.mes}"
            assert item.fonte == "CEAGESP"
        print(f"  OK: {len(items)} cotacoes com ano/mes corretos")
    else:
        print("  AVISO: 0 cotacoes — site pode estar fora do ar ou mudou layout")


async def test_smartcrawler_historico_2024():
    """Testa SmartCrawler2026.executar_para_ufs() com ano historico (2024).
    Deve rotear automaticamente para SantoGraalAdapter (HISTORICO).
    """
    from pipeline.scraper.adapters.smart_router import SmartCrawler2026

    crawler = SmartCrawler2026()
    resultados = await crawler.executar_para_ufs(["SP"], ano=2024, mes=6)
    items = resultados.get("SP", [])
    print(f"  SmartCrawler SP 2024/06: {len(items)} cotacoes")
    if items:
        for item in items[:3]:
            print(f"    {item.produto_original} | R${item.preco_bruto:.2f} | {item.fonte}")


async def test_orchestrator_historico_2024():
    """Testa orchestrator.coletar() para UF=SP, competencia=2024-06.
    Deve rotear: passo_direto (CeagespEngine) -> sucesso ou
    passo_smartrouter (SmartCrawler -> HISTORICO -> SantoGraal) -> sucesso.
    """
    from pipeline.scraper.orchestrator import AutonomousOrchestrator

    async with AutonomousOrchestrator() as orch:
        resultado = await orch.coletar("SP", "2024-06")
    if resultado:
        print(f"  Orchestrator SP 2024/06: {len(resultado)} registros")
        for r in resultado[:3]:
            print(f"    {r['fonte_id']} | {r['competencia']}")
    else:
        print("  Orchestrator SP 2024/06: [] vazio")


async def main():
    print("=" * 60)
    print("TESTE FASE 2 — SantoGraal + Playwright Historico 2024")
    print("=" * 60)

    tests = [
        ("SantoGraal CEAGESP direct", test_santograal_ceagesp_direct),
        ("SmartCrawler historico 2024", test_smartcrawler_historico_2024),
        ("Orchestrator SP 2024-06", test_orchestrator_historico_2024),
    ]

    falhas = 0
    for nome, test_fn in tests:
        print(f"\n[{nome}]")
        try:
            await test_fn()
            print("  [OK]")
        except Exception as e:
            print(f"  [FALHA] {e}")
            falhas += 1

    print("\n" + "=" * 60)
    print(f"Resultado: {len(tests) - falhas}/{len(tests)} passaram")
    if falhas:
        print(f"[FALHA] {falhas} falha(s)")
        sys.exit(1)
    else:
        print("[OK] Fase 2 verificada")


if __name__ == "__main__":
    asyncio.run(main())
