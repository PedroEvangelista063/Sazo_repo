# summary.md — /database (Pomar e Triagem)

## Propósito
DDLs, migrações e schemas do banco PostgreSQL. Arquitetura Medalhão adaptada: `raw` (bronze) → `staging` (prata) → `mart` (ouro). A Landing Zone (`raw.coleta_bruta`) engole inserts na velocidade máxima — sem FKs, sem constraints de domínio.

## Stack
- PostgreSQL 16+, PL/pgSQL, asyncpg, gen_random_uuid()
- DDL idempotente (`CREATE TABLE IF NOT EXISTS`, `DO $$` blocks)

## Regras de Ouro
1. **Landing Zone sem Barreiras**: `raw.coleta_bruta` PROIBIDA de ter FKs, UNIQUE compostas ou CHECKs de domínio. Apenas UUID PK, JSONB, TIMESTAMP, VARCHAR.
2. **Idempotência**: todo script DDL deve ser reexecutável (`IF NOT EXISTS`, `OR REPLACE`).
3. **Quarentena**: rejeições vão para `ops.quarentena_coleta` com raw_id + motivo_falha — nada se perde.
4. **Staging com UPSERT**: `fact_precos_mensais` usa `ON CONFLICT` para atualizar preços sem duplicar.
5. **Dimensões**: `dim_produto` e `dim_localidade` com resolução via `ON CONFLICT DO UPDATE`.
6. **Janela Temporal**: toda view/function/query deve filtrar por ano/mês entre 2024-01 e 2026-12.
7. **Índices Essenciais**: `raw.coleta_bruta (processado) WHERE processado = FALSE` — sem indexação excessiva.
8. **Forecast é fallback condicional**: dados com `is_forecast = FALSE` (reais) NUNCA são sobrescritos por forecast. `ON CONFLICT DO NOTHING`.

## Localização dos Dados Brutos

Existem **duas fontes de dados brutos** independentes:

### A. Banco PostgreSQL — `raw.coleta_bruta`
Pipeline do scraper ao vivo. 15 registros de payloads brutos (JSONB) capturados pelos micro-motores.
```
Scraper → raw.coleta_bruta (15) → SortingEngine → staging.fact_precos_mensais
```
**DBA**: schema `raw`, tabela `coleta_bruta`. Índice `idx_coleta_bruta_processado WHERE processado = FALSE`.
**Dev**: acessado via `asyncpg`. Usado pelo ciclo medalhão em `pipeline/scraper/persistence.py`.

### B. Arquivos — `database/processed_data/01_raw/`
Dados históricos CONAB (carga manual, não passa pelo scraper). São 20 listas de cotação (LISTA1 a LISTA20), cada uma em 3 formatos + arquivos consolidados:
```
database/processed_data/
├── 01_raw/                          ← Dados brutos CONAB (fonte original)
│   ├── LISTA{1..20} {data}.txt      ← Extração textual das listas CONAB
│   ├── LISTA{1..20} {data}.json     ← Mesmos dados em JSON estruturado
│   ├── LISTA{1..20} {data}.parquet  ← Mesmos dados em Parquet (otimizado)
│   ├── cotacoes_brutas.parquet      ← Consolidação de todas as listas
│   ├── sazonalidade_com_cotacao.parquet
│   └── scraper_hortifruti_historico.parquet
├── 02_cleaned/                      ← Dados limpos e tipados
├── 03_categorized/                  ← Classificados por categoria
├── 04_b2c_only/                     ← Filtro ALIMENTO_VAREJO
├── 05_aggregated/                   ← Agregações por UF/produto/mês
├── 06_seasonality/                  ← Sazonalidade calculada
├── sql/                             ← Scripts SQL do ETL
├── consolidated.parquet             ← Dado final consolidado
├── ETL_REPORT.md                    ← Relatório do processo
└── summary.json                     ← Resumo do ETL
```
**DBA**: arquivos `.parquet` no disco (não estão no PostgreSQL). Podem ser carregados via `COPY` ou `pandas`.
**Dev**: ler com `polars.read_parquet()` ou `pandas.read_parquet()`. Usado pelo `backfill_2024.py` para popular o mart histórico.

### Resumo para Dev e DBA
| Quem | Onde encontrar dados brutos | Como acessar |
|------|---------------------------|--------------|
| **DBA** | `raw.coleta_bruta` (banco) | `SELECT * FROM raw.coleta_bruta` |
| **DBA** | `database/processed_data/01_raw/*.parquet` | `COPY` ou ferramenta de arquivos |
| **Dev** | `raw.coleta_bruta` (via asyncpg) | `pipeline/scraper/persistence.py` |
| **Dev** | `database/processed_data/01_raw/*.parquet` | `polars.read_parquet()` |

## Volumes Atuais por Tabela
| Camada | Tabela | Registros |
|--------|--------|-----------|
| RAW | `raw.coleta_bruta` | 15 (payloads brutos, todos processados) |
| STAGING | `staging.fact_precos_mensais` | 27.545 (dados limpos e tipados) |
| STAGING | `staging.dim_produto` | 831 (produtos únicos) |
| STAGING | `staging.dim_localidade` | 850 (localidades únicas) |
| MART | `mart.sazonalidade_produto` | 37.013 (25.403 real + 11.610 forecast) |
| MART | `mart.sazonalidade_baseline` | 17.300 (moda do status_cor) |
| MV | `mart.vw_api_produtos_sazonalidade` | 36.684 (exposta à API) |

