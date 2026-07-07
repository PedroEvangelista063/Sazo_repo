# QUERO COMPRAR — Documentação

## Visão Geral

| Documento | Descrição |
|---|---|
| [README.md](./README.md) | Visão geral, setup, user journey, semáforo de sazonalidade |
| [AGENTS.md](./AGENTS.md) | Regras da casa para OpenCode/GGA |
| [AUDITORIA_BANCO_FRONTEND.md](./AUDITORIA_BANCO_FRONTEND.md) | Auditoria de dados: staging → mart → API → frontend |
| [PROMPT_AUDITORIA_ENRIQUECIMENTO.md](./PROMPT_AUDITORIA_ENRIQUECIMENTO.md) | Auditoria e enriquecimento completo do projeto |

## Arquitetura

| Documento | Descrição |
|---|---|
| [Plano Técnico](./quero_comprar_plano_tecnico.md) | Arquitetura completa — Fase 1, 2 e 3 |
| [Fase 2 — Autocura](./fase2_arquitetura_autocura.md) | Observability, Self-Healing DB, FastAPI |

---

## 🏗️ Taxonomia do Projeto (Micro-Monorepo)

O projeto segue o padrão de **micro-monorepo**: três serviços independentes que se comunicam via PostgreSQL.

```
quero_comprar_vg/
├── pipeline/     # Garagem  — ETL Worker (Polars, Python puro)
├── database/     # Despensa — DDLs, Migrations, Triggers (PostgreSQL)
├── backend/      # Cozinha  — FastAPI (asyncpg, Pydantic)
├── frontend/     # Sala de Estar — PWA React (Vite, Zustand, TanStack Query)
└── docs/         # Plantas da Casa — documentação
```

---

## 🚗 Garagem (Pipeline de Ingestão — ETL Worker)

**Propósito**: Ingerir dados brutos CONAB e CEASA, limpar, categorizar, enriquecer com deflação SIDRA e carregar no banco.

**Regras**:
- Nunca usa pandas → Polars para performance
- COPY ou `execute_values` → nunca INSERT linha por linha
- Motor semântico de regex separa `ALIMENTO_VAREJO` de `MAQUINARIO_FERRAMENTA` (tratores não entram no app B2C)
- Categoria `ALIMENTO_VAREJO` é a única que chega ao consumidor
- Variação de formato CONAB: arquivos podem ter 9 ou 11 colunas e podem ou não incluir linha de cabeçalho. O motor detecta automaticamente via `_ler_csv()` e normaliza para o schema padrão.

### Pipelines e Scripts Principais

| Caminho | Descrição |
|---|---|---|
| `pipeline/ingestao_conab.py` | Pipeline principal: extract → transform → load → medalhão |
| `pipeline/ingestao_conab_inteligente.py` | Leitura lazy Polars paralela + semantic engine (regex) para carga rápida de ALIMENTO_VAREJO |
| `pipeline/process_to_files.py` | ETL offline: processa LISTA*.txt → JSON/Parquet/SQL estáticos |
| `pipeline/transform.py` | Transform ETL: limpeza, normalização, validação de dados CONAB |
| `pipeline/load.py` | Módulo de carga: `execute_values` para INSERT em massa |
| `pipeline/load_master_list.py` | Carga da lista mestre de produtos no banco |
| `pipeline/enrich_master_list.py` | Enriquece lista mestre com cotações CEASA (parquet em `01_raw/`) |
| `pipeline/seasonality.py` | Cálculo do IS por município + fallback UF (baseline 2025 + fallback 12m) |
| `pipeline/ghost_dba_agent.py` | Agente de autocura com LLM (polling 300s, self-heal, webhook) |
| `pipeline/db_maintenance.py` | "Gari" do banco: upsert scraper raw → staging + GC de 30 dias |
| `pipeline/ingest.py` | Módulo auxiliar de download com httpx |
| `pipeline/run.py` | Runner genérico: orquestração de pipelines |
| `pipeline/run_scraper_historico.py` | Runner de coleta histórica CEASA (multi-UF, asyncio) |
| `pipeline/run_bulk_historical_fill.py` | Pipeline de Deflacao (IBGE SIDRA) para preenchimento de gaps historicos 2020-2024 via IPCA |
| `pipeline/run_deep_backfill.py` | Deep Backfill: varredura histórica profunda CEASA |
| `pipeline/run_ultimate_backfill.py` | Ultimate Backfill: preenchimento completo 2020-2024 |
| `pipeline/audit_local_db.py` | Auditoria de integridade: compara TXT locais vs banco |
| `pipeline/audit_b2c_export.py` | Auditoria de exportação B2C |
| `pipeline/audit_cobertura_produtos.py` | Auditoria de cobertura de produtos por UF/mês |
| `pipeline/audit_hardcode_uf_gaps.py` | Auditoria de gaps de UF hardcoded |

