"""
main_runner.py — Run and Die
=============================
Filosofia: O sistema acorda, colhe, persiste e morre.
Sem while True, sem daemon — apenas um job assíncrono com timeout global de 20min.

Fluxo completo: Coleta → Persiste raw.coleta_bruta → SortingEngine → Medalhao → MV.
"""

from __future__ import annotations

import asyncio
import logging
import sys
import time
from datetime import datetime
from typing import Any, NoReturn

import asyncpg

from pipeline.scraper.orchestrator import AutonomousOrchestrator, SCRAPER_TIMEOUT_SEC
from database.utils.snapshot_helper import atualizar_checkpoint, export_snapshot
from pipeline.scraper.persistence import persistir_coleta_bruta, executar_ciclo_medalhao

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
)
logger = logging.getLogger("main_runner")

# ──────────────────────────────────────────────
# Constantes de blindagem
# ──────────────────────────────────────────────
GLOBAL_TIMEOUT_SEC = 1200  # 20 min — vida máxima do processo
POOL_MIN_SIZE = 2
POOL_MAX_SIZE = 10
DSN = "postgresql://role_etl_writer:mude_essa_senha_em_producao@localhost:5432/quero_comprar"

_UFS: list[str] = [
    "AC", "AL", "AM", "AP", "BA", "CE", "DF", "ES", "GO", "MA",
    "MG", "MS", "MT", "PA", "PB", "PE", "PI", "PR", "RJ", "RN",
    "RO", "RR", "RS", "SC", "SE", "SP", "TO",
]


def _competencias_alvo() -> list[str]:
    hoje = datetime.now()
    competencias: list[str] = []
    for ano in range(2024, hoje.year + 1):
        mes_fim = hoje.month if ano == hoje.year else 12
        for mes in range(1, mes_fim + 1):
            competencias.append(f"{ano}-{mes:02d}")
    return competencias


async def _build_pool(dsn: str = DSN) -> asyncpg.Pool:
    logger.info("Inicializando pool de conexões (min=%d, max=%d)...", POOL_MIN_SIZE, POOL_MAX_SIZE)
    return await asyncpg.create_pool(
        dsn=dsn,
        min_size=POOL_MIN_SIZE,
        max_size=POOL_MAX_SIZE,
        command_timeout=30,
    )


async def _notificar_backend_etl_fim() -> None:
    import httpx

    api_url = "http://127.0.0.1:8000"
    api_key = ""
    url = f"{api_url.rstrip('/')}/api/v1/_internal/etl-done"
    headers = {}
    if api_key:
        headers["x-api-key"] = api_key
    try:
        resp = httpx.post(url, headers=headers, timeout=5.0)
        logger.info("Notificacao backend ETL_FINISHED: %s %s", resp.status_code, resp.text)
    except Exception:
        logger.warning("Nao foi possivel notificar backend (ETL rodando standalone?)", exc_info=True)


async def _run_job(pool: asyncpg.Pool) -> None:
    logger.info("Job iniciado — conectado ao banco via pool.")

    competencias = _competencias_alvo()
    logger.info(
        "Alvos: %d UFs x %d competências = %d extrações",
        len(_UFS), len(competencias), len(_UFS) * len(competencias),
    )

    total_persistidos = 0
    total_competencias = 0

    async with AutonomousOrchestrator() as orch:
        for uf in _UFS:
            for competencia in competencias:
                try:
                    resultados: list[dict[str, Any]] = await asyncio.wait_for(
                        orch.coletar(uf, competencia),
                        timeout=SCRAPER_TIMEOUT_SEC,
                    )
                    if resultados:
                        logger.info(
                            "[MAIN] UF=%s | %s | %d registros coletados — persistindo...",
                            uf, competencia, len(resultados),
                        )
                        inseridos = await persistir_coleta_bruta(pool, resultados, competencia)
                        total_persistidos += inseridos
                        total_competencias += 1
                except asyncio.TimeoutError:
                    logger.warning(
                        "[MAIN] UF=%s | %s | TIMEOUT de %ds — pulando",
                        uf, competencia, SCRAPER_TIMEOUT_SEC,
                    )
                except Exception:
                    logger.exception(
                        "[MAIN] UF=%s | %s | Erro não tratado — pulando",
                        uf, competencia,
                    )

    logger.info(
        "Coleta concluída: %d competências com dados, %d registros persistidos em raw.coleta_bruta",
        total_competencias, total_persistidos,
    )

    if total_persistidos == 0:
        logger.info("Nenhum dado novo — pulando ciclo medalhao.")
        return

    await executar_ciclo_medalhao(pool)

    try:
        async with pool.acquire() as conn:
            await export_snapshot(
                conexao=conn,
                schema="staging",
                tabela="fact_precos_mensais",
                diretorio="database/processed_data/01_raw",
            )
        atualizar_checkpoint({
            "conab-precos-uf": datetime.now().strftime("%Y-%m"),
            "conab-prohort-mensal": datetime.now().strftime("%Y-%m"),
        })
    except Exception:
        logger.warning("R3 — Snapshot/checkpoint nao concluido", exc_info=True)

    await _notificar_backend_etl_fim()
    logger.info("Job finalizado.")


async def main() -> NoReturn:
    t_global = time.perf_counter()
    pool: asyncpg.Pool | None = None
    try:
        pool = await _build_pool()
        task = asyncio.create_task(_run_job(pool))
        await asyncio.wait_for(task, timeout=GLOBAL_TIMEOUT_SEC)
    except asyncio.TimeoutError:
        logger.critical(
            "TIMEOUT GLOBAL de %ds atingido — processo encerrado por segurança.",
            GLOBAL_TIMEOUT_SEC,
        )
        sys.exit(1)
    except Exception:
        logger.exception("Erro não tratado no job principal.")
        sys.exit(2)
    finally:
        if pool is not None and not pool.is_closing():
            logger.info("Fechando pool de conexões...")
            await pool.close()
            logger.info("Pool fechado.")
        elapsed = time.perf_counter() - t_global
        logger.info("Run and Die — encerramento limpo em %.1fs.", elapsed)
        sys.exit(0)


if __name__ == "__main__":
    asyncio.run(main())
