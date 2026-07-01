"""
TÍTULO: Validação de Coleta Regional — TOMATE (Scraper)
ESCOPO: Dispara coleta paralela de preços de TOMATE em múltiplas fontes, exibe tabela comparativa
EXECUTA: ScraperFactory + DispatcherOrquestrador em pipeline.scraper — requires banco e rede
"""

import asyncio
import logging
import sys
from pathlib import Path
from datetime import date

PROJETO_RAIZ = Path(__file__).resolve().parents[3]
if str(PROJETO_RAIZ) not in sys.path:
    sys.path.insert(0, str(PROJETO_RAIZ))

from pipeline.scraper.adapters.factory import ScraperFactory
from pipeline.scraper.dispatcher import DispatcherOrquestrador

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("test_tomate")

HEADER = "\n" + "=" * 80 + "\n>> VALIDACAO AGRO-REGIONAL: TOMATE\n" + "=" * 80
FOOTER = "=" * 80
COL_WIDTHS = (28, 10, 10, 12, 12, 12, 12)


def montar_tabela(resultados: list, relatorio) -> str:
    linhas = []
    linhas.append(f"\n{'Fonte':<{COL_WIDTHS[0]}} "
                  f"{'UF':<{COL_WIDTHS[1]}} "
                  f"{'Qtde':<{COL_WIDTHS[2]}} "
                  f"{'Preco Min':<{COL_WIDTHS[3]}} "
                  f"{'Preco Med':<{COL_WIDTHS[4]}} "
                  f"{'Preco Max':<{COL_WIDTHS[5]}} "
                  f"{'Status':<{COL_WIDTHS[6]}}")
    linhas.append("-" * 80)

    if not resultados:
        linhas.append(f"{'NENHUM RESULTADO':^80}")
    else:
        for r in resultados:
            min_str = f"R$ {r.preco_min:.2f}/u" if r.preco_min else "-"
            med_str = f"R$ {r.preco_medio:.2f}/u" if r.preco_medio else "-"
            max_str = f"R$ {r.preco_max:.2f}/u" if r.preco_max else "-"
            linhas.append(
                f"{r.fonte:<{COL_WIDTHS[0]}} "
                f"{r.uf:<{COL_WIDTHS[1]}} "
                f"{'1':<{COL_WIDTHS[2]}} "
                f"{min_str:<{COL_WIDTHS[3]}} "
                f"{med_str:<{COL_WIDTHS[4]}} "
                f"{max_str:<{COL_WIDTHS[5]}} "
                f"{'OK':<{COL_WIDTHS[6]}}"
            )

    linhas.append("")
    linhas.append(f"RESUMO DA COLETA:")
    linhas.append(f"  Adaptadores disparados:  {relatorio.total_adapters}")
    linhas.append(f"  Fontes com sucesso:      {relatorio.fontes_ok}")
    linhas.append(f"  Fontes com falha:        {relatorio.fontes_falha}")
    linhas.append(f"  Taxa de sucesso:         {relatorio.taxa_sucesso_pct:.1f}%")
    linhas.append(f"  Total cotacoes:          {relatorio.total_cotacoes}")
    linhas.append(f"  Tempo de execucao:       {relatorio.tempo_execucao_s:.1f}s")

    if relatorio.erros:
        linhas.append(f"  Erros:")
        for e in relatorio.erros:
            linhas.append(f"    - {e}")

    for r in relatorio.resultados:
        if r.status == "erro":
            linhas.append(f"    - {r.nome} {r.uf}: {r.erro}")

    return "\n".join(linhas)


async def main():
    print(HEADER)

    logger.info("Inicializando ScraperFactory...")
    factory = ScraperFactory()

    fontes_tomate = factory.fonte_para_produto("TOMATE")
    logger.info("Fontes mapeadas para TOMATE: %d", len(fontes_tomate))
    for f in fontes_tomate:
        logger.info("  -> %s (%s-%s)", f["fonte"], f["uf"], f["municipio"])

    logger.info("\nCriando adapters para TOMATE...")
    adapters = factory.adapters_para_produto("TOMATE")
    logger.info("Adapters instanciados: %d", len(adapters))

    if not adapters:
        logger.warning("Nenhum adapter foi instanciado.")
        return

    dispatcher = DispatcherOrquestrador(max_concorrencia=5)
    logger.info("\nDisparando coleta paralela em %d fontes...", len(adapters))
    logger.info("=" * 80)

    resultados, relatorio = await dispatcher.executar(adapters)

    tabela = montar_tabela(resultados, relatorio)
    print(tabela)
    print(FOOTER)

    status_final = "SUCESSO" if relatorio.fontes_ok > 0 else "FALHA"
    print(f"\nVALIDACAO CONCLUIDA COM {status_final}")

    logger.info(
        "Teste TOMATE: %d/%d fontes OK, %d cotacoes em %.1fs",
        relatorio.fontes_ok,
        relatorio.total_adapters,
        relatorio.total_cotacoes,
        relatorio.tempo_execucao_s,
    )


if __name__ == "__main__":
    asyncio.run(main())
