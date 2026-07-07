import asyncio, asyncpg, sys
if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

async def fix():
    conn = await asyncpg.connect("postgresql://postgres:postgres@localhost:5432/quero_comprar")
    
    # Drop if exists (with CASCADE to handle dependencies)
    await conn.execute("DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE")
    
    # Re-create
    await conn.execute("""
        CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
        SELECT
            s.id_sazonalidade,
            p.id_produto,
            p.nome_produto AS produto,
            p.classificao_produto,
            p.conab_id_produto,
            p.status_fonte,
            COALESCE(c.nome_categoria, 'ALIMENTO_VAREJO') AS categoria,
            l.uf,
            l.municipio_nome AS municipio,
            l.municipio_id,
            CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER) AS ano,
            CAST(SPLIT_PART(s.data_referencia_atual, '-', 2) AS INTEGER) AS mes,
            s.preco_referencia,
            s.preco_atual,
            s.data_referencia_atual,
            s.usou_fallback_12m,
            s.status_cor,
            s.fonte,
            s.calculado_em
        FROM mart.sazonalidade_produto s
        JOIN staging.dim_produto p ON p.id_produto = s.id_produto
        JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
        LEFT JOIN staging.dim_categoria c ON c.id_categoria = p.id_categoria
        WHERE s.status_cor != 'INSUFICIENTE'
        ORDER BY s.status_cor, p.nome_produto
    """)
    
    await conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_vw_api_unique ON mart.vw_api_produtos_sazonalidade (id_sazonalidade)")
    await conn.execute("CREATE INDEX IF NOT EXISTS idx_vw_api_filtro ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor)")
    await conn.execute("CREATE INDEX IF NOT EXISTS idx_vw_api_categoria ON mart.vw_api_produtos_sazonalidade (categoria)")
    await conn.execute("CREATE INDEX IF NOT EXISTS idx_vw_api_id_produto ON mart.vw_api_produtos_sazonalidade (id_produto)")
    
    mv_count = await conn.fetchval("SELECT count(*) FROM mart.vw_api_produtos_sazonalidade")
    print(f"MV recriada com {mv_count} linhas")
    
    await conn.close()

asyncio.run(fix())
