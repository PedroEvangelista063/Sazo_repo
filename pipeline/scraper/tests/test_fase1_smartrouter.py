"""
test_fase1_smartrouter.py — Teste da integracao Fase 1
======================================================
Testa SmartCrawler2026 com target agentic (httpx, sem Playwright),
conversao CotacaoRegional -> dict, e chamada via orchestrator.
"""

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from pipeline.scraper.adapters.smart_router import (
    SmartCrawler2026,
    UF_ALVOS_DEDICADOS,
)
from pipeline.scraper.orchestrator import AutonomousOrchestrator


import pytest


@pytest.mark.asyncio
async def test_smartcrawler_cria_adapter():
    """SmartCrawler2026.criar_adapter_para_alvo retorna adapter para alvo existente."""
    crawler = SmartCrawler2026()
    for nome in ["ceasa_pr", "ceasa_mg", "ceasa_es"]:
        adp = crawler.criar_adapter_para_alvo(nome)
        assert adp is not None, f"{nome} nao produziu adapter"
        print(f"  OK {nome}: {type(adp).__name__}")


@pytest.mark.asyncio
async def test_smartcrawler_executa_alvo_agentic():
    """Executa CEASA-PR (agentic, httpx) — pelo menos retorna sem crash."""
    crawler = SmartCrawler2026()
    resultados = await crawler.executar_alvos(["ceasa_pr"], ano=2026, mes=7)
    items = resultados.get("ceasa_pr", [])
    print(f"  CEASA-PR: {len(items)} cotacoes")
    if items:
        amostra = items[0]
        print(f"    Ex: {amostra.produto_original} | R$ {amostra.preco_bruto} | {amostra.uf}")
    assert isinstance(items, list), "Resultado deve ser lista"


@pytest.mark.asyncio
async def test_uf_alvos_dedicados():
    """UF_ALVOS_DEDICADOS tem as UFs esperadas."""
    esperadas = {"SP", "PR", "MG", "ES", "PE", "RN", "MS", "RS"}
    presentes = set(UF_ALVOS_DEDICADOS.keys())
    print(f"  UFs dedicadas: {presentes}")
    for uf in esperadas:
        assert uf in UF_ALVOS_DEDICADOS, f"Faltando UF {uf}"
        assert len(UF_ALVOS_DEDICADOS[uf]) > 0, f"UF {uf} sem alvos"
    print(f"  OK {len(esperadas)} UFs verificadas")


@pytest.mark.asyncio
async def test_conversao_cotacao():
    """CotacaoRegional -> dict raw.coleta_bruta."""
    from pipeline.scraper.adapters.base import CotacaoRegional
    from pipeline.scraper.orchestrator import AutonomousOrchestrator

    cot = CotacaoRegional(
        produto_original="TOMATE",
        uf="PR",
        municipio="Curitiba",
        ano=2026,
        mes=7,
        fonte="CEASA-PR",
        preco_bruto=45.50,
        preco_medio=45.50,
        status_coleta="sucesso",
    )
    d = AutonomousOrchestrator._cotacao_to_bruta_dict(cot)
    assert d["fonte_id"] == "CEASA-PR", f"fonte_id: {d['fonte_id']}"
    assert d["competencia"] == "2026-07"
    assert d["payload_bruto"]["produto_original"] == "TOMATE"
    print(
        f"  OK Conversao: {d['fonte_id']} | {d['competencia']} | {d['payload_bruto']['produto_original']}"
    )


@pytest.mark.asyncio
async def test_orchestrator_smartrouter():
    """Orchestrator._passo_smartrouter() roda sem crash para UF com alvos."""
    async with AutonomousOrchestrator() as orch:
        resultado = await orch._passo_smartrouter("PR", 2026, 7)
        if resultado:
            print(f"  SmartRouter PR: {len(resultado)} registros")
            for r in resultado[:3]:
                print(f"    {r['fonte_id']} | {r['competencia']}")
        else:
            print("  SmartRouter PR: None (sem dados ou timeout)")
        # Nao deve crashar — None eh aceitavel


@pytest.mark.asyncio
async def test_orchestrator_coletar():
    """Orchestrator.coletar() roda sem crash para UF com SmartRouter."""
    async with AutonomousOrchestrator() as orch:
        resultado = await orch.coletar("PR", "2026-07")
        if resultado:
            print(f"  Coletar PR: {len(resultado)} registros")
        else:
            print("  Coletar PR: [] vazio")


async def main():
    print("=" * 60)
    print("TESTE FASE 1 — SmartCrawler Integration")
    print("=" * 60)

    tests = [
        ("UF_ALVOS_DEDICADOS", test_uf_alvos_dedicados),
        ("Conversao CotacaoRegional", test_conversao_cotacao),
        ("SmartCrawler cria adapter", test_smartcrawler_cria_adapter),
        ("SmartCrawler executa alvo agentic", test_smartcrawler_executa_alvo_agentic),
        ("Orchestrator _passo_smartrouter", test_orchestrator_smartrouter),
        ("Orchestrator.coletar", test_orchestrator_coletar),
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
        print("[OK] Todas as fases passaram — Fase 1 OK")


if __name__ == "__main__":
    asyncio.run(main())
