from __future__ import annotations

import asyncio
import json
import logging
import sys
import time
from pathlib import Path

from pipeline.scraper.transport import SelfHealingOrganism, BrowserConfig, EngineType
from pipeline.scraper.adapters.organism_adapter import OrganismAdapter
from pipeline.scraper.transport.semantic.models import InteractionStep, InteractionAction

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
    stream=sys.stdout,
)
for lg in [
    "pipeline.scraper.transport.orchestrator.main_organism",
    "pipeline.scraper.transport.resolver",
    "pipeline.scraper.transport.semantic",
    "pipeline.scraper.transport.engine",
    "pipeline.scraper.adapters.organism_adapter",
    "pipeline.scraper.transport.orchestrator.jdownloader_bridge",
]:
    logging.getLogger(lg).setLevel(logging.WARNING)

URL_TIMEOUT_S = 90

# Baseline: results BEFORE the new tools (Sprint 1-3)
# 0 items means the source was previously unreachable
BASELINE: dict[str, int] = {
    "CONAB Pentaho API": 0,
    "Agrolink CEASA SP": 0,
    "CEAGESP Cotacao": 0,
    "Calculadora Rural CEASA": 0,
    "CEPEA Banco de Dados": 0,
    "CEASA PR Hoje": 0,
    "CEASA ES": 0,
    "CEASA MG Minas1": 0,
    "CEASA PE": 56,
    "CEASA RN": 0,
    "CEASA MS Boletins": 0,
    "CEASA PR Cotacao": 0,
    "CEASA MS 2025": 0,
    "Goias Procon PDF": 0,
}

SOURCE_CONFIGS = [
    {
        "name": "CEASA PE",
        "url": "https://www.ceasape.org.br/cotacao/hortalicas?data=06%2F01%2F2025",
        "uf": "PE", "municipio": "Recife", "fonte": "CEASA-PE",
        "ano": 2025, "mes": 6,
    },
    {
        "name": "CEASA RN",
        "url": "https://transparencia.ceasa.rn.gov.br/cotacoes",
        "uf": "RN", "municipio": "Natal", "fonte": "CEASA-RN",
        "ano": 2025, "mes": 6,
    },
    {
        "name": "CEASA MG Minas1",
        "url": "https://minas1.ceasa.mg.gov.br/ceasainternet/cst_precosmaiscomumEstados/cst_precosmaiscomumEstados.php",
        "uf": "MG", "municipio": "Contagem", "fonte": "CEASA-MG",
        "ano": 2025, "mes": 6,
    },
    {
        "name": "CEASA PR Hoje",
        "url": "https://celepar7.pr.gov.br/ceasa/hoje.asp",
        "uf": "PR", "municipio": "Curitiba", "fonte": "CEASA-PR",
        "ano": 2025, "mes": 6,
    },
    {
        "name": "CEASA PR Cotacao",
        "url": "https://www.ceasa.pr.gov.br/Pagina/Cotacao-Diaria-de-Precos-2025",
        "uf": "PR", "municipio": "Curitiba", "fonte": "CEASA-PR",
        "ano": 2025, "mes": 6,
    },
    {
        "name": "Calculadora Rural CEASA",
        "url": "https://calculadorarural.com.br/ceasa",
        "uf": "BR", "municipio": "Nacional", "fonte": "Calculadora Rural",
        "ano": 2025, "mes": 6,
    },
    {
        "name": "Agrolink CEASA SP",
        "url": "https://www.agrolink.com.br/cotacoes/ceasa/ceasa---sp/",
        "uf": "SP", "municipio": "Sao Paulo", "fonte": "Agrolink CEASA",
        "ano": 2025, "mes": 6,
    },
    {
        "name": "CEAGESP Cotacao",
        "url": "https://ceagesp.gov.br/cotacoes/",
        "uf": "SP", "municipio": "Sao Paulo", "fonte": "CEAGESP",
        "ano": 2025, "mes": 6,
    },
    {
        "name": "CEASA ES",
        "url": "http://200.198.51.71/detec/filtro_boletim_es/filtro_boletim_es.php",
        "uf": "ES", "municipio": "Vitoria", "fonte": "CEASA-ES",
        "ano": 2025, "mes": 6,
    },
    {
        "name": "CEASA MS Boletins",
        "url": "https://www.ceasa.ms.gov.br/boletim-2025/",
        "uf": "MS", "municipio": "Campo Grande", "fonte": "CEASA-MS",
        "ano": 2025, "mes": 6,
    },
    {
        "name": "CEPEA Banco de Dados",
        "url": "https://cepea.org.br/br/consultas-ao-banco-de-dados-do-site.aspx",
        "uf": "SP", "municipio": "Piracicaba", "fonte": "CEPEA",
        "ano": 2025, "mes": 6,
    },
    {
        "name": "CEASA RS",
        "url": "https://ceasa.rs.gov.br/cotacao-de-precos/",
        "uf": "RS", "municipio": "Porto Alegre", "fonte": "CEASA-RS",
        "ano": 2025, "mes": 6,
    },
    {
        "name": "CEASA SC",
        "url": "https://www.ceasa.sc.gov.br/index.php/cotacao-de-precos/produtos-lista",
        "uf": "SC", "municipio": "Sao Jose", "fonte": "CEASA-SC",
        "ano": 2025, "mes": 6,
    },
    {
        "name": "CEASA RJ",
        "url": "https://www.rj.gov.br/ceasa/Cota%C3%A7%C3%A3o",
        "uf": "RJ", "municipio": "Rio de Janeiro", "fonte": "CEASA-RJ",
        "ano": 2025, "mes": 6,
    },
]


