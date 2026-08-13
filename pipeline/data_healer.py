"""
QUERO COMPRAR — Motor de Cura Analítica (Data Healing Engine)
==============================================================
Layer A + Layer B para cura de séries temporais inteiras.

Estratégia:
  1. Extrai TODO o histórico de fact_precos_mensais
  2. Para cada (produto, localidade), gera grid temporal completo
  3. Layer A: Interpolação linear com limite de 2 meses consecutivos
  4. UPDATE: preco_curado e is_interpolado nas linhas existentes
  5. INSERT: novas linhas para meses interpolados (buracos curados)
  6. Layer B: Score de confiança para 2025 em staging.confianca_baseline
"""

import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import polars as pl
import psycopg2
from psycopg2.extras import execute_values

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

DATABASE_URL: str = os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/quero_comprar",
)

COPY_BATCH_SIZE = 50_000


def extrair_fact() -> pl.DataFrame:
    conn = psycopg2.connect(DATABASE_URL, options="-c timezone=UTC")
    query = """
        SELECT
            f.id_produto,
            f.id_localidade,
            f.ano,
            f.mes,
            f.preco_medio
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_produto p ON p.id_produto = f.id_produto
                                   AND p.categoria_b2c = 'ALIMENTO_VAREJO'
        WHERE f.preco_medio IS NOT NULL
        ORDER BY f.id_produto, f.id_localidade, f.ano, f.mes
    """
    with conn:
        with conn.cursor() as cur:
            cur.execute(query)
            rows = cur.fetchall()
    conn.close()

    schema = {
        "id_produto": pl.Int32,
        "id_localidade": pl.Int32,
        "ano": pl.Int16,
        "mes": pl.Int16,
        "preco_medio": pl.Float64,
    }
    return pl.from_records(rows, schema=schema, orient="row")


def gerar_grid_temporal(df: pl.DataFrame) -> pl.DataFrame:
    ranges = df.group_by(["id_produto", "id_localidade"]).agg([
        pl.min("ano").alias("ano_min"),
        pl.max("ano").alias("ano_max"),
    ])

    months = pl.DataFrame({"mes": pl.Series(range(1, 13), dtype=pl.Int16)})

    all_grids = []
    for r in ranges.iter_rows(named=True):
        pid, lid, amin, amax = r["id_produto"], r["id_localidade"], r["ano_min"], r["ano_max"]
        anos = pl.DataFrame({
            "id_produto": pl.Series([pid], dtype=pl.Int32).new_from_index(0, amax - amin + 1),
            "id_localidade": pl.Series([lid], dtype=pl.Int32).new_from_index(0, amax - amin + 1),
            "ano": pl.Series(range(amin, amax + 1), dtype=pl.Int16),
        })
        all_grids.append(anos.join(months, how="cross"))

    grade = pl.concat(all_grids)

    return grade.join(
        df.select(["id_produto", "id_localidade", "ano", "mes", "preco_medio"]),
        on=["id_produto", "id_localidade", "ano", "mes"],
        how="left",
    ).sort(["id_produto", "id_localidade", "ano", "mes"])


def detectar_gaps(df: pl.DataFrame) -> pl.DataFrame:
    df = df.with_columns([
        pl.col("preco_medio").is_null().alias("_null"),
    ])
    df = df.with_columns([
        (
            pl.col("_null")
            & (pl.col("_null").shift(1).over(["id_produto", "id_localidade"]).fill_null(False) == False)
        ).alias("_block_start")
    ])
    df = df.with_columns([
        pl.col("_block_start").cum_sum().over(["id_produto", "id_localidade"]).alias("_null_block_id")
    ])
    df = df.with_columns([
        pl.col("_null").sum().over(["id_produto", "id_localidade", "_null_block_id"]).alias("_null_block_size")
    ])
    return df


def aplicar_camada_a(df: pl.DataFrame) -> pl.DataFrame:
    df = df.with_columns([
        pl.col("preco_medio")
        .interpolate(method="linear")
        .fill_null(strategy="forward", limit=2)
        .over(["id_produto", "id_localidade"])
        .alias("preco_interp_full")
    ])

    df = df.with_columns([
        pl.when(
            pl.col("_null") & (pl.col("_null_block_size") > 2)
        ).then(None)
        .otherwise(pl.col("preco_interp_full"))
        .alias("preco_curado")
    ])

    df = df.with_columns([
        (pl.col("preco_medio").is_null() & pl.col("preco_curado").is_not_null())
        .alias("is_interpolado")
    ])

    return df