### Machine Learning e Data Healing

| Caminho | Descrição |
|---|---|---|
| `pipeline/ml_forecast_engine.py` | ML Forecast Engine: modelo preditivo de preços |
| `pipeline/data_healer.py` | Data Healing Engine: correção de anomalias com Z-Score |
| `pipeline/imputar_gaps_baseline.py` | Imputação matemática de gaps no baseline 2025 |

### Scraper CEASA — Core

| Caminho | Descrição |
|---|---|---|
| `pipeline/scraper/` | Scrapers CEASA: engine, spider, normalizador, adaptadores, fuzzy matcher, buscador de fontes |
| `pipeline/scraper/ceasa_engine.py` | Engine principal de scraping CEASA |
| `pipeline/scraper/ceasa_spider.py` | Spider multi-UF: navegação e extração |
| `pipeline/scraper/data_normalizer.py` | Normalizador de preços e unidades |
| `pipeline/scraper/fuzzy_matcher.py` | Fuzzy matching de produtos (rapidfuzz) |
| `pipeline/scraper/buscador_fontes.py` | Buscador de fontes CEASA |
| `pipeline/scraper/price_collector.py` | Coletor de preços |
| `pipeline/scraper/dispatcher.py` | Dispatcher de tarefas de scraping |
| `pipeline/scraper/rate_limiter.py` | Rate limiter para fontes |
| `pipeline/scraper/circuit_breaker.py` | Circuit breaker para fontes falhas |
| `pipeline/scraper/retry.py` | Retry logic com backoff |
| `pipeline/scraper/url_manager.py` | Gerenciador de URLs |
| `pipeline/scraper/gap_analysis.py` | Análise de gaps de cobertura |
| `pipeline/scraper/report_engine_gaps.py` | Relatório de gaps por engine |
| `pipeline/scraper/schemas/coleta.py` | Schemas Pydantic de coleta |
| `pipeline/scraper/_probe_sources.py` | Sonda de fontes: teste de conectividade |
| `pipeline/scraper/_prospect_sources.py` | Prospecção de novas fontes |
| `pipeline/scraper/dry_run_sprint2.py` | Dry run da sprint 2 |
| `pipeline/scraper_hortifruti.py` | Scraper Hortifruti dedicado (fontes JS-renderizadas) |

### Scraper — Adapters (Fontes Específicas)

| Caminho | Descrição |
|---|---|---|
| `pipeline/scraper/adapters/stealth.py` | **PlaywrightStealthAdapter** — motor stealth (playwright-stealth + fingerprint) para fontes com Cloudflare/WAF. Lote único de browser via `executar_adapters_playwright()` |
| `pipeline/scraper/adapters/smart_router.py` | **SmartCrawler2026** — roteador multi-source: httpx (HTML simples) → Playwright (JS/WAF) → Postback (ASP.NET). Agrupa adapters Playwright em lote único de browser |
| `pipeline/scraper/adapters/agentic_html.py` | **Agentic HTML Adapter** — extração semântica via LLM para páginas sem schema fixo |
| `pipeline/scraper/adapters/organism_adapter.py` | **Organism Adapter** — orquestrador de múltiplos adapters por fonte |
| `pipeline/scraper/adapters/commodities/` | Adapters para commodities (soja, milho, etc.) |
| `pipeline/scraper/adapters/hortifrut/` | Adapters especializados Hortifrúti (ProHort, CEASA Standard) |
| `pipeline/scraper/adapters/base.py` | Classe base `BaseTargetAdapter` |
| `pipeline/scraper/adapters/factory.py` | Factory de adapters |
| `pipeline/scraper/adapters/legacy.py` | **LegacyPostbackAdapter** — ASP.NET WebForms com `__doPostBack` |
| `pipeline/scraper/adapters/santo_graal_adapter.py` | **Santo Graal Adapter** — CEASA SP com recaptcha + múltiplos forms |
| `pipeline/scraper/adapters/google_drive_adapter.py` | **Google Drive Adapter** — extrai PDFs de pastas do Drive |

