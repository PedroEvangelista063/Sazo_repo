"""
QUERO COMPRAR — Imputação Matemática de Gaps (Baseline 2025)
=============================================================
Layer A + Layer B do modelo de 3 camadas para gaps de dados.

Estratégia:
  1. Extrai fact_precos_mensais do ano 2025
  2. Gera grid completo de 12 meses por (produto, localidade)
  3. Interpola gaps de 1-2 meses com Polars .interpolate() + fill_null
  4. Calcula peso_confianca = meses_reais / 12
  5. Upsert em staging.baseline_2025_interpolado

Uso:
    python pipeline/imputar_gaps_baseline.py

Variáveis de ambiente:
    DATABASE_URL  — string de conexão PostgreSQL
"""

import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import polars as pl
from psycopg2.extras import execute_values

# ── Caminho relativo ao projeto ────────────────────────────────────────
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

DATABASE_URL: str = os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/quero_comprar",
)

COPY_BATCH_SIZE = 50_000


def extrair_fact_2025() -> pl.DataFrame:
    """Lê fact_precos_mensais WHERE ano = 2025."""
    import psycopg2

    conn = psycopg2.connect(DATABASE_URL, options="-c timezone=UTC")
    query = """
        SELECT
            f.id_produto,
            f.id_localidade,
            f.ano,
            f.mes,
            f.preco_medio
        FROM staging.fact_precos_mensais f
        WHERE f.ano = 2025
          AND f.preco_medio IS NOT NULL
        ORDER BY f.id_produto, f.id_localidade, f.mes
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


def gerar_grid_completo(df: pl.DataFrame) -> pl.DataFrame:
    """
    Garante que cada (id_produto, id_localidade) tenha 12 linhas (mes 1..12).
    Meses sem coleta recebem preco_medio = None.
    """
    grade_meses = pl.DataFrame({"mes": range(1, 13)}).cast({"mes": pl.Int16})

    pares = df.select(["id_produto", "id_localidade"]).unique()

    grade = pares.join(grade_meses, how="cross")

    df_grid = grade.join(
        df.select(["id_produto", "id_localidade", "mes", "preco_medio"]),
        on=["id_produto", "id_localidade", "mes"],
        how="left",
    )
    return df_grid


def imputar_gaps(df: pl.DataFrame) -> pl.DataFrame:
    """
    Layer A: Interpolação linear limitada a gaps de 2 meses.
    Aplica a cadeia:
        .interpolate(method='linear')  — preenche gaps entre valores conhecidos
        .fill_null(strategy='forward', limit=2)  — bordas: forward fill até 2

    Retorna df com coluna adicional 'preco_interpolado' e 'real_ou_interp'.
    """
    return df.with_columns(
        [
            pl.col("preco_medio")
            .interpolate(method="linear")
            .fill_null(strategy="forward", limit=2)
            .over(["id_produto", "id_localidade"])
            .alias("preco_interpolado"),
        ]
    ).with_columns(
        [
            pl.when(pl.col("preco_medio").is_not_null())
            .then(pl.lit("REAL"))
            .otherwise(pl.lit("IMPUTADO"))
            .alias("tipo_origem"),
        ]
    )


def calcular_confianca(df: pl.DataFrame) -> pl.DataFrame:
    """
    Layer B: Para cada (produto, localidade), calcula:
      - qtd_meses_reais: count(preco_medio IS NOT NULL)
      - peso_confianca:  qtd_meses_reais / 12
      - media_interpolada: AVG(preco_interpolado) com 12 meses
    """
    grupos = df.group_by(["id_produto", "id_localidade"]).agg(
        [
            pl.col("preco_medio").is_not_null().sum().alias("qtd_meses_reais"),
            pl.col("preco_medio").len().alias("qtd_meses_grid"),
            pl.col("preco_interpolado").mean().alias("media_interpolada"),
            pl.col("tipo_origem")
            .filter(pl.col("tipo_origem") == "IMPUTADO")
            .len()
            .alias("qtd_imputados"),
        ]
    )

    return grupos.with_columns(
        [
            (pl.col("qtd_meses_reais") / 12).round(2).alias("peso_confianca"),
            pl.col("media_interpolada").round(4),
        ]
    ).select(
        [
            "id_produto",
            "id_localidade",
            "media_interpolada",
            "peso_confianca",
            "qtd_meses_reais",
            "qtd_meses_grid",
        ]
    )


def upsert_baseline(df: pl.DataFrame) -> int:
    """
    Escreve resultados em staging.baseline_2025_interpolado com UPSERT.
    Retorna número de linhas afetadas.
    """
    import psycopg2

    now = datetime.now(timezone.utc).isoformat()
    rows = [
        (
            int(r["id_produto"]),
            int(r["id_localidade"]),
            float(r["media_interpolada"]) if r["media_interpolada"] is not None else None,
            float(r["peso_confianca"]),
            int(r["qtd_meses_reais"]),
            int(r["qtd_meses_grid"]),
            now,
        )
        for r in df.iter_rows(named=True)
    ]

    if not rows:
        print("  Nenhuma linha para upsert.")
        return 0

    sql = """
        INSERT INTO staging.baseline_2025_interpolado
            (id_produto, id_localidade, media_interpolada,
             peso_confianca, qtd_meses_reais, qtd_meses_grid, calculado_em)
        VALUES %s
        ON CONFLICT (id_produto, id_localidade) DO UPDATE SET
            media_interpolada  = EXCLUDED.media_interpolada,
            peso_confianca     = EXCLUDED.peso_confianca,
            qtd_meses_reais    = EXCLUDED.qtd_meses_reais,
            qtd_meses_grid     = EXCLUDED.qtd_meses_grid,
            calculado_em       = EXCLUDED.calculado_em
    """

    conn = psycopg2.connect(DATABASE_URL, options="-c timezone=UTC")
    try:
        with conn:
            with conn.cursor() as cur:
                execute_values(cur, sql, rows, page_size=COPY_BATCH_SIZE)
                affected = cur.rowcount
        return affected
    finally:
        conn.close()


def log_summary(df: pl.DataFrame):
    """Imprime resumo estatístico da imputação."""
    total = len(df)
    com_gaps = df.filter(pl.col("qtd_meses_reais") < 12).height
    abaixo_threshold = df.filter(pl.col("peso_confianca") < 0.50).height
    acima_threshold = df.filter(pl.col("peso_confianca") >= 0.50).height

    media_confianca = df.select(pl.col("peso_confianca").mean()).item()

    print(f"  Total de produtos+localidades: {total}")
    print(f"  Com gaps (meses < 12):         {com_gaps}")
    print(f"  Acima do threshold (C >= 0.50): {acima_threshold}")
    print(f"  Abaixo do threshold (C < 0.50): {abaixo_threshold}")
    print(f"  Confiança média geral:          {media_confianca:.2f}")

    # Top 5 produtos com menor confiança
    print("\n  Top 5 (menor confiança):")
    piores = df.sort("peso_confianca").head(5)
    for r in piores.iter_rows(named=True):
        print(
            f"    produto={r['id_produto']} local={r['id_localidade']} "
            f"C={r['peso_confianca']:.2f} "
            f"reais={r['qtd_meses_reais']}/{r['qtd_meses_grid']}"
        )

    print("\n  Top 5 (maior confiança):")
    melhores = df.sort("peso_confianca", descending=True).head(5)
    for r in melhores.iter_rows(named=True):
        print(
            f"    produto={r['id_produto']} local={r['id_localidade']} "
            f"C={r['peso_confianca']:.2f} "
            f"reais={r['qtd_meses_reais']}/{r['qtd_meses_grid']}"
        )


def main():
    t0 = datetime.now()

    print("[imputar_gaps_baseline] Extraindo fact_precos_mensais (ano=2025)...")
    df_raw = extrair_fact_2025()
    print(f"  Linhas brutas: {len(df_raw)}")

    print("[imputar_gaps_baseline] Gerando grid completo 12 meses...")
    df_grid = gerar_grid_completo(df_raw)
    print(f"  Linhas no grid: {len(df_grid)}")

    print("[imputar_gaps_baseline] Aplicando interpolação linear (Layer A)...")
    df_interp = imputar_gaps(df_grid)

    qtd_imputados = df_interp.filter(pl.col("tipo_origem") == "IMPUTADO").height
    qtd_reais = df_interp.filter(pl.col("tipo_origem") == "REAL").height
    print(f"  Valores REAIS: {qtd_reais}, IMPUTADOS: {qtd_imputados}")

    print("[imputar_gaps_baseline] Calculando scores de confiança (Layer B)...")
    df_result = calcular_confianca(df_interp)

    log_summary(df_result)

    print("[imputar_gaps_baseline] Upsertindo em staging.baseline_2025_interpolado...")
    affected = upsert_baseline(df_result)
    print(f"  Linhas afetadas: {affected}")

    elapsed = (datetime.now() - t0).total_seconds()
    print(f"\n[imputar_gaps_baseline] Concluído em {elapsed:.1f}s")


if __name__ == "__main__":
    main()