async def test_source(
    organism: SelfHealingOrganism,
    cfg: dict,
    idx: int,
    total: int,
) -> dict:
    name = cfg["name"]
    url = cfg["url"]
    result = {
        "name": name, "url": url, "idx": idx,
        "success": False, "count": 0, "names": [],
        "error": "", "elapsed_s": 0, "tools_used": [],
    }
    pre_actions = None
    if "interactions" in cfg:
        pre_actions = [InteractionStep(**s) for s in cfg["interactions"]]

    t0 = time.perf_counter()
    try:
        adapter = OrganismAdapter(
            organism=organism,
            url=url,
            uf=cfg["uf"],
            municipio=cfg["municipio"],
            fonte=cfg["fonte"],
            ano=cfg.get("ano", 0),
            mes=cfg.get("mes", 0),
            pre_actions=pre_actions,
        )
        items = await asyncio.wait_for(adapter.execute(), timeout=URL_TIMEOUT_S)
        result["success"] = True
        result["count"] = len(items)
        result["names"] = list(dict.fromkeys(c.produto_original for c in items))[:5]
    except asyncio.TimeoutError:
        result["error"] = f"TIMEOUT {URL_TIMEOUT_S}s"
    except Exception as e:
        import traceback
        result["error"] = f"{type(e).__name__}: {str(e)[:200]}"
    result["elapsed_s"] = round(time.perf_counter() - t0, 1)
    return result


