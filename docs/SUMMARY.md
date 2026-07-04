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
| `pipeline/db_maintenance.py` | "Gari" do banco: upsert scraper raw → staging + GC de 30 dias |
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
| `backend/app/db/session.py` | Pool asyncpg (10-50 conexões) via connection string URI |
| `backend/app/schemas/responses.py` | Pydantic V2: SazonalidadeResponse, MunicipioListResponse, ErrorResponse |
| `backend/app/api/v1/endpoints/produtos.py` | `GET /api/v1/sazonalidade` com filtros UF, município, mês, produto, status_cor; paginação; `ano`+`mes` dispara computação dinâmica por mês |
| `backend/app/api/v1/endpoints/municipios.py` | `GET /api/v1/municipios?uf=SP` |
| `backend/app/api/v1/endpoints/internal.py` | `GET/POST /api/v1/_internal/cache-clear` (protegido por API Key) |
| `backend/app/api/v1/endpoints/stream.py` | SSE endpoint `GET /api/v1/stream/updates` — broadcast de eventos `ETL_FINISHED` para invalidar cache do frontend em tempo real; keepalive 30s |
| `backend/get_data_summary.py` | Script ad-hoc: health check do banco (counts, distribuição, freshness) |
| `backend/run_migration.py` | Executa migração SQL via asyncpg |
| `backend/requirements.txt` | Dependências: fastapi, uvicorn, asyncpg, pydantic-settings, httpx, polars, rapidfuzz |

---

## 🛋️ Sala de Estar (Frontend — PWA React)

**Propósito**: Aplicativo B2C instalável (PWA) — funcionamento offline-first.

**Regras**:
- **Nunca exibe R$** — apenas o semáforo (🟢🟡🔴)
- `staleTime` de 12h para sazonalidade (`useHortifruti`), 24h para categorias (`useCategorias`)
- Service Worker com Cache-First (assets) e Stale-While-Revalidate (API)
- IndexedDB para cache persistente (em vez de localStorage)
- Background Sync para ações offline futuras
- Mobile-first com skeletons (sem spinners bloqueantes)

### Fluxo de Interação (User Journey Pipeline)

O usuário percorre 3 etapas implementadas inline na `SupermercadoView` (sem modal de onboarding):

| Etapa | Funcionalidade | Descrição |
|---|---|---|
| 1. 📅 Período | Seletor de ano (dropdown) + mês (chips) | Anos disponíveis extraídos da API; chips de mês com indicador de dados. Seleção de ano+mes dispara computação dinâmica de sazonalidade |
| 2. 🛒 Lista | Seletor de produtos (inline, colapsável) | Botões toggle com +/X; acesso ao modal de categorias (`CategoriesModal`) via botão no header |
| 3. 🚦 Resultado | Grid de `ProductCard` (colapsável) | Ordenação por status: 🟢 VERDE → 🟡 AMARELO → 🔴 VERMELHO; contador de itens |

A localização é fixa (SP, dados CONAB). Não há mais modal de onboarding — o usuário entra direto na página com o ano corrente pré-selecionado e os meses com dados disponíveis marcados.

### Arquivos

| Caminho | Descrição |
|---|---|
| `frontend/vite.config.ts` | Vite 6 + PWA Plugin (Manifest, Workbox, Background Sync) + manualChunks |
| `frontend/tailwind.config.js` | Cores sazonais personalizadas (verde/amarelo/vermelho) |
| `frontend/src/store/useUserStore.ts` | Zustand 5 + persist via IndexedDB (idb-keyval) — `selectedProducts`, `selectedMonth` |
| `frontend/src/services/api.ts` | Axios + hooks TanStack Query v5 |
| `frontend/src/components/ProductCard.tsx` | Card com semáforo visual + emoji fallback (nunca exibe R$) |
| `frontend/src/components/SkeletonCard.tsx` | Skeleton loading pulsante |
| `frontend/src/components/CategoriesModal.tsx` | Modal de drill-down por categoria — agrupa produtos, toggle multi-select |
| `frontend/src/components/ThemeToggle.tsx` | Toggle dark/light mode |
| `frontend/src/pages/SupermercadoView.tsx` | View principal inline: período (ano+mês) → lista de produtos (colapsável) → grid de resultados (colapsável); `CategoriesModal` acionado via header |
| `frontend/src/hooks/useHortifruti.ts` | Hook TanStack Query dual-query: `hortifruti-meta` (snapshot sem filtro) + `hortifruti-filter` (ativada com ano+mes). StaleTime 12h. Ordena por `STATUS_ORDER` (VERDE=0, AMARELO=1, VERMELHO=2) |
| `frontend/src/hooks/useCategorias.ts` | Hook TanStack Query para lista de categorias de varejo (staleTime 24h) |
| `frontend/src/hooks/useDataStream.ts` | Hook SSE — conecta ao endpoint `/api/v1/stream/updates`, invalida cache TanStack Query ao receber evento `ETL_FINISHED` (exponential backoff reconnect) |
| `frontend/src/hooks/useTheme.ts` | Hook de tema dark/light |
| `frontend/src/types/domain.ts` | Interfaces TypeScript: ProdutoVarejo, StatusCor, SazonalidadeResponse |
| `frontend/src/types/index.ts` | Barrel export dos tipos |

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
