"""
ETL: CONAB ProhortDiario.txt → staging.fact_precos_mensais
==========================================================
1. Download ~178MB CSV diário da CONAB
2. Agregar diário → mensal (AVG) por (produto, UF, ano, mês)
3. Carregar no medalhão via CarregadorMedalhao
4. Acionar sp_executar_carga_completa()
"""

from __future__ import annotations

import io
import logging
import sys
import time
from pathlib import Path

import httpx
import polars as pl
from dotenv import load_dotenv

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
load_dotenv()

from pipeline.ingestao_conab_inteligente import CarregadorMedalhao, DATABASE_URL  # noqa: E402

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("etl_conab_diario")

URL_DIARIO = (
    "https://portaldeinformacoes.conab.gov.br/downloads/arquivos/ProhortDiario.txt"
)

COLUNAS = [
    "municipio_ceasa",
    "cod_ibge_municipio",
    "uf_ceasa",
    "dsc_ceasa",
    "dsc_produto",
    "sig_unidade_medida",
    "data_preco",
    "preco_diario",
]

PRODUTOS_HORTIFRUTI = {
    "ABACATE", "ABACAXI", "ACELGA", "ALFACE", "ALHO", "ALMEIRAO",
    "BANANA", "BATATA", "BATATA DOCE", "BERINJELA", "BETERRABA",
    "BROCOLIS", "CANA", "CAQUI", "CEBOLA", "CEBOLINHA",
    "CENOURA", "CHUCHU", "COCO", "COUVE", "COUVE-FLOR",
    "ESPINAFRE", "FEIJAO", "FIGO", "GOIABA", "HORTELA",
    "INHAME", "LARANJA", "LIMÃO", "LIMAO", "MACA",
    "MAMAO", "MAMÃO", "MANDIOCA", "MANGA", "MARAQUJA",
    "MELANCIA", "MELAO", "MILHO", "MORANGO", "MOSTARDA",
    "NABO", "PEPINO", "PIMENTA", "PIMENTAO", "QUIABO",
    "REPOLHO", "RUCULA", "SALSINHA", "SEMENTE", "SOJA",
    "TANGERINA", "TOMATE", "UVA", "VAGEM",
}

TODAS_UFS = {
    "AC", "AL", "AM", "AP", "BA", "CE", "DF", "ES", "GO",
    "MA", "MG", "MS", "MT", "PA", "PB", "PE", "PI", "PR",
    "RJ", "RN", "RO", "RR", "RS", "SC", "SE", "SP", "TO",
}


def download_csv() -> str:
    logger.info("Baixando %s ...", URL_DIARIO)
    t0 = time.perf_counter()
    with httpx.Client(
        timeout=httpx.Timeout(180.0, connect=15.0),
        follow_redirects=True,
    ) as client:
        resp = client.get(
            URL_DIARIO,
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/125.0.0.0 Safari/537.36"
                ),
            },
        )
        resp.raise_for_status()
    dt = time.perf_counter() - t0
    logger.info("Download concluido: %.1f MB em %.1fs", len(resp.content) / 1e6, dt)
    return resp.content.decode("iso-8859-1")


def parse_csv(raw: str) -> pl.DataFrame:
    logger.info("Parseando CSV...")
    t0 = time.perf_counter()
    buf = io.StringIO(raw)
    df = pl.read_csv(
        buf,
        separator=";",
        has_header=True,
        truncate_ragged_lines=True,
        infer_schema_length=0,
        encoding="iso-8859-1",
    )
    df = df.rename({
        "municipio_ceasa": "municipio_ceasa",
        "cod_ibge_municipio": "cod_ibge_municipio",
        "uf_ceasa": "uf_ceasa",
        "dsc_ceasa": "dsc_ceasa",
        "dsc_produto": "dsc_produto",
        "sig_unidade_medida": "sig_unidade_medida",
        "data_preco": "data_preco",
        "preco_diario": "preco_diario",
    })
    logger.info("Parse: %s linhas, %.1fs", len(df), time.perf_counter() - t0)
    return df


