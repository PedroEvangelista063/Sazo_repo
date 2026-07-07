"""Health check script for Quero Comprar API.

Usage:
    python docs/scripts/verify_api.py

Exits with code 0 only if ALL endpoints respond 200.
"""
import json
import sys
import urllib.error
import urllib.request

BASE = "http://localhost:8000"
ENDPOINTS = [
    ("Health", "/health"),
    ("Sazonalidade SP", "/api/v1/sazonalidade?por_pagina=1&uf=SP"),
    ("Categorias", "/api/v1/categorias"),
    ("UFs", "/api/v1/ufs"),
    ("Municipios SP", "/api/v1/municipios?uf=SP"),
]

passed = 0
failed = 0

for name, path in ENDPOINTS:
    url = f"{BASE}{path}"
    try:
        resp = urllib.request.urlopen(url, timeout=10)
        data = json.loads(resp.read().decode())
        status = "OK" if resp.status == 200 else f"HTTP {resp.status}"
        print(f"  [PASS] {name:25s} {status}")
        passed += 1
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:300]
        print(f"  [FAIL] {name:25s} HTTP {e.code} - {body}")
        failed += 1
    except Exception as e:
        print(f"  [FAIL] {name:25s} {e}")
        failed += 1

print(f"\nResult: {passed} passed, {failed} failed")
sys.exit(0 if failed == 0 else 1)
