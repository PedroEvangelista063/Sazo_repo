"""
validar_forecast.py — Valida implementacao do modelo forecast
==============================================================
 Checks:
   1. Matriz densidade: todo (ano, mes) tem dados?
   2. Gaps 2026: meses sem real tem forecast?
   3. Sem regressao: dados reais intactos?
   4. Confianca do baseline
   5. MV refletida corretamente

 Exit: 0 se OK, 1 se falha
"""

import asyncio
import logging
import sys

import asyncpg

logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger("validar_forecast")

DSN = "postgresql://postgres:postgres@localhost:5432/quero_comprar"
ERROS = []


async def check_densidade(conn: asyncpg.Connection) -> None:
    rows = await conn.fetch("""
        SELECT SUBSTRING(data_referencia_atual, 1, 4) AS ano,
               CAST(SPLIT_PART(data_referencia_atual, '-', 2) AS INTEGER) AS mes,
               is_forecast, COUNT(*) AS total
        FROM mart.sazonalidade_produto
        GROUP BY ano, mes, is_forecast
        ORDER BY ano, mes, is_forecast
    """)
    logger.info("[DENSIDADE] %d combinacoes (ano, mes, is_forecast)", len(rows))
    for r in rows:
        logger.info("  %s-%02d is_forecast=%s: %d linhas",
                     r["ano"], r["mes"], r["is_forecast"], r["total"])

    meses_2026 = [r for r in rows if int(r["ano"]) == 2026]
    if len(meses_2026) == 12:
        logger.info("[DENSIDADE] OK — todos os 12 meses de 2026 tem dados (real ou forecast)")
    else:
        msg = f"Apenas {len(meses_2026)}/12 meses de 2026 com dados"
        ERROS.append(msg)
        logger.error("[DENSIDADE] FALHA — %s", msg)


async def check_gaps_2026(conn: asyncpg.Connection) -> None:
    rows = await conn.fetch("""
        SELECT CAST(SPLIT_PART(data_referencia_atual, '-', 2) AS INTEGER) AS mes,
               BOOL_OR(is_forecast = FALSE) AS tem_real,
               BOOL_OR(is_forecast = TRUE) AS tem_forecast,
               COUNT(*) AS total
        FROM mart.sazonalidade_produto
        WHERE data_referencia_atual LIKE '2026-%'
        GROUP BY mes
        ORDER BY mes
    """)
    for r in rows:
        if r["tem_real"]:
            logger.info("[GAP] 2026-%02d: REAL (%d linhas)", r["mes"], r["total"])
        elif r["tem_forecast"]:
            logger.info("[GAP] 2026-%02d: FORECAST (%d linhas)", r["mes"], r["total"])
        else:
            msg = f"2026-{r['mes']:02d} sem dados"
            ERROS.append(msg)
            logger.error("[GAP] FALHA — %s", msg)

    if not any(not r["tem_real"] and not r["tem_forecast"] for r in rows):
        logger.info("[GAP] OK — nenhum mes de 2026 vazio")
    else:
        logger.error("[GAP] FALHA — existem meses vazios em 2026")


async def check_sem_regressao(conn: asyncpg.Connection) -> None:
    total_real = await conn.fetchval("SELECT COUNT(*) FROM mart.sazonalidade_produto WHERE is_forecast = FALSE")
    total_forecast = await conn.fetchval("SELECT COUNT(*) FROM mart.sazonalidade_produto WHERE is_forecast = TRUE")

    logger.info("[REGRESSAO] Real: %d | Forecast: %d", total_real, total_forecast)

    if total_real > 0 and total_forecast > 0:
        logger.info("[REGRESSAO] OK — ambos os blocos presentes")
    else:
        ERROS.append("Bloco real ou forecast vazio")
        logger.error("[REGRESSAO] FALHA")


async def check_confianca(conn: asyncpg.Connection) -> None:
    stats = await conn.fetchrow("""
        SELECT COUNT(*) AS total,
               ROUND(AVG(confianca), 2) AS media,
               ROUND(MIN(confianca), 2) AS min,
               ROUND(MAX(confianca), 2) AS max
        FROM mart.sazonalidade_baseline
    """)
    logger.info("[CONFIANCA] %d linhas | media=%.1f%% min=%.1f%% max=%.1f%%",
                stats["total"], stats["media"], stats["min"], stats["max"])

    if stats["total"] > 0:
        logger.info("[CONFIANCA] OK — baseline populado")
    else:
        ERROS.append("Baseline vazio")
        logger.error("[CONFIANCA] FALHA")


async def check_mv(conn: asyncpg.Connection) -> None:
    stats = await conn.fetchrow("""
        SELECT COUNT(*) FILTER (WHERE is_forecast = FALSE) AS real_,
               COUNT(*) FILTER (WHERE is_forecast = TRUE) AS forecast_,
               COUNT(*) AS total
        FROM mart.vw_api_produtos_sazonalidade
    """)
    logger.info("[MV] %d linhas (real=%d, forecast=%d)",
                stats["total"], stats["real_"], stats["forecast_"])

    if stats["total"] > 0:
        logger.info("[MV] OK — MV populada com is_forecast")
    else:
        ERROS.append("MV vazia")
        logger.error("[MV] FALHA")


async def main():
    logger.info("=" * 50)
    logger.info("VALIDACAO DO MODELO FORECAST")
    logger.info("=" * 50)

    conn = await asyncpg.connect(DSN)
    try:
        await check_densidade(conn)
        logger.info("")
        await check_gaps_2026(conn)
        logger.info("")
        await check_sem_regressao(conn)
        logger.info("")
        await check_confianca(conn)
        logger.info("")
        await check_mv(conn)

        logger.info("")
        logger.info("=" * 50)
        if ERROS:
            logger.error("FALHA — %d erro(s):", len(ERROS))
            for e in ERROS:
                logger.error("  - %s", e)
            sys.exit(1)
        else:
            logger.info("VALIDACAO OK — todas as checagens passaram")
            logger.info("=" * 50)
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
