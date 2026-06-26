"""
Cálculo do Índice de Sazonalidade — o coração do QUERO COMPRAR.

Fórmula:
    IS(produto, localidade, mês) = Preço_Médio_Mês / Média_Móvel_12_Meses

Classificação do semáforo:
    IS < 0.90  → VERDE   (preço ≥10% abaixo da média → safra)
    0.90–1.10  → AMARELO (dentro do padrão esperado)
    IS > 1.10  → VERMELHO (preço ≥10% acima da média → entressafra)
    <6 meses   → INSUFICIENTE (dados insuficientes para calcular)
"""

import logging
from typing import Literal

import polars as pl

logger = logging.getLogger(__name__)

SeasonalityStatus = Literal["VERDE", "AMARELO", "VERMELHO", "INSUFICIENTE"]

THRESHOLD_GREEN = 0.90
THRESHOLD_RED = 1.10
MIN_PERIODS = 6  # mínimo de meses de histórico para calcular


def _classify_status(index_col: pl.Expr) -> pl.Expr:
    """Aplica a lógica do semáforo ao Índice de Sazonalidade."""
    return (
        pl.when(index_col.is_null())
        .then(pl.lit("INSUFICIENTE"))
        .when(index_col < THRESHOLD_GREEN)
        .then(pl.lit("VERDE"))
        .when(index_col <= THRESHOLD_RED)
        .then(pl.lit("AMARELO"))
        .otherwise(pl.lit("VERMELHO"))
    )


def _build_tip(status_col: pl.Expr, produto_col: pl.Expr) -> pl.Expr:
    """Gera a dica textual para o card do produto."""
    return (
        pl.when(status_col == "VERDE")
        .then(pl.lit("Boa época! Preço abaixo da média anual."))
        .when(status_col == "AMARELO")
        .then(pl.lit("Preço normal para esta época."))
        .when(status_col == "VERMELHO")
        .then(pl.lit("Entressafra. Considere esperar ou substituir."))
        .otherwise(pl.lit("Dados históricos insuficientes para esta localidade."))
    )


def calculate_seasonality_municipio(df: pl.DataFrame) -> pl.DataFrame:
    """
    Calcula o Índice de Sazonalidade por produto + município + mês.

    Fluxo:
    1. Agrega preço médio mensal por produto+município
    2. Calcula média móvel de 12 meses (mínimo 6 para classificar)
    3. Calcula IS = preco_medio / media_movel_12m
    4. Classifica: VERDE / AMARELO / VERMELHO / INSUFICIENTE
    5. Gera dica textual

    Args:
        df: DataFrame limpo de load_municipio_file()

    Returns:
        DataFrame com colunas de sazonalidade prontas para carga no PostgreSQL.
    """
    # Passo 1: agregar por produto + município + ano + mês
    monthly = (
        df.group_by(["produto", "municipio_id", "municipio_nome", "uf", "ano", "mes"])
        .agg(pl.col("preco_medio").mean().alias("preco_medio"))
        .sort(["produto", "municipio_id", "ano", "mes"])
    )

    # Passo 2: média móvel 12 meses por produto+município
    monthly = monthly.with_columns(
        pl.col("preco_medio")
        .rolling_mean(window_size=12, min_periods=MIN_PERIODS)
        .over(["produto", "municipio_id"])
        .alias("media_movel_12m")
    )

    # Passo 3: Índice de Sazonalidade
    monthly = monthly.with_columns(
        (pl.col("preco_medio") / pl.col("media_movel_12m"))
        .alias("indice_sazonalidade")
    )

    # Passo 4 e 5: status semáforo + dica + fonte
    monthly = monthly.with_columns([
        _classify_status(pl.col("indice_sazonalidade")).alias("status_semaforo"),
        pl.lit("municipio").alias("fonte"),
    ]).with_columns(
        _build_tip(pl.col("status_semaforo"), pl.col("produto")).alias("dica")
    )

    n_insuf = monthly.filter(pl.col("status_semaforo") == "INSUFICIENTE").height
    logger.info(
        "Sazonalidade município: %d registros | %d insuficientes (%.1f%%)",
        monthly.height,
        n_insuf,
        100 * n_insuf / monthly.height if monthly.height else 0,
    )

    return monthly.select([
        "produto", "municipio_id", "municipio_nome", "uf",
        "ano", "mes", "preco_medio", "media_movel_12m",
        "indice_sazonalidade", "status_semaforo", "dica", "fonte",
    ])


