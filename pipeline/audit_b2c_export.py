#!/usr/bin/env python3
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

os.environ["PYTHONIOENCODING"] = "utf-8"

import polars as pl

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = PROJECT_ROOT / "reports"
DOT_ENV = PROJECT_ROOT / ".env"

COL_EXPORT = {
    "id_produto": "ID Produto",
    "categoria": "Categoria",
    "produto": "Nome do Produto",
    "uf": "UF",
    "municipio": "Municipio",
    "data_referencia_atual": "Mes/Ano Referencia",
    "preco_atual": "Preco Atual (R$)",
    "preco_referencia": "Preco Referencia (Baseline - R$)",
    "divergencia_pct": "Divergencia Matematica (%)",
    "status_cor_db": "Status do Semafaro (Cor no DB)",
    "tendencia_futura": "Previsao IA (Tendencia Futura)",
    "usou_fallback_12m": "Usa Dado Fallback?",
    "preco_estimado": "Usa Dado Interpolado?",
}

B2B_CLASSIFICACOES = {"INSUMO_AGRICOLA", "MAQUINARIO_FERRAMENTA", "SERVICO_LOGISTICA"}
TRINDADE = {"VERDE", "AMARELO", "VERMELHO"}
TRINDADE_ML = {"ALTA", "QUEDA", "ESTAVEL", None}
OBRIGATORIAS = {"id_produto", "produto", "categoria", "uf", "data_referencia_atual"}
LIMIAR_VERDE = 0.85
LIMIAR_VERMELHO = 1.15


