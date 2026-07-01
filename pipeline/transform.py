"""
Motor de transformação: lê os .txt brutos da CONAB, limpa e normaliza.

Armadilhas conhecidas com dados governamentais CONAB:
- Encoding Latin-1 (não UTF-8)
- Separador decimal vírgula: "6,50" → 6.50
- Separador de coluna: ponto-e-vírgula ";"
- Nomes de produtos inconsistentes: "TOMATE" vs "Tomate Salada"
- Linhas de cabeçalho duplicadas no meio do arquivo
- Campos com espaços extras antes/depois
"""

import logging
from pathlib import Path

import polars as pl

logger = logging.getLogger(__name__)

# Mapeamento esperado de colunas após normalização
_EXPECTED_COLUMNS_UF = {
    "produto",
    "uf",
    "ano",
    "mes",
    "preco_medio",
}
_EXPECTED_COLUMNS_MUN = {
    "produto",
    "municipio_id",
    "municipio_nome",
    "uf",
    "ano",
    "mes",
    "preco_medio",
}


def _normalize_column_names(df: pl.DataFrame) -> pl.DataFrame:
    """Remove espaços, converte para snake_case lowercase."""
    return df.rename({c: c.strip().lower().replace(" ", "_").replace("-", "_") for c in df.columns})


def _parse_price_column(df: pl.DataFrame, col: str) -> pl.DataFrame:
    """Converte string 'X,XX' para Float64."""
    if df[col].dtype == pl.Utf8:
        df = df.with_columns(
            pl.col(col)
            .str.strip_chars()
            .str.replace(",", ".")
            .cast(pl.Float64, strict=False)
            .alias(col)
        )
    return df


def _remove_outliers_zscore(df: pl.DataFrame, col: str, threshold: float = 3.0) -> pl.DataFrame:
    """
    Remove outliers extremos (Z-score > threshold) por produto+municipio.

    Evita que um evento climático pontual (ex: geada) distorça a média anual
    e gere uma falsa recomendação de "VERDE" no semáforo.
    """
    group_cols = ["produto", "municipio_id"] if "municipio_id" in df.columns else ["produto", "uf"]
    df = df.with_columns(
        [
            pl.col(col).mean().over(group_cols).alias("_mean"),
            pl.col(col).std().over(group_cols).alias("_std"),
        ]
    )
    df = df.filter(
        ((pl.col(col) - pl.col("_mean")) / pl.col("_std").fill_null(1.0)).abs() < threshold
    ).drop(["_mean", "_std"])
    return df


def load_uf_file(path: Path) -> pl.DataFrame:
    """
    Lê e limpa o arquivo PrecosMensalUF.txt da CONAB.

    Returns:
        DataFrame com colunas: produto, uf, ano, mes, preco_medio
    """
    df = pl.read_csv(
        path,
        separator=";",
        encoding="latin1",
        infer_schema_length=10_000,
        ignore_errors=True,
        truncate_ragged_lines=True,
    )
    df = _normalize_column_names(df)
    logger.info("UF raw shape: %s | colunas: %s", df.shape, df.columns)

    # Detectar coluna de preço (pode variar: "preco", "preco_medio", "valor")
    price_col = next((c for c in df.columns if "preco" in c or "valor" in c), None)
    if price_col is None:
        raise ValueError(f"Coluna de preço não encontrada. Colunas disponíveis: {df.columns}")
    if price_col != "preco_medio":
        df = df.rename({price_col: "preco_medio"})

    df = _parse_price_column(df, "preco_medio")

    # Garantir tipos corretos
    df = df.with_columns(
        [
            pl.col("ano").cast(pl.Int32, strict=False),
            pl.col("mes").cast(pl.Int32, strict=False),
            pl.col("uf").str.strip_chars().str.to_uppercase(),
            pl.col("produto").str.strip_chars().str.to_uppercase(),
        ]
    )

    # Remover linhas inválidas
    df = df.filter(
        pl.col("preco_medio").is_not_null()
        & pl.col("produto").is_not_null()
        & pl.col("uf").is_not_null()
        & (pl.col("preco_medio") > 0)
        & pl.col("ano").is_not_null()
        & pl.col("mes").is_not_null()
        & pl.col("mes").is_between(1, 12)
    )

    df = _remove_outliers_zscore(df, "preco_medio")

    logger.info("UF cleaned shape: %s", df.shape)
    return df.select(["produto", "uf", "ano", "mes", "preco_medio"])


def load_municipio_file(path: Path) -> pl.DataFrame:
    """
    Lê e limpa o arquivo PrecosMensalMunicipio.txt da CONAB.

    Returns:
        DataFrame com colunas: produto, municipio_id, municipio_nome, uf, ano, mes, preco_medio
    """
    df = pl.read_csv(
        path,
        separator=";",
        encoding="latin1",
        infer_schema_length=10_000,
        ignore_errors=True,
        truncate_ragged_lines=True,
    )
    df = _normalize_column_names(df)
    logger.info("Município raw shape: %s | colunas: %s", df.shape, df.columns)

    # Detectar coluna de preço
    price_col = next((c for c in df.columns if "preco" in c or "valor" in c), None)
    if price_col is None:
        raise ValueError(f"Coluna de preço não encontrada. Colunas: {df.columns}")
    if price_col != "preco_medio":
        df = df.rename({price_col: "preco_medio"})

    # Detectar coluna de código do município (código IBGE)
    id_col = next((c for c in df.columns if "cod" in c or "ibge" in c or "id_mun" in c), None)
    if id_col and id_col != "municipio_id":
        df = df.rename({id_col: "municipio_id"})

    # Detectar coluna de nome do município
    nome_col = next(
        (c for c in df.columns if "municipio" in c and "id" not in c and "nome" in c), None
    )
    if nome_col and nome_col != "municipio_nome":
        df = df.rename({nome_col: "municipio_nome"})

    df = _parse_price_column(df, "preco_medio")

    df = df.with_columns(
        [
            pl.col("ano").cast(pl.Int32, strict=False),
            pl.col("mes").cast(pl.Int32, strict=False),
            pl.col("uf").str.strip_chars().str.to_uppercase(),
            pl.col("produto").str.strip_chars().str.to_uppercase(),
            pl.col("municipio_nome").str.strip_chars().str.to_titlecase()
            if "municipio_nome" in df.columns
            else pl.lit(None).alias("municipio_nome"),
        ]
    )

    df = df.filter(
        pl.col("preco_medio").is_not_null()
        & pl.col("produto").is_not_null()
        & (pl.col("preco_medio") > 0)
        & pl.col("ano").is_not_null()
        & pl.col("mes").is_not_null()
        & pl.col("mes").is_between(1, 12)
    )

    df = _remove_outliers_zscore(df, "preco_medio")

    # Colunas que DEVEM existir
    required = ["produto", "uf", "ano", "mes", "preco_medio"]
    for c in required:
        if c not in df.columns:
            raise ValueError(f"Coluna obrigatória ausente após limpeza: {c}")

    optional = ["municipio_id", "municipio_nome"]
    for c in optional:
        if c not in df.columns:
            df = df.with_columns(pl.lit(None).cast(pl.Utf8).alias(c))

    logger.info("Município cleaned shape: %s", df.shape)
    return df.select(
        ["produto", "municipio_id", "municipio_nome", "uf", "ano", "mes", "preco_medio"]
    )
