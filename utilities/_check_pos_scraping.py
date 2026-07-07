import asyncio, asyncpg, sys
if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

async def check():
    conn = await asyncpg.connect("postgresql://postgres:postgres@localhost:5432/quero_comprar")
    
    print("=== CHECK POS-SCRAPING ===")
    
    # Total fact
    f = await conn.fetchval("SELECT count(*) FROM staging.fact_precos_mensais")
    print(f"fact_precos_mensais: {f} linhas")
    
    # fato_cotacao_regional
    fcr = await conn.fetchval("SELECT count(*) FROM staging.fato_cotacao_regional")
    print(f"fato_cotacao_regional: {fcr} linhas")
    
    # Coverage for 2026-06 and 2026-07 per UF
    for mes in [6, 7]:
        rows = await conn.fetch("""
            SELECT l.uf, count(DISTINCT f.id_produto) as qtd
            FROM staging.fact_precos_mensais f
            JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
            WHERE f.ano = 2026 AND f.mes = $1
            GROUP BY l.uf
            ORDER BY l.uf
        """, mes)
        print(f"\n2026-{mes:02d} coverage:")
        for r in rows:
            print(f"  {r['uf']}: {r['qtd']} produtos")
    
    # Check specific UFs that were zero before
    zero_antes = ["AC", "AM", "AP", "GO", "PA", "PI", "RO", "RR", "SE", "BR"]
    for uf in zero_antes:
        for mes in [6, 7]:
            qtd = await conn.fetchval("""
                SELECT count(DISTINCT f.id_produto)
                FROM staging.fact_precos_mensais f
                JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
                WHERE l.uf = $1 AND f.ano = 2026 AND f.mes = $2
            """, uf, mes)
            if qtd and qtd > 0:
                print(f"  >>> {uf} 2026-{mes:02d}: AGORA TEM {qtd} produtos (antes: 0)")
    
    await conn.close()

asyncio.run(check())
