import asyncio, sys, os
sys.path.insert(0, '.')
os.environ['PYTHONIOENCODING'] = 'utf-8'
import asyncpg

DB_URL = 'postgresql://postgres:postgres@localhost:5432/quero_comprar'

async def run():
    conn = await asyncpg.connect(DB_URL)

    print("=" * 65)
    print("AUDITORIA COMPLETA: DB -> API -> FRONTEND")
    print("=" * 65)

    # CHECK 0: Coverage por mes/ano
    print("\n[0] COBERTURA MENSAL NA fact_precos_mensais")
    rows = await conn.fetch("""
        SELECT ano, mes, COUNT(*) as total, COUNT(DISTINCT id_produto) as produtos,
               COUNT(DISTINCT id_localidade) as localidades
        FROM staging.fact_precos_mensais
        GROUP BY ano, mes ORDER BY ano DESC, mes DESC
        LIMIT 30
    """)
    for r in rows:
        print("  %04d/%02d: %5d registros | %3d produtos | %3d locais" % (r['ano'], r['mes'], r['total'], r['produtos'], r['localidades']))

    # CHECK 1: Produtos B2B na MV
    print("\n[1.1] PRODUTOS B2B NA MV (deve ser 0)")
    try:
        r = await conn.fetchval("SELECT COUNT(*) FROM mart.vw_api_produtos_sazonalidade WHERE categoria_b2c != 'ALIMENTO_VAREJO'")
        print("  B2B vazados: %d %s" % (r, 'OK' if r == 0 else 'CRITICO'))
    except Exception as e:
        print("  MV nao existe: %s" % e)

    # CHECK 2: INSUFICIENTE na MV
    print("\n[1.2] INSUFICIENTE NA MV (deve ser 0)")
    try:
        r = await conn.fetchval("SELECT COUNT(*) FROM mart.vw_api_produtos_sazonalidade WHERE status_cor = 'INSUFICIENTE'")
        print("  INSUFICIENTE vazados: %d %s" % (r, 'OK' if r == 0 else 'CRITICO'))
    except Exception as e:
        print("  (tabela nao existe: %s)" % e)

    # CHECK 3: Distribuicao do semaforo
    print("\n[1.3] DISTRIBUICAO DO SEMAFORO")
    try:
        rows = await conn.fetch("""
            SELECT status_cor, COUNT(*) as total,
                   ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as pct
            FROM mart.vw_api_produtos_sazonalidade
            GROUP BY status_cor ORDER BY status_cor
        """)
        for r in rows:
            print("  %s: %d (%.1f%%)" % (r['status_cor'], r['total'], r['pct']))
        total = sum(r['total'] for r in rows)
        print("  Total na MV: %d" % total)
    except Exception as e:
        print("  (tabela nao existe: %s)" % e)

    # CHECK 4: Campos obrigatorios
    print("\n[1.4] CAMPOS OBRIGATORIOS (todos devem ser 0)")
    try:
        r = await conn.fetchrow("""
            SELECT
                COUNT(*) FILTER (WHERE produto IS NULL OR produto = '') AS nome_nulo,
                COUNT(*) FILTER (WHERE uf IS NULL OR LENGTH(uf) != 2) AS uf_invalida,
                COUNT(*) FILTER (WHERE status_cor IS NULL) AS status_nulo,
                COUNT(*) FILTER (WHERE ano IS NULL OR ano < 2020 OR ano > 2030) AS ano_invalido,
                COUNT(*) FILTER (WHERE mes IS NULL OR mes < 1 OR mes > 12) AS mes_invalido
            FROM mart.vw_api_produtos_sazonalidade
        """)
        for k, v in r.items():
            print("  %s: %d %s" % (k, v, 'OK' if v == 0 else 'PROBLEMA'))
    except Exception as e:
        print("  (tabela nao existe: %s)" % e)

    # CHECK 5: Precos invalidos na fact
    print("\n[1.5] PRECO_INVALIDOS (deve ser 0)")
    r = await conn.fetchval("SELECT COUNT(*) FROM staging.fact_precos_mensais WHERE preco_medio <= 0 OR preco_medio IS NULL")
    print("  Precos <= 0: %d %s" % (r, 'OK' if r == 0 else 'PROBLEMA'))

    # CHECK 6: Precos rejeitados
    print("\n[1.6] PRECOS REJEITADOS (anomalias > 500%)")
    try:
        rows = await conn.fetch("""
            SELECT p.nome_produto, l.uf, pr.razao, pr.rejeitado_em
            FROM staging.precos_rejeitados pr
            JOIN staging.dim_produto p ON p.id_produto = pr.id_produto
            JOIN staging.dim_localidade l ON l.id_localidade = pr.id_localidade
            ORDER BY pr.rejeitado_em DESC LIMIT 5
        """)
        for r in rows:
            nome = r['nome_produto'].encode('ascii', 'replace').decode('ascii')
            print("  %-25s %-3s razao=%s %s" % (nome[:25], r['uf'], r['razao'], r['rejeitado_em']))
    except UnicodeEncodeError as e:
        print("  (encoding error no nome do produto: %s)" % e)

    # CHECK 7: Freshness
    print("\n[1.7] FRESHNESS DOS DADOS")
    try:
        r = await conn.fetchrow("""
            SELECT
                MAX(ano || '-' || LPAD(mes::TEXT, 2, '0')) AS data_mais_recente,
                MIN(ano || '-' || LPAD(mes::TEXT, 2, '0')) AS data_mais_antiga,
                COUNT(DISTINCT ano || '-' || mes) AS periodos_distintos,
                COUNT(*) AS total_registros
            FROM mart.vw_api_produtos_sazonalidade
        """)
        print("  Mais recente: %s" % r['data_mais_recente'])
        print("  Mais antiga:  %s" % r['data_mais_antiga'])
        print("  Periodos:     %d" % r['periodos_distintos'])
        print("  Total:        %d" % r['total_registros'])
    except Exception as e:
        print("  (tabela nao existe: %s)" % e)

    # CHECK 8: Fallback proportion
    print("\n[1.8] PROPORCAO DE FALLBACK")
    try:
        rows = await conn.fetch("""
            SELECT usou_fallback_12m, COUNT(*) as total,
                   ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as pct
            FROM mart.vw_api_produtos_sazonalidade
            GROUP BY usou_fallback_12m
        """)
        for r in rows:
            print("  usou_fallback_12m=%s: %d (%.1f%%)" % (r['usou_fallback_12m'], r['total'], r['pct']))
    except Exception as e:
        print("  (tabela nao existe: %s)" % e)

    # CHECK 9: Baseline 2025 coverage
    print("\n[1.9] Cobertura BASELINE 2025 vs NOVOS PRODUTOS")
    rows = await conn.fetch("""
        SELECT ano, COUNT(*) as total FROM staging.baseline_2025_interpolado
        GROUP BY ano ORDER BY ano
    """)
    for r in rows:
        print("  %s: %d registros" % (r['ano'], r['total']))

    # CHECK 10: Controle de carga
    print("\n[1.10] ULTIMOS BATCHES DE CARGA")
    try:
        rows = await conn.fetch("""
            SELECT arquivo, status, linhas_lidas, linhas_inseridas, iniciado_em
            FROM raw.controle_carga ORDER BY iniciado_em DESC LIMIT 5
        """)
        for r in rows:
            print("  %-30s %-10s lidas=%d inseridas=%d %s" % (r['arquivo'][:30], r['status'], r['linhas_lidas'], r['linhas_inseridas'], r['iniciado_em']))
    except:
        print("  (raw.controle_carga vazia ou nao existe)")

    # CHECK 11: Ultimos registros carregados
    print("\n[1.11] ULTIMOS REGISTROS INSERIDOS (full pipeline)")
    rows = await conn.fetch("""
        SELECT fp.ano, fp.mes, p.nome_produto, l.uf, fp.preco_medio, fp.batch_id, fp.loaded_at
        FROM staging.fact_precos_mensais fp
        JOIN staging.dim_produto p ON p.id_produto = fp.id_produto
        JOIN staging.dim_localidade l ON l.id_localidade = fp.id_localidade
        ORDER BY fp.loaded_at DESC LIMIT 5
    """)
    for r in rows:
        print("  %-25s %-3s %04d/%02d R$ %.2f batch=%s" % (r['nome_produto'][:25], r['uf'], r['ano'], r['mes'], r['preco_medio'], str(r['batch_id'])[:8]))

    await conn.close()
    print("\n" + "=" * 65)
    print("AUDITORIA CONCLUIDA")
    print("=" * 65)

asyncio.run(run())