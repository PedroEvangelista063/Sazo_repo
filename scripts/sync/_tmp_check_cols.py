import asyncpg, asyncio
async def check():
    conn = await asyncpg.connect('postgresql://postgres:postgres@localhost:5432/quero_comprar')
    rows = await conn.fetch("SELECT column_name, ordinal_position FROM information_schema.columns WHERE table_schema = 'mart' AND table_name = 'sazonalidade_produto' ORDER BY ordinal_position")
    for r in rows:
        print(f'{r["ordinal_position"]}: {r["column_name"]}')
    await conn.close()
asyncio.run(check())