def calcular_confianca_2025(df_all: pl.DataFrame) -> pl.DataFrame:
    df_2025 = df_all.filter(pl.col("ano") == 2025)

    grupos = df_2025.group_by(["id_produto", "id_localidade"]).agg([
        pl.col("preco_medio").is_not_null().sum().alias("meses_reais"),
        pl.col("is_interpolado").sum().alias("meses_interpolados"),
        pl.col("preco_curado").mean().alias("media_2025_curada"),
        pl.len().alias("total_meses_grid"),
    ])

    return grupos.with_columns([
        ((pl.col("meses_reais") + pl.col("meses_interpolados")) / 12.0)
        .round(2).alias("score_confianca"),
    ]).with_columns([
        (pl.col("score_confianca") >= 0.50).alias("confiavel_2025"),
        pl.col("media_2025_curada").round(4),
    ])


def upsert_fact(df_healed: pl.DataFrame) -> tuple[int, int]:
    conn = psycopg2.connect(DATABASE_URL, options="-c timezone=UTC")
    batch_id = str(uuid.uuid4())
    updated = 0
    inserted = 0

    try:
        with conn:
            with conn.cursor() as cur:
                existing = df_healed.filter(pl.col("preco_medio").is_not_null())
                if len(existing) > 0:
                    update_rows = [
                        (
                            int(r["id_produto"]),
                            int(r["id_localidade"]),
                            int(r["ano"]),
                            int(r["mes"]),
                            float(r["preco_curado"]) if r["preco_curado"] is not None else None,
                            bool(r["is_interpolado"]),
                        )
                        for r in existing.select(
                            ["id_produto", "id_localidade", "ano", "mes", "preco_curado", "is_interpolado"]
                        ).iter_rows(named=True)
                    ]

                    update_sql = """
                        UPDATE staging.fact_precos_mensais
                        SET preco_curado = data.preco_curado::NUMERIC(14,4),
                            is_interpolado = data.is_interpolado::BOOLEAN
                        FROM (VALUES %s) AS data(id_produto, id_localidade, ano, mes, preco_curado, is_interpolado)
                        WHERE staging.fact_precos_mensais.id_produto = data.id_produto
                          AND staging.fact_precos_mensais.id_localidade = data.id_localidade
                          AND staging.fact_precos_mensais.ano = data.ano
                          AND staging.fact_precos_mensais.mes = data.mes
                    """
                    execute_values(cur, update_sql, update_rows, page_size=COPY_BATCH_SIZE)
                    updated = len(update_rows)

                new_rows_df = df_healed.filter(
                    pl.col("preco_medio").is_null() & pl.col("is_interpolado")
                )
                if len(new_rows_df) > 0:
                    insert_rows = [
                        (
                            int(r["id_produto"]),
                            int(r["id_localidade"]),
                            int(r["ano"]),
                            int(r["mes"]),
                            float(r["preco_curado"]),
                            float(r["preco_curado"]),
                            True,
                            batch_id,
                        )
                        for r in new_rows_df.select(
                            ["id_produto", "id_localidade", "ano", "mes", "preco_curado"]
                        ).iter_rows(named=True)
                    ]

                    insert_sql = """
                        INSERT INTO staging.fact_precos_mensais
                            (id_produto, id_localidade, ano, mes, preco_medio, preco_curado, is_interpolado, batch_id)
                        VALUES %s
                        ON CONFLICT (id_produto, id_localidade, ano, mes, (COALESCE(unidade_canonica, 'kg'))) DO UPDATE SET
                            preco_medio    = EXCLUDED.preco_medio,
                            preco_curado   = EXCLUDED.preco_curado,
                            is_interpolado = EXCLUDED.is_interpolado,
                            batch_id       = EXCLUDED.batch_id,
                            loaded_at      = NOW()
                    """
                    execute_values(cur, insert_sql, insert_rows, page_size=COPY_BATCH_SIZE)
                    inserted = len(insert_rows)
    finally:
        conn.close()

    return updated, inserted


