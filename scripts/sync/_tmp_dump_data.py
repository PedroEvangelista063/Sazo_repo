import subprocess, re

def dump_and_prep(table, outfile):
    result = subprocess.run([
        r'C:\Program Files\PostgreSQL\17\bin\pg_dump.exe',
        '--dbname=postgresql://postgres:postgres@localhost:5432/quero_comprar',
        '--data-only', '--column-inserts', '--rows-per-insert=100',
        '--no-owner', '--no-acl', '--no-comments',
        '--table=' + table
    ], capture_output=True, text=True, timeout=120)
    sql = result.stdout
    idx = sql.find('INSERT')
    if idx > 0:
        sql = sql[idx:]
    def add_oc(m):
        block = m.group(0).rstrip()
        if block.endswith(';'):
            block = block[:-1] + ' ON CONFLICT DO NOTHING;'
        return block
    sql = re.sub(r'INSERT.+?;(?:\n|$)', add_oc, sql, flags=re.DOTALL)
    open(outfile, 'w', encoding='utf-8').write(sql)
    cnt = sql.count('INSERT')
    print(f'{table}: {len(sql)} bytes, {cnt} blocks')

dump_and_prep('staging.fact_precos_mensais', r'D:\D\PROJETOS EM ANDAMENTO\quero_comprar_vg\_tmp_fact_precos.sql')
dump_and_prep('staging.dim_produto', r'D:\D\PROJETOS EM ANDAMENTO\quero_comprar_vg\_tmp_dim_produto.sql')
print('Done')
