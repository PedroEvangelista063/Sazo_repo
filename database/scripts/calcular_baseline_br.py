"""
calcular_baseline_br.py — Agregacao Nacional "BR" do Baseline
===============================================================
Para cada (id_produto, mes), calcula a moda do status_cor_mode entre
todas as UFs disponiveis no sazonalidade_baseline.
Confianca = media das confiancas das UFs participantes.
Insere com id_localidade da entrada 'BR' em dim_localidade.

Execucao: python -m database.scripts.calcular_baseline_br
"""

import asyncio
import logging

import asyncpg

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("calcular_baseline_br")

DSN = "postgresql://postgres:postgres@localhost:5432/quero_comprar"


async def calcular_baseline_br(conn: asyncpg.Connection) -> int:
    br_id = await conn.fetchval(
        "SELECT id_localidade FROM staging.dim_localidade WHERE uf = 'BR' AND municipio_id = '0'"
    )
    if br_id is None:
        logger.error("dim_localidade com uf='BR' nao encontrada — execute o INSERT primeiro.")
        return 0

    logger.info("Agregando baseline nacional (BR) — id_localidade=%s...", br_id)

    result = await conn.execute("""
        INSERT INTO mart.sazonalidade_baseline
            (id_produto, id_localidade, mes, status_cor_mode, confianca, fonte)
        SELECT
            b.id_produto,
            $1::INTEGER                                 AS id_localidade,
            b.mes,
            MODE() WITHIN GROUP (ORDER BY b.status_cor_mode) AS status_cor_mode,
            ROUND(AVG(b.confianca), 2)                  AS confianca,
            'BASELINE_NACIONAL'                         AS fonte
        FROM mart.sazonalidade_baseline b
        JOIN staging.dim_localidade l ON l.id_localidade = b.id_localidade
        WHERE l.uf <> 'BR'
        GROUP BY b.id_produto, b.mes
        ON CONFLICT (id_produto, id_localidade, mes)
        DO UPDATE SET
            status_cor_mode = EXCLUDED.status_cor_mode,
            confianca       = EXCLUDED.confianca,
            fonte           = 'BASELINE_NACIONAL',
            atualizado_em   = NOW()
    """, br_id)
    inserted = int(result.split()[-1]) if result else 0
    logger.info("Baseline BR calculado: %d linhas inseridas/atualizadas.", inserted)
    return inserted


async def main():
    logger.info("=== Calculo do Baseline Nacional (BR) ===")
    conn = await asyncpg.connect(DSN)
    try:
        total = await calcular_baseline_br(conn)
        logger.info("Total: %d linhas em mart.sazonalidade_baseline (uf=BR)", total)
    finally:
        await conn.close()
    logger.info("Done.")


if __name__ == "__main__":
    asyncio.run(main())
