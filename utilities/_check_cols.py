import asyncio, asyncpg, sys
if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

async def check():
    conn = await asyncpg.connect("postgresql://postgres:postgres@localhost:5432/quero_comprar")
    cols = await conn.fetch(
        "SELECT column_name, data_type FROM information_schema.columns "
        "WHERE table_schema='mart' AND table_name='sazonalidade_produto' "
        "ORDER BY ordinal_position"
    )
    print("Colunas de mart.sazonalidade_produto:")
    for c in cols:
        print(f"  {c['column_name']:30s} {c['data_type']}")
    
    # Check data_referencia_atual specifically
    has_ref = any(c['column_name'] == 'data_referencia_atual' for c in cols)
    print(f"\ndata_referencia_atual: {'EXISTE' if has_ref else 'AUSENTE'}")
    
    # Check previous MV
    mv = await conn.fetchval(
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='mart' AND table_name='vw_api_produtos_sazonalidade'"
    )
    print(f"vw_api_produtos_sazonalidade (antes do fix): {'EXISTE' if mv else 'AUSENTE'}")
    
    await conn.close()

asyncio.run(check())
