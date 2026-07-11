"""
calcular_baseline.py — Fase 2b: Cálculo do Baseline Histórico
===============================================================
Lê dados reais (is_forecast=false) do mart.sazonalidade_produto para
2024 e 2025. Para cada combinação (produto, localidade, mes):
  - Moda do status_cor → status_cor_mode
  - Confiança = (anos com dados / anos analisados) * 100

Execução: python -m database.scripts.calcular_baseline
"""

import asyncio
import logging
from collections import Counter

import asyncpg

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("calcular_baseline")

DSN = "postgresql://postgres:postgres@localhost:5432/quero_comprar"

ANOS_ANALISE = [2024, 2025]


async def calcular_baseline(conn: asyncpg.Connection) -> int:
    logger.info("Lendo dados reais (is_forecast=false) de %s-%s...",
                ANOS_ANALISE[0], ANOS_ANALISE[-1])

    rows = await conn.fetch("""
        SELECT s.id_produto, s.id_localidade,
               EXTRACT(YEAR FROM TO_DATE(s.data_referencia_atual, 'YYYY-MM'))::INTEGER AS ano,
               EXTRACT(MONTH FROM TO_DATE(s.data_referencia_atual, 'YYYY-MM'))::INTEGER AS mes,
               s.status_cor
        FROM mart.sazonalidade_produto s
        WHERE NOT s.is_forecast
          AND s.data_referencia_atual >= '2024-01'
          AND s.data_referencia_atual <= '2025-12'
    """)
    logger.info("Total registros reais 2024-2025: %d", len(rows))

    if not rows:
        logger.warning("Nenhum dado real encontrado — execute backfill_2024 primeiro.")
        return 0

    # Agrupa por (id_produto, id_localidade, mes)
    groups: dict[tuple[int, int, int], list[str]] = {}
    anos_por_grupo: dict[tuple[int, int, int], set[int]] = {}

    for r in rows:
        key = (r["id_produto"], r["id_localidade"], r["mes"])
        if key not in groups:
            groups[key] = []
            anos_por_grupo[key] = set()
        groups[key].append(r["status_cor"])
        anos_por_grupo[key].add(r["ano"])

    logger.info("Combinações únicas (prod, loc, mes): %d", len(groups))

    # Limpa baseline anterior para este dataset
    await conn.execute("TRUNCATE mart.sazonalidade_baseline RESTART IDENTITY CASCADE")
    logger.info("Baseline anterior truncado.")

    batch = []
    for key, statuses in groups.items():
        id_prod, id_loc, mes = key
        anos_presentes = len(anos_por_grupo[key])
        confianca = round((anos_presentes / len(ANOS_ANALISE)) * 100, 2)

        mode_count = Counter(statuses).most_common(1)
        status_mode = mode_count[0][0] if mode_count else "AMARELO"

        batch.append((id_prod, id_loc, mes, status_mode, confianca))

    # Batch insert
    total = 0
    chunk_size = 500
    for i in range(0, len(batch), chunk_size):
        chunk = batch[i:i + chunk_size]
        values = []
        params = []
        idx = 1
        for id_prod, id_loc, mes, status_mode, confianca in chunk:
            values.append(f"(${idx}, ${idx+1}, ${idx+2}, ${idx+3}::TEXT, ${idx+4}::NUMERIC(5,2))")
            params.extend([id_prod, id_loc, mes, status_mode, confianca])
            idx += 5

        sql = f"""
            INSERT INTO mart.sazonalidade_baseline
                (id_produto, id_localidade, mes, status_cor_mode, confianca)
            VALUES {','.join(values)}
            ON CONFLICT (id_produto, id_localidade, mes)
            DO UPDATE SET
                status_cor_mode = EXCLUDED.status_cor_mode,
                confianca       = EXCLUDED.confianca,
                fonte           = 'BASELINE_HISTORICO',
                atualizado_em   = NOW()
        """
        await conn.execute(sql, *params)
        total += len(chunk)
        logger.info("  %d/%d linhas inseridas...", total, len(batch))

    logger.info("Baseline calculado: %d combinações inseridas.", total)
    return total


async def main():
    logger.info("=== Cálculo do Baseline Histórico ===")
    conn = await asyncpg.connect(DSN)
    try:
        total = await calcular_baseline(conn)
        logger.info("Total: %d linhas em mart.sazonalidade_baseline", total)
    finally:
        await conn.close()
    logger.info("Done.")


if __name__ == "__main__":
    asyncio.run(main())
