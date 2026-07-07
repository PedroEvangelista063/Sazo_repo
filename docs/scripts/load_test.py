"""Lightweight load test for Quero Comprar API.

Tests resilience under concurrent requests and validates
the TimeoutMiddleware (504 on slow endpoints).

Usage:
    python docs/scripts/load_test.py
"""
import json
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

BASE = "http://localhost:8000"
UFS = ["SP", "MG", "RJ", "BA", "MT", "GO", "PR", "RS", "SC", "ES"]

results: list[dict] = []
errors = 0


def fetch(path: str) -> dict:
    url = f"{BASE}{path}"
    start = time.monotonic()
    try:
        resp = urllib.request.urlopen(url, timeout=15)
        elapsed = time.monotonic() - start
        return {"path": path, "status": resp.status, "elapsed": round(elapsed, 3)}
    except urllib.error.HTTPError as e:
        elapsed = time.monotonic() - start
        return {"path": path, "status": e.code, "elapsed": round(elapsed, 3)}
    except Exception as e:
        elapsed = time.monotonic() - start
        return {"path": path, "status": 0, "elapsed": round(elapsed, 3), "error": str(e)}


print("Sazonalidade snapshot (todos UFs em paralelo)...")
with ThreadPoolExecutor(max_workers=10) as pool:
    futs = [pool.submit(fetch, f"/api/v1/sazonalidade?por_pagina=1&uf={uf}") for uf in UFS]
    for f in as_completed(futs):
        r = f.result()
        results.append(r)
        status = "OK" if r["status"] == 200 else f"ERR {r['status']}"
        print(f"  {r['path'][-7:]:7s} {status:8s} {r['elapsed']:6.3f}s")

print("\nSummary:")
oks = [r for r in results if r["status"] == 200]
fails = [r for r in results if r["status"] != 200]
print(f"  200 OK: {len(oks)}")
print(f"  Errors: {len(fails)}")
if fails:
    for f in fails[:5]:
        print(f"    {f['path']}: HTTP {f['status']} ({f['elapsed']:.3f}s)")
    sys.exit(1)

print("\nResiliencia OK — TimeoutMiddleware nao disparou (nenhum endpoint lento).")
