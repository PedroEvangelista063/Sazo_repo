# Plano de Implementação — Fase 1 (CRITICAL)

## Task 1.1 — Dockerfile: add COPY config/

**Arquivo**: `backend/Dockerfile`
**Linha**: 23
**Mudança**: Inserir `COPY config/ /app/config/` após as cópias existentes

```diff
 COPY backend/ /app/backend/
 COPY pipeline/ /app/pipeline/
+COPY config/ /app/config/
```

---

## Task 1.2 — `confianca_baseline` falsy check (2 ocorrências)

**Arquivo**: `backend/app/api/v1/endpoints/produtos.py`

### Ocorrência 1 — snapshot (linhas 284-286)
```diff
             confianca_baseline=float(r["confianca_baseline"])
-                if r.get("confianca_baseline")
+                if r["confianca_baseline"] is not None
                 else None,
             )
         )

     await safe_set(hist_key, full, float(_HIST_CACHE_TTL))
```

### Ocorrência 2 — query direta (linhas 376-378)
```diff
             confianca_baseline=float(r["confianca_baseline"])
-            if r.get("confianca_baseline")
+            if r["confianca_baseline"] is not None
             else None,
         )
         for r in rows
     ]
```

---

## Task 1.3 — `data_referencia_atual` vazia em regionais (2 ocorrências)

**Arquivo**: `backend/app/api/v1/endpoints/produtos.py`

### Ocorrência 1 — regional snapshot (linha 493)
```diff
-            data_referencia_atual=r.get("data_referencia_atual", ""),
+            data_referencia_atual=r.get("data_referencia_atual")
+                or f"{r['ano']:04d}-{r['mes']:02d}",
             usou_fallback_12m=False,
```

### Ocorrência 2 — regional por-mês (linha 546)
```diff
-            data_referencia_atual=r.get("data_referencia_atual", ""),
+            data_referencia_atual=r.get("data_referencia_atual")
+                or f"{r['ano']:04d}-{r['mes']:02d}",
             usou_fallback_12m=False,
```

**Lógica**: Se a função PL/pgSQL retorna NULL para `data_referencia_atual`, reconstruímos a partir de `ano` e `mes` (ex: `"2026-08"`). O regex `^\d{4}-\d{2}$` sempre valida.

---

## Task 1.4 — `variacao_pct` falsy check (1 ocorrência)

**Arquivo**: `backend/app/api/v1/endpoints/produtos.py`
**Linha**: 669

```diff
-                variacao_pct=float(r["variacao_pct"]) if r.get("variacao_pct") else None,
+                variacao_pct=float(r["variacao_pct"]) if r["variacao_pct"] is not None else None,
```

---

## Verificação

Após aplicar as 4 tasks:

```bash
# 1. Syntax check
python -c "import ast; ast.parse(open('backend/app/api/v1/endpoints/produtos.py').read()); print('OK')"

# 2. Dockerfile check
grep -n "COPY config/" backend/Dockerfile
# → Deve mostrar: COPY config/ /app/config/

# 3. Diff summary
git diff --stat
# → 22 modificações no produtos.py, 1 no Dockerfile
```
