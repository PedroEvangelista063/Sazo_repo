# Summary.md Snapshot — 2026-07-18

Consolidated snapshot of all 6 module summary.md files (SSOT state).

---

## frontend/summary.md (111 lines)

**Propósito**: App React PWA (offline-first, mobile-first). Interface de cores (verde/amarelo/vermelho) para preços de hortifrúti — NUNCA exibe valores monetários.

**Stack**: React 19, Vite 6 + PWA plugin, TailwindCSS 3.4 + tailwindcss-animate, shadcn/ui, TanStack Table, Recharts, Framer Motion, React Bits (Beams/SpotlightCard/TiltedCard/BlurText), Three.js + @react-three/fiber + @react-three/drei, Zustand 5, TanStack Query v5, Lucide React, canvas-confetti.

**3 View Modes**:
- Cards (padrão) — grid de ProductCard com SpotlightCard + semáforo
- Mapa Regional — BrasilMap (27 dots SVG) + RegiaoPanel (SpotlightCard com polos CEASA)
- Grade Sazonal — SazonalidadeNacional grid (apenas BR Nacional)

**BRNationalIcon**: substitui dropdown de UF nos modos Mapa Regional e Grade Sazonal. Bandeira BR + 5 frutas orbitando. Cards mantém dropdown normal.

**11 Regras de Ouro**: Sem Dinheiro na Tela, Offline-first, Mobile-first, Fallback Visual (emoji), Tailwind+shadcn, Sem Loading Genéricos, Streaming SSE, Tema dark/light, Transparência no Forecast, React Bits Registry, Mapa Regional em Dots.

**Hooks**: useHortifruti, useRegioes, useRegiaoResumo, useSazonalidadeComPreco, useDataStream, useCategorias, useUfs, useTheme, useConfetti.

---

## database/summary.md (217 lines)

**Propósito**: DDLs, migrações e schemas PostgreSQL. Medalhão: raw→staging→mart.

**Volumes**:
| Camada | Tabela | Registros |
|--------|--------|-----------|
| RAW | raw.coleta_bruta | 15 |
| STAGING | staging.fact_precos_mensais | 42.358 |
| STAGING | staging.dim_produto | 857 |
| STAGING | staging.dim_localidade | 850 |
| STAGING | staging.dim_categoria | 11 |
| STAGING | staging.confianca_baseline | 2.802 |
| STAGING | staging.baseline_2025_interpolado | 2.802 |
| STAGING | staging.dim_conab_produto_mapping | 20 |
| STAGING | staging.precos_rejeitados | 87 |
| MART | mart.sazonalidade_produto | 62.291 |
| MART | mart.sazonalidade_baseline_24_25 | 23.449 |
| MART | mart.sazonalidade_baseline_25_26 | 32.581 |
| MV | mart.vw_api_produtos_sazonalidade | 62.291 |
| OPS | ops.quarentena_coleta | 9 |
| OPS | ops.config_agente | 8 |

**Total**: 174.240 linhas em 14 tabelas com dados.

**Forecast Engine v2**: SP `sp_calcular_forecast_2026()` — 100% SQL, Moda ponderada. Baselines: 25_26 (primary, conf >= 30), 24_25 (fallback, *0.5). Method: `beta_weighted_25_24`. Execution: 1.02s.

**Migração Supabase (2026-07-18)**: Fase 3 concluída — 14 tabelas migradas, 100% idênticas.
- Schema drift corrigido: raw.coleta_bruta e ops.quarentena_coleta (UUID PK)
- fact_precos_mensais ganhou 3 colunas (preco_curado, is_interpolado, fonte)
- Trigger trg_valida_anomalia_preco desativada durante restore, reativada após
- Todas as sequences corrigidas com setval()
- MV vw_api_produtos_sazonalidade populada via REFRESH CONCURRENTLY (62.291)

