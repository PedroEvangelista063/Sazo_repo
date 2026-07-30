# 📁 Mapeamento de Arquivos-Chave do Projeto

> Gerado em 30/07/2026 — Mapeamento completo dos arquivos por funcionalidade.

---

## 📊 1. Comparação 2024 vs 2025 (Baseline / Forecast)

| Arquivo | Descrição |
|---|---|
| **`database/28_recalibracao_baseline_24_25.sql`** | Procedure `sp_calcular_sazonalidade_v11` — recalcula baseline usando dados 2024-2025 com fallback para 2026 |
| **`database/05_recalibracao_baseline_2025.sql`** | Recalibração do baseline histórico para 2025 |
| **`database/16_baseline_2025_interpolado.sql`** | Baseline 2025 com dados interpolados para preencher lacunas |
| **`database/30_engine_preditiva_forecast_2026.sql`** | Engine preditiva que gera forecast para 2026 — contém CTEs que comparam `dados_reais_2026` vs `baseline_projetado_2026` |
| **`database/26_forecast_baseline.sql`** | Geração do baseline de forecast |
| **`database/scripts/calcular_baseline.py`** | Script Python standalone para cálculo do baseline (legado) |
| **`database/scripts/projetar_2026.py`** | Script Python para projeção 2026 (legado) |

---

## 🗂️ 2. View da Grade Sazonal (Materialized View)

| Arquivo | Descrição |
|---|---|
| **`database/18_sazonalidade_preditiva_v2.sql`** | Cria a `mart.vw_api_produtos_sazonalidade` — MV principal da grade sazonal (V6, motor preditivo) |
| **`database/23_time_series_mart.sql`** | Transforma a MV em série temporal (múltiplos registros por produto/localidade, um por mês) |
| **`database/25_fix_mv_missing_columns.sql`** | Adiciona colunas faltantes como `preco_estimado` e `tendencia_futura` |
| **`database/31_remove_year_filter_mv.sql`** | Remove filtro de ano da MV, permitindo visão completa |
| **`backend/app/api/v1/endpoints/produtos.py`** | Endpoint `GET /api/v1/sazonalidade` — consulta a MV e retorna os dados paginados para o frontend |

---

## 🔗 3. Conexão Banco ↔ Backend ↔ FastAPI

| Arquivo | Descrição |
|---|---|
| **`backend/app/main.py`** | Entrypoint do FastAPI — inicializa app, configura middlewares, inclui routers |
| **`backend/app/db/session.py`** | Pool de conexões assíncronas (`asyncpg`) para API e ETL — coração da conexão com o banco |
| **`backend/app/core/config.py`** | Configurações Pydantic — URLs do banco (`database_url_api`, `database_url_etl`), cache TTL, CORS |
| **`backend/app/core/cache.py`** | Cache LRU/TTL em memória (com `clear_cache()`) |
| **`backend/app/api/v1/endpoints/produtos.py`** | Endpoint principal de produtos/sazonalidade |
| **`backend/app/api/v1/endpoints/admin.py`** | Endpoints administrativos — trigger de pipeline, limpeza de cache |
| **`backend/app/api/v1/endpoints/categorias.py`** | Endpoint de categorias |
| **`backend/app/api/v1/endpoints/regioes.py`** | Endpoint de regiões (lê `config/regions.json`) |
| **`backend/app/api/v1/endpoints/fluxos.py`** | Endpoint de fluxos de abastecimento (lê `config/flows.json`) |
| **`backend/app/api/v1/endpoints/municipios.py`** | Endpoint de municípios por UF |
| **`backend/app/core/ratelimit.py`** | Rate limiter por IP |
| **`backend/app/core/timeout.py`** | Middleware de timeout (retorna 504) |

---

## ⚙️ 4. ETL / ELT

| Arquivo | Descrição |
|---|---|
| **`pipeline/ingestao_conab.py`** | Pipeline medalhão completo: `extract()` (streaming CONAB) → `transform()` (Polars) → `load()` (COPY bulk com upsert) |
| **`pipeline/ingestao_conab_inteligente.py`** | Versão inteligente da ingestão CONAB — fallbacks contextuais, dados implícitos |
| **`pipeline/etl_conab_diario.py`** | ETL diário CONAB — download, agregação mensal, carga no DW |
| **`pipeline/ingest.py`** | Download de dados CONAB com streaming e exponential backoff |
| **`pipeline/transform.py`** | Limpeza e normalização com Polars (encoding, delimiters, outliers) |
| **`pipeline/load.py`** | Carga no PostgreSQL com UPSERT |
| **`pipeline/scraper/main_runner.py`** | Orquestrador "Run and Die" — coleta → persiste → SortingEngine → Medalhão → MV |
| **`pipeline/run.py`** | Entrypoint principal do pipeline |
| **`pipeline/run_ultimate_backfill.py`** | Backfill completo de dados históricos |

