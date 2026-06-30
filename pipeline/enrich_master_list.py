from __future__ import annotations

import asyncio
import logging
from pathlib import Path

import polars as pl

from pipeline.scraper_hortifruti import (
    RAW_DIR,
    CotacaoItem,
    coletar_todas_fontes,
)
from pipeline.utils.entity_matcher import EntityMatcher

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)

MASTER_OUTPUT = RAW_DIR / "sazonalidade_com_cotacao.parquet"
COTACOES_OUTPUT = RAW_DIR / "cotacoes_brutas.parquet"


def cotacoes_para_df(items: list[CotacaoItem]) -> pl.DataFrame:
    rows = [
        {
            "produto_original": i.produto_original,
            "preco_medio": i.preco_medio,
            "preco_min": i.preco_min,
            "preco_max": i.preco_max,
            "unidade": i.unidade,
            "fator_kg": i.fator_kg,
            "preco_por_kg": i.preco_por_kg,
            "data_coleta": i.data_coleta,
            "fonte": i.fonte,
            "uf": i.uf,
            "categoria": i.categoria,
        }
        for i in items
    ]
    return pl.DataFrame(rows)


def enrich_master(
    df_cotacoes: pl.DataFrame,
    matcher: EntityMatcher,
) -> pl.DataFrame:
    df_master = matcher.df
    col_nome = next(
        c for c in df_master.columns
        if "produto" in c.lower() or "nome" in c.lower() or "item" in c.lower()
    )

    match_log: list[dict] = []

    for row in df_cotacoes.iter_rows(named=True):
        nome_cot = row.get("produto_original", "")
        if not nome_cot:
            continue
        match, score = matcher.melhor_match(nome_cot)
        match_log.append({
            "cotacao_produto": nome_cot,
            "match_master": match or "",
            "match_score": score,
        })

    df_log = pl.DataFrame(match_log)

    matched = df_log.filter(pl.col("match_score") >= matcher.score_cutoff)
    if matched.height == 0:
        logger.warning("Nenhuma cotação teve match com o CSV mestre (score >= %.0f)", matcher.score_cutoff)
        return pl.DataFrame(), df_log

    cotacoes_com_match = df_cotacoes.join(
        matched.select("cotacao_produto", match_master=pl.col("match_master")),
        left_on="produto_original",
        right_on="cotacao_produto",
        how="inner",
    )

    aggregated = cotacoes_com_match.group_by("match_master").agg(
        pl.col("preco_por_kg").mean().alias("preco_medio"),
        pl.col("preco_por_kg").min().alias("preco_min"),
        pl.col("preco_por_kg").max().alias("preco_max"),
        pl.col("fonte").first(),
        pl.col("uf").first(),
        pl.col("data_coleta").first(),
    )

    df_enriquecido = df_master.join(
        aggregated,
        left_on=col_nome,
        right_on="match_master",
        how="inner",
    ).with_columns(
        pl.lit("cotacao_scraping").alias("origem_preco"),
    )

    logger.info(
        "Enriquecimento: %d cotacoes pareadas em %d itens do CSV",
        cotacoes_com_match.height,
        df_enriquecido.height,
    )
    return df_enriquecido, df_log


async def run():
    logger.info("=== Iniciando enriquecimento da lista mestre ===")

    matcher = EntityMatcher()
    matcher.carregar_master()

    logger.info("Coletando cotações das fontes...")
    cotacoes = await coletar_todas_fontes()
    logger.info("Total de cotações coletadas: %d", len(cotacoes))

    df_cotacoes = cotacoes_para_df(cotacoes)
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    df_cotacoes.write_parquet(COTACOES_OUTPUT)
    logger.info("Cotações brutas salvas em %s", COTACOES_OUTPUT)

    df_enriquecido, df_log = enrich_master(df_cotacoes, matcher)

    if df_enriquecido.height > 0:
        df_enriquecido.write_parquet(MASTER_OUTPUT)
        logger.info("Lista mestre enriquecida salva em %s", MASTER_OUTPUT)
    else:
        logger.warning("Nenhum item foi enriquecido — output não foi gerado")

    logger.info("=== Enriquecimento concluido ===")
    print(f"\nCotacoes brutas: {df_cotacoes.height} linhas -> {COTACOES_OUTPUT}")
    print(f"Itens enriquecidos: {df_enriquecido.height} -> {MASTER_OUTPUT}")
    print(f"Score cutoff usado: {matcher.score_cutoff}")


if __name__ == "__main__":
    asyncio.run(run())
