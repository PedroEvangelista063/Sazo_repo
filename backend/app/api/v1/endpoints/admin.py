"""
admin.py — Rotas administrativas para acionar o pipeline ETL.
Uso exclusivo interno / operadores do sistema.
"""

from __future__ import annotations

import asyncio
import logging
import uuid

from fastapi import APIRouter, BackgroundTasks, Depends, Header, HTTPException
from typing import Optional

from backend.app.core.events import broadcaster
from backend.app.db.session import get_etl_pool

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/admin", tags=["Admin"])


async def _verify_api_key(x_api_key: Optional[str] = Header(None)) -> None:
    from backend.app.core.config import get_settings

    settings = get_settings()
    if settings.internal_api_key and x_api_key != settings.internal_api_key:
        raise HTTPException(status_code=403, detail="Forbidden")


def _normalizar_competencia(ano: int, mes: int) -> str:
    return f"{ano}-{mes:02d}"


async def _rodar_pipeline_background(
    job_id: str,
    ufs: list[str],
    competencias: list[str],
) -> None:
    """
    Executa o pipeline completo em background:
    1. Coleta via AutonomousOrchestrator
    2. Persiste em raw.coleta_bruta
    3. SortingEngine + ciclo medalhao
    4. Refresh MV
    5. Notifica SSE
    """
    from pipeline.scraper.orchestrator import AutonomousOrchestrator, SCRAPER_TIMEOUT_SEC
    from pipeline.scraper.persistence import persistir_coleta_bruta, executar_ciclo_medalhao

    logger.info("[ADMIN JOB=%s] Pipeline iniciado: %d UFs x %d competências", job_id, len(ufs), len(competencias))

    pool = await get_etl_pool()
    total_persistidos = 0

    async with AutonomousOrchestrator() as orch:
        for uf in ufs:
            for competencia in competencias:
                try:
                    resultados = await asyncio.wait_for(
                        orch.coletar(uf, competencia),
                        timeout=SCRAPER_TIMEOUT_SEC,
                    )
                    if resultados:
                        inseridos = await persistir_coleta_bruta(pool, resultados, competencia)
                        total_persistidos += inseridos
                        logger.info(
                            "[ADMIN JOB=%s] UF=%s %s → %d registros",
                            job_id, uf, competencia, inseridos,
                        )
                except asyncio.TimeoutError:
                    logger.warning("[ADMIN JOB=%s] UF=%s %s TIMEOUT", job_id, uf, competencia)
                except Exception:
                    logger.exception("[ADMIN JOB=%s] UF=%s %s ERRO", job_id, uf, competencia)

    if total_persistidos == 0:
        logger.info("[ADMIN JOB=%s] Nenhum dado coletado — pulando medalhao.", job_id)
        await broadcaster.publish("PIPELINE_DONE", f"{{\"job_id\":\"{job_id}\",\"total\":0}}")
        return

    logger.info("[ADMIN JOB=%s] Coleta concluída: %d registros. Executando ciclo medalhao...", job_id, total_persistidos)
    await executar_ciclo_medalhao(pool)
    await broadcaster.publish("PIPELINE_DONE", f"{{\"job_id\":\"{job_id}\",\"total\":{total_persistidos}}}")
    logger.info("[ADMIN JOB=%s] Pipeline concluído — MV atualizada.", job_id)


@router.post(
    "/trigger-pipeline",
    dependencies=[Depends(_verify_api_key)],
)
async def trigger_pipeline(background_tasks: BackgroundTasks):
    """
    Dispara o pipeline completo de coleta + persistência + materialização.
    Executa em BackgroundTasks para não bloquear a request.

    Retorna imediatamente com o job_id para acompanhamento via SSE.
    """
    job_id = str(uuid.uuid4())
    ufs = [
        "AC", "AL", "AM", "AP", "BA", "CE", "DF", "ES", "GO", "MA",
        "MG", "MS", "MT", "PA", "PB", "PE", "PI", "PR", "RJ", "RN",
        "RO", "RR", "RS", "SC", "SE", "SP", "TO",
    ]
    from datetime import datetime
    hoje = datetime.now()
    competencias = [
        _normalizar_competencia(a, m)
        for a in range(2024, hoje.year + 1)
        for m in range(1, (hoje.month if a == hoje.year else 12) + 1)
    ]

    background_tasks.add_task(
        _rodar_pipeline_background,
        job_id,
        ufs,
        competencias,
    )

    return {
        "status": "accepted",
        "job_id": job_id,
        "message": f"Pipeline disparado em background: {len(ufs)} UFs x {len(competencias)} competências",
    }
