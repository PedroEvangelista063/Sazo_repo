#!/usr/bin/env python3
"""
Restore data from local PostgreSQL to Supabase via supabase db query --linked
Exports data as INSERT statements and executes in batches.
"""
import subprocess
import os
import sys
import json

# Local DB connection
LOCAL_DB = "quero_comprar"
LOCAL_USER = "postgres"
LOCAL_HOST = "localhost"
PGPASSWORD = "postgres"
PSQL = r"C:\Program Files\PostgreSQL\17\bin\psql.exe"
NPX = r"C:\Program Files\nodejs\npx.cmd"

# Tables in FK order
TABLES = [
    # 1. Dimensions (no FK)
    ("staging", "dim_produto"),
    ("staging", "dim_localidade"),
    ("staging", "dim_categoria"),
    ("staging", "dim_conab_produto_mapping"),
    # 2. Facts (FK to dimensions)
    ("staging", "fact_precos_mensais"),
    ("staging", "precos_rejeitados"),
    ("staging", "confianca_baseline"),
    ("staging", "baseline_2025_interpolado"),
    ("staging", "fato_cotacao_regional"),
    # 3. Mart
    ("mart", "sazonalidade_produto"),
    ("mart", "sazonalidade_baseline_24_25"),
    ("mart", "sazonalidade_baseline_25_26"),
    # 4. Raw
    ("raw", "coleta_bruta"),
    ("raw", "controle_carga"),
    ("raw", "precos_uf"),
    ("raw", "precos_municipio"),
    # 5. Ops
    ("ops", "quarentena_coleta"),
    ("ops", "config_agente"),
    ("ops", "controle_erros_ddl"),
    ("ops", "audit_llm_queries"),
]

def psql_query(sql):
    """Execute SQL on local database and return output"""
    env = os.environ.copy()
    env["PGPASSWORD"] = PGPASSWORD
    env["PGCLIENTENCODING"] = "UTF8"
    result = subprocess.run(
        [PSQL, "-U", LOCAL_USER, "-h", LOCAL_HOST, "-d", LOCAL_DB, "-t", "-A", "-c", sql],
        capture_output=True, env=env, timeout=60
    )
    if result.stdout:
        return result.stdout.decode('utf-8', errors='replace').strip()
    return ""

def get_count(schema, table):
    """Get row count from local database"""
    result = psql_query(f"SELECT COUNT(*) FROM {schema}.{table};")
    return int(result) if result else 0

def get_remote_columns(schema, table):
    """Get column names from Supabase using JSON output"""
    result = subprocess.run(
        [NPX, "supabase", "db", "query", "--linked", "--output-format", "json",
         f"SELECT column_name FROM information_schema.columns WHERE table_schema = '{schema}' AND table_name = '{table}' ORDER BY ordinal_position;"],
        capture_output=True, timeout=30
    )
    if result.stdout:
        output = result.stdout.decode('utf-8', errors='replace')
        try:
            data = json.loads(output)
            if isinstance(data, list):
                return [row.get('column_name', '') for row in data if row.get('column_name')]
        except json.JSONDecodeError:
            pass
    return []

def export_table(schema, table, chunk_size=500):
    """Export table data as INSERT statements in chunks"""
    count = get_count(schema, table)
    if count == 0:
        return []
    
    # Get remote columns (Supabase schema)
    remote_cols = get_remote_columns(schema, table)
    if not remote_cols:
        print(f"    ⚠️  No columns found in Supabase for {schema}.{table}")
        return []
    
    # Get local column names
    cols_result = psql_query(
        f"SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) "
        f"FROM information_schema.columns "
        f"WHERE table_schema = '{schema}' AND table_name = '{table}';"
    )
    
    if not cols_result:
        return []
    
    local_cols = cols_result.split(", ")
    
    # Only use columns that exist in both local and remote
    cols = [c for c in local_cols if c in remote_cols]
    
    if len(cols) < len(remote_cols):
        missing = [c for c in remote_cols if c not in local_cols]
        print(f"    ⚠️  Missing columns in local: {missing}")
    
    # Export as JSON for easier handling (only matching columns)
    cols_str = ", ".join(cols)
    json_result = psql_query(
        f"SELECT row_to_json(t) FROM (SELECT {cols_str} FROM {schema}.{table}) t;"
    )
    
    if not json_result:
        return []
    
    # Parse JSON lines
    rows = []
    for line in json_result.split("\n"):
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    
    # Generate INSERT statements in chunks
    chunks = []
    for i in range(0, len(rows), chunk_size):
        chunk = rows[i:i+chunk_size]
        inserts = []
        for row in chunk:
            values = []
            for col in cols:
                val = row.get(col)
                if val is None:
                    values.append("NULL")
                elif isinstance(val, bool):
                    values.append("TRUE" if val else "FALSE")
                elif isinstance(val, (int, float)):
                    values.append(str(val))
                elif isinstance(val, dict):
                    values.append(f"'{json.dumps(val).replace(chr(39), chr(39)+chr(39))}'::jsonb")
                else:
                    escaped = str(val).replace("'", "''")
                    values.append(f"'{escaped}'")
            
            inserts.append(f"INSERT INTO {schema}.{table} ({', '.join(cols)}) VALUES ({', '.join(values)}) ON CONFLICT DO NOTHING;")
        
        chunks.append("\n".join(inserts))
    
    return chunks

def execute_on_supabase(sql):
    """Execute SQL on Supabase via supabase db query --linked"""
    # Write SQL to temp file
    temp_file = os.path.join(os.environ.get("TEMP", "."), "supabase_restore_temp.sql")
    with open(temp_file, "w", encoding="utf-8") as f:
        f.write(sql)
    
    result = subprocess.run(
        [NPX, "supabase", "db", "query", "--linked", "--file", temp_file],
        capture_output=True, timeout=120
    )
    
    # Clean up temp file
    try:
        os.remove(temp_file)
    except:
        pass
    
    stdout = result.stdout.decode('utf-8', errors='replace') if result.stdout else ""
    stderr = result.stderr.decode('utf-8', errors='replace') if result.stderr else ""
    return result.returncode, stdout, stderr

def main():
    print("=" * 60)
    print("SUPABASE DATA RESTORE")
    print("=" * 60)
    
    total_inserted = 0
    errors = []
    
    for schema, table in TABLES:
        count = get_count(schema, table)
        if count == 0:
            print(f"  ⏭  {schema}.{table}: 0 rows (skipped)")
            continue
        
        print(f"\n  📦 {schema}.{table}: {count} rows")
        
        chunks = export_table(schema, table)
        if not chunks:
            print(f"    ⚠️  No data exported")
            continue
        
        table_inserted = 0
        for i, chunk in enumerate(chunks):
            rc, stdout, stderr = execute_on_supabase(chunk)
            if rc == 0:
                table_inserted += chunk.count("INSERT")
            else:
                error_msg = stderr[:200] if stderr else "Unknown error"
                errors.append(f"{schema}.{table} chunk {i}: {error_msg}")
                print(f"    ❌ Chunk {i+1}/{len(chunks)}: {error_msg[:80]}")
        
        total_inserted += table_inserted
        print(f"    ✅ {table_inserted}/{count} rows inserted")
    
    print("\n" + "=" * 60)
    print(f"TOTAL: {total_inserted} rows inserted")
    if errors:
        print(f"ERRORS: {len(errors)}")
        for e in errors[:5]:
            print(f"  - {e[:100]}")
    print("=" * 60)
    
    return 0 if not errors else 1

if __name__ == '__main__':
    sys.exit(main())
