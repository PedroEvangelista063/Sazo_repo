# summary.md — /docs

## Propósito

Fonte única da verdade (Single Source of Truth). Diagramas, prompts mestres, históricos de backfill, relatórios de auditoria, documentação arquitetural, regras para agentes AI e registro do modelo forecast.

## Stack

Markdown, Mermaid (diagramas), Python (scripts de diagnóstico).

## Regras de Ouro

1. **Fonte Única**: qualquer decisão arquitetural relevante DEVE estar documentada aqui. Se não está em /docs, não aconteceu.
2. **Prompts Mestres**: `PROMPT_AUDITORIA_ENRIQUECIMENTO.md` contém o prompt de engenharia reversa.
3. **Histórico**: `HISTORICO_MELHORIAS_BACKFILL.md` rastreia todas as mudanças no pipeline de backfill.
4. **Agentes AI**: `AGENTS.md` contém as regras da casa injetadas no contexto dos agentes (OpenCode, GGA, etc).
5. **scripts/** — utilitários de diagnóstico, exportação e teste. Isolados, sem dependência entre si.

## Conteúdo

### Removidos (limpeza 2026-07-30)

- ~~`AUDITORIA_SUPABASE_2026-07-18.md`~~ — obsoleto (dados já reconciliados)
- ~~`MELHORIAS_SISTEMA_AGENTES.md`~~ — obsoleto (arquitetura híbrida implementada)
- ~~`PROMPT_AUDITORIA_ENRIQUECIMENTO.md`~~ — obsoleto (prompts migrados)
- ~~`plano_sync_supabase.md`~~ — obsoleto (sync completo)
- ~~`sync_supabase_fase4_concluida.md`~~ — obsoleto (fase 4 concluída)

### Novos (lote 2026-08-11)

- `QUERY_CONSULTA_BANCO.md` — queries de consulta e diagnóstico do banco
- `runbook_migration_78_local.md` — runbook de execução e validação da migration 78 (deep fallback) no ambiente local
- `auditoria_nomenclatura_2026-08.md` — auditoria de nomenclatura + draft da migration 77
- `RELATORIO_AUDITORIA_RECONCILIACAO.md`, `RELATORIO_AUDITORIA_VALIDACAO_DADO_HISTORICO.md`, `RELATORIO_AUDITORIA_ANO_ANCORA_REAL.md` — auditorias do dado histórico real
- `RELATORIO_IMPLEMENTACAO_DADO_HISTORICO.md`, `RELATORIO_TRANSPARENCIA_MATEMATICA.md`, `VALIDACAO_AUDITS_1_9.md`, `RELATORIO_PROGRESSO_LIMIARES_ZSCORE.md` — relatórios de implementação/validação
- `RELATORIO_CLAYMORPHISM.md` — implementação do estilo claymorphism (tokens `shadow-clay-*`/`rounded-clay*`)
- `AUDITORIA_E2E_SINCRONISMO.md`, `DIAGNOSTICO_SANDUICHE_SAZONAL.md`, `plano_contingencia_gaps.md`, `relatorio_investigacao_sp.md` — diagnósticos e planos de contingência
- `FRONTEND_IMPROVEMENTS.md`, `GOOGLE-STUDIO-alinhamento-frontend.md`, `STICH-GOOGLE-frontend.md` — alinhamentos de UI/frontend
- `HANDOFF_MIGRACAO_AIVEN.md`, `deploy.md` — migração Aiven e deploy
- `PROMPT_HOUND_INTEGRACAO_SCRAPER.md`, `RELATORIO_ARQUIVOS_CHAVE.md`, `implementation_plan.md`, `implementation_plan2.md` — planos e integrações
- ~~`CHECK_CONEXAO_SUPABASE.md`~~ — removido (legado Supabase eliminado em `8f7ea7de`)

### Ativos

- `AGENTS.md` — regras da casa para agentes AI (stack, classificação, medalhão, frontend)
- `HISTORICO_MELHORIAS_BACKFILL.md` — changelog de backfill (inclui diagnóstico gap 2024, proposta target-list e snapshot de validação CONAB)
- `quero_comprar_plano_tecnico.md` — plano técnico geral
- `AUDITORIA_BANCO_FRONTEND.md` — auditoria banco + frontend
- `README.md` — visão geral do projeto (micro-monorepo, setup, deploy)
- `PROJECT_RULES.md` — regras para desenvolvimento
- `DATABASE_ARCHITECTURE.md` — arquitetura do banco de dados
- `PROXIMOS_PASSOS.md` — roadmap futuro
- `CONVENTIONS.md` — convenções de código
- `PLANO_GRADE_SAZONAL_ICONE.md` — plano da grade sazonal
- `scripts/` — scripts de diagnóstico e utilidades
  - `get_data_summary.py` — health check do banco
  - `start_ecosystem.py` — levanta ecossistema local
  - `verify_api.py` — valida endpoints da API
  - `load_test.py` — teste de carga
- `archive/` — documentos arquivados (planos obsoletos)
  - `plano_micro_motores.md` — plano original dos micro-motores
  - `fase2_arquitetura_autocura.md` — arquitetura de auto-cura e fallback
  - `migracao-supabase-plano.md` — plano de migração Supabase

### Auditoria

- `reports/auditoria_b2c_completa_2026-07-06.csv` — relatório de auditoria B2C
- `reports/auditoria_padrao_ouro_b2c.csv` — padrão ouro B2C

## Mudanças Recentes (2026-08-11)

- **DB**: migrations `74`-`80` — quality gates (12 meses, baseline, completude de série MV V21), deep fallback histórico (**MV V22**, `78` — aplicada, validada em local+remoto) e /br-sazonalidade inclui projeção (**`79`**, P1-1 — aplicada); **`80` (V23, janela 2023+) COMMITADA mas NÃO aplicada** (piso ausente na MV real — aplicar DDL + refresh via psql); draft de nomenclatura DBA-friendly (`77`). Ver `database/summary.md`.
- **Backend**: memoização do `X-Last-Refresh` (TTL 30s + lock) e mensagens de transparência V22 (`245c4155`). Ver `backend/summary.md`.
- **Frontend**: claymorphism UI completo + A2HS + paginação híbrida (`42f315b3`), fixes do manifest PWA, e lote não commitado — círculos claymorphism na grade sazonal, remoção do (i), abas Cards→Mapa→Tabela e fix do sticky do acordeão (overflow-clip + top-[7.5rem]). Ver `frontend/summary.md`.
- **query_DBA**: kit validado para o estado atual — MV **V22 aplicada** (177.485 linhas), V23 pendente; `07_migrations.sql` removido (legado Supabase) — ver `query_DBA/summary.md`.

## Mudanças Recentes (2026-08-12, follow-ups)

- **Migration 80 (V23) APLICADA nos 2 bancos** (local + Aiven) com backup + validação funcional: 0 âncoras FALLBACK < 2023, `min(ano_referencia)` set–dez 2026 = 2023, MV 177.485, 0 nulo/CINZA. Correção de marcador: `position('YEAR FROM CURRENT_DATE')` é case-sensitive quebrado (deparser normaliza) — validar por funcional. Runbook dedicado: `docs/runbook_migration_80_local.md`.
- **Sync Produção ➔ Homologação executado** (`scripts/sync_db_prod_to_staging.sh`): local espelha o Aiven (fact 245.362, MV 177.485, sazonalidade 346.961), `ops.*`/`raw.*` preservados; restore reescrito para **um único `pg_restore --clean --if-exists`** (psql schema conflitava com schemas preservados) + exclusão de `audit` do dump + pre-drop do event trigger `ensure_rls` (legado Supabase, ausente no Aiven — local agora idêntico ao Aiven).
- **Fast-path no guardião do commit** (`scripts/guard_commit.sh`): só docs/JSON/yml staged → smoke pulado; sem TS/TSX staged → tsc pulado (commit de docs libera instantâneo).
- **Migration 77 (nomenclatura)**: revisada → **HOLD** com evidência (trigger `trg_valida_anomalia_preco` chama `fn_classificar_preco_anomalia` por nome; a 77 não cria wrapper de funções). Correção proposta: wrappers de 30 dias também para funções chamadas em runtime.

## Arquitetura de Ambientes e CI/CD

> FASE 2–6 (2026-08-12) — ver documento completo: `docs/ARQUITETURA_AMBIENTES_CI_CD.md`

Separação estrita entre **Homologação (servidor FÍSICO/local)** e **Produção (nuvem Aiven)** com fail-fast via Git Hooks:

- **Fronteira = `APP_ENV`** (`staging` | `production`): o backend (pydantic-settings, `backend/app/core/config.py`) carrega `backend/.env.staging` ou `backend/.env.production` dinamicamente; fallback para `backend/.env` legado.
- **Pool dinâmico**: staging min 2/max 30 (testes de carga); production min 2/max 8 com teto 10 (Aiven free/basic). `POOL_*` explícito vence o autotuning (`backend/app/db/session.py`).
- **Banner de startup** no lifespan (`backend/app/main.py`): `[!] INICIANDO SISTEMA NO AMBIENTE DE: {STAGING|PRODUCTION} — CONECTADO AO BANCO: {FÍSICO|AIVEN}` (rótulo derivado do hostname real da URL primária).
- **Guardiões do Git**: `.husky/pre-commit` → `lint-staged` + `scripts/guard_commit.sh` (tsc --noEmit + `scripts/smoke_staging.sh`: /health + /br-sazonalidade sem 500 e sem status_cor null/CINZA); `.husky/pre-push` → `scripts/guard_push.sh` (+ pytest backend/tests + vitest frontend). Bypasses: `SKIP_TSC`, `SKIP_STAGING_SMOKE`, `SKIP_PUSH_TESTS`, `SKIP_GUARD_COMMIT/PUSH`.
- **DB Sync CLI**: `scripts/sync_db_prod_to_staging.sh` (Produção ➔ Homologação) com `--dry-run`, proteção de `ops.*`/`raw.*` no destino e recusa de destino não-local (npm: `db:sync:staging` / `db:sync:staging:dry`).
- **Frontend**: modos Vite `dev:staging`/`dev:production` carregam `frontend/.env.staging`/`.env.production` (VITE_API_URL).
- **Regra de Ouro mantida**: NO GRAY / NO NULL — o smoke valida `0 status_cor nulo/CINZA` na grade a cada commit; Deep Fallback V22/V23 intacto.
- **Arquivos**: `.gitignore` ganhou `.env.staging`/`.env.production`; `render.yaml` declara `APP_ENV=production`; `backend/.env.example` reescrito (seções staging/production).

## Forecast — Engine Preditiva (Fase 30, 100% SQL)

- `database/26_forecast_baseline.sql` — migration original: baseline + is_forecast + MV V13
- `database/29_focus_2025_2026.sql` — focus 2025-2026, baseline V12, exclusão B2B
- `database/30_engine_preditiva_forecast_2026.sql` — **SP `sp_calcular_forecast_2026()`**, baseline_24_25, MV V14 com `baseline_confianca`, `forecast_method`
- `database/scripts/calcular_baseline.py` — legado (substituído pela SP)
- `database/scripts/projetar_2026.py` — legado (substituído pela SP)
- `database/scripts/backfill_2024.py` — backfill dos 12 meses de 2024 no mart
- `database/scripts/validar_forecast.py` — validação automatizada
- `pipeline/scraper/persistence.py` — 2 passos: SortingEngine + `sp_executar_carga_completa()` (inclui forecast SQL)
- `frontend/src/components/GameCard.tsx` — badge `📊 Estimativa` com tooltip de confiança + confetti
- `frontend/src/components/TabelaView.tsx` — TanStack Table com coluna is_forecast
- `frontend/src/components/GraficosView.tsx` — Recharts com gráficos de sazonalidade
- `backend/app/schemas/responses.py` — `is_forecast: bool`, `confianca_baseline: float | None`, `tendencia_futura: str | None`

---

## Mapa completo do projeto (resumo dos summary.md)

```
quero_comprar_vg/
│
├── pipeline/          (Motor de Extração — ELT)
│   ├── Propósito: Scrape Now, Parse Later. Micro-motores depositam na Landing Zone.
│   ├── Stack: Python 3.13+, Polars, Playwright, HTTPX, asyncio, curl-cffi, patchright, asyncpg
│   │
│   ├── Regras de Ouro:
│   │   1. Scrape Now, Parse Later
│   │   2. Run and Die (sem daemon)
│   │   3. Timeout Global 1200s
│   │   4. Timeouts Locais HTTPX 15s / Playwright 20s
│   │   5. Concorrência Semaphore(3), CircuitBreaker 5 falhas → 120s
│   │   6. Micro-motores especialistas (1 engine = 1 layout)
│   │   7. Janela Temporal 2024-2026
│   │   8. Discovery sem AND/OR/filetype
│   │   9. Orquestrador cascata: CEASA → Agregadores → Discovery
│   │   10. Fontes centralizadas em config/sources_matrix.json
│   │
│   ├── Ciclo Medalhão (2 passos em persistence.py):
│   │   1. SortingEngine: raw → staging.fact_precos_mensais
│   │   2. sp_executar_carga_completa(): staging → mart → forecast 2026 → MV refresh
│   │
│   ├── Fluxo RAW → STAGING → MART → MV
│   │   - raw.coleta_bruta: 15 registros
│   │   - staging.fact_precos_mensais: 45.114
│   │   - staging.dim_produto: 865
│   │   - staging.dim_localidade: 850
│   │   - staging.precos_rejeitados: 87
│   │   - staging.confianca_baseline: 2.802
│   │   - staging.baseline_2025_interpolado: 2.802
│   │   - mart.sazonalidade_produto: 145.740 (65.760 forecast, 0 INSUFICIENTE)
│   │   - mart.sazonalidade_baseline: 24_25=23.449 + 25_26=32.581
│   │   - mart.vw_api_produtos_sazonalidade: 139.255
│   │
│   └── Mapa Rápido:
│       ├── scraper/main_runner.py          — entry point Run and Die
│       ├── scraper/orchestrator.py         — AutonomousOrchestrator (cascata 3 passos)
│       ├── scraper/micro_engines/
│       │   ├── base_engine.py              — ABC + Semaphore(3) + CircuitBreaker
│       │   └── ConabApiEngine.py           — motor CONAB Pentaho/Portal
│       ├── scraper/discovery_engine.py     — SimpleDorkGenerator + DiscoveryEngine
│       ├── scraper/circuit_breaker.py      — CircuitBreaker (CLOSED/OPEN/HALF-OPEN)
│       ├── processor/                      — esteira de triagem (pós-coleta)
│       └── scraper/persistence.py          — executar_ciclo_medalhao
│
├── database/          (Pomar e Triagem — PostgreSQL)
│   ├── Propósito: DDLs, migrações, schemas. Arquitetura Medalhão raw→staging→mart.
│   ├── Stack: PostgreSQL 16+, PL/pgSQL, asyncpg, gen_random_uuid()
│   │
│   ├── Regras de Ouro:
│   │   1. Landing Zone sem FKs/UNIQUE/CHECK
│   │   2. DDL idempotente (IF NOT EXISTS, OR REPLACE)
│   │   3. Quarentena em ops.quarentena_coleta
│   │   4. UPSERT em fact_precos_mensais (ON CONFLICT)
│   │   5. Dimensões com ON CONFLICT DO UPDATE
│   │   6. Janela Temporal 2024-01 a 2026-12
│   │   7. Índices essenciais (ex: idx_coleta_bruta_processado)
│   │   8. Forecast é fallback: ON CONFLICT DO UPDATE para is_forecast=FALSE
│   │
│   ├── Duas fontes de dados brutos:
│   │   A. raw.coleta_bruta (banco) — 15 registros via scraper
│   │   B. database/processed_data/01_raw/ — CONAB manual (LISTA1..20)
│   │
│   └── Mapa Rápido (SQLs principais):
│       ├── 01_ddl_medalhao.sql             — DDL fundacional
│       ├── 01_elt_landing_zone.sql         — Landing Zone ELT
│       ├── 08_data_hygiene.sql             — limpeza e VACUUM
│       ├── 10_zscore_classificacao_produtos.sql — classificação estatística
│       ├── 23_time_series_mart.sql         — mart de séries temporais
│       ├── 24_predictive_schema.sql        — schema preditivo ML
│       ├── 25_fix_mv_missing_columns.sql   — hotfix MV
│       ├── 26_forecast_baseline.sql        — baseline + is_forecast + MV V13
│       ├── 27_fix_br_nacional_weighting.sql — hotfix BR Nacional
│       ├── 28_recalibracao_baseline_24_25.sql — recalibração baseline
│       ├── 29_focus_2025_2026.sql          — focus 2025-2026 + exclusão B2B
│       ├── 30_engine_preditiva_forecast_2026.sql — SP forecast 100% SQL + MV V14
│       └── scripts/
│           ├── backfill_2024.py            — insere dados 2024 no mart
│           ├── calcular_baseline.py        — legado (substituído por SP)
│           ├── projetar_2026.py            — legado (substituído por SP)
│           └── validar_forecast.py         — validação automatizada
│
├── backend/           (API B2C — FastAPI)
│   ├── Propósito: API HTTP assíncrona. Consulta apenas mart.vw_*. Sem ORM.
│   ├── Stack: Python 3.13+, FastAPI[standard], Pydantic v2, asyncpg, httpx, Uvicorn
│   │
│   ├── Regras de Ouro:
│   │   1. Sem ORM (raw SQL com asyncpg)
│   │   2. Read-only para API (só mart.vw_* e staging.*)
│   │   3. Timeout em toda rota (Event Loop Starvation)
│   │   4. Cache interno core/cache.py com TTL
│   │   5. Rate Limit core/ratelimit.py
│   │   6. Pydantic v2 na borda
│   │   7. CORS + RLS (migration 012)
│   │   8. Janela Temporal 2024+
│   │
│   ├── Fluxo: Scraper → raw → staging → mart → REFRESH MV → API
│   ├── Rotas com is_forecast:
│   │   - GET /api/v1/sazonalidade
│   │   - GET /api/v1/sazonalidade/{uf}/{municipio}
│   │   - GET /api/v1/sazonalidade/historico/{ano}/{mes}
│   │
│   └── Mapa Rápido:
│       ├── app/main.py                     — app FastAPI, middlewares, lifespan
│       ├── app/api/v1/endpoints/           — produtos, categorias, ufs, municipios, stream, admin, internal
│       ├── app/core/config.py              — settings via Pydantic
│       ├── app/core/cache.py              — cache LRU/TTL
│       ├── app/core/ratelimit.py          — rate limiter por IP
│       ├── app/core/timeout.py            — TimeoutMiddleware (504)
│       ├── app/core/events.py             — EventBroadcaster (SSE)
│       ├── app/db/session.py              — pools asyncpg
│       ├── app/schemas/responses.py       — Pydantic responses (is_forecast, confianca_baseline, tendencia_futura)
│       ├── migrations/                     — SQL incrementais (RLS, limpeza)
│       └── tests/                          — testes de resiliência
│
├── frontend/          (Aplicativo B2C — React PWA)
│   ├── Propósito: App offline-first, mobile-first. Cores (verde/amarelo/vermelho), sem valores.
│   ├── Stack: React 19, Vite + PWA, TailwindCSS 3, shadcn/ui, Framer Motion, TanStack Table, Recharts, Zustand, TanStack Query v5
│   │
│   ├── Regras de Ouro:
│   │   1. Sem R$ na tela
│   │   2. Offline-first (service worker)
│   │   3. Mobile-first (320px, touch >=44px)
│   │   4. Fallback visual com emoji gigante
│   │   5. Zero MUI/Ant Design (só shadcn/ui + Tailwind + Framer Motion)
│   │   6. SkeletonCards (sem spinners)
│   │   7. Streaming SSE via useDataStream
│   │   8. Dark/light mode
│   │   9. Badge "Estimativa" para forecast com tooltip de confiança
│   │
│   └── Mapa Rápido:
│       ├── src/App.tsx                     — root React Router
│       ├── src/main.tsx                    — entry point Vite + PWA
│       ├── src/components/
│       │   ├── ProductCard.tsx             — card + semáforo + badge forecast
│       │   ├── GameCard.tsx                — card animado Framer Motion + confetti
│       │   ├── GameButton.tsx              — botão com springs Framer Motion
│       │   ├── LivingStatus.tsx            — indicador pulsante de status
│       │   ├── TabelaView.tsx              — TanStack Table (colunas is_forecast)
│       │   ├── GraficosView.tsx            — Recharts (gráficos de sazonalidade)
│       │   ├── CategoriesModal.tsx         — modal de categorias
│       │   ├── SkeletonCard.tsx            — loading state
│       │   └── ThemeToggle.tsx             — dark/light toggle
│       ├── src/hooks/
│       │   ├── useHortifruti.ts            — TanStack Query fetch
│       │   ├── useSazonalidadeComPreco.ts  — hook /sazonalidade/com-preco
│       │   ├── useDataStream.ts            — SSE stream
│       │   ├── useCategorias.ts            — categorias via API
│       │   ├── useUfs.ts                   — UFs disponíveis
│       │   ├── useTheme.ts                 — tema persistido
│       │   └── useConfetti.ts              — canvas-confetti hook
│       ├── src/index.css                   — TailwindCSS directives
│       ├── src/pages/SupermercadoView.tsx  — página principal (tabs Cards/Tabela/Gráficos)
│       ├── src/services/api.ts             — axios instance
│       ├── src/types/
│       │   ├── domain.ts                   — tipos ProdutoVarejo (is_forecast, tendencia_futura)
│       │   └── index.ts                    — barrel exports
│       ├── src/store/useUserStore.ts       — Zustand store
│       ├── src/vite-env.d.ts               — tipos Vite
│       └── vite.config.ts                  — Vite + PWA + proxy
│
├── config/            (Configurações)
│   ├── Propósito: JSONs de roteamento, matriz de fontes. Nada de código.
│   ├── Stack: JSON puro
│   │
│   ├── Regras de Ouro:
│   │   1. Configuration Over Code
│   │   2. Janela Temporal hardcoded: "2024-01 a 2026-12"
│   │   3. Sem secrets (vão em .env)
│   │
│   └── Mapa Rápido:
│       ├── sources_matrix.json             — matriz oficial 24+ fontes (4 categorias)
│       ├── sources.json                    — legado (compatibilidade)
│       └── sources_map.json               — mapeamento produto → fontes regionais
│
├── utilities/         (Ferramentas CLI)
│   ├── Propósito: Scripts autônomos de diagnóstico, auditoria, validação E2E.
│   ├── Stack: Python 3.13+, asyncpg, httpx, argparse
│   │
│   ├── Regras de Ouro:
│   │   1. Autônomo (sem imports cruzados)
│   │   2. Diagnóstico, não produção
│   │   3. Read-only por padrão (--apply para escrita)
│   │
│   └── Mapa Rápido:
│       ├── _check_db.py                    — conexão e estado do banco
│       ├── _check_pos_scraping.py          — valida dados pós-coleta
│       ├── _check_cols.py                  — diagnóstico de colunas
│       ├── _check_migration_15.py          — valida migração 15
│       ├── _check_pos_migration.py         — sanity check pós-migração
│       ├── _debug_single_uf.py             — debug coleta por UF
│       ├── _fix_mv.py                      — correção de MV
│       ├── _fix_mv_migration_15.py         — hotfix MV migração 15
│       ├── _test_agregador.py              — teste isolado de agregador
│       ├── audit_full.py                   — auditoria completa
│       ├── validate_e2e.py                 — teste end-to-end
│       └── teste_apication/                — testes de aplicação
│           ├── backend/                    — testes de conexão
│           ├── pipeline/                   — ingestão, transform, seasonality, baseline
│           ├── root/                       — testes avulsos (CEPEA)
│           └── scraper/                    — testes de coleta
│
└── docs/              (Single Source of Truth)
    ├── Propósito: Diagramas, prompts, históricos, documentação arquitetural, regras AI.
    ├── Stack: Markdown, Mermaid, Python
    │
    ├── Regras de Ouro:
    │   1. Fonte Única — se não está em /docs, não aconteceu
    │   2. Prompts Mestres (PROMPT_AUDITORIA_ENRIQUECIMENTO)
    │   3. Histórico de backfill (HISTORICO_MELHORIAS_BACKFILL)
    │   4. AGENTS.md com regras para AI
    │   5. scripts/ utilitários isolados
    │
    └── Conteúdo:
        ├── AGENTS.md                       — regras da casa para AI
        ├── PROMPT_AUDITORIA_ENRIQUECIMENTO.md
        ├── HISTORICO_MELHORIAS_BACKFILL.md  — (inclui diagnóstico gap 2024 + proposta target-list)
        ├── quero_comprar_plano_tecnico.md
        ├── AUDITORIA_BANCO_FRONTEND.md
        ├── README.md                       — visão geral do projeto
        ├── scripts/                        — utilitários de diagnóstico
        │   ├── get_data_summary.py
        │   ├── start_ecosystem.py
        │   ├── verify_api.py
        │   └── load_test.py
        └── archive/                        — documentos arquivados
            ├── plano_micro_motores.md
            ├── fase2_arquitetura_autocura.md
            └── migracao-supabase-plano.md
```
