import asyncpg, asyncio

async def check():
    conn = await asyncpg.connect('postgresql://postgres:postgres@localhost:5432/quero_comprar')

    # Latest month with data per UF
    latest = await conn.fetch("""
        SELECT l.uf, l.municipio_nome,
               max(f.ano) as ultimo_ano,
               max(f.mes) filter (where f.ano = (select max(ano) from staging.fact_precos_mensais)) as ultimo_mes,
               count(*)::int as total_linhas,
               count(*) filter (where f.fonte = 'SCRAPER')::int as scraper,
               count(*) filter (where f.fonte = 'IBGE_SIDRA_MATH_MODEL')::int as sidra
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
        GROUP BY l.uf, l.municipio_nome
        ORDER BY l.uf, l.municipio_nome
    """)
    print("=== Dados por UF/municipio ===")
    for r in latest:
        print(f"  {r['uf']:2s} {r['municipio_nome']:20s} ultimo={r['ultimo_ano']}/{r['ultimo_mes']:02d}  total={r['total_linhas']:5d}  scraper={r['scraper']:5d}  sidra={r['sidra']:5d}")

    # Months with data availability
    months = await conn.fetch("""
        SELECT ano, mes, count(distinct f.id_localidade)::int as ufs
        FROM staging.fact_precos_mensais f
        GROUP BY ano, mes ORDER BY ano, mes
    """)
    print("\n=== Cobertura por mes ===")
    for m in months:
        print(f"  {m['ano']}/{m['mes']:02d}: {m['ufs']:3d} localidades")

    await conn.close()
asyncio.run(check())
