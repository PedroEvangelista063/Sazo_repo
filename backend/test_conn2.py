import asyncio
import sys

if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

import asyncpg

async def main():
    conn = await asyncpg.connect(
        host="127.0.0.1", port=5432,
        user="role_api_reader", password="senha",
        database="quero_comprar"
    )
    q = "SELECT column_name FROM information_schema.columns WHERE table_schema='mart' AND table_name='vw_api_produtos_sazonalidade' ORDER BY ordinal_position"
    cols = await conn.fetch(q)
    for c in cols:
        print(c["column_name"])
    await conn.close()

asyncio.run(main())
