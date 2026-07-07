import asyncio, asyncpg, sys
if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

async def check():
    conn = await asyncpg.connect("postgresql://postgres:postgres@localhost:5432/quero_comprar")
    print("=== VERIFICACAO POS MIGRATION 15 ===")
    
    # Tabela fato
    c = await conn.fetchval("SELECT count(*) FROM staging.fato_cotacao_regional")
    print(f"staging.fato_cotacao_regional: {c} linhas")
    
    # View dedup
    v = await conn.fetchval("SELECT count(*) FROM information_schema.views WHERE table_schema='staging' AND table_name='vw_cotacao_regional_dedup'")
    print(f"staging.vw_cotacao_regional_dedup: {'EXISTE' if v else 'AUSENTE'}")
    
    # MV
    mv = await conn.fetchval("SELECT count(*) FROM information_schema.tables WHERE table_schema='mart' AND table_name='vw_api_produtos_sazonalidade'")
    print(f"mart.vw_api_produtos_sazonalidade: {'EXISTE' if mv else 'AUSENTE'}")
    if mv:
        mv_c = await conn.fetchval("SELECT count(*) FROM mart.vw_api_produtos_sazonalidade")
        print(f"  Linhas na MV: {mv_c}")
    
    # Categoria
    cat = await conn.fetchval("SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria='HORTIFRUTIGRANJEIROS'")
    print(f"Categoria HORTIFRUTIGRANJEIROS: id={cat}")
    
    # Total schemas
    for s in ['raw', 'staging', 'mart']:
        ts = await conn.fetch(f"SELECT table_name FROM information_schema.tables WHERE table_schema=$1 ORDER BY table_name", s)
        vs = await conn.fetch(f"SELECT table_name FROM information_schema.views WHERE table_schema=$1 ORDER BY table_name", s)
        names = [r['table_name'] for r in ts] + [f"{r['table_name']} (view)" for r in vs]
        print(f"\n{s} schema ({len(names)} objetos):")
        for n in names:
            print(f"  - {n}")
    
    await conn.close()

asyncio.run(check())