def transform(df: pl.DataFrame) -> pl.DataFrame:
    logger.info("Transformando dados...")
    t0 = time.perf_counter()

    df = df.with_columns([
        pl.col("dsc_produto").str.strip_chars().alias("produto"),
        pl.col("uf_ceasa").str.strip_chars().alias("uf"),
        pl.col("preco_diario").str.strip_chars().alias("preco_str"),
        pl.col("data_preco").str.strip_chars().alias("data_str"),
    ])

    df = df.with_columns(
        pl.col("data_str").str.slice(0, 10).alias("data_iso"),
    )

    df = df.with_columns([
        pl.col("data_iso").str.to_date("%Y/%m/%d").alias("data"),
    ])

    df = df.with_columns([
        pl.col("data").dt.year().alias("ano"),
        pl.col("data").dt.month().alias("mes"),
    ])

    df = df.with_columns(
        pl.col("preco_str").cast(pl.Float64, strict=False).alias("preco"),
    )

    df = df.drop_nulls("preco").filter(pl.col("preco") > 0)

    produtos_ok = pl.Series(list(PRODUTOS_HORTIFRUTI))
    df = df.filter(pl.col("produto").str.to_uppercase().is_in(produtos_ok))

    df = df.filter(pl.col("uf").is_in(TODAS_UFS))

    df = df.filter(pl.col("ano").is_between(2024, 2026))

    df = df.group_by(["produto", "uf", "ano", "mes"]).agg(
        pl.col("preco").mean().alias("preco_medio"),
    )

    df = df.with_columns(pl.col("preco_medio").round(4))

    df = df.select(["produto", "uf", "ano", "mes", "preco_medio"])

    logger.info(
        "Transform: %d linhas (%.1fs)",
        len(df), time.perf_counter() - t0,
    )
    return df


def validar_qualidade(df: pl.DataFrame) -> dict:
    stats = {
        "total_linhas": len(df),
        "meses_cobertos": df.select(pl.struct(["ano", "mes"])).unique().height,
        "ufs": sorted(df["uf"].unique().to_list()),
        "produtos": sorted(df["produto"].unique().to_list()),
        "total_ufs": df["uf"].n_unique(),
        "total_produtos": df["produto"].n_unique(),
        "cobertura_uf_mes": {},
    }

    for row in df.group_by(["ano", "mes"]).agg(
        pl.col("uf").n_unique().alias("n_ufs"),
    ).sort(["ano", "mes"]).iter_rows():
        stats["cobertura_uf_mes"][f'{row[0]}-{row[1]:02d}'] = row[2]

    stats["preco_medio_geral"] = round(float(df["preco_medio"].mean()), 2)
    stats["preco_min"] = round(float(df["preco_medio"].min()), 2)
    stats["preco_max"] = round(float(df["preco_medio"].max()), 2)

    return stats


def main():
    logger.info("=" * 60)
    logger.info("ETL CONAB ProhortDiario → fact_precos_mensais")
    logger.info("=" * 60)

    raw = download_csv()
    df_raw = parse_csv(raw)
    df = transform(df_raw)
    del raw, df_raw

    stats = validar_qualidade(df)
    logger.info("--- QUALIDADE DOS DADOS ---")
    logger.info("Total linhas agregadas: %s", f"{stats['total_linhas']:,}")
    logger.info("Meses cobertos: %d", stats["meses_cobertos"])
    ufs_str = ", ".join(stats["ufs"])
    logger.info("UFs: %d — %s", stats["total_ufs"], ufs_str)
    prods_str = ", ".join(stats["produtos"][:10]) + "..."
    logger.info("Produtos: %d — %s", stats["total_produtos"], prods_str)
    logger.info("Preço médio geral: R$ %.2f", stats["preco_medio_geral"])
    for comp, n_ufs in stats["cobertura_uf_mes"].items():
        logger.info("  %s: %d UFs", comp, n_ufs)

    if stats["total_linhas"] == 0:
        logger.error("Nenhum dado para carregar — abortando.")
        return

    logger.info("--- CARREGANDO NO MEDALHAO ---")
    carregador = CarregadorMedalhao(database_url=DATABASE_URL)
    inseridas = carregador.carregar(df)
    logger.info("Linhas inseridas/atualizadas em fact_precos_mensais: %s", f"{inseridas:,}")
    logger.info("ETL concluido com sucesso!")
    logger.info("=" * 60)

    return stats


if __name__ == "__main__":
    main()
