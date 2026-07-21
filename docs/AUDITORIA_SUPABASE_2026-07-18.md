# Auditoria Supabase vs Local — 18/07/2026

## Resumo

**41/44 testes passando** (93.2%)

| Bloco | Status | Passaram | Total |
|-------|--------|----------|-------|
| 1. Conexões | ✅ | 3 | 3 |
| 2. Contagem | ✅ | 14 | 14 |
| 3. Amostragem | ❌ | 0 | 3 |
| 4. API | ✅ | 13 | 13 |
| 5. Sequences | ✅ | 11 | 11 |

## Detalhamento

### Bloco 1 — Conexões ✅
- Banco Local (Docker PostgreSQL) — OK
- Supabase Remoto (`supabase db query --linked`) — OK
- PG Local Version — OK

### Bloco 2 — Contagem ✅
**TODAS as 14 tabelas com contagens idênticas entre local e Supabase.**

| Tabela | Esperado | Local | Supabase |
|--------|----------|-------|----------|
| raw.coleta_bruta | 15 | 15 | 15 |
| staging.fact_precos_mensais | 42.358 | 42.358 | 42.358 |
| staging.dim_produto | 857 | 857 | 857 |
| staging.dim_localidade | 850 | 850 | 850 |
| staging.dim_categoria | 11 | 11 | 11 |
| staging.confianca_baseline | 2.802 | 2.802 | 2.802 |
| staging.baseline_2025_interpolado | 2.802 | 2.802 | 2.802 |
| staging.dim_conab_produto_mapping | 20 | 20 | 20 |
| staging.precos_rejeitados | 87 | 87 | 87 |
| mart.sazonalidade_produto | 62.291 | 62.291 | 62.291 |
| mart.sazonalidade_baseline_24_25 | 23.449 | 23.449 | 23.449 |
| mart.sazonalidade_baseline_25_26 | 32.581 | 32.581 | 32.581 |
| ops.quarentena_coleta | 9 | 9 | 9 |
| ops.config_agente | 8 | 8 | 8 |

### Bloco 3 — Amostragem ❌
Divergência completa nas amostras `LIMIT 5` com ORDER BY PK:
- staging.fact_precos_mensais — 5 local-only / 5 remote-only
- mart.sazonalidade_produto — 5 local-only / 5 remote-only
- staging.dim_produto — 5 local-only / 5 remote-only

**Causa provável**: Os dados diferem entre local e Supabase mesmo com contagens iguais. As PKs batem nos COUNTs mas as LINHAS específicas capturadas pelo ORDER BY + LIMIT 5 não são as mesmas. Pode indicar que o Supabase recebeu inserts em ordem diferente ou teve dados modificados após a migração.

### Bloco 4 — API ✅
**13 endpoints funcionando.**

| Endpoint | Status |
|----------|--------|
| /health | ✅ |
| /api/v1/sazonalidade?uf=SP | ✅ |
| /api/v1/sazonalidade?uf=SP&ano=2025&mes=6 | ✅ |
| /api/v1/sazonalidade/com-preco?uf=SP | ✅ |
| /api/v1/sazonalidade?uf=BR | ✅ |
| /api/v1/sazonalidade/br-sazonalidade?ano=2025 | ✅ |
| /api/v1/categorias | ✅ |
| /api/v1/ufs | ✅ |
| /api/v1/municipios?uf=SP | ✅ |
| /api/v1/regioes | ✅ |
| /api/v1/fluxos | ✅ |
| /api/v1/sazonalidade/SP/São Paulo | ✅ |
| Cache hit (segunda chamada rápida) | ✅ |

### Bloco 5 — Sequences ✅
**11 sequences saudáveis** (last_value >= 1).

## Bugfixes Aplicados

### 1. API: `for r in page` → `for r in rows` (3 ocorrências)
Arquivo: `backend/app/api/v1/endpoints/produtos.py`
- `_build_br_response()` → NameError: `page` não definido
- `_query_regional_snapshot()` → mesma falha
- `_query_regional_por_mes()` → mesma falha

### 2. PostgreSQL: Overloads ambíguas
- Drop da overload `fn_br_nacional_snapshot(TEXT, INTEGER, INTEGER)` (quebrada — coluna `categoria_final` não existe na view)
- Drop da overload `fn_br_nacional_por_mes(INTEGER, INTEGER, TEXT, INTEGER, INTEGER)` (mesmo problema)
- Mantida apenas a overload de 1 arg `fn_br_nacional_snapshot(TEXT)` — paginação movida para memória Python

### 3. Script de auditoria
- `_s()` para sanitizar output cp1252
- `_parse_psql_table()` para parsear saída formatada do `supabase db query --linked`
- `AUDIT_OVERALL_TIMEOUT=300s` com `asyncio.wait_for` para evitar loops
- `_normalize_types()` para normalizar tipos entre asyncpg e psql

## Script
`backend/tests/audit_supabase.py` (645 linhas)

Uso:
```
python -m backend.tests.audit_supabase             # completo
python -m backend.tests.audit_supabase --db-only    # só banco
python -m backend.tests.audit_supabase --api-only   # só API
python -m backend.tests.audit_supabase --local-only # só local
```
