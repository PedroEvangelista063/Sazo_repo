import asyncio
import asyncpg
import os

async def check():
    conn = await asyncpg.connect(
        os.environ.get('DATABASE_URL', 'postgresql://postgres:postgres@localhost:5432/quero_comprar')
    )
    total_prod = await conn.fetchval('SELECT count(*) FROM staging.dim_produto')
    total_fato = await conn.fetchval('SELECT count(*) FROM staging.fact_precos_mensais')
    meses = await conn.fetch('SELECT ano, mes, count(*) as cnt FROM staging.fact_precos_mensais GROUP BY ano, mes ORDER BY ano, mes')
    mv_count = await conn.fetchval('SELECT count(*) FROM mart.vw_api_produtos_sazonalidade')
    await conn.close()
    print(f'Produtos (dim_produto): {total_prod}')
    print(f'Fact precos: {total_fato}')
    print(f'MV API rows: {mv_count}')
    print(f'Meses disponiveis:')
    for m in meses:
        print(f'  {m["ano"]}-{m["mes"]:02d}: {m["cnt"]} registros')

asyncio.run(check())
