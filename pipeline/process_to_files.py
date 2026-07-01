"""
ETL Offline — Processa LISTA*.txt e salva dados tratados em database/processed_data/.

Saída:
  database/processed_data/
  ├── 01_raw/              JSON bruto por arquivo
  ├── 02_cleaned/          Dados limpos e normalizados
  ├── 03_categorized/      Com categoria_b2c (ALIMENTO_VAREJO / B2B)
  ├── 04_b2c_only/         Apenas ALIMENTO_VAREJO (o que vai pro app)
  ├── 05_aggregated/       Agregado mensal por produto+UF
  ├── 06_seasonality/      Sazonalidade calculada (baseline 2025 + fallback 12m)
  ├── sql/                 Scripts INSERT para PostgreSQL
  ├── consolidated.parquet Dados completos em Parquet
  ├── summary.json         Resumo consolidado
  └── ETL_REPORT.md        Relatório legível

Uso:
    python -m pipeline.process_to_files
"""

from __future__ import annotations

import io
import json
import logging
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, NoReturn

import polars as pl

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("process_to_files")

PROJECT_ROOT = Path(__file__).resolve().parent.parent
LOCAL_DATA_DIR = PROJECT_ROOT / "dados_sazonliza_dados_bruto"
OUTPUT_DIR = PROJECT_ROOT / "database" / "processed_data"

UF_COLUMNS = ["produto", "uf", "ano", "mes", "preco_medio"]

CONAB_COLUMNS_9 = [
    "produto",
    "classificao_produto",
    "id_produto",
    "uf",
    "regiao",
    "ano",
    "mes",
    "dsc_nivel_comercializacao",
    "valor_produto_kg",
]

CONAB_COLUMNS_11 = [
    "produto",
    "classificao_produto",
    "id_produto",
    "nom_municipio",
    "cod_ibge",
    "uf",
    "regiao",
    "ano",
    "mes",
    "dsc_nivel_comercializacao",
    "valor_produto_kg",
]


def _tem_header(text: str) -> bool:
    first = text.lstrip("\ufeff").strip().split("\n", 1)[0].strip().lower()
    return first.startswith("produto") or first.startswith('"produto')