### Scraper — Transport Ecosystem

| Caminho | Descrição |
|---|---|---|
| `pipeline/scraper/transport/engine.py` | Transport engine base: interface unificada para todos os transports |
| `pipeline/scraper/transport/config.py` | Configuração de transports (proxies, timeouts, user-agents) |
| `pipeline/scraper/transport/fingerprint.py` | Browser fingerprinting para anti-detecção |
| `pipeline/scraper/transport/patchright_engine.py` | **Patchright Engine** — transport async usando Patchright (fork indetectável do Playwright). Fallback automático para Playwright + stealth se Patchright não disponível |
| `pipeline/scraper/transport/pydoll_engine.py` | **Pydoll Engine** — transport alternativo via CDP direto (sem wrapper Playwright). Bypass de detecção Puppeteer/Playwright |
| `pipeline/scraper/transport/orchestrator/` | Orquestrador de transports: JDownloader bridge, WAF bypass, Main Organism |
| `pipeline/scraper/transport/resolver/` | Challenge solvers: Flaresolverr, Turnstile, Captcha params, DOM observer |
| `pipeline/scraper/transport/semantic/` | Extração semântica: NER, XPath selector, block detector, interaction executor |

### Utilitários

| Caminho | Descrição |
|---|---|---|
| `pipeline/utils/entity_matcher.py` | EntityMatcher: fuzzy match com rapidfuzz (partial_ratio ≥ 85%) contra CSV mestre |
| `pipeline/requirements.txt` | Dependências: polars, httpx, psycopg2-binary, tenacity, rapidfuzz, beautifulsoup4 |
| `pipeline/tests/` | Testes unitários (validação, sazonalidade, baseline, dados reais) |

---

## 🗄️ Despensa (Banco de Dados — PostgreSQL 16+)

**Propósito**: Esquema Medalhão (raw → staging → mart) com observabilidade e artefatos estáticos.

### Banco Online

Acessado pelo pipeline (`ingestao_conab.py`) e pela API FastAPI.

**Regras**:
- `role_etl_writer` para pipeline, `role_api_reader` para API (SELECT only)
- Semáforo calculado EXCLUSIVAMENTE na stored procedure — o frontend nunca calcula nada
- Frontend B2C nunca recebe preço em R$ — apenas `status_cor`
- Migration管理器: scripts SQL versionados (01, 02, 03...)

