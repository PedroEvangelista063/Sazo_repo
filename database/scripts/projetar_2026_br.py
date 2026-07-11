"""
projetar_2026_br.py -- Projecao Nacional "BR" para 2026
=========================================================
Para meses de 2026 sem dado real em nenhuma UF, projeta a partir
do baseline nacional (uf=BR) em sazonalidade_produto com is_forecast=TRUE.

Nota: O MODE aggregation via API cobre todos os meses automaticamente.
Este script e um fallback para meses onde 0 UFs tem dados.

Execucao: python -m database.scripts.projetar_2026_br
"""

import asyncio
import logging
from datetime import datetime

import asyncpg

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("projetar_2026_br")

DSN = "postgresql://postgres:postgres@localhost:5432/quero_comprar"
MESES_2026 = list(range(1, 13))


async def projetar_2026_br(conn: asyncpg.Connection) -> int:
    br_id = await conn.fetchval(
        "SELECT id_localidade FROM staging.dim_localidade WHERE uf = 'BR' AND municipio_id = '0'"
    )
    if br_id is None:
        logger.error("dim_localidade BR nao encontrada.")
        return 0

    hoje = datetime.now()
    total = 0

    for mes in MESES_2026:
        data_alvo = f"2026-{mes:02d}"

        if mes > hoje.month:
            break

        existentes = await conn.fetchval("""
            SELECT COUNT(*) FROM mart.sazonalidade_produto
            WHERE data_referencia_atual = $1
              AND id_localidade = $2
              AND NOT is_forecast
        """, data_alvo, br_id)

        if existentes > 0:
            continue

        rows = await conn.fetch("""
            SELECT b.id_produto, b.status_cor_mode, b.confianca
            FROM mart.sazonalidade_baseline b
            WHERE b.id_localidade = $1 AND b.mes = $2
        """, br_id, mes)

        if not rows:
            logger.info("  Mes %02d: sem baseline BR — pulando.", mes)
            continue

        batch = []
        for r in rows:
            ultimo_preco = await conn.fetchval("""
                SELECT s.preco_atual FROM mart.sazonalidade_produto s
                WHERE s.id_produto = $1 AND s.preco_atual IS NOT NULL
                ORDER BY s.data_referencia_atual DESC LIMIT 1
            """, r["id_produto"])

            if ultimo_preco is None:
                continue

            batch.append((
                r["id_produto"], br_id,
                ultimo_preco, ultimo_preco,
                data_alvo, r["status_cor_mode"],
            ))

        if not batch:
            continue

        values = []
        params = []
        idx = 1
        for id_prod, id_loc, preco_ref, preco_at, data_ref, status in batch:
            values.append(
                f"(${idx}, ${idx+1}, ${idx+2}::NUMERIC(14,4), ${idx+3}::NUMERIC(14,4), "
                f"${idx+4}, ${idx+5}::TEXT, true)"
            )
            params.extend([id_prod, id_loc, preco_ref, preco_at, data_ref, status])
            idx += 6

        await conn.execute(f"""
            INSERT INTO mart.sazonalidade_produto
                (id_produto, id_localidade, preco_referencia, preco_atual,
                 data_referencia_atual, status_cor, is_forecast)
            VALUES {','.join(values)}
            ON CONFLICT (id_produto, id_localidade, data_referencia_atual)
            DO NOTHING
        """, *params)

        total += len(batch)
        logger.info("  Mes %02d: %d produtos projetados (BR forecast).", mes, len(batch))

    logger.info("Projecao BR concluida: %d linhas.", total)
    return total


async def main():
    logger.info("=== Projecao Nacional BR 2026 ===")
    conn = await asyncpg.connect(DSN)
    try:
        total = await projetar_2026_br(conn)
        logger.info("Total: %d linhas", total)
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
