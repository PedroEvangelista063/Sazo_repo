import subprocess, re

result = subprocess.run([
    r'C:\Program Files\PostgreSQL\17\bin\pg_dump.exe',
    '--dbname=postgresql://postgres:postgres@localhost:5432/quero_comprar',
    '--data-only', '--column-inserts', '--rows-per-insert=100',
    '--no-owner', '--no-acl', '--no-comments',
    '--table=mart.sazonalidade_produto'
], capture_output=True, text=True, timeout=120)
sql = result.stdout
idx = sql.find('INSERT')
if idx > 0:
    sql = sql[idx:]

def add_on_conflict(m):
    block = m.group(0).rstrip()
    if block.endswith(';'):
        block = block[:-1] + ' ON CONFLICT DO NOTHING;'
    return block

sql = re.sub(r'INSERT.+?;(?:\n|$)', add_on_conflict, sql, flags=re.DOTALL)
out = r'D:\D\PROJETOS EM ANDAMENTO\quero_comprar_vg\_tmp_sazonalidade.sql'
open(out, 'w', encoding='utf-8').write(sql)
size = len(sql)
cnt = sql.count('INSERT')
print(f'{size} bytes, {cnt} insert blocks')
