import asyncio, asyncpg

async def main():
    conn = await asyncpg.connect('postgresql://postgres:postgres@localhost:5432/quero_comprar')
    
    # Sample fact records from 2025
    print("=== Sample fact records (2025) ===")
    samples = await conn.fetch("""
        SELECT f.ano, f.mes, f.preco_medio, f.is_interpolado, f.id_produto, f.id_localidade
        FROM staging.fact_precos_mensais f
        WHERE f.ano = 2025 AND f.mes = 1
        LIMIT 10
    """)
    for s in samples:
        print(f"  ano={s['ano']} mes={s['mes']} preco={s['preco_medio']} interpolado={s['is_interpolado']} prod_id={s['id_produto']} loc_id={s['id_localidade']}")

    # Distinct UF values in dim_localidade
    print("\n=== Distinct UFs in dim_localidade ===")
    ufs = await conn.fetch("SELECT DISTINCT uf FROM staging.dim_localidade ORDER BY uf")
    uf_list = [u['uf'].strip() for u in ufs]
    print(f"  {', '.join(uf_list)}")
    print(f"  Count: {len(uf_list)}")

    # How many distinct products have data in 2025?
    print("\n=== Products with data in 2025 ===")
    prods = await conn.fetch("""
        SELECT p.id_produto, p.nome_produto, count(f.id_fato) as records
        FROM staging.dim_produto p
        JOIN staging.fact_precos_mensais f ON f.id_produto = p.id_produto
        WHERE f.ano = 2025 AND p.status_fonte = 'MAPEADA'
        GROUP BY p.id_produto, p.nome_produto
        ORDER BY p.nome_produto
        LIMIT 40
    """)
    for p in prods:
        print(f"  id={p['id_produto']:5d} nome={p['nome_produto'][:50]:50s} records={p['records']}")

    # Count localidade per UF
    print("\n=== Localidades per UF ===")
    loc_counts = await conn.fetch("""
        SELECT uf, count(*) as locais
        FROM staging.dim_localidade
        GROUP BY uf
        ORDER BY uf
    """)
    for l in loc_counts:
        print(f"  {l['uf']}: {l['locais']} localidades")

    await conn.close()

asyncio.run(main())
