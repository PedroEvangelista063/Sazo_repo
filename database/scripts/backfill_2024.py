"""
backfill_2024.py — Fase 1: Backfill Histórico
===============================================
Lê dados reais de staging.fact_precos_mensais para 2024 e insere no
mart.sazonalidade_produto replicando a lógica de classificação da
sp_calcular_sazonalidade_preditiva (média móvel 12m, semáforo).

Pré-requisito: is_forecast column e tabelas mart existentes.
Execução: python -m database.scripts.backfill_2024
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
logger = logging.getLogger("backfill_2024")

DSN = "postgresql://postgres:postgres@localhost:5432/quero_comprar"

# Só CEAGESP (SP, MG, PR) tem dados em 2024
UFS_2024 = ["SP", "MG", "PR"]


async def backfill_2024(conn: asyncpg.Connection) -> int:
    """Insere dados de 2024 no mart.sazonalidade_produto.

    Lógica replicada da procedure V9:
    1. Para cada (produto, localidade) → preco_referencia = média de 2025 (se existir)
    2. Fallback = média de 12 meses anteriores
    3. Cold start = próprio preço
    4. Semáforo: <85% = VERDE, >115% = VERMELHO, else AMARELO
    """
    logger.info("Backfill 2024 — lendo staging.fact_precos_mensais...")

    anos_validos = await conn.fetchval("""
        SELECT COUNT(*) FROM staging.fact_precos_mensais WHERE ano = 2024
    """)
    logger.info("Registros em staging para 2024: %s", anos_validos)

    if anos_validos == 0:
        logger.warning("Nenhum dado de 2024 na staging — abortando.")
        return 0

    # Busca preco_referencia da média 2025 para cada (produto, localidade)
    ref_2025 = await conn.fetch("""
        SELECT f.id_produto, f.id_localidade,
               AVG(COALESCE(f.preco_curado, f.preco_medio)) AS preco_ref
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_produto p ON p.id_produto = f.id_produto
                                   AND p.categoria_b2c = 'ALIMENTO_VAREJO'
        WHERE f.ano = 2025 AND COALESCE(f.preco_curado, f.preco_medio) > 0
        GROUP BY f.id_produto, f.id_localidade
    """)
    ref_map = {}
    for r in ref_2025:
        ref_map[(r["id_produto"], r["id_localidade"])] = float(r["preco_ref"])
    logger.info("Referências 2025 carregadas: %d pares (prod, loc)", len(ref_map))

    # Fallback 12m para quem não tem 2025
    fallback = await conn.fetch("""
        WITH ultimo AS (
            SELECT f2.id_produto, f2.id_localidade,
                   MAX(f2.ano * 12 + f2.mes) AS ultimo_periodo
            FROM staging.fact_precos_mensais f2
            WHERE COALESCE(f2.preco_curado, f2.preco_medio) > 0
            GROUP BY f2.id_produto, f2.id_localidade
        )
        SELECT f.id_produto, f.id_localidade,
               AVG(COALESCE(f.preco_curado, f.preco_medio)) AS media_fallback
        FROM staging.fact_precos_mensais f
        JOIN ultimo u ON u.id_produto = f.id_produto
                     AND u.id_localidade = f.id_localidade
        WHERE COALESCE(f.preco_curado, f.preco_medio) > 0
          AND (f.ano * 12 + f.mes) > (u.ultimo_periodo - 12)
          AND (f.ano * 12 + f.mes) <= u.ultimo_periodo
        GROUP BY f.id_produto, f.id_localidade
        HAVING COUNT(*) >= 3
    """)
    fallback_map = {}
    for r in fallback:
        fallback_map[(r["id_produto"], r["id_localidade"])] = float(r["media_fallback"])
    logger.info("Fallbacks 12m carregados: %d pares", len(fallback_map))

    rows_2024 = await conn.fetch("""
        SELECT f.id_produto, f.id_localidade, f.ano, f.mes,
               COALESCE(f.preco_curado, f.preco_medio) AS preco_atual,
               f.is_interpolado AS preco_estimado
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_produto p ON p.id_produto = f.id_produto
                                   AND p.categoria_b2c = 'ALIMENTO_VAREJO'
        WHERE f.ano = 2024 AND COALESCE(f.preco_curado, f.preco_medio) > 0
        ORDER BY f.id_produto, f.id_localidade, f.mes
    """)
    logger.info("Linhas 2024 para processar: %d", len(rows_2024))

    inserted = 0
    for row in rows_2024:
        key = (row["id_produto"], row["id_localidade"])
        preco = float(row["preco_atual"])
        data_ref = f"{row['ano']}-{row['mes']:02d}"

        preco_ref = ref_map.get(key) or fallback_map.get(key) or preco
        metodo = "alpha_sazonal" if key in ref_map else (
            "beta_media_disponivel" if key in fallback_map else "gamma_cold_start"
        )
        usou_fallback = key not in ref_map and key in fallback_map
        proporcao = preco / preco_ref if preco_ref > 0 else 1.0

        if proporcao < 0.85:
            status = "VERDE"
        elif proporcao > 1.15:
            status = "VERMELHO"
        else:
            status = "AMARELO"

        await conn.execute("""
            INSERT INTO mart.sazonalidade_produto
                (id_produto, id_localidade, preco_referencia, preco_atual,
                 data_referencia_atual, usou_fallback_12m, preco_estimado,
                 status_cor, fonte, metodo_calculo, is_forecast,
                 variacao_mom_pct, preco_mes_anterior)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'municipio',
                    $9, false, NULL, NULL)
            ON CONFLICT (id_produto, id_localidade, data_referencia_atual)
            DO UPDATE SET
                preco_referencia   = EXCLUDED.preco_referencia,
                preco_atual        = EXCLUDED.preco_atual,
                status_cor         = EXCLUDED.status_cor,
                metodo_calculo     = EXCLUDED.metodo_calculo,
                usou_fallback_12m  = EXCLUDED.usou_fallback_12m,
                preco_estimado     = EXCLUDED.preco_estimado,
                is_forecast        = false,
                calculado_em       = NOW()
        """, row["id_produto"], row["id_localidade"],
            round(preco_ref, 4), round(preco, 4),
            data_ref, usou_fallback, row["preco_estimado"], status, metodo)
        inserted += 1

        if inserted % 100 == 0:
            logger.info("  %d linhas inseridas...", inserted)

    logger.info("Backfill 2024 concluído: %d linhas inseridas/atualizadas.", inserted)
    return inserted


async def main():
    logger.info("=== Backfill 2024 ===")
    conn = await asyncpg.connect(DSN)
    try:
        await backfill_2024(conn)
    finally:
        await conn.close()
    logger.info("Done.")


if __name__ == "__main__":
    asyncio.run(main())
