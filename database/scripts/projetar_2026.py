"""
projetar_2026.py — Fase 2c: Projeção de 2026 (Espelhamento Inteligente)
=========================================================================
Para cada mês de 2026 que tenha ZERO registros reais (is_forecast=false)
no mart.sazonalidade_produto, insere dados do baseline histórico
marcando com is_forecast=true.

Regra de Ouro: NUNCA sobrescreve dados reais (is_forecast=false).

Execução: python -m database.scripts.projetar_2026
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
logger = logging.getLogger("projetar_2026")

DSN = "postgresql://postgres:postgres@localhost:5432/quero_comprar"

MESES_2026 = list(range(1, 13))


async def projetar_2026(conn: asyncpg.Connection) -> dict[int, int]:
    """Projeta meses de 2026 sem dados a partir do baseline.

    Returns: dict {mes: linhas_inseridas}
    """
    hoje = datetime.now()
    meses_futuros = [m for m in MESES_2026 if m > hoje.month]

    logger.info("Analisando gaps de 2026 (meses futuros: %s)...", meses_futuros)

    # Para cada mês, descobre quais (prod, loc) estão faltando
    resultados: dict[int, int] = {}

    for mes in meses_futuros:
        data_alvo = f"2026-{mes:02d}"

        # Produtos que já têm dado real neste mês
        existentes = await conn.fetch("""
            SELECT id_produto, id_localidade
            FROM mart.sazonalidade_produto
            WHERE data_referencia_atual = $1 AND NOT is_forecast
        """, data_alvo)
        existentes_set = {(r["id_produto"], r["id_localidade"]) for r in existentes}

        # Baseline disponível
        baseline = await conn.fetch("""
            SELECT b.id_produto, b.id_localidade, b.status_cor_mode, b.confianca
            FROM mart.sazonalidade_baseline b
            WHERE b.mes = $1
        """, mes)
        logger.debug("Mês %02d: %d existentes, %d baseline disponível",
                     mes, len(existentes), len(baseline))

        if not baseline:
            logger.info("Mês %02d: sem baseline — pulando.", mes)
            resultados[mes] = 0
            continue

        # Último preco_real conhecido para cada (prod, loc) como referência
        ultimos_precos = await conn.fetch("""
            SELECT DISTINCT ON (s.id_produto, s.id_localidade)
                s.id_produto, s.id_localidade, s.preco_atual,
                s.data_referencia_atual
            FROM mart.sazonalidade_produto s
            WHERE NOT s.is_forecast
              AND s.preco_atual IS NOT NULL
            ORDER BY s.id_produto, s.id_localidade, s.data_referencia_atual DESC
        """)
        preco_map = {}
        for r in ultimos_precos:
            preco_map[(r["id_produto"], r["id_localidade"])] = float(r["preco_atual"])

        inserted = 0
        batch = []
        for b in baseline:
            key = (b["id_produto"], b["id_localidade"])
            if key in existentes_set:
                continue  # já tem dado real, não sobrescreve

            preco_ref = preco_map.get(key)
            if preco_ref is None:
                continue  # sem referência de preço, não projeta

            batch.append((
                b["id_produto"], b["id_localidade"],
                preco_ref, data_alvo,
                b["status_cor_mode"],
            ))

            if len(batch) >= 500:
                await _insert_batch(conn, batch)
                inserted += len(batch)
                batch = []

        if batch:
            await _insert_batch(conn, batch)
            inserted += len(batch)

        resultados[mes] = inserted
        logger.info("Mês %02d: %d produtos projetados (forecast).", mes, inserted)

    return resultados


async def _insert_batch(conn: asyncpg.Connection, batch: list[tuple]) -> None:
    values = []
    params = []
    idx = 1
    for id_prod, id_loc, preco_ref, data_alvo, status_cor in batch:
        values.append(
            f"(${idx}, ${idx+1}, ${idx+2}::NUMERIC(14,4), ${idx+3}::NUMERIC(14,4), "
            f"${idx+4}, ${idx+5}::TEXT, true)"
        )
        params.extend([id_prod, id_loc, preco_ref, preco_ref, data_alvo, status_cor])
        idx += 6

    sql = f"""
        INSERT INTO mart.sazonalidade_produto
            (id_produto, id_localidade, preco_referencia, preco_atual,
             data_referencia_atual, status_cor, is_forecast)
        VALUES {','.join(values)}
        ON CONFLICT (id_produto, id_localidade, data_referencia_atual)
        DO NOTHING
    """
    await conn.execute(sql, *params)


async def main():
    logger.info("=== Projeção de 2026 ===")
    conn = await asyncpg.connect(DSN)
    try:
        resultados = await projetar_2026(conn)
        total = sum(resultados.values())
        meses = sum(1 for v in resultados.values() if v > 0)
        logger.info("Total: %d linhas projetadas em %d meses de 2026.", total, meses)
        for mes, qtd in sorted(resultados.items()):
            status = f"{qtd} projeções" if qtd > 0 else "sem baseline disponível"
            logger.info("  2026-%02d: %s", mes, status)
    finally:
        await conn.close()
    logger.info("Done.")


if __name__ == "__main__":
    asyncio.run(main())
