#!/usr/bin/env python3
"""
Restore missing data from local PostgreSQL to Supabase.
Only processes tables where local count > remote count.
Uses supabase db query --linked tunnel (DNS-independent on Windows).
"""
import subprocess, os, json, sys

NPX = r"C:\Program Files\nodejs\npx.cmd"
PSQL = r"C:\Program Files\PostgreSQL\17\bin\psql.exe"

LOCAL = ["postgres", "localhost", "quero_comprar"]

def psql(sql):
    env = os.environ.copy(); env["PGPASSWORD"] = "postgres"
    env["PGCLIENTENCODING"] = "UTF8"
    r = subprocess.run([PSQL, "-U", LOCAL[0], "-h", LOCAL[1], "-d", LOCAL[2],
        "-t", "-A", "-c", sql], capture_output=True, env=env, timeout=60)
    return r.stdout.decode('utf-8', errors='replace').strip() if r.stdout else ""

def remote_count(schema, table):
    r = subprocess.run([NPX, "supabase", "db", "query", "--linked", "--output-format", "json",
        f"SELECT COUNT(*) as c FROM {schema}.{table};"], capture_output=True, timeout=30)
    if r.stdout:
        try: return json.loads(r.stdout.decode())[0]['c']
        except: pass
    return -1

def remote_column_info(schema, table):
    r = subprocess.run([NPX, "supabase", "db", "query", "--linked", "--output-format", "json",
        f"SELECT column_name, is_nullable FROM information_schema.columns WHERE table_schema='{schema}' AND table_name='{table}' ORDER BY ordinal_position;"],
        capture_output=True, timeout=30)
    if r.stdout:
        try: return json.loads(r.stdout.decode())
        except: pass
    return []

def restore_table(schema, table):
    print(f"\n  >> {schema}.{table}")
    
    remote_info = remote_column_info(schema, table)
    if not remote_info:
        print("  !! No remote columns -- skipping")
        return False
    
    remote_cols = [c['column_name'] for c in remote_info]
    remote_notnull = {c['column_name'] for c in remote_info if c['is_nullable'] == 'NO'}
    
    local_cols_str = psql(
        f"SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) "
        f"FROM information_schema.columns "
        f"WHERE table_schema='{schema}' AND table_name='{table}';")
    local_cols = [c.strip() for c in local_cols_str.split(",")] if local_cols_str else []
    
    common = [c for c in local_cols if c in remote_cols]
    if not common:
        print("  !! No common columns -- skipping (schema mismatch)")
        return False
    
    missing_notnull = [c for c in remote_notnull if c not in common and c not in ('id',)]
    if missing_notnull:
        print(f"  !! Skipping: remote NOT NULL cols not in common: {missing_notnull}")
        print("  !! Schema mismatch -- handle this table manually")
        return False
    
    if len(common) < len(local_cols):
        print(f"  ** Columns skipped (not in remote): {[c for c in local_cols if c not in remote_cols]}")
    
    cols_str = ", ".join(common)
    raw = psql(f"SELECT row_to_json(t) FROM (SELECT {cols_str} FROM {schema}.{table}) t;")
    if not raw:
        print("  !! No data exported from local")
        return False
    
    rows = []
    for line in raw.split("\n"):
        line = line.strip()
        if line:
            try: rows.append(json.loads(line))
            except: continue
    
    total = len(rows)
    if total == 0:
        print("  !! No rows to insert")
        return False
    
    inserted = 0
    chunk_size = 200
    errors = 0
    
    for i in range(0, total, chunk_size):
        chunk = rows[i:i+chunk_size]
        inserts = []
        for row in chunk:
            vals = []
            for col in common:
                v = row.get(col)
                if v is None: vals.append("NULL")
                elif isinstance(v, bool): vals.append("TRUE" if v else "FALSE")
                elif isinstance(v, (int, float)): vals.append(str(v))
                elif isinstance(v, dict): vals.append(f"'{json.dumps(v).replace(chr(39), chr(39)+chr(39))}'::jsonb")
                else: vals.append(f"'{str(v).replace(chr(39), chr(39)+chr(39))}'")
            inserts.append(
                f"INSERT INTO {schema}.{table} ({', '.join(common)}) "
                f"VALUES ({', '.join(vals)}) ON CONFLICT DO NOTHING;")
        
        sql_text = "\n".join(inserts)
        tmp = os.path.join(os.environ.get("TEMP", "."), "supa_restore_tmp.sql")
        with open(tmp, "w", encoding="utf-8") as f: f.write(sql_text)
        
        r = subprocess.run([NPX, "supabase", "db", "query", "--linked", "--file", tmp],
            capture_output=True, timeout=120)
        
        if r.returncode == 0:
            inserted += len(inserts)
        else:
            err = r.stderr.decode('utf-8', errors='replace')[:200] if r.stderr else "unknown"
            print(f"\n    ** chunk {i//chunk_size+1}: {err}")
            errors += 1
        
        try: os.remove(tmp)
        except: pass
        
        pct = (i + len(chunk)) * 100 // total
        sys.stdout.write(f"\r    => {i+len(chunk):,}/{total:,} ({pct}%) inserted={inserted:,}")
        sys.stdout.flush()
    
    print(f"\n    => DONE: {inserted:,} rows inserted ({errors} errors)")
    return True