def upsert_confianca(df_conf: pl.DataFrame) -> int:
    conn = psycopg2.connect(DATABASE_URL, options="-c timezone=UTC")
    now_str = datetime.now(timezone.utc).isoformat()
    rows = [
        (
            int(r["id_produto"]),
            int(r["id_localidade"]),
            bool(r["confiavel_2025"]),
            float(r["score_confianca"]),
            int(r["meses_reais"]),
            int(r["meses_interpolados"]),
            float(r["media_2025_curada"]) if r["media_2025_curada"] is not None else None,
            now_str,
        )
        for r in df_conf.iter_rows(named=True)
    ]

    if not rows:
        return 0

    sql = """
        INSERT INTO staging.confianca_baseline
            (id_produto, id_localidade, confiavel_2025, score_confianca,
             meses_reais, meses_interpolados, media_2025_curada, calculado_em)
        VALUES %s
        ON CONFLICT (id_produto, id_localidade) DO UPDATE SET
            confiavel_2025      = EXCLUDED.confiavel_2025,
            score_confianca     = EXCLUDED.score_confianca,
            meses_reais         = EXCLUDED.meses_reais,
            meses_interpolados  = EXCLUDED.meses_interpolados,
            media_2025_curada   = EXCLUDED.media_2025_curada,
            calculado_em        = EXCLUDED.calculado_em
    """

    try:
        with conn:
            with conn.cursor() as cur:
                execute_values(cur, sql, rows, page_size=COPY_BATCH_SIZE)
                return cur.rowcount
    finally:
        conn.close()


def log_summary(df_healed: pl.DataFrame, df_conf: pl.DataFrame):
    total_pares = df_healed.select(
        pl.struct(["id_produto", "id_localidade"]).unique().len()
    ).item()
    total_linhas = len(df_healed)
    qtd_interpolados = df_healed.filter(pl.col("is_interpolado")).height
    qtd_reais = df_healed.filter(pl.col("preco_medio").is_not_null()).height
    pct_interp = round(qtd_interpolados / total_linhas * 100, 2) if total_linhas else 0

    total_conf = len(df_conf)
    confiaveis = df_conf.filter(pl.col("confiavel_2025")).height
    nao_confiaveis = df_conf.filter(~pl.col("confiavel_2025")).height

    print(f"\n{'=' * 60}")
    print(f"  RESUMO DA CURA ANALÍTICA")
    print(f"{'=' * 60}")
    print(f"  Pares (produto, localidade):       {total_pares}")
    print(f"  Total de linhas no grid:            {total_linhas}")
    print(f"  Valores REAIS:                      {qtd_reais}")
    print(f"  Valores INTERPOLADOS (buracos):     {qtd_interpolados} ({pct_interp}%)")
    print(f"  ---")
    print(f"  Produtos avaliados (baseline 2025): {total_conf}")
    print(f"  Confiáveis (score >= 0.50):          {confiaveis}")
    print(f"  Não confiáveis (score < 0.50):       {nao_confiaveis}")

    if nao_confiaveis > 0:
        print(f"\n  Top 5 (menor confiança):")
        piores = df_conf.sort("score_confianca").head(5)
        for r in piores.iter_rows(named=True):
            print(f"    produto={r['id_produto']} local={r['id_localidade']} "
                  f"score={r['score_confianca']:.2f} "
                  f"reais={r['meses_reais']}+interp={r['meses_interpolados']}")

    print(f"{'=' * 60}\n")


def main():
    t0 = datetime.now()

    print("[data_healer] Extraindo fact_precos_mensais...")
    df_raw = extrair_fact()
    print(f"  Linhas brutas: {len(df_raw)}")

    print("[data_healer] Gerando grid temporal completo...")
    df_grid = gerar_grid_temporal(df_raw)
    print(f"  Linhas no grid: {len(df_grid)}")

    print("[data_healer] Detectando gaps...")
    df_grid = detectar_gaps(df_grid)

    print("[data_healer] Aplicando Layer A (interpolação linear)...")
    df_healed = aplicar_camada_a(df_grid)
    qtd_interp = df_healed.filter(pl.col("is_interpolado")).height
    print(f"  Meses interpolados: {qtd_interp}")

    print("[data_healer] Calculando Layer B (confiança 2025)...")
    df_conf = calcular_confianca_2025(df_healed)
    print(f"  Produtos+localidades em 2025: {len(df_conf)}")

    print("[data_healer] Escrevendo dados curados no banco...")
    updated, inserted = upsert_fact(df_healed)
    print(f"  UPDATE (preco_curado): {updated}")
    print(f"  INSERT (novas linhas): {inserted}")

    print("[data_healer] Escrevendo confiança baseline...")
    affected = upsert_confianca(df_conf)
    print(f"  Linhas em confianca_baseline: {affected}")

    log_summary(df_healed, df_conf)

    elapsed = (datetime.now() - t0).total_seconds()
    print(f"[data_healer] Concluído em {elapsed:.1f}s")


if __name__ == "__main__":
    main()
