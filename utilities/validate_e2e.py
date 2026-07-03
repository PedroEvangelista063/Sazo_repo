import sys, asyncio, logging, json, uuid
sys.path.insert(0, '.')
logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

async def validate_e2e():
    from pipeline.scraper.adapters.agentic_html import AgenticHtmlAdapter
    from pipeline.scraper.data_normalizer import DataNormalizer
    from pipeline.scraper.ceasa_spider import CotacaoHistorica
    from pipeline.run_scraper_historico import formatar_staging, STAGING_COLUNAS_FUZZY
    import polars as pl
    import asyncpg

    DB_URL = 'postgresql://postgres:postgres@localhost:5432/quero_comprar'

    # STEP 1: Coletar de CEASA PR Hoje (fonte que funcionou no dry-run)
    print("=" * 60)
    print("VALIDACAO E2E - COLETA -> NORMALIZER -> DB")
    print("=" * 60)
    print()
    print("[1/4] COLETA: CEASA PR Hoje (celepar7)...")
    adapter = AgenticHtmlAdapter(
        url='https://celepar7.pr.gov.br/ceasa/hoje.asp',
        uf='PR', municipio='Curitiba', fonte='CEASA-PR'
    )
    items_raw = await adapter.fetch()
    print("  Extraidos: %d itens brutos" % len(items_raw))
    for item in items_raw[:5]:
        print("    %-40s R$ %s" % (item.produto_original[:40], item.preco_bruto))

    # STEP 2: Normalizer
    print()
    print("[2/4] NORMALIZACAO...")
    normalizer = DataNormalizer(fuzzy_cutoff=75.0)
    normalizer.carregar_csv()

    historicas = [
        CotacaoHistorica(
            produto_original=i.produto_original, uf=i.uf or 'PR',
            municipio=i.municipio or 'Curitiba', ano=2026, mes=7,
            preco_bruto=i.preco_bruto, fonte=i.fonte or 'CEASA-PR'
        )
        for i in items_raw
    ]

    df_staging = formatar_staging(historicas, normalizer)
    print("  Staging: %d linhas (%d high + %d fuzzy)" % (
        df_staging.height,
        df_staging.filter(pl.col('is_fuzzy') == False).height,
        df_staging.filter(pl.col('is_fuzzy') == True).height
    ) if df_staging.height > 0 else "  0 items passaram no normalizer")
    
    if df_staging.height == 0:
        print("  NADA A CARREGAR - abortando")
        return

    for row in df_staging.head(5).iter_rows():
        print("    %s" % (row,))

    # STEP 3: Conectar DB e carregar
    print()
    print("[3/4] CARGA NO BANCO...")
    conn = await asyncpg.connect(DB_URL)

    # Ensure dimensions
    all_produtos = set(df_staging['produto'].to_list())
    all_ufs = set(df_staging['uf'].to_list())

    for p in all_produtos:
        await conn.execute("INSERT INTO staging.dim_produto (nome_produto) VALUES ($1) ON CONFLICT DO NOTHING", p)
    for u in all_ufs:
        await conn.execute("INSERT INTO staging.dim_localidade (uf, municipio_id, municipio_nome) VALUES ($1, '', '') ON CONFLICT (uf, municipio_id) DO NOTHING", u)

    prod_map = {r['nome_produto']: r['id_produto'] for r in await conn.fetch("SELECT id_produto, nome_produto FROM staging.dim_produto")}
    loc_map = {r['uf']: r['id_localidade'] for r in await conn.fetch("SELECT id_localidade, uf FROM staging.dim_localidade WHERE municipio_id = '' OR municipio_id IS NULL")}

    batch_id = str(uuid.uuid4())
    rows_inserted = 0
    seen = set()

    for row in df_staging.iter_rows(named=True):
        id_prod = prod_map.get(row['produto'])
        id_loc = loc_map.get(row['uf'])
        if not id_prod or not id_loc:
            continue
        preco = row['valor_produto_kg']
        if preco <= 0:
            continue
        key = (id_prod, id_loc, row['ano'], row['mes'])
        if key in seen:
            continue
        seen.add(key)
        await conn.execute(
            "INSERT INTO staging.fact_precos_mensais (id_produto, id_localidade, ano, mes, preco_medio, batch_id) "
            "VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT (id_produto, id_localidade, ano, mes) "
            "DO UPDATE SET preco_medio = EXCLUDED.preco_medio, batch_id = EXCLUDED.batch_id, loaded_at = NOW()",
            id_prod, id_loc, row['ano'], row['mes'], row['valor_produto_kg'], batch_id
        )
        rows_inserted += 1

    await conn.execute("COMMIT")
    print("  Inseridas/atualizadas: %d linhas (batch=%s)" % (rows_inserted, batch_id[:8]))

    # STEP 4: Verificar persistencia
    print()
    print("[4/4] VERIFICACAO...")
    count = await conn.fetchval(
        "SELECT count(*) FROM staging.fact_precos_mensais WHERE batch_id = $1", batch_id
    )
    amostra = await conn.fetch(
        "SELECT fp.preco_medio, p.nome_produto, l.uf, fp.ano, fp.mes, fp.batch_id "
        "FROM staging.fact_precos_mensais fp "
        "JOIN staging.dim_produto p ON p.id_produto = fp.id_produto "
        "JOIN staging.dim_localidade l ON l.id_localidade = fp.id_localidade "
        "WHERE fp.batch_id = $1 LIMIT 5", batch_id
    )
    print("  Registros com batch_id %s: %d" % (batch_id[:8], count))
    for r in amostra:
        print("    %-30s %-3s R$ %.2f" % (r['nome_produto'][:30], r['uf'], r['preco_medio']))
    
    total_geral = await conn.fetchval("SELECT count(*) FROM staging.fact_precos_mensais")
    print("  Total geral na fact_precos_mensais: %d" % total_geral)

    await conn.close()
    print()
    print("VALIDACAO E2E CONCLUIDA - dados coletados, normalizados e persistidos")

asyncio.run(validate_e2e())