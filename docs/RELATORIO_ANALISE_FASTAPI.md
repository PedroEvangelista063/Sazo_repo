# Relatório de Análise — Backend FastAPI + Frontend

**Data**: 2026-07-17
**Contexto**: Projeto Quero Comprar VG — monitoramento de preços de hortifrúti CONAB
**Escopo**: Rotas FastAPI, schemas de resposta, consumo no frontend React

---

## 🔴 CRITICAL — Quebra em produção

| # | Problema | Arquivo | Linha | Efeito |
|---|----------|---------|-------|--------|
| **C1** | `config/` (regions.json, flows.json) **não copiado no Dockerfile** | `backend/Dockerfile` | 23 | `/regioes`, `/fluxos`, e filtro `?regiao=` no `/sazonalidade` retornam vazio em produção. Rotas que dependem de `regions.json` e `flows.json` não funcionam |
| **C2** | `data_referencia_atual=""` em rotas regionais quebra validação Pydantic | `produtos.py` | 493, 546 | Regional `fn_regional_*` retorna string vazia → regex Pydantic `^\d{4}-\d{2}$` rejeita → **500 Internal Server** |
| **C3** | `confianca_baseline=None` quando valor é `0` (falsy check) | `produtos.py` | 285, 376 | `if r.get("confianca_baseline")` → `0` é falsy em Python → campo vira `None` no response. Dado legítimo é perdido |
| **C4** | `variacao_pct=None` quando valor é `0` (mesmo bug) | `produtos.py` | 669 | Variação 0% some do response. Mesmo problema do `confianca_baseline` |

---

## 🟠 HIGH — Dados errados ou não aparecem

| # | Problema | Arquivo | Linha | Efeito |
|---|----------|---------|-------|--------|
| **H1** | Regional endpoint seta `uf=regiao_id` (ex: `"SUDESTE"`) | `produtos.py` | 488-489, 541-542 | `RegiaoPanel` faz `Set(produtos.map(p => p.uf)).size` → **sempre 1**. UI mostra "1/4 UFs com dados" — métrica inútil |
| **H2** | `preco_mes_anterior` hardcoded `NULL` no SQL | `produtos.py` | 632 | Coluna "Mês Ant." na `TabelaView` + linha de tendência no `GraficosView` sempre vazios. UI morta |
| **H3** | `id_produto` populado com `id_sazonalidade` nos snapshots | `produtos.py` | 268, 360 | IDs inconsistentes entre endpoints. Se `id_sazonalidade ≠ id_produto`, frontend recebe IDs errados |
| **H4** | BR/Regional: fetch **todas** as linhas, paginação em Python | `produtos.py` | 396-560 | Escala mal. Com 37k+ registros na MV, memória e latência disparam |
| **H5** | `/com-preco`: 2 queries por request, **sem cache** | `produtos.py` | 590-688 | Cada request = 2 hits no DB. Sem cache, sem proteção |

---

## 🟡 MEDIUM — Degradação de UX

| # | Problema | Arquivo | Linha | Efeito |
|---|----------|---------|-------|--------|
| **M1** | SSE `ETL_FINISHED` não invalida queries de com-preco, br-sazonalidade, regiao-resumo | `frontend/src/hooks/useDataStream.ts` | 17-21 | Após ETL, tabelas/gráficos/painel regional mostram dados **stale** até refresh manual |
| **M2** | `ProdutoVarejo` não inclui `tendencia_futura` | `frontend/src/types/domain.ts` | — | Backend envia o campo, frontend descarta. Dado existe mas não é usado para setas de tendência |
| **M3** | `variacao_pct=0` vira `None` | `produtos.py` | 669 | Variação 0% some do response |
| **M4** | Cache é **in-memory por worker** (Redis configurado mas não usado) | `backend/app/core/cache.py` | — | Deploy multi-worker = N caches separados. Cache stampede. Redis `redis_url` existe no Settings mas `InMemoryCache` é sempre usado |
| **M5** | `/categorias` e `/municipios` consultam `staging.*` diretamente | `categorias.py`, `municipios.py` | — | Viola regra documentada "API só lê de `mart.vw_*`" |

---

## 🔵 LOW — Melhorias

| # | Problema | Arquivo | Linha |
|---|----------|---------|-------|
| L1 | `isLoading` em vez de `isFetching` → skeleton pisca em refetch de fundo | `frontend/src/hooks/useHortifruti.ts` | — |
| L2 | `classificao_produto` — typo consistente (backend + frontend) | `responses.py`, `domain.ts` | — |
| L3 | Nenhum hook itera páginas → dados truncados se total > `por_pagina` | Todos os hooks | — |
| L4 | Leitura síncrona de JSON em rotas async (`open()` bloqueia event loop) | `regioes.py`, `fluxos.py` | 15-26 |
| L5 | COUNT query inclui LEFT JOIN desnecessário | `produtos.py` | 196-207 |

