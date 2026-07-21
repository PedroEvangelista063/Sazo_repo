# -*- coding: utf-8 -*-
import asyncio, asyncpg

async def local_cols(schema, table):
    conn = await asyncpg.connect('postgresql://postgres:postgres@localhost:5432/quero_comprar')
    rows = await conn.fetch("SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema =  AND table_name =  ORDER BY ordinal_position", schema, table)
    await conn.close()
    return {r['column_name']: r for r in rows}

async def supabase_cols(schema, table):
    # Via npx supabase db query --linked
    import subprocess, json
    sql = "SELECT json_agg(json_build_object('column_name', column_name, 'data_type', data_type, 'is_nullable', is_nullable, 'column_default', column_default) ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema = '%s' AND table_name = '%s'" % (schema, table)
    result = subprocess.run(['npx', 'supabase', 'db', 'query', '--linked', sql], capture_output=True, text=True, timeout=30, cwd=r'D:\D\PROJETOS EM ANDAMENTO\quero_comprar_vg')
    # Parse the tabular output... this is unreliable
    print(result.stdout[:500])
    print(result.stderr[:500])

async def main():
    conn = await asyncpg.connect('postgresql://postgres:postgres@localhost:5432/quero_comprar')
    # Check staging.dim_produto
    print("=== local staging.dim_produto ===")
    rows = await conn.fetch("SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema = 'staging' AND table_name = 'dim_produto' ORDER BY ordinal_position")
    local_cols = {r['column_name'] for r in rows}
    for r in rows:
        print("  %-25s %-15s nullable=%s" % (r['column_name'], r['data_type'], r['is_nullable']))
    await conn.close()
    print()
    print("Missing from local (for reference): %d cols" % len(local_cols))

asyncio.run(main())
