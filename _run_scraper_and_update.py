"""
Coleta SmartCrawler + upsert DB + sazonalidade + MV refresh
"""
import asyncio, asyncpg, logging, os, sys, time
from datetime import date

if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/quero_comprar")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("run_all")

async def run():
    t0 = time.time()

    # ── FASE 1: SmartCrawler ──
    logger.info("─" * 50)
    logger.info("SmartCrawler2026 — coleta para todas as UFs (mes atual)")
    logger.info("─" * 50)

    from pipeline.scraper.adapters.smart_router import SmartCrawler2026, TODAS_UFS
    crawler = SmartCrawler2026()
    hoje = date.today()
    resultados = await crawler.executar_para_ufs(TODAS_UFS, ano=hoje.year, mes=hoje.month)
    total_cot = sum(len(v) for v in resultados.values())
    logger.info("SmartCrawler: %d cotacoes de %d UFs", total_cot, len(resultados))
    for uf, cots in sorted(resultados.items()):
        logger.info("  %s: %d cotacoes", uf, len(cots))

    # ── FASE 2: Salvar no DB ──
    logger.info("─" * 50)
    logger.info("Salvando cotacoes no banco (raw.scraper_data)")
    logger.info("─" * 50)

    conn = await asyncpg.connect(DATABASE_URL)
    try:
        saved = 0
        for uf, cotacoes in resultados.items():
            for c in cotacoes:
                try:
                    await conn.execute("""
                        INSERT INTO raw.scraper_data
                            (fonte, uf, municipio, produto, ano, mes, preco_medio, preco_bruto, raw_data, status_coleta, coletado_em)
                        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,NOW())
                        ON CONFLICT DO NOTHING
                    """, c.fonte, c.uf, c.municipio, c.produto_original, c.ano, c.mes,
                        float(c.preco_medio) if c.preco_medio else None,
                        float(c.preco_bruto) if c.preco_bruto else None,
                        None, c.status_coleta)
                    saved += 1
                except Exception as e:
                    logger.debug("Erro salvando cotacao %s %s: %s", c.uf, c.produto_original, e)
        logger.info("%d cotacoes salvas em raw.scraper_data", saved)

        # ── FASE 3: Upsert raw → staging ──
        logger.info("─" * 50)
        logger.info("DB maintenance: upsert raw -> staging")
        logger.info("─" * 50)
        await conn.execute("CALL ops.sp_limpeza_diaria_scraper(30, false)")
        logger.info("sp_limpeza_diaria_scraper OK")

        # ── FASE 4: Sazonalidade ──
        logger.info("─" * 50)
        logger.info("sp_calcular_sazonalidade_preditiva()")
        logger.info("─" * 50)
        await conn.execute("CALL staging.sp_calcular_sazonalidade_preditiva()")
        logger.info("sp_calcular_sazonalidade_preditiva OK")

        # ── FASE 5: MV refresh ──
        logger.info("─" * 50)
        logger.info("REFRESH MATERIALIZED VIEW")
        logger.info("─" * 50)
        await conn.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade")
        logger.info("MV refreshed")

        # ── RESUMO ──
        cnt = await conn.fetchrow("""
            SELECT
                (SELECT count(*) FROM staging.fact_precos_mensais) as staging,
                (SELECT count(*) FROM mart.sazonalidade_produto) as sazonalidade,
                (SELECT count(*) FROM mart.vw_api_produtos_sazonalidade) as mv
        """)
        logger.info("─" * 50)
        logger.info("RESUMO: staging=%s  sazonalidade=%s  mv=%s  tempo=%.1fs",
                     cnt["staging"], cnt["sazonalidade"], cnt["mv"], time.time() - t0)
        logger.info("─" * 50)
    finally:
        await conn.close()

if __name__ == "__main__":
    asyncio.run(run())
