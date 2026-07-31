"""
persistence.py — Load step of ELT
==================================
Recebe o dicionário bruto do orquestrador e faz UPSERT no banco.
Flow: raw.coleta_bruta → SortingEngine → sp_executar_carga_completa (inclui forecast 2026 + refresh MV).
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
    2. sp_executar_carga_completa (staging → mart → forecast 2026 → MV refresh)
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

    # Passo 2: SP completa (inclui cálculo sazonalidade + forecast 2026 + refresh MV)
    logger.info("[CICLO] Executando sp_executar_carga_completa()...")
    async with pool.acquire() as conn:
        await conn.execute("CALL staging.sp_executar_carga_completa()")

    # Passo 6: Purge cache do backend
    try:
        from pipeline.cache_purge import purge_cache_sync
        purge_cache_sync()
    except (ImportError, OSError):
        logger.warning("[CICLO] Cache purge falhou (backend offline?) — continuando.")

    logger.info("[CICLO] Ciclo medalhao COMPLETO — dados prontos para a API.")