| Migration | Descrição |
|---|---|
| `database/01_ddl_medalhao.sql` | Schemas raw/staging/mart, tabelas, índices, roles, SP de sazonalidade (rolling window) |
| `database/02_observability.sql` | Schema `ops` — controle_erros_ddl, audit_llm_queries, config_agente |
| `database/03_ajustes_fase4.sql` | Dimensão produto: `categoria_b2c`, `classificao_produto`, `conab_id_produto`; trigger de anomalia corrigida; MV com filtro ALIMENTO_VAREJO |
| `database/04_reestruturacao_b2c.sql` | Reestruturação B2C com documentação das regras da Sala de Estar |
| `database/05_recalibracao_baseline_2025.sql` | Baseline 2025 com fallback híbrido de 12 meses. Abandono da média móvel contínua. SP `sp_calcular_sazonalidade_baseline()` com 4 CTEs |
| `database/06_audit_triggers.sql` | Tabela `ops.audit_logs` + trigger de mudança de `status_cor` em `mart.sazonalidade_produto` |
| `database/07_refatoracao_categorias.sql` | Normalização: `staging.dim_categoria` + FK `id_categoria` em `dim_produto` + migração de dados existentes |
| `database/08_data_hygiene.sql` | Landing Zone: `raw.scraper_data` (append-only log, row_hash, UNIQUE por dia) + `ops.sp_limpeza_diaria_scraper()` (upsert + GC 30 dias) |
| `database/09_update_view_categorias.sql` | Recriação de `mart.vw_api_produtos_sazonalidade` com suporte a FK `id_categoria` |
| `database/10_zscore_classificacao_produtos.sql` | Classificação por Z-Score — estatística descritiva para precificação inteligente |
| `database/11_status_imagem_produto.sql` | Status de imagem na dimensão produto |
| `database/12_status_fonte_produto.sql` | Status da fonte de dados na dimensão produto (coluna `status_fonte`) |
| `database/15_schema_agro_regional.sql` | Schema Agro-Regional — cotações regionalizadas por fonte (CEASAs + CONAB ProHort) |
| `database/16_baseline_2025_interpolado.sql` | Baseline 2025 com imputação matemática de gaps — Polars (Layer A) + Confiança (Layer B) |
| `database/17_mom_seasonality.sql` | Seasonality MoM (Month-over-Month) — estratégia de contorno para gaps |
| `database/18_sazonalidade_preditiva_v2.sql` | Heurística preditiva com degradação graciosa — trindade estrita (VERDE/AMARELO/VERMELHO) |
| `database/19_fix_supressao_preditiva.sql` | Fix supressão silenciosa — forward fill com último preço conhecido (zero data loss) |
| `database/20_hotfix_filtro_varejo.sql` | Hotfix: trava de domínio B2C — data leak de insumos B2B no frontend B2C |
| `database/21_reclassifica_orfaos.sql` | Reclassificação de produtos órfãos (v1.0.0-rc2) |
| `database/22_data_healing_schema.sql` | Data Healing Engine — cura analítica + corta-fogo de confiança |
| `database/22b_data_healing_hotfix.sql` | Hotfix Fase 22b: patch de segurança para Data Healing |
| `database/23_time_series_mart.sql` | Time-Series Mart: MV `vw_api_produtos_sazonalidade` com índices `(ano, mes)` e novas colunas de série temporal |
| `database/24_predictive_schema.sql` | Schema preditivo: colunas `preco_estimado` e `tendencia_futura` na MV |
| `database/25_fix_mv_missing_columns.sql` | Hotfix MV: adiciona colunas `preco_estimado`, `tendencia_futura`, `variacao_mom_pct` e `metodo_calculo` que a API espera |

### Artefatos Estáticos (Camada de Auditoria)

Gerados pelo `process_to_files.py` — ETL offline que não depende de conexão PostgreSQL. Útil para CI, validação local, e geração de relatórios.

```
database/processed_data/
├── 01_raw/              JSON/Parquet brutos por arquivo LISTA
├── 02_cleaned/          Dados limpos e normalizados
├── 03_categorized/      Com categoria_b2c (ALIMENTO_VAREJO / B2B)
├── 04_b2c_only/         Apenas ALIMENTO_VAREJO (o que vai pro app)
├── 05_aggregated/       Agregado mensal por produto+UF
├── 06_seasonality/      Sazonalidade calculada (baseline 2025 + fallback 12m)
├── sql/                 Scripts INSERT para PostgreSQL
├── consolidated.parquet Dados B2C completos em Parquet
├── summary.json         Resumo consolidado
└── ETL_REPORT.md        Relatório legível
```

**Fluxo do motor offline:** Raw → Cleaned → Categorized → B2C_Only → Aggregated → Seasonality

```
LISTA*.txt → [ler_csv] → 01_raw → 02_cleaned → 03_categorized → 04_b2c_only
                                                                        ↓
                                                                05_aggregated
                                                                        ↓
                                                              06_seasonality
                                                                        ↓
                                                            sql/*.sql + summary.json
```

