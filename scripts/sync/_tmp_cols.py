# -*- coding: utf-8 -*-
import asyncio, asyncpg
async def main():
    conn = await asyncpg.connect('postgresql://postgres:postgres@localhost:5432/quero_comprar')
    rows = await conn.fetch("SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = 'staging' AND table_name = 'dim_produto' ORDER BY ordinal_position")
    for r in rows:
        print("  %-35s %-20s nullable=%-5s default=%s" % (r['column_name'], r['data_type'], r['is_nullable'], str(r['column_default'])[:60] if r['column_default'] else 'NULL'))
    await conn.close()
asyncio.run(main())