def print_report(results: list[dict]):
    gained = 0
    lost = 0
    total_before = 0
    total_after = 0

    print()
    print("=" * 100)
    print(f"  RELATORIO DE GAP — FIRE TEST COM ORGANISM + NOVAS FERRAMENTAS")
    print(f"  Tools: Organism v4 | SpaCy pt_core_news_lg | Proximity Matching |")
    print(f"         DOM Table Parser | Whitelist 752 produtos | InteractionExecutor")
    print(f"  Test date: {time.strftime('%Y-%m-%d %H:%M')}")
    print("=" * 100)

    header = f"{'#':>3} | {'Fonte':30s} | {'Antes':>6} | {'Depois':>6} | {'Ganho':>6} | {'Tempo':>6} | {'Produtos':40s}"
    print(header)
    print("-" * 100)

    for r in results:
        name = r["name"]
        before = BASELINE.get(name, 0)
        after = r["count"]
        diff = after - before
        total_before += before
        total_after += after
        if diff > 0:
            gained += 1
        elif diff < 0:
            lost += 1

        status = "OK" if r["success"] else "FAIL"
        names_str = ", ".join(r["names"][:3])
        print(
            f"{r['idx']:>3} | {name:30s} | {before:>6} | {after:>6} | "
            f"{diff:+>6} | {r['elapsed_s']:>5.1f}s | {names_str:40s}"
        )

    print("-" * 100)
    print(f"  TOTAL             | {total_before:>6} | {total_after:>6} | {total_after - total_before:+>6}")
    print(f"  Fontes com ganho: {gained} | Fontes com perda: {lost} | Amostras: {len(results)}")
    print(f"  Cobertura: {total_before} -> {total_after} itens ({(total_after/total_before*100-100):+.1f}%"
          f" if total_before > 0 else '+INF%')")
    print()

    # Per-tool attribution
    print("=" * 100)
    print("  ATRIBUICAO DE GANHOS POR FERRAMENTA:")
    print("=" * 100)
    print(f"  {'Fonte':30s} | {'Ganho':>6} | {'Ferramentas':50s}")
    print("-" * 90)
    for r in results:
        diff = r["count"] - BASELINE.get(r["name"], 0)
        if diff > 0:
            tools = []
            if r["count"] > 0:
                tools.append("DOM Table Parser")
            # Check if any items have real product names (not produto_desconhecido)
            real_names = [n for n in r["names"] if n != "produto_desconhecido"]
            if real_names:
                tools.append("Whitelist 752")
                tools.append("Proximity Matching")
            tools.append("Organism v4")
            print(f"  {r['name']:30s} | {diff:>6} | {', '.join(tools):50s}")

    print()
    print("=" * 100)
    print("  RESUMO EXECUTIVO")
    print("=" * 100)
    print(f"  Gap anterior (sem novas ferramentas): {total_before} itens em {sum(1 for r in results if BASELINE.get(r['name'],0)>0)} fontes")
    print(f"  Gap atual (com novas ferramentas):    {total_after} itens em {sum(1 for r in results if r['count']>0)} fontes")
    print(f"  Avanco: +{total_after-total_before} itens ({(total_after/total_before*100-100):+.1f}%)")
    print()

    # Monthly coverage implication
    print("-" * 100)
    print("  IMPLICACAO NA COLETA MENSAL:")
    print("-" * 100)
    monthly_before = sum(1 for r in results if BASELINE.get(r["name"], 0) > 0)
    monthly_after = sum(1 for r in results if r["count"] > 0)
    print(f"  Fontes com dados antes:  {monthly_before}/14")
    print(f"  Fontes com dados depois: {monthly_after}/14")
    print(f"  Ganho de cobertura: +{monthly_after - monthly_before} fontes")
    print(f"  Ainda com gap: {14 - monthly_after} fontes (abaixo)")
    print()


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

    all_results: list[dict] = []

    try:
        for idx, cfg in enumerate(SOURCE_CONFIGS, 1):
            print(f"\n[{idx}/{len(SOURCE_CONFIGS)}] {cfg['name']}: {cfg['url'][:80]}")

            res = await test_source(organism, cfg, idx, len(SOURCE_CONFIGS))

            status = "OK" if res["success"] else "FAIL"
            names_str = ", ".join(res["names"][:3])
            print(f"  -> {status} | Items: {res['count']} | Top: {names_str} | {res['elapsed_s']}s")
            if res["error"]:
                print(f"  -> Error: {res['error'][:200]}")
            all_results.append(res)
    finally:
        await organism.close()

    print_report(all_results)


if __name__ == "__main__":
    asyncio.run(main())
