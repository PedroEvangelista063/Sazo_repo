import sys, asyncio
sys.path.insert(0, '.')
import asyncpg

async def check_db():
    db_url = 'postgresql://postgres:postgres@localhost:5432/quero_comprar'
    try:
        conn = await asyncpg.connect(db_url)
        schemas = ['staging', 'raw']
        tables = await conn.fetch(
            "SELECT table_schema, table_name FROM information_schema.tables "
            "WHERE table_schema = ANY($1) ORDER BY table_schema, table_name",
            schemas
        )
        print("TABELAS ENCONTRADAS:")
        for t in tables:
            schema = t['table_schema']
            table = t['table_name']
            count = await conn.fetchval(
                'SELECT count(*) FROM "' + schema + '"."' + table + '"'
            )
            print("  %s.%s: %d linhas" % (schema, table, count))

        print()
        print("ULTIMAS 5 LINHAS (fact_precos_mensais):")
        try:
            rows = await conn.fetch(
                "SELECT fp.id_produto, fp.id_localidade, fp.ano, fp.mes, "
                "fp.preco_medio, fp.batch_id, p.nome_produto, l.uf "
                "FROM staging.fact_precos_mensais fp "
                "LEFT JOIN staging.dim_produto p ON p.id_produto = fp.id_produto "
                "LEFT JOIN staging.dim_localidade l ON l.id_localidade = fp.id_localidade "
                "ORDER BY fp.loaded_at DESC LIMIT 5"
            )
            for r in rows:
                print("  %-25s %-3s %04d/%02d R$ %.2f batch=%s" % (
                    r['nome_produto'][:25], r['uf'], r['ano'], r['mes'],
                    r['preco_medio'], str(r['batch_id'])[:8]
                ))
        except Exception as e:
            print("  (sem dados ou tabela vazia: %s)" % e)

        await conn.close()
        print()
        print("CONEXAO OK - banco acessivel")
    except Exception as e:
        print("ERRO DE CONEXAO: %s" % e)

asyncio.run(check_db())