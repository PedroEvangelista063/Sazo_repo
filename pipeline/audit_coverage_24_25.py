import os
import json
import polars as pl
import psycopg2

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/quero_comprar")
conn = psycopg2.connect(DATABASE_URL)

query = """
SELECT
  f.id_produto,
  f.ano,
  f.mes,
  f.is_interpolado,
  p.nome_produto,
  l.uf
FROM staging.fact_precos_mensais f
JOIN staging.dim_produto p ON f.id_produto = p.id_produto
JOIN staging.dim_localidade l ON f.id_localidade = l.id_localidade
WHERE p.categoria_b2c = 'ALIMENTO_VAREJO'
  AND f.ano IN (2024, 2025)
"""

df = pl.read_database(query, conn)
conn.close()

months = pl.DataFrame([{"ano": a, "mes": m} for a in (2024, 2025) for m in range(1, 13)])

product_uf = df.unique(subset=["id_produto", "uf"]).select("id_produto", "uf", "nome_produto")

denom = (
    product_uf
    .group_by("uf")
    .agg(
        pl.col("nome_produto").unique().alias("produtos_uf"),
        pl.col("id_produto").n_unique().alias("total_produtos_uf"),
    )
)

numer = (
    df
    .filter(~pl.col("is_interpolado"))
    .unique(subset=["id_produto", "uf", "ano", "mes"])
    .group_by("uf", "ano", "mes")
    .agg(
        pl.col("nome_produto").unique().alias("produtos_real"),
        pl.col("id_produto").n_unique().alias("total_real"),
    )
)

all_uf = denom.select("uf")
all_uf_months = all_uf.join(months, how="cross")

coverage = (
    all_uf_months
    .join(denom, on="uf")
    .join(numer, on=["uf", "ano", "mes"], how="left")
    .with_columns(
        pl.col("total_real").fill_null(0),
        pl.col("produtos_real").fill_null(pl.Series([[]], dtype=pl.List(pl.String))),
    )
    .with_columns(
        ((pl.col("total_real").cast(pl.Float64) / pl.col("total_produtos_uf").cast(pl.Float64)) * 100)
        .round(1)
        .alias("coverage_pct"),
    )
    .with_columns(
        pl.when(pl.col("coverage_pct") < 50.0)
        .then(pl.lit("[ALERTA]"))
        .otherwise(pl.lit(""))
        .alias("alerta"),
    )
    .sort("ano", "mes", "uf")
)

print("=" * 80)
print("MATRIZ DE COBERTURA — ALIMENTO_VAREJO (2024-2025)")
print("=" * 80)
for row in coverage.iter_rows(named=True):
    label = (
        f"[{row['uf']}] {row['ano']}-{row['mes']:02d}: "
        f"{row['coverage_pct']:.1f}% ({int(row['total_real'])}/{int(row['total_produtos_uf'])} produtos)"
    )
    if row["alerta"]:
        label += f" {row['alerta']}"
    print(label)

gaps_raw = (
    coverage
    .filter(pl.col("total_real") < pl.col("total_produtos_uf"))
    .with_columns(
        pl.col("produtos_uf").list.set_difference(pl.col("produtos_real")).alias("produtos_faltantes"),
    )
    .select("ano", "mes", "uf", "produtos_faltantes")
)

gaps_list = [
    {"ano": r["ano"], "mes": r["mes"], "uf": r["uf"], "produtos_faltantes": sorted(r["produtos_faltantes"])}
    for r in gaps_raw.iter_rows(named=True)
]

os.makedirs("logs", exist_ok=True)
gap_path = os.path.join(os.path.dirname(__file__), "..", "logs", "gaps_2024_2025.json")
with open(gap_path, "w", encoding="utf-8") as f:
    json.dump(gaps_list, f, ensure_ascii=False, indent=2)

total_products = product_uf.select(pl.col("id_produto").n_unique()).item()
total_ufs = all_uf.select(pl.len()).item()
avg_cov = coverage.select(pl.col("coverage_pct").mean()).item()

worst_uf = (
    coverage
    .group_by("uf")
    .agg(pl.col("coverage_pct").mean().alias("avg_cov"))
    .sort("avg_cov")
    .head(1)
)

worst_month = (
    coverage
    .group_by("ano", "mes")
    .agg(pl.col("coverage_pct").mean().alias("avg_cov"))
    .sort("avg_cov")
    .head(1)
)

print()
print("=" * 80)
print("ESTATÍSTICAS RESUMIDAS")
print("=" * 80)
print(f"Total produtos: {total_products}")
print(f"Total UFs: {total_ufs}")
print(f"Cobertura média geral: {avg_cov:.1f}%")
print(f"Pior UF: {worst_uf['uf'][0]} ({worst_uf['avg_cov'][0]:.1f}%)")
print(f"Pior mês: {worst_month['ano'][0]}-{worst_month['mes'][0]:02d} ({worst_month['avg_cov'][0]:.1f}%)")
print(f"\nGaps exportados para: {gap_path}")
