#!/usr/bin/env python3
"""
Restore remaining tables after schema fix.
Only processes tables where local > remote.
"""
import subprocess, os, json, sys

NPX = r"C:\Program Files\nodejs\npx.cmd"
PSQL = r"C:\Program Files\PostgreSQL\17\bin\psql.exe"

def psql(sql):
    env = os.environ.copy(); env["PGPASSWORD"] = "postgres"
    env["PGCLIENTENCODING"] = "UTF8"
    r = subprocess.run([PSQL, "-U", "postgres", "-h", "localhost", "-d", "quero_comprar",
        "-t", "-A", "-c", sql], capture_output=True, env=env, timeout=60)
    return r.stdout.decode('utf-8', errors='replace').strip() if r.stdout else ""

def remote_val(sql):
    r = subprocess.run([NPX, "supabase", "db", "query", "--linked", "--output-format", "json",
        sql], capture_output=True, timeout=30)
    if r.stdout:
        try: return json.loads(r.stdout.decode())
        except: pass
    return None

def restore_table(schema, table):
    print(f"\n  >> {schema}.{table}")

    ri = remote_val(f"SELECT column_name, is_nullable FROM information_schema.columns WHERE table_schema='{schema}' AND table_name='{table}' ORDER BY ordinal_position")
    if not ri: print("  !! No remote info"); return False
    remote_cols = [c['column_name'] for c in ri]
    remote_notnull = {c['column_name'] for c in ri if c['is_nullable'] == 'NO'}

    lc = psql(f"SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='{schema}' AND table_name='{table}';")
    local_cols = [c.strip() for c in lc.split(",")] if lc else []
    common = [c for c in local_cols if c in remote_cols]

    if not common: print("  !! No common columns"); return False
    missing_nn = [c for c in remote_notnull if c not in common]
    if missing_nn: print(f"  !! NOT NULL cols missing: {missing_nn}"); return False

    raw = psql(f"SELECT row_to_json(t) FROM (SELECT {', '.join(common)} FROM {schema}.{table}) t;")
    if not raw: return False

    rows = []
    for line in raw.split("\n"):
        line = line.strip()
        if line:
            try: rows.append(json.loads(line))
            except: continue

    total = len(rows)
    if total == 0: return False

    inserted = 0
    errors = 0
    chunk_size = 200

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
            inserts.append(f"INSERT INTO {schema}.{table} ({', '.join(common)}) VALUES ({', '.join(vals)}) ON CONFLICT DO NOTHING;")

        tmp = os.path.join(os.environ.get("TEMP", "."), "su2.sql")
        with open(tmp, "w", encoding="utf-8") as f: f.write("\n".join(inserts))
        r = subprocess.run([NPX, "supabase", "db", "query", "--linked", "--file", tmp], capture_output=True, timeout=120)
        if r.returncode == 0: inserted += len(inserts)
        else:
            err = r.stderr.decode('utf-8', errors='replace')[:200] if r.stderr else "?"
            print(f"\n    ** chunk {i//chunk_size+1}: {err}")
            errors += 1
        try: os.remove(tmp)
        except: pass

        pct = (i + len(chunk)) * 100 // total
        sys.stdout.write(f"\r    => {i+len(chunk):,}/{total:,} ({pct}%) ok={inserted:,} err={errors}")
        sys.stdout.flush()

    print(f"\n    => DONE: {inserted:,} inserted, {errors} errors")
    return True

# Tables in FK order - only those with local data
TABLES = [
    ("staging", "dim_conab_produto_mapping"),
    ("staging", "fact_precos_mensais"),
    ("staging", "confianca_baseline"),
    ("staging", "baseline_2025_interpolado"),
    ("mart", "sazonalidade_produto"),
    ("mart", "sazonalidade_baseline_25_26"),
    ("raw", "coleta_bruta"),
    ("ops", "quarentena_coleta"),
    ("ops", "config_agente"),
]

print("="*55)
print("RESTORE V2 - Remaining Tables (schema fixed)")
print("="*55)
print(f"{'Table':40s} {'Local':>8s} {'Remote':>8s}")
print("-"*58)

todo = []
for schema, table in TABLES:
    rc = remote_val(f"SELECT COUNT(*) as c FROM {schema}.{table};")
    remote_n = rc[0]['c'] if rc else -1
    local_n = int(psql(f"SELECT COUNT(*) FROM {schema}.{table};") or 0)
    status = "OK" if remote_n >= local_n else "PEND"
    print(f"  {f'{schema}.{table}':35s} {local_n:>8,} {remote_n:>8,}  {status}")
    if remote_n < local_n:
        todo.append((schema, table))

if not todo:
    print("\n=> All tables complete!")
    sys.exit(0)

total_pend = sum(int(psql(f"SELECT COUNT(*) FROM {s}.{t};") or 0) for s,t in todo)
remote_pend = sum(json.loads(subprocess.run([NPX,"supabase","db","query","--linked","--output-format","json",
    f"SELECT COUNT(*) as c FROM {s}.{t};"],capture_output=True,timeout=30).stdout.decode())[0]['c'] for s,t in todo)
print(f"\n=> {len(todo)} tables, local={total_pend:,}, remote={remote_pend:,}, missing={total_pend - remote_pend:,}")

for schema, table in todo:
    restore_table(schema, table)

print("\n"+"="*55)
print("FINAL VERIFICATION")
print("="*55)
all_ok = True
for schema, table in TABLES:
    rc = remote_val(f"SELECT COUNT(*) as c FROM {schema}.{table};")
    remote_n = rc[0]['c'] if rc else -1
    local_n = int(psql(f"SELECT COUNT(*) FROM {schema}.{table};") or 0)
    status = "OK" if remote_n >= local_n else f"FALTA {local_n - remote_n}"
    if remote_n < local_n: all_ok = False
    print(f"  {f'{schema}.{table}':35s} local={local_n:>8,} remote={remote_n:>8,}  {status}")

print(f"\n=> {'ALL OK!' if all_ok else 'Still missing data'}")
sys.exit(0 if all_ok else 1)
