"""Exporta checklist CSV de imagens pendentes do banco.

Gera checklist_imagens.csv com todos os produtos ALIMENTO_VAREJO
para controle manual de curadoria de imagens.

Usage:
    python backend/export_checklist_imagens.py
    python backend/export_checklist_imagens.py --db-url postgresql://user:pass@host/db
    python backend/export_checklist_imagens.py --output checklist.csv
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import sys

import asyncpg

if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())


async def main() -> None:
    parser = argparse.ArgumentParser(description="Exporta checklist de imagens pendentes")
    parser.add_argument(
        "--db-url",
        default="postgresql://postgres:postgres@localhost:5432/quero_comprar",
        help="PostgreSQL connection URI",
    )
    parser.add_argument(
        "--output",
        "-o",
        default="checklist_imagens.csv",
        help="Caminho do arquivo CSV de saída",
    )
    args = parser.parse_args()

    conn = await asyncpg.connect(args.db_url)
    try:
        rows = await conn.fetch("""
            SELECT
                p.id_produto,
                p.nome_produto,
                COALESCE(p.status_imagem, 'PENDENTE') AS status
            FROM staging.dim_produto p
            WHERE p.categoria_b2c = 'ALIMENTO_VAREJO'
            ORDER BY p.nome_produto
        """)

        with open(args.output, "w", newline="", encoding="utf-8-sig") as f:
            writer = csv.writer(f)
            writer.writerow(["ID_Produto", "Nome_Produto", "Status"])
            for r in rows:
                writer.writerow([r["id_produto"], r["nome_produto"], r["status"]])

        print(f"Exportado: {len(rows)} produtos para {args.output}")
    except Exception as e:
        print(f"Erro: {e}")
        sys.exit(1)
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