---

## 📥 5. Leitura de Arquivos SQL em RAW (Database Local/Remoto)

| Arquivo | Descrição |
|---|---|
| **`pipeline/ghost_dba_agent.py`** | Agente DBA fantasma que lê scripts SQL e aplica no banco local e remoto (possivelmente Supabase) |
| **`database/01_ddl_medalhao.sql`** ao **`database/39_*.sql`** | Todos os 39+ scripts SQL de migração, organizados numericamente |
| **`database/scripts/injetar_sintetico_coldstart.py`** | Injeta dados sintéticos para cold start no banco |
| **`scripts/restore/`** | Scripts de restore que leem e aplicam SQL no banco (local e remoto) |

---

## 🕷️ 6. Scraper (Coleta → Backend → Banco)

| Arquivo | Descrição |
|---|---|
| **`pipeline/scraper/main_runner.py`** | Orquestrador "Run and Die" — define 27 UFs, 2024-hoje, chama AutonomousOrchestrator |
| **`pipeline/scraper/orchestrator.py`** | Orquestrador autônomo — coordena múltiplos scrapers por UF/competência |
| **`pipeline/scraper/ceasa_engine.py`** | Motores de scraping: `HFBrasilRegionalScraper`, `CEAGESPScraper`, `CEASAGOScraper`, `CEASAMGScraper` |
| **`pipeline/scraper/ceasa_spider.py`** | Spiders: `HFBrasilSpider`, `CEAGESPSpider` com fallbacks de parsing |
| **`pipeline/scraper/price_collector.py`** | `PriceCollector` — registra adapters e executa coleta concorrente com métricas de qualidade |
| **`pipeline/scraper/persistence.py`** | `persistir_coleta_bruta()` + `executar_ciclo_medalhao()` — persiste raw → staging → mart |
| **`pipeline/scraper/micro_engines/ConabApiEngine.py`** | Micro-motor CONAB — baixa ProhortDiario.txt (~30MB, 2M linhas) |
| **`pipeline/scraper/micro_engines/CeagespEngine.py`** | Micro-motor CEAGESP — POST com `cot_grupo` + `cot_data` |
| **`pipeline/scraper/data_normalizer.py`** | Normalizador de dados pós-coleta |
| **`pipeline/processor/sorting_engine.py`** | SortingEngine — transforma dados brutos em `fact_precos_mensais` |
| **`pipeline/scraper_hortifruti.py`** | Scraper específico para dados hortifrúti |

---

## 🔍 7. Auditoria (Validação/Qualidade dos Dados Exibidos)

| Arquivo | Descrição |
|---|---|
| **`pipeline/audit_coverage_24_25.py`** | Análise de cobertura 2024-2025 — % de produtos com dados por mês/UF, identifica gaps |
| **`pipeline/audit_local_db.py`** | Auditoria de integridade — compara arquivos locais com o banco de dados |
| **`pipeline/audit_hardcode_uf_gaps.py`** | Auditoria de gaps por UF, gaps absolutos, produtos órfãos |
| **`pipeline/audit_b2c_export.py`** | Valida dados B2C — checagens matemáticas, preços fantasmas, consistência do `status_cor`, exporta CSV |
| **`database/06_audit_triggers.sql`** | Triggers de auditoria no banco — log de mudanças no `status_cor` |
| **`utilities/audit_full.py`** | Auditoria completa/abrangente de todo o sistema |
| **`utilities/validate_e2e.py`** | Validação end-to-end da consistência dos dados |
| **`pipeline/data_healer.py`** | Correção/qualidade — identifica e corrige dados faltantes ou errôneos |
| **`pipeline/imputar_gaps_baseline.py`** | Imputação de gaps no baseline |
| **`pipeline/enrich_master_list.py`** | Enriquecimento da lista mestra de produtos |

---

## 🎯 Resumo dos Arquivos-Chave

| Categoria | Arquivo-Chave |
|---|---|
| Comparação 2024-2025 | `database/30_engine_preditiva_forecast_2026.sql` |
| Grade Sazonal (MV) | `database/18_sazonalidade_preditiva_v2.sql` |
| Conexão Backend-Banco | `backend/app/db/session.py` |
| Pipeline ETL | `pipeline/ingestao_conab.py` |
| Leitura SQL RAW | `pipeline/ghost_dba_agent.py` |
| Scraper | `pipeline/scraper/main_runner.py` |
| Auditoria | `pipeline/audit_coverage_24_25.py` |