def calculate_seasonality_uf(df: pl.DataFrame) -> pl.DataFrame:
    """
    Calcula o Índice de Sazonalidade por produto + UF + mês.

    Usado como FALLBACK quando não há dados municipais suficientes.
    """
    monthly = (
        df.group_by(["produto", "uf", "ano", "mes"])
        .agg(pl.col("preco_medio").mean().alias("preco_medio"))
        .sort(["produto", "uf", "ano", "mes"])
    )

    monthly = monthly.with_columns(
        pl.col("preco_medio")
        .rolling_mean(window_size=12, min_periods=MIN_PERIODS)
        .over(["produto", "uf"])
        .alias("media_movel_12m")
    )

    monthly = monthly.with_columns(
        (pl.col("preco_medio") / pl.col("media_movel_12m"))
        .alias("indice_sazonalidade")
    )

    monthly = monthly.with_columns([
        _classify_status(pl.col("indice_sazonalidade")).alias("status_semaforo"),
        pl.lit(None).cast(pl.Utf8).alias("municipio_id"),
        pl.lit(None).cast(pl.Utf8).alias("municipio_nome"),
        pl.lit("uf").alias("fonte"),
    ]).with_columns(
        _build_tip(pl.col("status_semaforo"), pl.col("produto")).alias("dica")
    )

    logger.info("Sazonalidade UF: %d registros", monthly.height)

    return monthly.select([
        "produto", "municipio_id", "municipio_nome", "uf",
        "ano", "mes", "preco_medio", "media_movel_12m",
        "indice_sazonalidade", "status_semaforo", "dica", "fonte",
    ])


def apply_municipio_fallback(
    mun_df: pl.DataFrame,
    uf_df: pl.DataFrame,
) -> pl.DataFrame:
    """
    Para registros INSUFICIENTES no nível município, aplica o dado de UF.

    Garante que o usuário sempre veja *algo*, com transparência sobre a fonte
    (campo `fonte` = 'municipio' | 'uf').
    """
    sufficient = mun_df.filter(pl.col("status_semaforo") != "INSUFICIENTE")
    insufficient = mun_df.filter(pl.col("status_semaforo") == "INSUFICIENTE")

    # Para cada linha insuficiente, buscar o dado de UF correspondente
    uf_lookup = uf_df.select([
        "produto", "uf", "ano", "mes",
        pl.col("preco_medio").alias("preco_medio_uf"),
        pl.col("media_movel_12m").alias("media_movel_12m_uf"),
        pl.col("indice_sazonalidade").alias("indice_sazonalidade_uf"),
        pl.col("status_semaforo").alias("status_semaforo_uf"),
        pl.col("dica").alias("dica_uf"),
    ])

    fallback = insufficient.join(uf_lookup, on=["produto", "uf", "ano", "mes"], how="left")
    fallback = fallback.with_columns([
        pl.col("preco_medio_uf").alias("preco_medio"),
        pl.col("media_movel_12m_uf").alias("media_movel_12m"),
        pl.col("indice_sazonalidade_uf").alias("indice_sazonalidade"),
        pl.col("status_semaforo_uf").fill_null("INSUFICIENTE").alias("status_semaforo"),
        pl.col("dica_uf").fill_null("Dados insuficientes para esta cidade.").alias("dica"),
        pl.lit("uf").alias("fonte"),
    ]).drop(["preco_medio_uf", "media_movel_12m_uf", "indice_sazonalidade_uf",
             "status_semaforo_uf", "dica_uf"])

    result = pl.concat([sufficient, fallback], how="diagonal")
    logger.info(
        "Após fallback: %d total | %d de município | %d de UF | %d ainda insuficiente",
        result.height,
        sufficient.height,
        fallback.filter(pl.col("fonte") == "uf").height,
        fallback.filter(pl.col("status_semaforo") == "INSUFICIENTE").height,
    )
    return result
