"""
persistence.py — Load step of ELT
==================================
Recebe o dicionário bruto do orquestrador e faz UPSERT no banco.
Flow: raw.coleta_bruta → SortingEngine → staging.fact_precos_mensais → sp_executar_carga_completa → MV.
"""

from __future__ import annotations

import json
import logging
import time
import uuid
from typing import Any

import asyncpg

logger = logging.getLogger(__name__)

_PERSIST_BATCH = 500


async def persistir_coleta_bruta(
    pool: asyncpg.Pool,
    resultados: list[dict[str, Any]],
    competencia: str,
) -> int:
    """
    Insere registros brutos na raw.coleta_bruta (landing zone).
    Retorna quantos foram inseridos.
    """
    if not resultados:
        return 0

    logger.info("[PERSIST] Iniciando Persistência de %d registros para competência %s", len(resultados), competencia)

    async with pool.acquire() as conn:
        inserted = 0
        for item in resultados:
            fonte_id = item.get("fonte_id", "UNKNOWN")
            payload_raw = item.get("payload_bruto", {})
            raw_id = uuid.uuid4()

            await conn.execute(
                """
                INSERT INTO raw.coleta_bruta (id, fonte_id, payload_bruto, competencia_alvo)
                VALUES ($1, $2, $3::jsonb, $4)
                ON CONFLICT (id) DO NOTHING
                """,
                raw_id,
                fonte_id,
                json.dumps(payload_raw, ensure_ascii=False, default=str),
                item.get("competencia", competencia),
            )
            inserted += 1

    logger.info("[PERSIST] Persistência Concluída — %d registros em raw.coleta_bruta [%s]", inserted, competencia)
    return inserted


async def executar_ciclo_medalhao(pool: asyncpg.Pool) -> None:
    """
    Executa o pipeline de transformação completo:
    1. SortingEngine (raw.coleta_bruta processado=FALSE → staging.fact_precos_mensais)
    2. sp_executar_carga_completa (staging → mart.sazonalidade_produto)
    3. REFRESH MATERIALIZED VIEW CONCURRENTLY
    """
    from pipeline.processor.sorting_engine import SortingEngine

    # Passo 1: SortingEngine
    t0 = time.perf_counter()
    logger.info("[CICLO] Iniciando SortingEngine — processando raw.coleta_bruta não processados...")
    engine = SortingEngine(pool=pool)
    try:
        total_processados = await engine.run()
        logger.info("[CICLO] SortingEngine concluído — %d registros processados em %.1fs", total_processados, time.perf_counter() - t0)
    finally:
        await engine.close()

    if total_processados == 0:
        logger.info("[CICLO] Nenhum registro novo para processar — pulando medalhao cycle.")
        return

    # Passo 2: Stored procedure
    logger.info("[CICLO] Executando sp_executar_carga_completa()...")
    async with pool.acquire() as conn:
        await conn.execute("CALL staging.sp_executar_carga_completa()")

    # Passo 3: Refresh MV
    logger.info("[CICLO] Refrescando materialized view...")
    async with pool.acquire() as conn:
        await conn.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade")

    # Passo 4: Recalcular baseline e projetar forecasts
    logger.info("[CICLO] Recalculando baseline histórico...")
    try:
        from database.scripts.calcular_baseline import calcular_baseline as _cb
        from database.scripts.projetar_2026 import projetar_2026 as _pj

        async with pool.acquire() as conn:
            total_baseline = await _cb(conn)
            logger.info("[CICLO] Baseline recalculado: %d linhas em mart.sazonalidade_baseline", total_baseline)

            resultados_forecast = await _pj(conn)
            total_forecast = sum(resultados_forecast.values())
            logger.info("[CICLO] Forecast atualizado: %d linhas projetadas para 2026", total_forecast)
    except Exception:
        logger.exception("[CICLO] Erro ao recalcular baseline — continuando sem forecast.")
        return

    # Passo 5: Refresh final da MV com os dados de forecast
    logger.info("[CICLO] Refrescando MV com dados de forecast...")
    async with pool.acquire() as conn:
        await conn.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade")

    logger.info("[CICLO] Ciclo medalhao COMPLETO — dados prontos para a API.")