---

## Mapa — Rotas vs Problemas

| Rota | Problemas |
|------|-----------|
| `GET /health` | ✅ Sem problemas |
| `GET /api/v1/sazonalidade` | C2, C3, H1, H3, H4, L5 |
| `GET /api/v1/sazonalidade/{uf}/{municipio}` | C3, H3, H4 |
| `GET /api/v1/sazonalidade/com-preco` | C4, H2, H5 |
| `GET /api/v1/sazonalidade/br-sazonalidade` | H4, L2 |
| `GET /api/v1/categorias` | M5 |
| `GET /api/v1/ufs` | — |
| `GET /api/v1/municipios` | M5 |
| `GET /api/v1/regioes` | C1, L4 |
| `GET /api/v1/fluxos` | C1, L4 |
| `GET /api/v1/stream/updates` | M1 |
| `POST /api/v1/admin/trigger-pipeline` | — |

---

## Impacto no Frontend

| Problema | Componente(s) afetados | O que o usuário vê |
|----------|------------------------|---------------------|
| Regional com UF sintética (H1) | `RegiaoPanel` | "1/4 UFs com dados" — sempre errado |
| `preco_mes_anterior=NULL` (H2) | `TabelaView`, `GraficosView` | Coluna vazia + linha de tendência sempre oculta |
| SSE invalidação incompleta (M1) | Todos | Dados desatualizados após ETL |
| `tendencia_futura` descartada (M2) | `ProductCard` | Seta de tendência nunca aparece |
| `confianca_baseline=0` some (C3) | `ProductCard` | Badge "Estimativa" sem % quando confiança é 0 |

---

## Plano de Implementação

### Fase 1 — 🔴 CRITICAL (produção quebrada)

| Task | Arquivo | Mudança |
|------|---------|---------|
| 1.1 | `backend/Dockerfile:23` | Adicionar `COPY config/ /app/config/` |
| 1.2 | `produtos.py:285,376` | `if r.get("confianca_baseline")` → `if r["confianca_baseline"] is not None` |
| 1.3 | `produtos.py:493,546` | `r.get("data_referencia_atual", "")` → `r.get(...) or f"{ano}-{mes}"` |
| 1.4 | `produtos.py:669` | `if r.get("variacao_pct")` → `if r["variacao_pct"] is not None` |

Diffs exatos em: `.opencode/plans/fase1-critical-fixes.md`

### Fase 2 — 🟠 HIGH (dados errados)

| Task | Arquivo | Mudança |
|------|---------|---------|
| 2.1 | `produtos.py:268,360` | `r.get("id_sazonalidade", 0)` → `r.get("id_produto", 0)` |
| 2.2 | `produtos.py:488-489` | Regional: campo `regiao_nome` separado, `uf` real |
| 2.3 | `produtos.py:632` | `NULL::NUMERIC AS preco_mes_anterior` → subquery real |
| 2.4 | `produtos.py:590-688` | Adicionar cache MD5 ao `/com-preco` |

### Fase 3 — 🟡 MEDIUM (UX)

| Task | Arquivo | Mudança |
|------|---------|---------|
| 3.1 | `useDataStream.ts:17-21` | Invalidar queries faltantes no SSE |
| 3.2 | `domain.ts` | Adicionar `tendencia_futura` ao `ProdutoVarejo` |
| 3.3 | `produtos.py:196-207` | Remover LEFT JOIN da COUNT query |

### Fase 4 — Performance

| Task | Arquivo | Mudança |
|------|---------|---------|
| 4.1 | `produtos.py` | BR/Regional: `LIMIT/OFFSET` no banco |
| 4.2 | `cache.py` | Implementar Redis cache |
| 4.3 | `categorias.py` | Migrar para MV |

---

## Problemas Não Encontrados (verificados e OK)

- ✅ CORS — configurado via env
- ✅ Rate limit — 60 req/min por IP
- ✅ Timeout middleware — 29s
- ✅ API key em endpoints internos
- ✅ RLS ativo (`012_security_rls_readonly.sql`)
- ✅ SSE keepalive + CancelledError handling
- ✅ Pool lazy singleton (double-checked locking)
- ✅ `safe_set` com try/except (cache não quebra request)
- ✅ Estrutura de tipos frontend/backend consistente (sem mismatch de schema além dos listados)
