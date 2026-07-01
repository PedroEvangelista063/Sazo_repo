from __future__ import annotations

import csv
import os
import sys
from pathlib import Path

import psycopg2

CSV_PATH = (
    Path(__file__).resolve().parent.parent
    / "docs"
    / "Planilha sem t\u00edtulo - sazonalidade_produtos.csv"
)
DATABASE_URL: str = os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/quero_comprar",
)

CATEGORIA_MAP: dict[str, int] = {
    "FRUTAS": 1,
    "LEGUMES": 2,
    "VERDURAS": 3,
    "FLORES": 4,
    "PESCADOS": 5,
    "DIVERSOS": 9,
}


def main() -> None:
    if not CSV_PATH.exists():
        print(f"CSV not found: {CSV_PATH}")
        sys.exit(1)

    rows: list[tuple[str, int, str]] = []
    with open(CSV_PATH, encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            categoria = (row.get("Categoria") or row.get("\ufeffCategoria") or "").strip()
            produto = (row.get("Produto") or "").strip()
            if not categoria or not produto or categoria.startswith("---"):
                continue
            id_cat = CATEGORIA_MAP.get(categoria)
            if id_cat is None:
                print(f"  WARN: unknown category '{categoria}' for '{produto}' — skipping")
                continue
            rows.append((produto, id_cat, categoria))

    print(f"Master list: {len(rows)} products loaded from CSV")
    print(f"  FRUTAS:    {sum(1 for r in rows if r[2] == 'FRUTAS')}")
    print(f"  LEGUMES:   {sum(1 for r in rows if r[2] == 'LEGUMES')}")
    print(f"  VERDURAS:  {sum(1 for r in rows if r[2] == 'VERDURAS')}")
    print(f"  FLORES:    {sum(1 for r in rows if r[2] == 'FLORES')}")
    print(f"  PESCADOS:  {sum(1 for r in rows if r[2] == 'PESCADOS')}")
    print(f"  DIVERSOS:  {sum(1 for r in rows if r[2] == 'DIVERSOS')}")

    conn = psycopg2.connect(DATABASE_URL)
    try:
        inserted = 0
        updated = 0
        with conn.cursor() as cur:
            for nome_produto, id_categoria, csv_categoria in rows:
                cur.execute(
                    "SELECT id_produto FROM staging.dim_produto WHERE nome_produto = %s",
                    (nome_produto,),
                )
                existing = cur.fetchone()

                if existing:
                    cur.execute(
                        """
                        UPDATE staging.dim_produto
                        SET id_categoria = %s,
                            categoria_b2c = 'ALIMENTO_VAREJO',
                            status_imagem = COALESCE(status_imagem, 'PENDENTE')
                        WHERE id_produto = %s
                        """,
                        (id_categoria, existing[0]),
                    )
                    updated += 1
                else:
                    cur.execute(
                        """
                        INSERT INTO staging.dim_produto
                            (nome_produto, id_categoria, categoria_b2c, status_imagem)
                        VALUES (%s, %s, 'ALIMENTO_VAREJO', 'PENDENTE')
                        """,
                        (nome_produto, id_categoria),
                    )
                    inserted += 1

        conn.commit()
        print(f"\nDone: {inserted} inserted, {updated} updated")

        with conn.cursor() as cur:
            cur.execute("""
                SELECT c.nome_categoria, count(p.id_produto) as cnt
                FROM staging.dim_categoria c
                LEFT JOIN staging.dim_produto p ON p.id_categoria = c.id_categoria
                GROUP BY c.nome_categoria, c.id_categoria
                ORDER BY c.id_categoria
            """)
            print(f"\n{'Categoria':30s} {'Qtd':>6s}")
            print("-" * 36)
            for row in cur.fetchall():
                print(f"{row[0]:30s} {row[1]:>6d}")

            cur.execute(
                "SELECT count(*) FROM staging.dim_produto WHERE categoria_b2c = 'ALIMENTO_VAREJO'",
            )
            print(f"\nTotal ALIMENTO_VAREJO (categoria_b2c): {cur.fetchone()[0]}")

            cur.execute("SELECT count(*) FROM staging.dim_produto")
            print(f"Total dim_produto (all): {cur.fetchone()[0]}")

    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
