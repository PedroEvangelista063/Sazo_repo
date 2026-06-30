# QUERO COMPRAR — Documentação

## Visão Geral

| Documento | Descrição |
|---|---|
| [README.md](./README.md) | Visão geral, setup, user journey, semáforo de sazonalidade |
| [AGENTS.md](./AGENTS.md) | Regras da casa para OpenCode/GGA |

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

**Propósito**: Ingerir dados brutos CONAB, limpar, categorizar e carregar no banco ou em arquivos estáticos.

**Regras**:
- Nunca usa pandas → Polars para performance
- COPY ou `execute_values` → nunca INSERT linha por linha
- Motor semântico de regex separa `ALIMENTO_VAREJO` de `MAQUINARIO_FERRAMENTA` (tratores não entram no app B2C)
- Categoria `ALIMENTO_VAREJO` é a única que chega ao consumidor
- Variação de formato CONAB: arquivos podem ter 9 ou 11 colunas e podem ou não incluir linha de cabeçalho. O motor detecta automaticamente via `_ler_csv()` e normaliza para o schema padrão.

| Caminho | Descrição |
|---|---|---|
| `pipeline/ingestao_conab.py` | Pipeline principal: extract → transform → load → medalhão |
| `pipeline/ingestao_conab_inteligente.py` | Leitura lazy Polars paralela + semantic engine (regex) para carga rápida de ALIMENTO_VAREJO |
| `pipeline/seasonality.py` | Cálculo do IS por município + fallback UF (baseline 2025 + fallback 12m) |
| `pipeline/ghost_dba_agent.py` | Agente de autocura com LLM (polling 300s, self-heal, webhook) |
| `pipeline/audit_local_db.py` | Auditoria de integridade: compara TXT locais vs banco |
| `pipeline/process_to_files.py` | ETL offline: processa LISTA*.txt → JSON/Parquet/SQL estáticos |
| `pipeline/enrich_master_list.py` | Enriquece lista mestre com cotações CEASA (parquet em `01_raw/`) |
| `pipeline/run_scraper_historico.py` | Runner de coleta histórica CEASA (multi-UF, asyncio) |
| `pipeline/ingest.py` | Módulo auxiliar de download com httpx |
| `pipeline/scraper/` | Scrapers CEASA: engine, spider, normalizador, adaptadores, fuzzy matcher, buscador de fontes |
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
| `database/06_audit_triggers.sql` | **NOVO** — Tabela `ops.audit_logs` + trigger de mudança de `status_cor` em `mart.sazonalidade_produto` |

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
- Cache in-memory thread-safe com TTL (24h)
- Nunca expõe preço em R$ como campo principal — `preco_referencia` e `preco_atual` existem apenas para o schema interno
- Rate limiting por IP (60 req/min)
- Zero ORM — raw SQL com asyncpg

| Caminho | Descrição |
|---|---|---|
| `backend/app/main.py` | Bootstrap FastAPI com CORS, lifespan, routers |
| `backend/app/core/config.py` | Settings via pydantic-settings (`DATABASE_URL` do `.env`) |
| `backend/app/core/cache.py` | Cache in-memory thread-safe com TTL (24h) |
| `backend/app/core/ratelimit.py` | Rate limiting por IP (60 req/min, sliding window) |
| `backend/app/db/session.py` | Pool asyncpg (10-50 conexões) via connection string URI |
| `backend/app/schemas/responses.py` | Pydantic V2: SazonalidadeResponse, MunicipioListResponse, ErrorResponse |
| `backend/app/api/v1/endpoints/produtos.py` | `GET /api/v1/sazonalidade` com filtros UF, município, mês, produto, status_cor; paginação |
| `backend/app/api/v1/endpoints/municipios.py` | `GET /api/v1/municipios?uf=SP` |
| `backend/app/api/v1/endpoints/internal.py` | `GET/POST /api/v1/_internal/cache-clear` (protegido por API Key) |
| `backend/get_data_summary.py` | Script ad-hoc: health check do banco (counts, distribuição, freshness) |
| `backend/run_migration.py` | Executa migração SQL via asyncpg |
| `backend/requirements.txt` | Dependências: fastapi, uvicorn, asyncpg, pydantic-settings, httpx, polars, rapidfuzz |

---

## 🛋️ Sala de Estar (Frontend — PWA React)

**Propósito**: Aplicativo B2C instalável (PWA) — funcionamento offline-first.

**Regras**:
- **Nunca exibe R$** — apenas o semáforo (🟢🟡🔴)
- `staleTime` de 12h para sazonalidade, 24h para municípios
- Service Worker com Cache-First (assets) e Stale-While-Revalidate (API)
- IndexedDB para cache persistente (em vez de localStorage)
- Background Sync para ações offline futuras
- Mobile-first com skeletons (sem spinners bloqueantes)

### Fluxo de Interação (User Journey Pipeline)

O usuário percorre 4 etapas implementadas dentro da `SupermercadoView`:

| Etapa | Funcionalidade | Descrição |
|---|---|---|
| 1. 📍 Localização | `LocationModal` | Modal de onboarding: seleção de UF e Município |
| 2. 🛒 Lista | Seletor de produtos (inline) | Botões toggle com +/X; filtro por categorias de varejo |
| 3. 📅 Mês | Seletor de período (inline) | Chips de mês extraídos do `data_referencia_atual` da API |
| 4. 🚦 Resultado | Grid de `ProductCard` (inline) | Ordenação por status: 🟢 VERDE → 🟡 AMARELO → 🔴 VERMELHO |

### Arquivos

| Caminho | Descrição |
|---|---|
| `frontend/vite.config.ts` | Vite 6 + PWA Plugin (Manifest, Workbox, Background Sync) + manualChunks |
| `frontend/tailwind.config.js` | Cores sazonais personalizadas (verde/amarelo/vermelho) |
| `frontend/src/store/useUserStore.ts` | Zustand 5 + persist via IndexedDB (idb-keyval) — UF/Cidade |
| `frontend/src/services/api.ts` | Axios + hooks TanStack Query v5 |
| `frontend/src/components/LocationModal.tsx` | Modal de onboarding: UF dropdown + city datalist + prefetch debounce 600ms |
| `frontend/src/components/ProductCard.tsx` | Card com semáforo visual + emoji fallback + skeleton |
| `frontend/src/components/SkeletonCard.tsx` | Skeleton loading pulsante (`animate-pulse-soft`) |
| `frontend/src/pages/SupermercadoView.tsx` | View principal única: onboarding → multi-select → mês → dashboard |
| `frontend/src/hooks/useHortifruti.ts` | Hook TanStack Query para dados de sazonalidade (staleTime 12h) |
| `frontend/src/hooks/useMunicipios.ts` | Hook TanStack Query para lista de municípios (staleTime 24h) |
| `frontend/src/types/domain.ts` | Interfaces TypeScript: ProdutoVarejo, StatusCor, SazonalidadeResponse |
| `frontend/src/types/index.ts` | Barrel export dos tipos |

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