**Nota sobre formato CONAB:** Os arquivos `LISTA*.txt` da CONAB não seguem um schema único. Eles variam entre 9 colunas (sem município/IBGE) e 11 colunas (com município/IBGE). Além disso, alguns incluem cabeçalho e outros não. A função `_ler_csv()` em `process_to_files.py` detecta automaticamente os 4 casos e normaliza para colunas padronizadas.

---

## 🍳 Cozinha (Backend — FastAPI)

**Propósito**: API RESTful B2C — fornece sazonalidade filtrada para o PWA.

**Regras**:
- URLs no plural (`/api/v1/sazonalidade`, `/api/v1/municipios`)
- Conexão via **connection string URI** `postgresql://user:pass@host:port/dbname`
- Cache in-memory thread-safe com TTL (24h) para requisições exatas + cache imutável de 24h para dados históricos mensais (chave apenas de dimensões: ano, mês, UF, município, categoria)
- Per-month sazonalidade: quando `ano`+`mes` são fornecidos, o backend computa dinamicamente via 4 CTEs (precos_mes → baseline → fallback → semaforo), cacheando o resultado agregado. Diferentes filtros de produto/status_cor/páginação são servidos de memória via `_slice_periodo()`
- Nunca expõe preço em R$ como campo principal — `preco_referencia` e `preco_atual` existem apenas para o schema interno
- Rate limiting por IP (60 req/min)
- Zero ORM — raw SQL com asyncpg

| Caminho | Descrição |
|---|---|---|
| `backend/app/main.py` | Bootstrap FastAPI com CORS, lifespan, routers |
| `backend/app/core/config.py` | Settings via pydantic-settings (`DATABASE_URL` do `.env`) |
| `backend/app/core/cache.py` | Cache in-memory thread-safe com TTL (24h) |
| `backend/app/core/ratelimit.py` | Rate limiting por IP (60 req/min, sliding window) |
| `backend/app/core/events.py` | Lifespan events: startup/shutdown hooks |
| `backend/app/core/timeout.py` | Timeout handling para requisições longas |
| `backend/app/db/session.py` | Pool asyncpg (10-50 conexões) via connection string URI |
| `backend/app/schemas/responses.py` | Pydantic V2: SazonalidadeResponse, MunicipioListResponse, ErrorResponse |
| `backend/app/api/v1/endpoints/produtos.py` | `GET /api/v1/sazonalidade` com filtros UF, município, mês, produto, status_cor; paginação; `ano`+`mes` dispara computação dinâmica por mês |
| `backend/app/api/v1/endpoints/municipios.py` | `GET /api/v1/municipios?uf=SP` |
| `backend/app/api/v1/endpoints/ufs.py` | `GET /api/v1/ufs` — lista de UFs disponíveis |
| `backend/app/api/v1/endpoints/categorias.py` | `GET /api/v1/categorias` — categorias de varejo |
| `backend/app/api/v1/endpoints/internal.py` | `GET/POST /api/v1/_internal/cache-clear` (protegido por API Key) |
| `backend/app/api/v1/endpoints/stream.py` | SSE endpoint `GET /api/v1/stream/updates` — broadcast de eventos `ETL_FINISHED` para invalidar cache do frontend em tempo real; keepalive 30s |
| `backend/tests/test_resilience.py` | Testes de resiliência: timeout, rate limit, cache |
| `backend/get_data_summary.py` | Script ad-hoc: health check do banco (counts, distribuição, freshness) |
| `backend/run_migration.py` | Executa migração SQL via asyncpg |
| `backend/requirements.txt` | Dependências: fastapi, uvicorn, asyncpg, pydantic-settings, httpx, polars, rapidfuzz |

---

## 🛋️ Sala de Estar (Frontend — PWA React)

**Propósito**: Aplicativo B2C instalável (PWA) — funcionamento offline-first.

**Stack**:

| Tecnologia | Versão | Função |
|---|---|---|
| React | 19 | Core UI |
| Mantine | 9 | Component library (AppShell, Select, SimpleGrid, Card, Chip, Modal, Badge) |
| Vite | 6 | Bundler + PWA plugin |
| TailwindCSS | 3.4 | Utility classes (co-existe com Mantine, dark mode sync) |
| TanStack Query | 5 | Cache offline-first, stale-while-revalidate |
| Zustand | 5 | Estado persistente do usuário |
| Axios | — | HTTP client |
| Lucide React | — | Ícones (ícones de estado, actions) |

