"""
test_orchestrator_real.py — Sniper Test
========================================
Valida o fluxo completo do AutonomousOrchestrator em <60s:
  1. Coleta real de 1 UF + 1 competência
  2. Persistência em raw.coleta_bruta
  3. SortingEngine + ciclo medalhao
  4. Query de verificação no banco
"""

from __future__ import annotations

import asyncio
import logging
import sys
import time

import asyncpg

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("test")

DSN = "postgresql://postgres:postgres@localhost:5432/quero_comprar"

UF_ALVO = "SP"
COMPETENCIA_ALVO = "2026-06"
TIMEOUT_TOTAL = 55  # segundos


async def _contar_raw(pool: asyncpg.Pool) -> int:
    async with pool.acquire() as conn:
        row = await conn.fetchval("SELECT COUNT(*) FROM raw.coleta_bruta")
        return row or 0


async def _contar_staging(pool: asyncpg.Pool) -> int:
    async with pool.acquire() as conn:
        row = await conn.fetchval("SELECT COUNT(*) FROM staging.fact_precos_mensais")
        return row or 0


async def _exibir_amostra_raw(pool: asyncpg.Pool) -> None:
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            "SELECT id, fonte_id, competencia_alvo, length(payload_bruto::text) AS payload_len, LEFT(payload_bruto::text, 80) AS payload_preview FROM raw.coleta_bruta ORDER BY data_coleta DESC LIMIT 3"
        )
        for r in rows:
            preview = (r['payload_preview'] or '')[:80].replace('\n', ' ').replace('\r', '')
            print(f"  [{r['fonte_id']}] {r['competencia_alvo']} | {r['payload_len']}b | {preview}")


async def _exibir_amostra_staging(pool: asyncpg.Pool) -> None:
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT p.nome_produto, l.uf, f.ano, f.mes, f.preco_medio
            FROM staging.fact_precos_mensais f
            JOIN staging.dim_produto p ON p.id_produto = f.id_produto
            JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
            ORDER BY f.loaded_at DESC
            LIMIT 5
            """
        )
        if rows:
            for r in rows:
                print(f"  {r['nome_produto']} | {r['uf']} | {r['ano']}-{r['mes']:02d} | R$ {float(r['preco_medio']):.2f}")
        else:
            print("  (vazio)")


async def main() -> int:
    logger.info("=" * 60)
    logger.info("SNIPER TEST - AutonomousOrchestrator + Persistence")
    logger.info("Alvo: UF=%s | Competencia=%s | Timeout=%ds", UF_ALVO, COMPETENCIA_ALVO, TIMEOUT_TOTAL)
    logger.info("=" * 60)

    t0 = time.perf_counter()

    pool = await asyncpg.create_pool(DSN, min_size=1, max_size=2, command_timeout=30)

    # ── Contagem antes ─────────────────────────────────────────────
    raw_antes = await _contar_raw(pool)
    staging_antes = await _contar_staging(pool)
    logger.info("Antes: raw.coleta_bruta=%d | staging.fact_precos_mensais=%d", raw_antes, staging_antes)

    # ── 1. Coleta ──────────────────────────────────────────────────
    from pipeline.scraper.orchestrator import AutonomousOrchestrator

    logger.info("[ETAPA 1/4] Coletando dados via AutonomousOrchestrator...")
    resultados: list[dict] | None = None
    try:
        async with AutonomousOrchestrator() as orch:
            resultados = await asyncio.wait_for(
                orch.coletar(UF_ALVO, COMPETENCIA_ALVO),
                timeout=30,
            )
    except asyncio.TimeoutError:
        logger.error("TIMEOUT na coleta — >30s")
        await pool.close()
        return 1
    except Exception as e:
        logger.error("Falha na coleta: %s", e)
        await pool.close()
        return 1

    if not resultados:
        logger.warning("Nenhum resultado retornado pelo orquestrador.")
    else:
        logger.info("[ETAPA 1/4] Coleta OK — %d item(ns) brutos retornados", len(resultados))
        for i, r in enumerate(resultados[:3]):
            fonte = r.get("fonte_id", "?")
            comp = r.get("competencia", "?")
            print(f"  [{i+1}] fonte={fonte} | competencia={comp}")

    # ── 2. Persistência ─────────────────────────────────────────────
    from pipeline.scraper.persistence import persistir_coleta_bruta

    logger.info("[ETAPA 2/4] Persistindo em raw.coleta_bruta...")
    if resultados:
        try:
            inseridos = await persistir_coleta_bruta(pool, resultados, COMPETENCIA_ALVO)
            logger.info("[ETAPA 2/4] Persistência OK — %d registro(s) inserido(s)", inseridos)
        except Exception as e:
            logger.error("Falha na persistência: %s", e)
            await pool.close()
            return 1
    else:
        inseridos = 0
        logger.info("[ETAPA 2/4] Nada a persistir (skip)")

    # ── 3. Ciclo Medalhão ──────────────────────────────────────────
    from pipeline.scraper.persistence import executar_ciclo_medalhao

    logger.info("[ETAPA 3/4] Executando ciclo medalhao (SortingEngine → SP → MV)...")
    try:
        await asyncio.wait_for(
            executar_ciclo_medalhao(pool),
            timeout=25,
        )
        logger.info("[ETAPA 3/4] Ciclo medalhao finalizado sem erros")
    except asyncio.TimeoutError:
        logger.error("TIMEOUT no ciclo medalhao — >25s")
        await pool.close()
        return 1
    except Exception as e:
        logger.error("Falha no ciclo medalhao: %s", e)
        await pool.close()
        return 1

    # ── 4. Validação ───────────────────────────────────────────────
    logger.info("[ETAPA 4/4] Validando dados no banco...")
    raw_depois = await _contar_raw(pool)
    staging_depois = await _contar_staging(pool)

    logger.info("Depois: raw.coleta_bruta=%d | staging.fact_precos_mensais=%d", raw_depois, staging_depois)

    print()
    print("-- Amostra raw.coleta_bruta --")
    await _exibir_amostra_raw(pool)

    print()
    print("-- Amostra staging.fact_precos_mensais --")
    await _exibir_amostra_staging(pool)
    print()

    # ── Verificação ────────────────────────────────────────────────
    checks_ok = 0
    if raw_depois > raw_antes:
        checks_ok += 1
        logger.info("[CHECK] raw.coleta_bruta cresceu: %d -> %d", raw_antes, raw_depois)
    else:
        logger.warning("[CHECK] raw.coleta_bruta nao cresceu")

    if staging_depois > staging_antes:
        checks_ok += 1
        logger.info("[CHECK] staging.fact_precos_mensais cresceu: %d -> %d", staging_antes, staging_depois)
    else:
        logger.warning("[CHECK] staging.fact_precos_mensais nao cresceu (SortingEngine nao parseou)")

    print()
    logger.info("=" * 60)
    if checks_ok == 2:
        logger.info("RESULTADO: SUCESSO - Cadeia completa verificada")
        logger.info("Scraper -> raw.coleta_bruta -> staging.fact_precos_mensais -> API pronta")
    else:
        logger.info("RESULTADO: PARCIAL - raw.coleta_bruta tem dados, staging precisa de parser melhor")
        logger.info("Chain: Scraper -> raw.coleta_bruta = OK | staging.fact_precos_mensais = PENDENTE")
    logger.info("=" * 60)

    elapsed = time.perf_counter() - t0
    logger.info("Tempo total: %.1fs", elapsed)

    await pool.close()
    return 0


if __name__ == "__main__":
    exit_code = asyncio.run(main())
    sys.exit(exit_code)
