import asyncio, asyncpg

async def main():
    conn = await asyncpg.connect('postgresql://postgres:postgres@localhost:5432/quero_comprar')
    print("=== fact_precos_mensais ===")
    cols = await conn.fetch(
        "SELECT column_name, data_type, is_nullable FROM information_schema.columns "
        "WHERE table_schema='staging' AND table_name='fact_precos_mensais' "
        "ORDER BY ordinal_position"
    )
    for c in cols:
        print(f"  {c['column_name']:25s} {c['data_type']:20s} nullable={c['is_nullable']}")

    print("\n=== dim_localidade ===")
    cols2 = await conn.fetch(
        "SELECT column_name, data_type FROM information_schema.columns "
        "WHERE table_schema='staging' AND table_name='dim_localidade' "
        "ORDER BY ordinal_position"
    )
    for c in cols2:
        print(f"  {c['column_name']:25s} {c['data_type']}")

    print("\n=== dim_produto (relevant columns) ===")
    cols3 = await conn.fetch(
        "SELECT column_name, data_type FROM information_schema.columns "
        "WHERE table_schema='staging' AND table_name='dim_produto' "
        "ORDER BY ordinal_position"
    )
    for c in cols3:
        print(f"  {c['column_name']:25s} {c['data_type']}")

    # Check if the `fonte` column exists
    print("\n=== Checking for 'fonte' column in fact_precos_mensais ===")
    fonte_check = await conn.fetch(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_schema='staging' AND table_name='fact_precos_mensais' "
        "AND column_name IN ('fonte', 'is_interpolado')"
    )
    for c in fonte_check:
        print(f"  Found: {c['column_name']}")

    # Sample dim_produto records
    print("\n=== Sample dim_produto records (first 5) ===")
    samples = await conn.fetch("SELECT id_produto, nome_produto, status_fonte, classificao_produto FROM staging.dim_produto WHERE status_fonte='MAPEADA' LIMIT 5")
    for s in samples:
        print(f"  id={s['id_produto']} nome={s['nome_produto'][:40]:40s} status={s['status_fonte']} classif={s['classificao_produto']}")

    # Localidades
    print("\n=== dim_localidade records ===")
    locs = await conn.fetch("SELECT id_localidade, uf, municipio_nome FROM staging.dim_localidade ORDER BY uf")
    for l in locs:
        print(f"  id={l['id_localidade']:3d} uf={l['uf']} municipio={l['municipio_nome'][:30] or 'N/A':30s}")

    await conn.close()

asyncio.run(main())
