# Summary.md Snapshot — 2026-07-17

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

## database/summary.md (149 lines)

**Propósito**: DDLs, migrações e schemas PostgreSQL. Medalhão: raw→staging→mart.

**Volumes**:
| Camada | Tabela | Registros |
|--------|--------|-----------|
| RAW | raw.coleta_bruta | 15 |
| STAGING | staging.fact_precos_mensais | 27.545 |
| STAGING | staging.dim_produto | 831 |
| STAGING | staging.dim_localidade | 850 |
| MART | mart.sazonalidade_produto | 65.830 (30.964 real + 34.866 forecast) |
| MART | mart.sazonalidade_baseline_24_25 | 23.449 |
| MART | mart.sazonalidade_baseline_25_26 | 32.581 |
| MV | mart.vw_api_produtos_sazonalidade | 54.479 |

**Forecast Engine v2**: SP `sp_calcular_forecast_2026()` — 100% SQL, Moda ponderada. Baselines: 25_26 (primary, conf >= 30), 24_25 (fallback, *0.5). Method: `beta_weighted_25_24`. Execution: 1.02s.

**Regional Functions**: `fn_regioes_listar()`, `fn_resumo_regiao(p_regiao_id, p_ano)`.

**Key Migrations**: 27 (fix br nacional weighting), 28 (recalibracao baseline 24-25), 29 (focus 2025-2026), 30 (engine preditiva v2), 32 (fn regional snapshot).

**Two Data Sources**: DB (raw.coleta_bruta) + files (database/processed_data/01_raw/*.parquet).

---

## backend/summary.md (61 lines)

**Propósito**: API HTTP assíncrona (FastAPI) que serve o frontend B2C. Consulta apenas views materializadas.

**Stack**: Python 3.13+, FastAPI, Pydantic v2, asyncpg, httpx, Uvicorn.

**8 Regras de Ouro**: Sem ORM, Read-Only API, Event Loop Starvation protection, Cache LRU/TTL, Rate Limit per-IP, Pydantic v2 schemas, CORS+RLS, Janela Temporal >= 2024.

**Endpoints que expõem is_forecast**:
- GET /api/v1/sazonalidade — snapshot + filtro regional
- GET /api/v1/sazonalidade/{uf}/{municipio}
- GET /api/v1/sazonalidade/historico/{ano}/{mes}

**Regional**: GET /api/v1/regioes (lê config/regions.json), GET /api/v1/sazonalidade?regiao=&ano= (chama fn_resumo_regiao).

**Core modules**: config.py, cache.py (LRU/TTL), ratelimit.py, timeout.py (504), events.py (SSE), session.py (asyncpg pools).

---

## pipeline/summary.md (84 lines)

**Propósito**: ELT "Scrape Now, Parse Later". Micro-motores burros e focados.

**Stack**: Python 3.13+, Polars, Playwright, HTTPX, asyncio, curl-cffi, patchright, asyncpg.

**10 Regras de Ouro**: Scrape Now Parse Later, Run and Die, Timeout Global 1200s, Timeouts Locais 15s/20s, Concorrência Semaphore(3)+CircuitBreaker, Micro-Motores, Janela 2024-2026, Discovery anti-PDF, Orquestrador cascata, Fontes em JSON.

**2-Step Medalhão Cycle** (persistence.py):
1. SortingEngine — raw→staging
2. sp_executar_carga_completa() — staging→mart→MV refresh

**Orquestrador**: `AutonomousOrchestrator.coletar_global()` — dispatch por competência, todas as UFs.

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

## utilities/summary.md (36 lines)

**Propósito**: Ferramentas CLI autônomas para diagnóstico, auditoria, validação E2E.

**Scripts**: _check_db.py, _check_pos_scraping.py, _check_cols.py, _check_migration_15.py, _check_pos_migration.py, _debug_single_uf.py, _fix_mv.py, _fix_mv_migration_15.py, _test_agregador.py, audit_full.py, validate_e2e.py.

**validate_e2e.py**: insere dado fake, verifica fluxo completo.

**Forecast validation**: database/scripts/validar_forecast.py (exit 0/1).