def main():
    tables = [
        ("staging", "dim_produto", 857),
        ("staging", "dim_localidade", 850),
        ("staging", "dim_categoria", 11),
        ("staging", "dim_conab_produto_mapping", 20),
        ("staging", "fact_precos_mensais", 42358),
        ("staging", "precos_rejeitados", 87),
        ("staging", "confianca_baseline", 2802),
        ("staging", "baseline_2025_interpolado", 2802),
        ("mart", "sazonalidade_produto", 62291),
        ("mart", "sazonalidade_baseline_24_25", 23449),
        ("mart", "sazonalidade_baseline_25_26", 32581),
        ("raw", "coleta_bruta", 15),
        ("ops", "quarentena_coleta", 9),
        ("ops", "config_agente", 8),
    ]
    
    print("=" * 55)
    print("SUPABASE DATA RESTORE - Missing Data Only")
    print("=" * 55)
    print(f"{'Tabela':40s} {'Local':>8s} {'Remote':>8s} {'Status':>8s}")
    print("-" * 64)
    
    to_restore = []
    for schema, table, local_cnt in tables:
        if local_cnt == 0:
            print(f"{f'{schema}.{table}':40s} {local_cnt:>8,} {'--':>8s} {'skip':>8s}")
            continue
        rc = remote_count(schema, table)
        if rc < 0:
            print(f"{f'{schema}.{table}':40s} {local_cnt:>8,} {'ERR':>8s} {'err':>8s}")
            continue
        status = "ok" if rc >= local_cnt else "MISS"
        print(f"{f'{schema}.{table}':40s} {local_cnt:>8,} {rc:>8,} {status:>8s}")
        if rc < local_cnt:
            to_restore.append((schema, table, local_cnt - rc, local_cnt))
    
    if not to_restore:
        print("\n=> All tables complete on Supabase!")
        return 0
    
    total_pending = sum(r[2] for r in to_restore)
    print(f"\n== {len(to_restore)} tables pending, {total_pending:,} rows ==")
    
    restored = 0
    for schema, table, _, local_cnt in to_restore:
        ok = restore_table(schema, table)
        if ok: restored += 1
    
    print("\n" + "=" * 55)
    print("POST-RESTORE VERIFICATION")
    print("=" * 55)
    all_ok = True
    for schema, table, _, _ in to_restore:
        rc = remote_count(schema, table)
        local_cnt = int(psql(f"SELECT COUNT(*) FROM {schema}.{table};") or 0)
        diff = local_cnt - rc
        status = "OK" if diff == 0 else f"DIFF -{diff}"
        if diff != 0: all_ok = False
        print(f"  {f'{schema}.{table}':35s} local={local_cnt:>8,} remote={rc:>8,} {status}")
    
    if all_ok:
        print("\n=> ALL TABLES COMPLETE!")
    else:
        print("\n=> Some tables still have missing data")
    
    return 0 if all_ok else 1

if __name__ == '__main__':
    sys.exit(main())