**Regras**:
- **Nunca exibe R$** — apenas o semáforo (🟢🟡🔴)
- `staleTime` de 5min para sazonalidade, retry 2
- Service Worker com Cache-First (assets) e Stale-While-Revalidate (API)
- IndexedDB para cache persistente (em vez de localStorage)
- Mobile-first com skeletons (sem spinners bloqueantes)
- Touch targets mínimos de 44×44px para usuários 60+
- Dark mode via Mantine `useMantineColorScheme` sync com classe `.dark` do Tailwind

### Fluxo de Interação (User Journey)

O usuário entra direto na página com SP + ano corrente pré-selecionados:

| Etapa | Componente | Descrição |
|---|---|---|
| 1. 📍 UF + Ano | 2× `Select` Mantine | Dropdown de estado (SP default) + dropdown de anos disponíveis. Resetam mês e status ao trocar |
| 2. 📅 Mês | `SimpleGrid` de `Button` Mantine | 12 botões (4/mobile, 6/tablet, 12/desktop). Verde = com dados, cinza = sem, preenchido = selecionado. Cada um com `minHeight: 44px`. Clique no mesmo mês destoggle. Dispara computação dinâmica no backend |
| 3. 🛒 Produtos | `Chip.Group` Mantine | Multi-select chips com todos os produtos do ano. Funciona em AND com o filtro de mês |
| 4. 🚦 Status | `Chip` exclusivo Mantine | Filtro VERDE/AMARELO/VERMELHO. Clique no mesmo chip limpa. Botão X explícito |
| 5. 🃏 Grid | `SimpleGrid` de `ProductCard` | 2/mobile, 3/tablet, 4/desktop. Ordenação VERDE → AMARELO → VERMELHO. Badge contagem no topo |
| 6. 📂 Categorias | `Modal` Mantine + `ScrollArea.Autosize` | Drill-down: lista de categorias → chips de produtos. Multi-select via `Chip.Group` |

### Componentes

| Caminho | Descrição |
|---|---|
| `frontend/src/main.tsx` | Bootstrap: `MantineProvider` (tema verde), `QueryClientProvider`, import de `@mantine/core/styles.css` |
| `frontend/src/App.tsx` | `App` → `useSyncDarkMode()` (Mantine ↔ Tailwind `.dark` class) + `useDataStream()` + `SupermercadoView` |
| `frontend/src/pages/SupermercadoView.tsx` | View principal (~280 linhas): `AppShell` com header fixo, seletor UF/ano, grid de meses, `Chip.Group` de produtos, filtro de status, `SimpleGrid` de `ProductCard`, `CategoriesModal` |
| `frontend/src/components/ProductCard.tsx` | `Card` Mantine: emoji 28px (mapa `PRODUTO_EMOJI`), nome, ícone+label status, borda esquerda colorida por status, nota fallback |
| `frontend/src/components/SkeletonCard.tsx` | `Skeleton` Mantine: círculo 80px + 2 barras |
| `frontend/src/components/CategoriesModal.tsx` | `Modal` Mantine: nível 1 com `Button` fullWidth (categorias), nível 2 com `Chip.Group` (produtos), `ScrollArea.Autosize` |
| `frontend/src/components/ThemeToggle.tsx` | `ActionIcon` Mantine → `toggleColorScheme()` |
| `frontend/src/hooks/useHortifruti.ts` | TanStack Query dual-query: `hortifruti-meta` (snapshot) + `hortifruti-filter` (ano+mes). Ordena por `STATUS_ORDER` (VERDE=0) |
| `frontend/src/hooks/useCategorias.ts` | TanStack Query para categorias de varejo |
| `frontend/src/hooks/useDataStream.ts` | SSE → `/api/v1/stream/updates`, invalida queries ao `ETL_FINISHED`, exponential backoff 1s→30s |
| `frontend/src/hooks/useUfs.ts` | TanStack Query para lista de UFs disponíveis |
| `frontend/src/types/domain.ts` | Interfaces: `ProdutoVarejo`, `StatusCor`, `SazonalidadeResponse`, `Categoria` |
| `frontend/postcss.config.js` | PostCSS: `postcss-preset-mantine` + TailwindCSS + Autoprefixer |
| `frontend/vite.config.ts` | Vite 6 + PWA Plugin (Manifest, Workbox, manualChunks) |
| `frontend/tailwind.config.js` | `darkMode: 'class'`, cores sazonais personalizadas |