**Scripts de Restore**: restore_supabase_final.py, restore_remaining_v2.py, restore_final_v3.py, fix_schema_v3.sql, fix_sequences.sql.

---

## backend/summary.md (89 lines)

**Propósito**: API HTTP assíncrona (FastAPI) que serve o frontend B2C. Consulta apenas views materializadas.

**Stack**: Python 3.13+, FastAPI, Pydantic v2, asyncpg, httpx, Uvicorn.

**Fluxo dos Dados**:
```
Scraper → raw.coleta_bruta (15)
→ SortingEngine → staging.fact_precos_mensais (42.358)
→ sp_executar_carga_completa → mart.sazonalidade_produto (62.291)
→ REFRESH MV → mart.vw_api_produtos_sazonalidade (62.291)
```

**8 Regras de Ouro**: Sem ORM, Read-Only API, Event Loop Starvation protection, Cache LRU/TTL, Rate Limit per-IP, Pydantic v2 schemas, CORS+RLS, Janela Temporal >= 2024.

**Endpoints que expõem is_forecast**:
- GET /api/v1/sazonalidade — snapshot + filtro regional
- GET /api/v1/sazonalidade/{uf}/{municipio}
- GET /api/v1/sazonalidade/historico/{ano}/{mes}

**Regional**: GET /api/v1/regioes (lê config/regions.json), GET /api/v1/sazonalidade?regiao=&ano= (chama fn_resumo_regiao).

---

## pipeline/summary.md (84 lines)

**Propósito**: ELT "Scrape Now, Parse Later". Micro-motores burros e focados.

**Stack**: Python 3.13+, Polars, Playwright, HTTPX, asyncio, curl-cffi, patchright, asyncpg.

**10 Regras de Ouro**: Scrape Now Parse Later, Run and Die, Timeout Global 1200s, Timeouts Locais 15s/20s, Concorrência Semaphore(3)+CircuitBreaker, Micro-Motores, Janela 2024-2026, Discovery anti-PDF, Orquestrador cascata, Fontes em JSON.

**2-Step Medalhão Cycle**:
1. SortingEngine — raw→staging
2. sp_executar_carga_completa() — staging→mart→MV refresh

---

## config/summary.md (24 lines)

**Propósito**: JSONs de roteamento, matriz de fontes, regiões.

**Arquivos**:
- sources_matrix.json — 24+ fontes em 4 categorias
- regions.json — 5 regiões brasileiras com UFs e polos CEASA
- flows.json — 104 fluxos de abastecimento UF↔UF (v2.0)
- sources.json — legado
- sources_map.json — mapeamento produto→fontes

---

## docs/ reorganization (2026-07-18)

**docs/ reorganizado** — arquivamento de planos concluídos + atualização de SSOT:
- `docs/archive/` criado: plano_micro_motores, fase2_arquitetura_autocura, migracao-supabase-plano movidos
- `conab-consultaweb.yml` movido para `pipeline/scraper/tests/fixtures/`
- `RELATORIO_MIGRACAO_SUPABASE.md` removido (info no database/summary.md)
- `AGENTS.md` atualizado: stack real (React 19, shadcn/ui, Supabase), sem Mantine, frontend reescrito
- `SUMMARY.md` atualizado: volumes corretos, refs archive/
- `README.md` atualizado: deploy Supabase, UI shadcn/ui, pipeline simplificado

**Pendente**: publicar schemas raw/staging/mart/ops no dashboard Supabase (Project Settings → API)

---

## utilities/summary.md (36 lines)

**Propósito**: Ferramentas CLI autônomas para diagnóstico, auditoria, validação E2E.

**Scripts**: _check_db.py, _check_pos_scraping.py, _check_cols.py, _check_migration_15.py, _check_pos_migration.py, _debug_single_uf.py, _fix_mv.py, _fix_mv_migration_15.py, _test_agregador.py, audit_full.py, validate_e2e.py.

**validate_e2e.py**: insere dado fake, verifica fluxo completo.
