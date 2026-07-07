import asyncio, asyncpg, sys
if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

async def check():
    conn = await asyncpg.connect("postgresql://postgres:postgres@localhost:5432/quero_comprar")
    
    r1 = await conn.fetchval(
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='staging' AND table_name='fato_cotacao_regional'"
    )
    print(f"fato_cotacao_regional: {'EXISTE' if r1 else 'AUSENTE'}")
    if r1:
        c1 = await conn.fetchval("SELECT count(*) FROM staging.fato_cotacao_regional")
        print(f"  Linhas: {c1}")

    r2 = await conn.fetchval(
        "SELECT count(*) FROM information_schema.views WHERE table_schema='staging' AND table_name='vw_cotacao_regional_dedup'"
    )
    print(f"vw_cotacao_regional_dedup: {'EXISTE' if r2 else 'AUSENTE'}")

    r3 = await conn.fetchval(
        "SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria='HORTIFRUTIGRANJEIROS'"
    )
    print(f"Categoria HORTIFRUTIGRANJEIROS: {'EXISTE id=' + str(r3) if r3 else 'AUSENTE'}")

    r4 = await conn.fetchval(
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='mart' AND table_name='vw_api_produtos_sazonalidade'"
    )
    print(f"vw_api_produtos_sazonalidade: {'EXISTE' if r4 else 'AUSENTE'}")
    if r4:
        mv = await conn.fetchval("SELECT count(*) FROM mart.vw_api_produtos_sazonalidade")
        print(f"  Linhas na MV: {mv}")

    await conn.close()

asyncio.run(check())
