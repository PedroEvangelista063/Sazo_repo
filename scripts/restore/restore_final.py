#!/usr/bin/env python3
"""Restore remaining tables to Supabase - focused on baselines and raw/ops"""
import subprocess
import os
import json
import sys

NPX = r"C:\Program Files\nodejs\npx.cmd"
PSQL = r"C:\Program Files\PostgreSQL\17\bin\psql.exe"
PGPASSWORD = "postgres"

TABLES = [
    ("mart", "sazonalidade_baseline_24_25"),
    ("mart", "sazonalidade_baseline_25_26"),
    ("staging", "confianca_baseline"),
    ("staging", "baseline_2025_interpolado"),
    ("staging", "fato_cotacao_regional"),
    ("staging", "dim_conab_produto_mapping"),
    ("raw", "coleta_bruta"),
    ("raw", "controle_carga"),
    ("raw", "precos_uf"),
    ("raw", "precos_municipio"),
    ("ops", "quarentena_coleta"),
    ("ops", "config_agente"),
    ("ops", "controle_erros_ddl"),
    ("ops", "audit_llm_queries"),
]

def psql(sql):
    env = os.environ.copy()
    env["PGPASSWORD"] = PGPASSWORD
    env["PGCLIENTENCODING"] = "UTF8"
    r = subprocess.run([PSQL, "-U", "postgres", "-h", "localhost", "-d", "quero_comprar", "-t", "-A", "-c", sql], capture_output=True, env=env, timeout=60)
    return r.stdout.decode('utf-8', errors='replace').strip() if r.stdout else ""

def get_remote_cols(schema, table):
    r = subprocess.run([NPX, "supabase", "db", "query", "--linked", "--output-format", "json",
        f"SELECT column_name FROM information_schema.columns WHERE table_schema='{schema}' AND table_name='{table}' ORDER BY ordinal_position;"], capture_output=True, timeout=30)
    if r.stdout:
        try:
            return [x['column_name'] for x in json.loads(r.stdout.decode('utf-8', errors='replace'))]
        except: pass
    return []

def restore_table(schema, table):
    count = int(psql(f"SELECT COUNT(*) FROM {schema}.{table};") or 0)
    if count == 0:
        print(f"  ⏭  {schema}.{table}: 0 rows")
        return 0
    
    remote_cols = get_remote_cols(schema, table)
    if not remote_cols:
        print(f"  ⚠️  {schema}.{table}: no remote columns")
        return 0
    
    local_cols_result = psql(f"SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='{schema}' AND table_name='{table}';")
    local_cols = [c.strip() for c in local_cols_result.split(",")] if local_cols_result else []
    cols = [c for c in local_cols if c in remote_cols]
    
    if not cols:
        print(f"  ⚠️  {schema}.{table}: no matching columns")
        return 0
    
    cols_str = ", ".join(cols)
    json_result = psql(f"SELECT row_to_json(t) FROM (SELECT {cols_str} FROM {schema}.{table}) t;")
    
    if not json_result:
        return 0
    
    rows = []
    for line in json_result.split("\n"):
        line = line.strip()
        if line:
            try: rows.append(json.loads(line))
            except: continue
    
    inserted = 0
    chunk_size = 100
    for i in range(0, len(rows), chunk_size):
        chunk = rows[i:i+chunk_size]
        inserts = []
        for row in chunk:
            vals = []
            for col in cols:
                v = row.get(col)
                if v is None: vals.append("NULL")
                elif isinstance(v, bool): vals.append("TRUE" if v else "FALSE")
                elif isinstance(v, (int, float)): vals.append(str(v))
                elif isinstance(v, dict): vals.append(f"'{json.dumps(v).replace(chr(39), chr(39)+chr(39))}'::jsonb")
                else: vals.append(f"'{str(v).replace(chr(39), chr(39)+chr(39))}'")
            inserts.append(f"INSERT INTO {schema}.{table} ({', '.join(cols)}) VALUES ({', '.join(vals)}) ON CONFLICT DO NOTHING;")
        
        sql = "\n".join(inserts)
        tmp = os.path.join(os.environ.get("TEMP", "."), "restore_tmp.sql")
        with open(tmp, "w", encoding="utf-8") as f: f.write(sql)
        
        r = subprocess.run([NPX, "supabase", "db", "query", "--linked", "--file", tmp], capture_output=True, timeout=120)
        if r.returncode == 0:
            inserted += len(inserts)
        else:
            err = r.stderr.decode('utf-8', errors='replace')[:150] if r.stderr else "error"
            print(f"    ❌ chunk {i//chunk_size+1}: {err}")
    
    return inserted

def main():
    print("=" * 50)
    print("RESTORE FINAL - Baselines + Raw + Ops")
    print("=" * 50)
    total = 0
    for schema, table in TABLES:
        print(f"\n📦 {schema}.{table}")
        n = restore_table(schema, table)
        total += n
        print(f"    ✅ {n} rows")
    print(f"\n{'='*50}")
    print(f"TOTAL: {total} rows inserted")
    print("=" * 50)

if __name__ == '__main__':
    main()