def _pg_url() -> str:
    url = os.environ.get("DATABASE_URL")
    if url:
        return url
    if DOT_ENV.exists():
        for line in DOT_ENV.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("DATABASE_URL="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    print("ERROR: DATABASE_URL nao encontrada no .env nem nas variaveis de ambiente.")
    sys.exit(1)


def _conectar() -> pl.DataFrame:
    import asyncio
    import asyncpg

    url = _pg_url()

    async def go() -> list[dict]:
        conn = await asyncpg.connect(url)
        try:
            rows = await conn.fetch("""
                SELECT
                    id_sazonalidade, id_produto, produto, uf, municipio,
                    ano, mes, data_referencia_atual,
                    preco_referencia, preco_atual,
                    preco_estimado, usou_fallback_12m,
                    status_cor, categoria, fonte,
                    tendencia_futura,
                    classificao_produto
                FROM mart.vw_api_produtos_sazonalidade
            """)
            return [dict(r) for r in rows]
        finally:
            await conn.close()

    data = asyncio.run(go())
    if not data:
        print("AVISO CRITICO: mart.vw_api_produtos_sazonalidade esta VAZIA.")
        print("Nada a auditar. Encerrando.")
        sys.exit(1)

    df = pl.from_dicts(data, infer_schema_length=None)
    print(f"[OK] Lidas {len(df):_} linhas da MV.")
    return df


def _auditar(df: pl.DataFrame) -> tuple[pl.DataFrame, int]:
    fatal = 0
    total = len(df)

    print()
    print("=" * 60)
    print("  AUDITORIA PADRAO OURO — SANITY CHECKS")
    print("=" * 60)

    # ── 1. INTEGRIDADE ESTRUTURAL ───────────────────────────────────────────
    print()
    print("--- [1] INTEGRIDADE ESTRUTURAL ---")

    nulos = df.filter(pl.any_horizontal(pl.col(c).is_null() for c in OBRIGATORIAS))
    if len(nulos):
        fatal += 1
        print(f"  [FATAL] {len(nulos):_} linhas com nulos em colunas obrigatorias")
        for c in OBRIGATORIAS:
            qtd = nulos.filter(pl.col(c).is_null()).height
            if qtd:
                print(f"         {c}: {qtd} nulos")
    else:
        print("  [OK] Nenhum valor nulo em colunas obrigatorias.")

    corrupt_re = re.compile(r"[\uFFFD\x00]")
    corrupt_texto = df.filter(
        pl.col("produto").str.contains(f"(?u){corrupt_re.pattern}")
        | pl.col("municipio").str.contains(f"(?u){corrupt_re.pattern}")
    )
    if len(corrupt_texto):
        fatal += 1
        print(f"  [FATAL] {len(corrupt_texto):_} linhas com caracteres corrompidos em produto/municipio")
    else:
        print("  [OK] Nenhum caractere corrompido detectado.")

    # ── 2. PROVA REAL MATEMÁTICA ────────────────────────────────────────────
    print()
    print("--- [2] PROVA REAL MATEMATICA ---")

    df = df.with_columns(
        (pl.col("preco_atual") / pl.col("preco_referencia")).alias("ratio_calculado")
    )

    df = df.with_columns(
        pl.when(
            pl.col("preco_referencia").is_null()
            | (pl.col("preco_referencia") <= 0)
            | pl.col("preco_atual").is_null()
        )
        .then(pl.lit(None))
        .when(pl.col("preco_atual") < pl.col("preco_referencia") * LIMIAR_VERDE)
        .then(pl.lit("VERDE"))
        .when(pl.col("preco_atual") > pl.col("preco_referencia") * LIMIAR_VERMELHO)
        .then(pl.lit("VERMELHO"))
        .otherwise(pl.lit("AMARELO"))
        .alias("status_cor_calculado")
    )

    df = df.with_columns(
        pl.when(
            pl.col("preco_referencia").is_null()
            | (pl.col("preco_referencia") <= 0)
            | pl.col("preco_atual").is_null()
        )
        .then(pl.lit(None))
        .otherwise(((pl.col("preco_atual") / pl.col("preco_referencia")) - 1) * 100)
        .alias("divergencia_pct")
    )

    divergencias = df.filter(
        pl.col("status_cor").is_not_null()
        & pl.col("status_cor_calculado").is_not_null()
        & (pl.col("status_cor") != pl.col("status_cor_calculado"))
    )
    qtd_div = len(divergencias)
    if qtd_div:
        fatal += 1
        print(f"  [FATAL] INCONSISTENCIA MATEMATICA: {qtd_div:_} divergencias")
        for r in divergencias.head(10).iter_rows(named=True):
            print(
                f"         id_produto={r['id_produto']} "
                f"uf={r['uf']} "
                f"mes={r['data_referencia_atual']} "
                f"DB={r['status_cor']} "
                f"calc={r['status_cor_calculado']} "
                f"ratio={r['ratio_calculado']:.4f}"
            )
        if qtd_div > 10:
            print(f"         ... e mais {qtd_div - 10} divergencias (total {qtd_div})")
    else:
        print("  [OK] Prova Real Matematica: 100% consistente.")

    # ── 3. LEAKAGE B2B ──────────────────────────────────────────────────────
    print()
    print("--- [3] LEAKAGE B2B ---")

    leak = df.filter(pl.col("classificao_produto").is_in(B2B_CLASSIFICACOES))
    if len(leak):
        fatal += 1
        for r in leak.unique("classificao_produto").iter_rows(named=True):
            print(
                f"  [FATAL] LEAKAGE B2B: {len(leak):_} linhas com "
                f"classificacao={r['classificao_produto']}"
            )
    else:
        print("  [OK] Nenhum vazamento B2B (classificacao_produto limpa).")

    # ── 4. GHOST PRICING ────────────────────────────────────────────────────
    print()
    print("--- [4] GHOST PRICING ---")

    ghost = df.filter(
        pl.col("preco_atual").is_null() | (pl.col("preco_atual") <= 0)
    )
    if len(ghost):
        fatal += 1
        print(f"  [FATAL] GHOST PRICING: {len(ghost):_} linhas com preco_atual <= 0 ou nulo")
    else:
        print("  [OK] Nenhum preco fantasma (ghost pricing).")

    ref_zero = df.filter(
        pl.col("preco_referencia").is_null() | (pl.col("preco_referencia") <= 0)
    )
    if len(ref_zero):
        fatal += 1
        print(f"  [FATAL] BASELINE ZERADA: {len(ref_zero):_} linhas com preco_referencia <= 0 ou nulo")
    else:
        print("  [OK] Nenhum preco_referencia zerado.")

    # ── 5. TRINDADE E ML CONTRACT ───────────────────────────────────────────
    print()
    print("--- [5] TRINDADE E CONTRATO ML ---")

    corrupt = df.filter(~pl.col("status_cor").is_in(TRINDADE))
    if len(corrupt):
        fatal += 1
        print(f"  [FATAL] TRINDADE CORROMPIDA: {len(corrupt):_} linhas status_cor invalido")
    else:
        print("  [OK] Trindade estrita respeitada.")

    ml_invalido = df.filter(
        pl.col("tendencia_futura").is_not_null()
        & ~pl.col("tendencia_futura").is_in({"ALTA", "QUEDA", "ESTAVEL"})
    )
    if len(ml_invalido):
        fatal += 1
        print(f"  [FATAL] ML CONTRACT VIOLATION: {len(ml_invalido):_} tendencias invalidas")
    else:
        print("  [OK] Contrato ML respeitado (apenas ALTA/QUEDA/ESTAVEL/NULL).")

    # ── 6. PADRAO OURO STATS ────────────────────────────────────────────────
    print()
    print("--- [6] PADRAO OURO — DATA QUALITY SCORE ---")

    organicos = df.filter(
        (pl.col("usou_fallback_12m") == False)
        & (pl.col("preco_estimado") == False)
    )
    fallback = df.filter(pl.col("usou_fallback_12m") == True)
    interpolado = df.filter(pl.col("preco_estimado") == True)
    artificial = df.filter(
        (pl.col("usou_fallback_12m") == True)
        | (pl.col("preco_estimado") == True)
    )
    com_ml = df.filter(pl.col("tendencia_futura").is_not_null())

    print(f"  TOTAL REGISTROS:              {total:_}")
    print(f"  DADOS 100% ORGANICOS:         {len(organicos):_} ({organicos.shape[0]/total*100:.1f}%)")
    print(f"  DADOS ARTIFICIAIS (total):    {len(artificial):_} ({artificial.shape[0]/total*100:.1f}%)")
    print(f"    usou_fallback_12m:          {len(fallback):_} ({len(fallback)/total*100:.1f}%)")
    print(f"    preco_estimado:             {len(interpolado):_} ({len(interpolado)/total*100:.1f}%)")
    print(f"  COBERTURA ML (tendencia):    {len(com_ml):_} ({com_ml.shape[0]/total*100:.1f}%)")
    if len(com_ml):
        dist_ml = (
            com_ml.group_by("tendencia_futura")
            .agg(pl.len().alias("qtd"))
            .sort("qtd", descending=True)
        )
        for r in dist_ml.iter_rows(named=True):
            pct = r["qtd"] / len(com_ml) * 100
            print(f"    {r['tendencia_futura']}: {r['qtd']:_} ({pct:.1f}%)")

    dist = (
        df.group_by("status_cor")
        .agg(pl.len().alias("qtd"))
        .sort("qtd", descending=True)
    )
    print("  DISTRIBUICAO STATUS:")
    for r in dist.iter_rows(named=True):
        pct = r["qtd"] / total * 100
        print(f"    {r['status_cor']}: {r['qtd']:_} ({pct:.1f}%)")

    if fatal:
        print(f"\n[FATAL] {fatal} auditoria(s) reprovaram. Score de divergencia > 0%. Abortando.")
    else:
        divergencia_pct_global = df.filter(
            pl.col("divergencia_pct").is_not_null()
        ).select(
            pl.col("divergencia_pct").abs().mean().alias("media")
        ).item()
        print(f"\n[OK] Auditoria 100% limpa. Divergencia media global: {divergencia_pct_global:.4f}%")
        print(f"[OK] Padrao Ouro ATINGIDO. Chancelando exportacao.")

    return df, fatal


def _exportar(df: pl.DataFrame, output: Path) -> Path:
    out = df.rename({"status_cor": "status_cor_db"})

    export_cols = [c for c in COL_EXPORT if c in out.columns]
    rename_map = {k: COL_EXPORT[k] for k in export_cols}

    out = out.select(export_cols).rename(rename_map)

    for col in out.columns:
        if out[col].dtype == pl.Boolean:
            out = out.with_columns(
                pl.col(col).map_elements(
                    lambda x: "Sim" if x else "Nao", return_dtype=pl.Utf8,
                )
            )
        elif col == "Divergencia Matematica (%)":
            out = out.with_columns(
                pl.col(col).map_elements(
                    lambda x: f"{x:.2f}" if x is not None else "N/A",
                    return_dtype=pl.Utf8,
                )
            )

    output.parent.mkdir(parents=True, exist_ok=True)
    out.write_csv(output)
    print(f"[OK] Relatorio salvo: {output}  ({len(out):_} linhas)")
    return output


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(
        description="Auditoria B2C Padrao Ouro — Sanity Check Matematico + Export CSV"
    )
    parser.add_argument(
        "--output", "-o", default=None,
        help="Caminho do CSV (default: reports/auditoria_padrao_ouro_b2c.csv)",
    )
    parser.add_argument(
        "--uf", default=None, help="Filtrar por UF (ex: SP)",
    )
    args = parser.parse_args()

    output = (
        Path(args.output)
        if args.output
        else DEFAULT_OUTPUT / "auditoria_padrao_ouro_b2c.csv"
    )

    print("=" * 60)
    print("  AUDITORIA B2C — PADRAO OURO")
    print("=" * 60)

    df = _conectar()

    if args.uf:
        antes = len(df)
        df = df.filter(pl.col("uf") == args.uf.upper())
        print(f"[OK] Filtrado UF={args.uf.upper()}: {antes:_} -> {len(df):_} linhas")

    df, fatal = _auditar(df)
    if fatal:
        sys.exit(1)

    print()
    print("--- EXPORTANDO CSV ---")
    _exportar(df, output)


if __name__ == "__main__":
    main()