A **MV `vw_api_produtos_sazonalidade`** é a view final que a API B2C consulta. Definição em `26_forecast_baseline.sql:63`:
- JOIN: `sazonalidade_produto` + `dim_produto` + `dim_localidade` + `dim_categoria`
- Filtros: `categoria_b2c = 'ALIMENTO_VAREJO'`, `status_cor IN ('VERDE','AMARELO','VERMELHO')`, exclusão de `INSUMO_AGRICOLA`/`MAQUINARIO_FERRAMENTA`/`FLORES`/`OUTROS`
- Ordenação: `is_forecast` primeiro (FALSE = real antes de TRUE = projeção)

## Forecast — Engine Preditiva (Fase 30)

### Modelo Atual (100% SQL)
- `sp_calcular_forecast_2026()` — Stored Procedure que projeta meses de 2026 sem dado real usando a **Moda** do `status_cor` do baseline 2024-2025.
- `mart.sazonalidade_baseline_24_25` — tabela permanente com a moda por `(id_produto, id_localidade, mes)`. Substituiu a tabela antiga `mart.sazonalidade_baseline`.
- Colunas novas na `mart.sazonalidade_produto`:
  - `is_forecast BOOLEAN` — TRUE = projeção, FALSE = dado real
  - `baseline_confianca NUMERIC(5,2)` — % de meses com dado real no baseline (0-100)
  - `forecast_method TEXT` — rastreabilidade (`gamma_forecast_baseline`, `alpha_baseline_25_26`, `beta_media_disponivel`)
- UPSERT com regra de ouro: dado real (scraper) sempre vence projeção. `ON CONFLICT DO UPDATE` com lógica `is_forecast = FALSE` quando EXCLUDED é real.
- Threshold mínimo: confiança >= 25% (pelo menos 6 meses de 24 com dado real).
- `REFRESH MATERIALIZED VIEW CONCURRENTLY` executado no final da SP.

### MV V14 (`vw_api_produtos_sazonalidade`)
- Expõe `is_forecast`, `baseline_confianca`, `forecast_method`.
- Índices parcia: `idx_vw_sazonalidade_forecast` (WHERE is_forecast=TRUE), `idx_vw_sazonalidade_confianca` (DESC).

### Migrações Chave
- `27_fix_br_nacional_weighting.sql` — Hotfix: SP chama `sp_calcular_sazonalidade_preditiva()` em vez da legacy.
- `28_recalibracao_baseline_24_25.sql` — Recalibração do baseline para 2024-2025.
- `29_focus_2025_2026.sql` — Filtro temporal: apenas >= 2025, exclusão de B2B (INSUMO_AGRICOLA, MAQUINARIO, FLORES).
- `30_engine_preditiva_forecast_2026.sql` — SP forecast, baseline_24_25, MV V14, permissões.

## Scripts Python (database/scripts/)
- `backfill_2024.py` — insere dados de 2024 no mart replicando a lógica de classificação da SP V9
- `calcular_baseline.py` — lê dados reais 2024-2025, calcula moda do status_cor e confiança. **Legado** — não é mais chamado pelo pipeline.
- `projetar_2026.py` — projeta meses de 2026 sem dado real. **Legado** — substituído por `sp_calcular_forecast_2026()`.
- `validar_forecast.py` — validação automatizada (matriz densidade, gaps, sem regressão, confiança, MV)

## Conexão Externa (DBeaver / psql)

| Parâmetro | Valor |
|-----------|-------|
| **Host** | `localhost` |
| **Porta** | `5432` |
| **Database** | `quero_comprar` |
| **Username** | `postgres` |
| **Password** | `postgres` |
| **URL** | `postgresql://postgres:postgres@localhost:5432/quero_comprar` |

> ⚡ No DBeaver, vá em **Driver properties → PostgreSQL** e marque `Show all schemas` para visualizar `raw`, `staging`, `mart`, `ops`.

## Mapa Rápido
- `01_ddl_medalhao.sql` — DDL fundacional (schemas, dim, fact, views, triggers, roles)
- `01_elt_landing_zone.sql` — Landing Zone ELT: `raw.coleta_bruta` + `ops.quarentena_coleta`
- `08_data_hygiene.sql` — rotinas de limpeza e VACUUM
- `10_zscore_classificacao_produtos.sql` — classificação estatística de preços
- `23_time_series_mart.sql` — materialização do mart de séries temporais
- `24_predictive_schema.sql` — schema preditivo (modelo ML)
- `25_fix_mv_missing_columns.sql` — hotfix: adiciona colunas faltantes na MV
- `26_forecast_baseline.sql` — DDL baseline + is_forecast + MV V13 + permissões
- `27_fix_br_nacional_weighting.sql` — Hotfix: SP V3 chama `sp_calcular_sazonalidade_preditiva()`
- `28_recalibracao_baseline_24_25.sql` — Recalibração baseline 24-25
- `29_focus_2025_2026.sql` — Focus 2025-2026, baseline V12, exclusão B2B
- `30_engine_preditiva_forecast_2026.sql` — SP forecast, baseline_24_25, MV V14
