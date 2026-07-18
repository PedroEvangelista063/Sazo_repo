#!/usr/bin/env python3
"""Restore only the 5 remaining tables after schema v2 fix."""
import subprocess, os, json, sys
NPX = r"C:\Program Files\nodejs\npx.cmd"
PSQL = r"C:\Program Files\PostgreSQL\17\bin\psql.exe"
def psql(sql):
    env = os.environ.copy(); env["PGPASSWORD"]="postgres"; env["PGCLIENTENCODING"]="UTF8"
    r = subprocess.run([PSQL,"-U","postgres","-h","localhost","-d","quero_comprar","-t","-A","-c",sql],
        capture_output=True, env=env, timeout=60)
    return r.stdout.decode('utf-8',errors='replace').strip() if r.stdout else ""
def restore(schema, table):
    print(f"\n>> {schema}.{table}")
    ri = json.loads(subprocess.run([NPX,"supabase","db","query","--linked","--output-format","json",
        f"SELECT column_name, is_nullable FROM information_schema.columns WHERE table_schema='{schema}' AND table_name='{table}' ORDER BY ordinal_position"],
        capture_output=True,timeout=30).stdout.decode() or "[]")
    rcols = [c['column_name'] for c in ri]
    rnn = {c['column_name'] for c in ri if c['is_nullable']=='NO'}
    lc = psql(f"SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='{schema}' AND table_name='{table}';")
    lcols = [c.strip() for c in lc.split(",")] if lc else []
    common = [c for c in lcols if c in rcols]
    if not common or [c for c in rnn if c not in common]:
        print(f"  MISS: common={common}, missing_nn={[c for c in rnn if c not in common]}")
        return False
    raw = psql(f"SELECT row_to_json(t) FROM (SELECT {', '.join(common)} FROM {schema}.{table}) t;")
    rows = []
    for line in (raw or "").split("\n"):
        line=line.strip()
        if line:
            try: rows.append(json.loads(line))
            except: pass
    total = len(rows) if rows else 0
    if total==0: print("  NO DATA"); return False
    inserted = 0
    for i in range(0, total, 200):
        chunk = rows[i:i+200]
        inserts = []
        for row in chunk:
            vals = []
            for col in common:
                v = row.get(col)
                if v is None: vals.append("NULL")
                elif isinstance(v,bool): vals.append("TRUE" if v else "FALSE")
                elif isinstance(v,(int,float)): vals.append(str(v))
                else: vals.append(f"'{str(v).replace(chr(39), chr(39)+chr(39))}'")
            inserts.append(f"INSERT INTO {schema}.{table} ({', '.join(common)}) VALUES ({', '.join(vals)}) ON CONFLICT DO NOTHING;")
        tmp = os.environ.get("TEMP",".")+"/su3.sql"
        with open(tmp,"w",encoding="utf-8") as f: f.write("\n".join(inserts))
        r = subprocess.run([NPX,"supabase","db","query","--linked","--file",tmp],capture_output=True,timeout=120)
        if r.returncode == 0: inserted += len(inserts)
        else: print(f"  ERR chunk {i//200+1}: {(r.stderr.decode(errors='replace')[:150] if r.stderr else '?')}")
        try: os.remove(tmp)
        except: pass
        sys.stdout.write(f"\r  {i+len(chunk):,}/{total:,} ok={inserted:,}")
        sys.stdout.flush()
    print(f"\n  DONE: {inserted:,} inserted")
    return True

TABLES = [
    ("staging","fact_precos_mensais"),
    ("staging","confianca_baseline"),
    ("staging","baseline_2025_interpolado"),
    ("raw","coleta_bruta"),
    ("ops","quarentena_coleta"),
    ("ops","config_agente"),
]
print("RESTORE V3 - Remaining 5 tables")
for s,t in TABLES:
    lc = int(psql(f"SELECT COUNT(*) FROM {s}.{t};") or 0)
    rc = json.loads(subprocess.run([NPX,"supabase","db","query","--linked","--output-format","json",
        f"SELECT COUNT(*) as c FROM {s}.{t};"],capture_output=True,timeout=30).stdout.decode())[0]['c']
    print(f"  {s}.{t}: local={lc:,} remote={rc:,}")
    if lc > rc: restore(s,t)

print("\n=== FINAL ===")
for s,t in TABLES:
    lc = int(psql(f"SELECT COUNT(*) FROM {s}.{t};") or 0)
    rc = json.loads(subprocess.run([NPX,"supabase","db","query","--linked","--output-format","json",
        f"SELECT COUNT(*) as c FROM {s}.{t};"],capture_output=True,timeout=30).stdout.decode())[0]['c']
    print(f"  {s}.{t}: local={lc:,} remote={rc:,} {'OK' if lc==rc else 'DIFF'}")