def _ler_csv(text: str) -> pl.DataFrame:
    """Lê CSV detectando header vs no-header e variações de colunas."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if _tem_header(text):
        df = pl.read_csv(
            io.StringIO(text),
            separator=";",
            infer_schema_length=10_000,
            ignore_errors=True,
            truncate_ragged_lines=True,
        )
        df = df.rename(
            {c: c.strip().lower().replace(" ", "_").replace("-", "_") for c in df.columns}
        )
    else:
        first_line = text.strip().split("\n", 1)[0].strip()
        num_cols = len(first_line.split(";"))
        if num_cols >= 11:
            col_names = CONAB_COLUMNS_11
        else:
            col_names = CONAB_COLUMNS_9
        df = pl.read_csv(
            io.StringIO(text),
            separator=";",
            has_header=False,
            new_columns=col_names,
            infer_schema_length=10_000,
            ignore_errors=True,
            truncate_ragged_lines=True,
        )
    return df


REGRAS_CATEGORIAS: dict[str, str] = {
    "MAQUINARIO_FERRAMENTA": (
        r"(?i)^(TRATOR|ESCARIFICADOR|ESCADA|PAQUIMETRO|"
        r"BOTA|LUVAS|TRAPICHO)\b"
    ),
    "INSUMO_AGRICOLA": (
        r"(?i)^(00-\d{2}-\d{2}|ZINCO|FLUMYZIN|NATIVO|SENCOR|"
        r"SEMENTE|NEMAT|FLUIL|NHT|OLEO VEGETA|PARA BROCA)\b"
    ),
    "SERVICO_LOGISTICA": (r"(?i)^(TRANSPORTE|PASSAGEM|PATIO|TRATAMENTO)\b"),
    "ALIMENTO_VAREJO": (
        r"(?i)^(CARNE|PAO|FLOCOS DE MILHO|ERVA MATE|TOMATE|"
        r"FRANGO|ARROZ|FEIJAO|BATATA|CENOURA|CEBOLA|ALFACE|"
        r"REPOLHO|ABOBRINHA|PIMENTAO|LARANJA|BANANA|MACA|"
        r"MAMAO|UVA)\b"
    ),
}

THRESHOLD_GREEN = 0.85
THRESHOLD_RED = 1.15


def _sanitize_price(series: pl.Series) -> pl.Series:
    return series.str.strip_chars().str.replace(",", ".").cast(pl.Float64, strict=False)


def _clean_file(filepath: Path) -> pl.DataFrame:
    """Lê e limpa um LISTA*.txt, retornando DataFrame."""
    raw_text = filepath.read_bytes().decode("latin-1")
    df = _ler_csv(raw_text)

    for col in df.columns:
        if df[col].dtype == pl.Utf8:
            df = df.with_columns(pl.col(col).str.strip_chars().alias(col))

    if "produto" in df.columns:
        df = df.with_columns(pl.col("produto").alias("_produto_original"))

    if "classificao_produto" in df.columns and "produto" in df.columns:
        df = df.with_columns(
            (pl.col("produto") + " - " + pl.col("classificao_produto")).alias("produto")
        )

    if "valor_produto_kg" in df.columns:
        df = df.rename({"valor_produto_kg": "preco_medio"})

    if "preco_medio" in df.columns:
        df = df.with_columns(
            _sanitize_price(pl.col("preco_medio")).alias("preco_medio"),
        )

    if "ano" in df.columns:
        df = df.with_columns(pl.col("ano").cast(pl.Int32, strict=False))
    if "mes" in df.columns:
        df = df.with_columns(pl.col("mes").cast(pl.Int32, strict=False))

    df = df.filter(
        pl.col("preco_medio").is_not_null()
        & (pl.col("preco_medio") > 0)
        & pl.col("produto").is_not_null()
        & (pl.col("uf").str.len_chars() == 2)
        & pl.col("ano").is_not_null()
        & pl.col("mes").is_not_null()
        & pl.col("mes").is_between(1, 12)
    )

    if "produto" in df.columns:
        df = df.filter(~pl.col("produto").str.to_lowercase().str.contains("produto"))

    return df


def _categorizar(df: pl.DataFrame) -> pl.DataFrame:
    """Adiciona coluna categoria_b2c."""
    col = "_produto_original" if "_produto_original" in df.columns else "produto"
    expr = pl.lit("MATERIA_PRIMA_B2B")
    for cat, pattern in REGRAS_CATEGORIAS.items():
        expr = pl.when(pl.col(col).str.contains(pattern)).then(pl.lit(cat)).otherwise(expr)
    return df.with_columns(expr.alias("categoria_b2c"))


def _calcular_sazonalidade(df: pl.DataFrame) -> pl.DataFrame:
    """Calcula baseline 2025 + fallback 12m + MoM (réplica da SP do banco).

    Cadeia de fallback:
      1. rolling_12m → Baseline 2025 interpolada
      2. fallback_12m → Média 12 meses
      3. mom → Variação mês-a-mês (Δ% ±10%)
      4. insuficiente → Sem dados
    """
    if df.height == 0:
        return pl.DataFrame(
            schema={
                "produto": pl.Utf8,
                "uf": pl.Utf8,
                "preco_referencia": pl.Float64,
                "preco_atual": pl.Float64,
                "data_referencia_atual": pl.Utf8,
                "usou_fallback_12m": pl.Boolean,
                "status_cor": pl.Utf8,
                "fonte": pl.Utf8,
                "metodo_calculo": pl.Utf8,
                "variacao_mom_pct": pl.Float64,
                "preco_mes_anterior": pl.Float64,
            }
        )

    # Baseline 2025
    base_2025 = (
        df.filter(pl.col("ano") == 2025)
        .group_by(["produto", "uf"])
        .agg(pl.col("preco_medio").mean().alias("preco_referencia_2025"))
    )

    # Último preço de cada produto+UF
    ultimos = (
        df.sort(["produto", "uf", "ano", "mes"])
        .group_by(["produto", "uf"])
        .agg(
            [
                pl.col("preco_medio").last().alias("preco_atual"),
                pl.col("ano").last().alias("ultimo_ano"),
                pl.col("mes").last().alias("ultimo_mes"),
            ]
        )
        .with_columns(
            (
                pl.col("ultimo_ano").cast(pl.Utf8)
                + "-"
                + pl.col("ultimo_mes").cast(pl.Utf8).str.pad_start(2, "0")
            ).alias("data_referencia_atual")
        )
    )

    # Fallback 12m
    periodos = df.group_by(["produto", "uf"]).agg(
        (pl.col("ano") * 12 + pl.col("mes")).max().alias("ultimo_periodo")
    )
    fallback = df.join(periodos, on=["produto", "uf"], how="inner")
    fallback = fallback.filter(
        (fallback["ano"] * 12 + fallback["mes"]) > (fallback["ultimo_periodo"] - 12)
    )
    fallback = (
        fallback.group_by(["produto", "uf"])
        .agg([
            pl.col("preco_medio").mean().alias("preco_fallback_12m"),
            pl.len().alias("qtd_meses"),
        ])
        .filter(pl.col("preco_fallback_12m").is_not_null())
        .filter(pl.col("qtd_meses") >= 3)
    )

    # MoM: preço do mês anterior via window function
    mom = (
        df.sort(["produto", "uf", "ano", "mes"])
        .with_columns(
            pl.col("preco_medio")
            .shift(1)
            .over(["produto", "uf"])
            .alias("preco_mes_anterior")
        )
        .filter(pl.col("preco_mes_anterior").is_not_null())
        .group_by(["produto", "uf"])
        .agg([
            pl.col("preco_medio").last().alias("preco_atual_mom"),
            pl.col("preco_mes_anterior").last().alias("preco_mes_anterior"),
        ])
        .with_columns(
            pl.when(
                pl.col("preco_mes_anterior").is_not_null()
                & (pl.col("preco_mes_anterior") > 0)
            )
            .then(
                ((pl.col("preco_atual_mom") / pl.col("preco_mes_anterior") - 1) * 100).round(2)
            )
            .alias("variacao_mom_pct")
        )
        .select(["produto", "uf", "preco_mes_anterior", "variacao_mom_pct"])
    )

    # Master join
    resultado = ultimos.join(base_2025, on=["produto", "uf"], how="left")
    resultado = resultado.join(fallback, on=["produto", "uf"], how="left")
    resultado = resultado.join(mom, on=["produto", "uf"], how="left")

    resultado = resultado.with_columns(
        pl.coalesce(
            pl.col("preco_referencia_2025"),
            pl.col("preco_fallback_12m"),
            pl.col("preco_mes_anterior"),
        ).alias("preco_referencia"),
        (
            pl.col("preco_referencia_2025").is_null()
            & pl.col("preco_fallback_12m").is_not_null()
        ).alias("usou_fallback_12m"),
        pl.when(pl.col("preco_referencia_2025").is_not_null())
        .then(pl.lit("rolling_12m"))
        .when(pl.col("preco_fallback_12m").is_not_null())
        .then(pl.lit("fallback_12m"))
        .when(pl.col("preco_mes_anterior").is_not_null())
        .then(pl.lit("mom"))
        .otherwise(pl.lit("insuficiente"))
        .alias("metodo_calculo"),
    )

    # Semáforo com thresholds condicionais
    resultado = resultado.with_columns(
        pl.when(pl.col("preco_referencia").is_null() | (pl.col("preco_referencia") == 0))
        .then(pl.lit("INSUFICIENTE"))
        .when(pl.col("preco_atual").is_null())
        .then(pl.lit("INSUFICIENTE"))
        .when(
            (pl.col("metodo_calculo") == "mom")
            & (pl.col("preco_atual") < pl.col("preco_mes_anterior") * 0.90)
        )
        .then(pl.lit("VERDE"))
        .when(
            (pl.col("metodo_calculo") == "mom")
            & (pl.col("preco_atual") > pl.col("preco_mes_anterior") * 1.10)
        )
        .then(pl.lit("VERMELHO"))
        .when(pl.col("metodo_calculo") == "mom")
        .then(pl.lit("AMARELO"))
        .when(
            pl.col("preco_atual") < pl.col("preco_referencia") * THRESHOLD_GREEN
        )
        .then(pl.lit("VERDE"))
        .when(
            pl.col("preco_atual") > pl.col("preco_referencia") * THRESHOLD_RED
        )
        .then(pl.lit("VERMELHO"))
        .otherwise(pl.lit("AMARELO"))
        .alias("status_cor"),
        pl.lit("municipio").alias("fonte"),
    )

    cols = [
        "produto",
        "uf",
        "preco_referencia",
        "preco_atual",
        "data_referencia_atual",
        "usou_fallback_12m",
        "status_cor",
        "fonte",
        "metodo_calculo",
        "variacao_mom_pct",
        "preco_mes_anterior",
    ]
    return resultado.select(cols)


def _salvar_json(df: pl.DataFrame, subdir: str, nome: str, output_dir: Path):
    """Salva DataFrame como JSON + parquet."""
    dir_path = output_dir / subdir
    dir_path.mkdir(parents=True, exist_ok=True)

    json_path = dir_path / f"{nome}.json"
    records = df.to_dicts()
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(records, f, ensure_ascii=False, indent=2, default=str)
    logger.info("  → %s", json_path.relative_to(output_dir.parent))

    parquet_path = dir_path / f"{nome}.parquet"
    df.write_parquet(str(parquet_path))
    logger.info("  → %s", parquet_path.relative_to(output_dir.parent))

    return len(records)


def _gerar_sql_insert(df: pl.DataFrame, tabela: str, schema: str, output_dir: Path) -> str:
    """Gera script SQL INSERT para os dados."""
    sql_dir = output_dir / "sql"
    sql_dir.mkdir(parents=True, exist_ok=True)

    if df.height == 0:
        path = sql_dir / f"{tabela}.sql"
        path.write_text(f"-- {schema}.{tabela}: sem dados\n")
        return str(path)

    cols = list(df.columns)
    col_list = ", ".join(cols)
    placeholders = ", ".join([f"%({c})s" for c in cols])
    sql_path = sql_dir / f"insert_{tabela}.sql"

    lines = [
        f"-- {schema}.{tabela} — {df.height} linhas",
        f"-- Gerado em {datetime.now().isoformat()}",
        "BEGIN;",
        f"INSERT INTO {schema}.{tabela} ({col_list}) VALUES",
    ]

    row_lines = []
    for row in df.to_dicts():
        vals = []
        for c in cols:
            v = row[c]
            if v is None:
                vals.append("NULL")
            elif isinstance(v, (int, float)):
                vals.append(str(v))
            elif isinstance(v, bool):
                vals.append("TRUE" if v else "FALSE")
            else:
                sanitized = str(v).replace("'", "''")
                vals.append(f"'{sanitized}'")
        row_lines.append(f"  ({', '.join(vals)})")

    lines.append(",\n".join(row_lines))
    lines.append("ON CONFLICT DO NOTHING;")
    lines.append("COMMIT;")
    lines.append("")

    content = "\n".join(lines)
    sql_path.write_text(content, encoding="utf-8")
    logger.info("  → %s", sql_path.relative_to(output_dir.parent))
    return str(sql_path)


def processar() -> dict[str, Any]:
    """Executa o ETL completo e salva em database/processed_data/."""
    inicio = datetime.now()
    logger.info("=" * 60)
    logger.info("ETL OFFLINE — Processando LISTA*.txt")
    logger.info("  Origem:  %s", LOCAL_DATA_DIR)
    logger.info("  Destino: %s", OUTPUT_DIR)
    logger.info("=" * 60)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    files = sorted(LOCAL_DATA_DIR.glob("LISTA*.txt"))
    if not files:
        logger.error("Nenhum LISTA*.txt encontrado em %s", LOCAL_DATA_DIR)
        return {"erro": "arquivos nao encontrados"}

    logger.info("\nArquivos encontrados: %d", len(files))

    all_raw: list[dict] = []
    all_cleaned: list[dict] = []
    all_categorized: list[dict] = []
    all_b2c: list[dict] = []
    total_linhas_lidas = 0
    total_linhas_limpas = 0
    total_b2c = 0
    total_b2b = 0
    categorias_gerais: dict[str, int] = {}
    arquivos_processados: list[dict] = []

    for f in files:
        nome = f.stem
        logger.info("\n--- %s ---", nome)

        # 01: Raw
        raw_text = f.read_bytes().decode("latin-1")
        df_raw = _ler_csv(raw_text)
        raw_count = df_raw.height
        total_linhas_lidas += raw_count
        _salvar_json(df_raw, "01_raw", nome, OUTPUT_DIR)
        all_raw.append({"arquivo": nome, "linhas": raw_count})

        # 02: Cleaned
        df_clean = _clean_file(f)
        cleaned_count = df_clean.height
        total_linhas_limpas += cleaned_count

        kept_cols = [
            "produto",
            "classificao_produto",
            "id_produto",
            "uf",
            "regiao",
            "ano",
            "mes",
            "preco_medio",
        ]

        df_out = df_clean.select([c for c in kept_cols if c in df_clean.columns])
        _salvar_json(df_out, "02_cleaned", nome, OUTPUT_DIR)
        all_cleaned.append({"arquivo": nome, "linhas": cleaned_count})

        # 03: Categorized
        df_cat = _categorizar(df_clean)
        cat_count = df_cat.height
        _salvar_json(df_cat, "03_categorized", nome, OUTPUT_DIR)
        all_categorized.append({"arquivo": nome, "linhas": cat_count})

        # 04: B2C only
        df_b2c = df_cat.filter(pl.col("categoria_b2c") == "ALIMENTO_VAREJO")
        df_b2b = df_cat.filter(pl.col("categoria_b2c") != "ALIMENTO_VAREJO")
        b2c_count = df_b2c.height
        b2b_count = df_b2b.height
        total_b2c += b2c_count
        total_b2b += b2b_count

        if b2c_count > 0:
            df_b2c_out = df_b2c.select(UF_COLUMNS + ["categoria_b2c"])
            _salvar_json(df_b2c_out, "04_b2c_only", nome, OUTPUT_DIR)
            all_b2c.extend(df_b2c_out.to_dicts())

        arquivos_processados.append(
            {
                "arquivo": nome,
                "raw": raw_count,
                "cleaned": cleaned_count,
                "b2c": b2c_count,
                "b2b": b2b_count,
                "rejeitados": raw_count - cleaned_count,
            }
        )

        # Contagem de categorias
        for cat_df in [df_cat]:
            for cat in cat_df["categoria_b2c"].unique().to_list():
                if cat:
                    categorias_gerais[cat] = categorias_gerais.get(cat, 0) + 1

        logger.info(
            "  RAW=%d → CLEANED=%d | B2C=%d B2B=%d | rejeitados=%d",
            raw_count,
            cleaned_count,
            b2c_count,
            b2b_count,
            raw_count - cleaned_count,
        )

    # 05: Aggregated (B2C mensal por produto+UF)
    logger.info("\n--- Agregado B2C ---")
    if all_b2c:
        df_all_b2c = pl.DataFrame(all_b2c)
        df_agg = (
            df_all_b2c.group_by(["produto", "uf", "ano", "mes"])
            .agg(pl.col("preco_medio").mean().alias("preco_medio"))
            .sort(["produto", "uf", "ano", "mes"])
        )
        agg_count = _salvar_json(df_agg, "05_aggregated", "b2c_aggregated", OUTPUT_DIR)
        logger.info("  Total linhas agregadas: %d", agg_count)

        # 06: Seasonality
        logger.info("\n--- Cálculo de Sazonalidade (Baseline 2025 + Fallback 12m) ---")
        df_saz = _calcular_sazonalidade(df_agg)
        saz_count = _salvar_json(df_saz, "06_seasonality", "sazonalidade", OUTPUT_DIR)

        status_count = df_saz.group_by("status_cor").agg(pl.len().alias("count")).sort("status_cor")

        logger.info("  Total produtos com sazonalidade: %d", saz_count)
        for row in status_count.to_dicts():
            logger.info("    %s: %d", row["status_cor"], row["count"])

        # SQL files
        _gerar_sql_insert(df_agg, "fact_precos_mensais", "staging", OUTPUT_DIR)
        _gerar_sql_insert(df_saz, "sazonalidade_produto", "mart", OUTPUT_DIR)

        # Consolidated Parquet
        parquet_path = OUTPUT_DIR / "consolidated.parquet"
        df_all_b2c.write_parquet(str(parquet_path))
        logger.info("\n  → %s", parquet_path.relative_to(OUTPUT_DIR.parent))
    else:
        df_all_b2c = pl.DataFrame()
        df_agg = pl.DataFrame()
        df_saz = pl.DataFrame()

    # Summary
    duracao = (datetime.now() - inicio).total_seconds()
    summary = {
        "metadados": {
            "gerado_em": inicio.isoformat(),
            "duracao_seg": round(duracao, 2),
            "origem": str(LOCAL_DATA_DIR),
            "destino": str(OUTPUT_DIR),
            "versao_pipeline": "Fase 8 — Radical Simplification",
        },
        "arquivos": arquivos_processados,
        "totais": {
            "arquivos": len(files),
            "linhas_lidas_raw": total_linhas_lidas,
            "linhas_limpas": total_linhas_limpas,
            "linhas_b2c": total_b2c,
            "linhas_b2b": total_b2b,
            "linhas_rejeitadas": total_linhas_lidas - total_linhas_limpas,
        },
        "categorias": categorias_gerais,
    }
    if df_all_b2c.height > 0 and df_saz.height > 0:
        summary["sazonalidade"] = {
            "total_produtos": df_saz.height,
            "por_status": {
                r["status_cor"]: r["count"]
                for r in df_saz.group_by("status_cor").agg(pl.len().alias("count")).to_dicts()
            },
            "usou_fallback": int(df_saz["usou_fallback_12m"].sum()),
            "produtos_verdes": df_saz.filter(pl.col("status_cor") == "VERDE")["produto"].to_list(),
            "produtos_vermelhos": df_saz.filter(pl.col("status_cor") == "VERMELHO")[
                "produto"
            ].to_list(),
        }
        summary["produtos_disponiveis"] = sorted(df_all_b2c["produto"].unique().to_list())
        summary["ufs_disponiveis"] = sorted(df_all_b2c["uf"].unique().to_list())

    summary_path = OUTPUT_DIR / "summary.json"
    with open(summary_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2, default=str)
    logger.info("\n  → %s", summary_path.relative_to(OUTPUT_DIR.parent))

    # ETL Report
    report = _gerar_relatorio(summary, arquivos_processados)
    report_path = OUTPUT_DIR / "ETL_REPORT.md"
    report_path.write_text(report, encoding="utf-8")
    logger.info("  → %s", report_path.relative_to(OUTPUT_DIR.parent))

    logger.info("\n" + "=" * 60)
    logger.info("ETL CONCLUÍDO — %.1fs", duracao)
    logger.info("  %d arquivos | %d linhas B2C | %d B2B", len(files), total_b2c, total_b2b)
    logger.info("  Saída: %s", OUTPUT_DIR)
    logger.info("=" * 60)

    return summary


def _gerar_relatorio(summary: dict, arquivos: list[dict]) -> str:
    """Gera relatório Markdown do ETL."""
    linhas = [
        "# Relatório ETL — Quero Comprar",
        "",
        f"**Gerado em:** {summary['metadados']['gerado_em']}",
        f"**Duração:** {summary['metadados']['duracao_seg']}s",
        f"**Versão:** {summary['metadados']['versao_pipeline']}",
        "",
        "## Totais Gerais",
        "",
        "| Indicador | Valor |",
        "|---|---|",
        f"| Arquivos processados | {summary['totais']['arquivos']} |",
        f"| Linhas lidas (RAW) | {summary['totais']['linhas_lidas_raw']:,} |",
        f"| Linhas limpas | {summary['totais']['linhas_limpas']:,} |",
        f"| Linhas ALIMENTO_VAREJO (B2C) | {summary['totais']['linhas_b2c']:,} |",
        f"| Linhas B2B (excluídas do app) | {summary['totais']['linhas_b2b']:,} |",
        f"| Linhas rejeitadas | {summary['totais']['linhas_rejeitadas']:,} |",
        "",
        "## Por Arquivo",
        "",
        "| Arquivo | RAW | Limpas | B2C | B2B | Rejeitadas |",
        "|---|---|---|---|---|---|",
    ]
    for a in arquivos:
        linhas.append(
            f"| {a['arquivo']} | {a['raw']} | {a['cleaned']} | {a['b2c']} | {a['b2b']} | {a['rejeitados']} |"
        )

    if "sazonalidade" in summary:
        saz = summary["sazonalidade"]
        linhas += [
            "",
            "## Sazonalidade Calculada",
            "",
            "| Indicador | Valor |",
            "|---|---|",
            f"| Produtos com sazonalidade | {saz['total_produtos']} |",
        ]
        for status, count in saz["por_status"].items():
            linhas.append(f"| {status} | {count} |")
        linhas.append(f"| Usaram fallback 12m | {saz['usou_fallback']} |")
        linhas += [
            "",
            "### Produtos 🟢 Baratos (Safra)",
            "",
        ]
        for p in saz.get("produtos_verdes", []):
            linhas.append(f"- {p}")
        linhas += [
            "",
            "### Produtos 🔴 Caros (Entressafra)",
            "",
        ]
        for p in saz.get("produtos_vermelhos", []):
            linhas.append(f"- {p}")

    if "categorias" in summary:
        linhas += [
            "",
            "## Categorias de Produto",
            "",
            "| Categoria | Total |",
            "|---|---|",
        ]
        for cat, count in sorted(summary["categorias"].items()):
            linhas.append(f"| {cat} | {count} |")

    if "produtos_disponiveis" in summary:
        linhas += [
            "",
            "## Produtos B2C Disponíveis",
            "",
        ]
        for p in summary["produtos_disponiveis"]:
            linhas.append(f"- {p}")

    if "ufs_disponiveis" in summary:
        linhas += [
            "",
            "## UFs Disponíveis",
            "",
            ", ".join(summary["ufs_disponiveis"]),
        ]

    linhas += [
        "",
        "---",
        "*Relatório gerado automaticamente pelo pipeline ETL offline*",
        "",
    ]
    return "\n".join(linhas)


def main() -> NoReturn:
    try:
        processar()
        sys.exit(0)
    except Exception:
        logger.exception("ETL abortado — erro crítico")
        sys.exit(1)


if __name__ == "__main__":
    main()
