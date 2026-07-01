from __future__ import annotations

import csv
import logging
import os
import sys
from pathlib import Path
from typing import Any

import polars as pl

try:
    import psycopg2
except ImportError:
    psycopg2 = None

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("audit_cobertura")

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CSV_PATH = PROJECT_ROOT / "dados_sazonliza_dados_bruto" / "Planilha sem título - sazonalidade_produtos.csv"
DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/quero_comprar",
)

# CSV -> DB category mapping
CATEGORIA_MAP: dict[str, int] = {
    "FRUTAS": 1, "LEGUMES": 2, "VERDURAS": 3,
    "FLORES": 4, "PESCADOS": 5, "DIVERSOS": 9,
}


def ler_csv_master() -> pl.DataFrame:
    df = pl.read_csv(CSV_PATH, encoding="utf-8-sig", null_values=["", "-", "--"])
    cols = df.columns
    nome_col = next((c for c in cols if "produto" in c.lower()), cols[0])
    cat_col = next((c for c in cols if "categoria" in c.lower()), None)
    if cat_col:
        df = df.with_columns(pl.col(cat_col).str.strip_chars().alias("categoria"))
        df = df.filter(~pl.col("categoria").str.starts_with("---"))
    return df


def consultar_db() -> dict[str, Any]:
    if psycopg2 is None:
        logger.error("psycopg2 nao instalado - pulando consultas ao banco")
        return {}

    conn = psycopg2.connect(DATABASE_URL)
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT dp.nome_produto, dp.id_produto, dp.categoria_b2c,
                       dp.status_fonte, dp.status_imagem,
                       dc.nome_categoria
                FROM staging.dim_produto dp
                LEFT JOIN staging.dim_categoria dc ON dc.id_categoria = dp.id_categoria
                ORDER BY dp.nome_produto
            """)
            rows = cur.fetchall()
            db_produtos = {r[0]: {"id": r[1], "cat_b2c": r[2], "fonte": r[3], "img": r[4], "cat": r[5]} for r in rows}

            cur.execute("SELECT COUNT(DISTINCT id_produto) FROM staging.fact_precos_mensais")
            total_com_preco = cur.fetchone()[0]

            cur.execute("SELECT COUNT(DISTINCT id_produto) FROM mart.sazonalidade_produto WHERE status_cor != 'INSUFICIENTE'")
            total_com_saz = cur.fetchone()[0]

            cur.execute("""
                SELECT dp.nome_produto
                FROM staging.fact_precos_mensais f
                JOIN staging.dim_produto dp ON dp.id_produto = f.id_produto
                GROUP BY dp.nome_produto
                ORDER BY dp.nome_produto
            """)
            produtos_com_preco = {r[0] for r in cur.fetchall()}

            cur.execute("""
                SELECT dp.nome_produto
                FROM mart.sazonalidade_produto s
                JOIN staging.dim_produto dp ON dp.id_produto = s.id_produto
                WHERE s.status_cor != 'INSUFICIENTE'
                GROUP BY dp.nome_produto
            """)
            produtos_com_saz = {r[0] for r in cur.fetchall()}

            cur.execute("SELECT COUNT(*) FROM staging.dim_produto")
            total_dim = cur.fetchone()[0]

            cur.execute("SELECT COUNT(*) FROM staging.dim_produto WHERE categoria_b2c = 'ALIMENTO_VAREJO'")
            total_varejo = cur.fetchone()[0]

        return {
            "produtos": db_produtos,
            "total_dim": total_dim,
            "total_varejo": total_varejo,
            "total_com_preco": total_com_preco,
            "total_com_saz": total_com_saz,
            "produtos_com_preco": produtos_com_preco,
            "produtos_com_saz": produtos_com_saz,
        }
    finally:
        conn.close()


def audit() -> int:
    logger.info("=" * 70)
    logger.info("AUDITORIA DE COBERTURA - CSV Master vs Database")
    logger.info("=" * 70)

    # 1. Load CSV
    logger.info("\n[1] Lendo CSV master...")
    if not CSV_PATH.exists():
        logger.error("CSV nao encontrado: %s", CSV_PATH)
        return 1

    df_csv = ler_csv_master()
    cols = df_csv.columns
    nome_col = next((c for c in cols if "produto" in c.lower()), cols[0])
    cat_col = next((c for c in cols if "categoria" in c.lower()), None)

    csv_produtos: list[dict] = []
    for row in df_csv.iter_rows(named=True):
        nome = (row.get(nome_col) or "").strip()
        cat = (row.get(cat_col) or "").strip() if cat_col else ""
        if nome:
            csv_produtos.append({"nome": nome, "categoria": cat})

    logger.info("  CSV: %d produtos carregados", len(csv_produtos))

    # 2. Query DB
    logger.info("\n[2] Consultando banco de dados...")
    db_data = consultar_db()
    if not db_data:
        logger.warning("  Banco offline - auditando apenas CSV")
        db_produtos: dict = {}
        produtos_com_preco: set = set()
        produtos_com_saz: set = set()
    else:
        db_produtos = db_data["produtos"]
        produtos_com_preco = db_data["produtos_com_preco"]
        produtos_com_saz = db_data["produtos_com_saz"]
        logger.info("  dim_produto: %d total | %d ALIMENTO_VAREJO", db_data["total_dim"], db_data["total_varejo"])
        logger.info("  Com preco na fact: %d | Com sazonalidade: %d", db_data["total_com_preco"], db_data["total_com_saz"])

    # 3. Cross-reference
    logger.info("\n[3] Cruzando CSV vs Database...")
    presentes_db = 0
    ausentes_db: list[str] = []
    com_preco = 0
    com_saz = 0
    sem_preco: list[str] = []
    sem_saz: list[str] = []
    por_categoria: dict[str, dict] = {}

    for p in csv_produtos:
        nome = p["nome"]
        cat = p["categoria"] or "SEM_CATEGORIA"
        if cat not in por_categoria:
            por_categoria[cat] = {"total": 0, "db": 0, "preco": 0, "saz": 0, "ausentes": []}

        por_categoria[cat]["total"] += 1

        if nome in db_produtos:
            por_categoria[cat]["db"] += 1
            presentes_db += 1
            if nome in produtos_com_preco:
                por_categoria[cat]["preco"] += 1
                com_preco += 1
            else:
                sem_preco.append(nome)
            if nome in produtos_com_saz:
                por_categoria[cat]["saz"] += 1
                com_saz += 1
            else:
                sem_saz.append(nome)
        else:
            ausentes_db.append(nome)
            por_categoria[cat]["ausentes"].append(nome)

    # 4. Report
    logger.info("\n[4] RELATORIO DE COBERTURA")
    logger.info("=" * 70)

    total_csv = len(csv_produtos)
    logger.info("")
    logger.info("Resumo Geral:")
    logger.info("  Produtos no CSV:           %d", total_csv)
    logger.info("  Presentes no dim_produto:  %d (%.1f%%)", presentes_db, presentes_db / total_csv * 100 if total_csv else 0)
    logger.info("  Ausentes do dim_produto:   %d (%.1f%%)", len(ausentes_db), len(ausentes_db) / total_csv * 100 if total_csv else 0)
    logger.info("  Com preco na fact table:   %d (%.1f%%)", com_preco, com_preco / total_csv * 100 if total_csv else 0)
    logger.info("  Com sazonalidade:          %d (%.1f%%)", com_saz, com_saz / total_csv * 100 if total_csv else 0)

    logger.info("")
    logger.info("Por Categoria:")
    logger.info(f"{'Categoria':20s} {'Total':>6s} {'DB':>5s} {'Preco':>6s} {'Saz':>5s} {'Cobertura':>10s}")
    logger.info("-" * 52)
    for cat in sorted(por_categoria.keys()):
        d = por_categoria[cat]
        cov = d["db"] / d["total"] * 100 if d["total"] else 0
        logger.info(f"{cat:20s} {d['total']:>6d} {d['db']:>5d} {d['preco']:>6d} {d['saz']:>5d} {cov:>9.1f}%")

    if ausentes_db:
        logger.info("")
        logger.info("AUSENTES do dim_produto (%d items):", len(ausentes_db))
        for cat in sorted(por_categoria.keys()):
            if por_categoria[cat]["ausentes"]:
                logger.info("  [%s]", cat)
                for nome in por_categoria[cat]["ausentes"]:
                    logger.info("    - %s", nome)

    if sem_preco:
        logger.info("")
        logger.info("SEM PREÇO na fact table (%d items):", len(sem_preco))
        for nome in sem_preco[:30]:
            logger.info("    - %s", nome)
        if len(sem_preco) > 30:
            logger.info("    ... e mais %d", len(sem_preco) - 30)

    if sem_saz:
        logger.info("")
        logger.info("SEM SAZONALIDADE (%d items):", len(sem_saz))
        for nome in sem_saz[:30]:
            logger.info("    - %s", nome)
        if len(sem_saz) > 30:
            logger.info("    ... e mais %d", len(sem_saz) - 30)

    logger.info("")
    logger.info("=" * 70)
    qualidade = (com_saz / total_csv * 100) if total_csv else 0
    logger.info("QUALIDADE GERAL: %.1f%% (produtos CSV com sazonalidade no banco)", qualidade)
    logger.info("META: 99.9%%")
    logger.info("GAP:  %.1f%%", max(0, 99.9 - qualidade))
    logger.info("=" * 70)

    return 0


def main():
    try:
        sys.exit(audit())
    except Exception:
        logger.exception("Auditoria abortada")
        sys.exit(1)


if __name__ == "__main__":
    main()
