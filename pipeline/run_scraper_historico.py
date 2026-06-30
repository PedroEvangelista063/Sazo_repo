from __future__ import annotations

import argparse
import asyncio
import logging
from pathlib import Path

import polars as pl

from pipeline.scraper.ceasa_spider import (
    RAW_DIR,
    LOCALIDADES_ALVO,
    CotacaoHistorica,
)
from pipeline.scraper.data_normalizer import DataNormalizer
from pipeline.scraper.adapters import AgrolinkCEASAAdapter
from pipeline.scraper.price_collector import PriceCollector, QualidadeMetricas

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)

OUTPUT = RAW_DIR / "scraper_hortifruti_historico.parquet"
STAGING_COLUNAS = ["produto", "uf", "municipio", "ano", "mes", "valor_produto_kg"]


def formatar_staging(items: list[CotacaoHistorica], normalizer: DataNormalizer) -> pl.DataFrame:
    if not items:
        return pl.DataFrame(schema={c: pl.String for c in STAGING_COLUNAS})

    df = pl.DataFrame(
        {
            "produto_original": [i.produto_original for i in items],
            "valor_produto_kg": [round(i.valor_produto_kg, 4) for i in items],
            "uf": [i.uf for i in items],
            "municipio": [i.municipio for i in items],
            "ano": [i.ano for i in items],
            "mes": [i.mes for i in items],
            "fonte": [i.fonte for i in items],
        }
    )

    df_norm = normalizer.normalizar_lote(items)
    df_norm = df_norm.filter(pl.col("match_score") >= 70.0)

    if df_norm.height == 0:
        logger.warning("Nenhum item passou no normalizer (score >= 70)")
        return pl.DataFrame(schema={c: pl.String for c in STAGING_COLUNAS})

    df_norm = df_norm.with_columns(
        pl.col("ano").cast(pl.Int32),
        pl.col("mes").cast(pl.Int32),
        pl.col("valor_produto_kg").cast(pl.Float64),
    )

    aggregated = df_norm.group_by(["produto", "uf", "municipio", "ano", "mes"]).agg(
        pl.col("valor_produto_kg").mean().round(4).alias("valor_produto_kg"),
    )

    logger.info("Staging: %d linhas apos agregacao (normalizer)", aggregated.height)
    return aggregated.select(STAGING_COLUNAS)


async def main():
    parser = argparse.ArgumentParser(description="Scraper Historico Regional — PriceCollector + Qualidade")
    parser.add_argument("--descobrir", action="store_true", help="Executa descoberta de novas fontes antes da coleta")
    parser.add_argument("--concorrencia", type=int, default=4, help="Maximo de requisicoes simultaneas")
    args = parser.parse_args()

    logger.info("=== RUN SCRAPER HISTORICO REGIONAL (PriceCollector) ===")

    localidades = list(LOCALIDADES_ALVO)

    if args.descobrir:
        from pipeline.scraper.buscador_fontes import descobrir_fontes, fontes_para_localidades

        rel = await descobrir_fontes()
        novas = fontes_para_localidades(rel.fontes)
        logger.info("Descoberta: %d novas fontes com conteudo tabular", len(novas))
        for n in novas:
            logger.info("  + %s %s (%s)", n["uf"], n["municipio"], n["fonte"])
            localidades.append(n)

    collector = PriceCollector()
    collector.register_from_localidades(localidades)
    collector.register_adapter("Agrolink CEASA (todas UFs)", AgrolinkCEASAAdapter())

    normalizer = DataNormalizer(fuzzy_cutoff=75.0)
    normalizer.carregar_csv()

    items, metricas = await collector.collect_all(max_concorrencia=args.concorrencia)

    df_final = formatar_staging(items, normalizer)
    metricas.total_apos_fuzzy = df_final.height
    metricas.taxa_conversao_pct = (df_final.height / metricas.total_bruto * 100) if metricas.total_bruto > 0 else 0.0

    RAW_DIR.mkdir(parents=True, exist_ok=True)
    df_final.write_parquet(OUTPUT)

    print(metricas.relatorio())
    print(f"  Output: {OUTPUT}\n")


if __name__ == "__main__":
    asyncio.run(main())