### Detalhamento da Experiência

**Header (AppShell.Header)**:
- Ícone decorativo verde + título "Sazonalidade" + subtítulo com UF
- `ActionIcon` ThemeToggle (🌙/☀️) — alterna Mantine `colorScheme`, sincroniza classe `.dark`
- Botão "Categorias": `visibleFrom="sm"` mostra texto, `hiddenFrom="sm"` só ícone

**Loading state**:
- `SimpleGrid` 2/3/4 colunas com 6 `SkeletonCard` (círculo + barras animadas)

**Error state**:
- `Alert` variant="light" color="red" — mensagem de erro amigável

**Empty state**:
- `Center` com ícone `Salad` (lucide) + "Nenhum dado disponível"

**Seletor UF/Ano**:
- `Select` Mantine com 90px (UF) e 100px (ano). Trocar UF ou ano reseta mês e status
- `Badge` ao lado com contagem de itens visíveis

**Grid de Meses**:
- `SimpleGrid` cols base:4 sm:6 lg:12, spacing 6
- `Button` com `styles={{ inner: { flexDirection: 'column' } }}` e `minHeight: 44`
- Variants: `filled`=selecionado, `light`=com dados, `default`=sem dados
- Colors: `green`=com dados, `gray`=sem dados
- Botão "Visão Completa" aparece quando um mês está selecionado

**Filtro Produto**:
- `Chip.Group` com `multiple`, `onChange={setSelectedProducts}`
- `Chip` com `size="sm"` e `radius="xl"`

**Filtro Status**:
- 3 `Chip` exclusivos: Melhor Época (green), Preço Normal (yellow), Péssima Época (red)
- `ActionIcon` X para limpar quando ativo

**Grid de Cards**:
- `SimpleGrid` cols base:2 sm:3 lg:4
- Chave: `p.id_produto` (agora `id_sazonalidade` do backend — único por linha)

### Arquivos removidos

- `frontend/src/hooks/useTheme.ts` — substituído por `useMantineColorScheme` nativo do Mantine

---

## 📦 Cache Imutável Histórico (Phase 12 — Performance B2C)

O backend implementa uma estratégia de cache em duas camadas:

- **Cache geral**: TTL 24h para requisições exatas (combinando todos os filtros).
- **Cache imutável histórico** (`_HIST_CACHE_TTL = 86_400`): chave apenas de dimensões (`saz_hist_{ano}_{mes}_{uf}_{municipio}_{categoria}`). A computação mensal completa via `_compute_periodo_full()` (4 CTEs: precos_mes → baseline → fallback → semaforo) é cachead uma vez. Requisições subsequentes com diferentes filtros de `produto`/`status_cor`/`pagina` são servidas de memória via `_slice_periodo()`.

Isso garante que o banco seja consultado no máximo uma vez por combinação (ano, mês, UF, município, categoria), independentemente de quantos usuários filtrem por produtos diferentes.

**Cache clear**: `/_internal/cache-clear` limpa ambas as camadas (o cache imutável se re-popula naturalmente na próxima requisição).

---

## 🔍 Auditoria de Integridade

Para verificar se os dados locais (LISTA*.txt) bateram corretamente no banco:

```bash
# Executa o script de auditoria local
python -m pipeline.audit_local_db

# O script:
#   a) Conta linhas ALIMENTO_VAREJO nos TXT locais
#   b) Conta linhas em staging.fact_precos_mensais
#   c) Testa o endpoint /api/v1/sazonalidade
#   d) Exit code 0 se OK, 1 se divergência
```
