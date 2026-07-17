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
| MART | `mart.sazonalidade_produto` | 65.830 (30.964 real + 34.866 forecast) |
| MART | `mart.sazonalidade_baseline_24_25` | 23.449 (moda 2024-2025, fallback) |
| MART | `mart.sazonalidade_baseline_25_26` | 32.581 (moda 2025-2026, primária) |
| MV | `mart.vw_api_produtos_sazonalidade` | 54.479 (exposta à API) |

A **MV `vw_api_produtos_sazonalidade`** é a view final que a API B2C consulta. Definição em `26_forecast_baseline.sql:63`:
- JOIN: `sazonalidade_produto` + `dim_produto` + `dim_localidade` + `dim_categoria`
- Filtros: `categoria_b2c = 'ALIMENTO_VAREJO'`, `status_cor IN ('VERDE','AMARELO','VERMELHO')`, exclusão de `INSUMO_AGRICOLA`/`MAQUINARIO_FERRAMENTA`/`FLORES`/`OUTROS`
- Ordenação: `is_forecast` primeiro (FALSE = real antes de TRUE = projeção)

## Funções Regionais (Fase 32)
- `fn_regioes_listar()` — retorna as 5 regiões com seus polos CEASA (lê de `config/regions.json` via API, não SP)
- `fn_resumo_regiao(p_regiao_id TEXT, p_ano INT DEFAULT 2025)` — snapshot agregado por região: produtos com status_cor por UF. Cobertura mínima de 75% dos meses com dado real no ano. Usada por `GET /api/v1/sazonalidade?regiao=...`

## Forecast — Engine Preditiva (Fase 30)

### Modelo Atual v2 (100% SQL, Jul/2026)
- `sp_calcular_forecast_2026()` — Stored Procedure que projeta meses de 2026 sem dado real usando a **Moda** ponderada do `status_cor` de duas baselines.
- **Duas baselines permanentes**:
  - `mart.sazonalidade_baseline_25_26` — **primária**: moda sobre dados reais 2025-2026 (~19 meses). 32.581 linhas. Substitui baseline flat anterior.
  - `mart.sazonalidade_baseline_24_25` — **fallback**: moda sobre 2024-2025, com confiança reduzida à metade. 23.449 linhas.
- **CTE `baseline_ponderado`**: FULL JOIN entre ambas com CASE weighting:
  - `primary` (25_26) vence quando `confianca >= 30`
  - `fallback` (24_25 \* 0.5) usado quando primary não existe ou confiança < 30
  - Produtos sem baseline em nenhuma tabela são excluídos do grid de forecast
- **Método de forecast**: `beta_weighted_25_24` para TODAS as projeções (independente de qual baseline serviu de fonte)
- Colunas de rastreabilidade na `mart.sazonalidade_produto`:
  - `is_forecast BOOLEAN` — TRUE = projeção, FALSE = dado real
  - `baseline_confianca NUMERIC(5,2)` — confiança efetiva (0-100)
  - `forecast_method TEXT` — valores permitidos: `gamma_forecast_baseline`, `alpha_baseline_25_26`, `beta_media_disponivel`, `beta_weighted_25_24`
- UPSERT com regra de ouro: dado real (scraper) sempre vence projeção. `ON CONFLICT DO UPDATE` com lógica `is_forecast = FALSE` quando EXCLUDED é real.
- Sem threshold explícito de confiança — weighting embutido no CASE do `baseline_ponderado`.
- `REFRESH MATERIALIZED VIEW CONCURRENTLY` executado no final da SP.
- **Resultado**: 19.933 projeções para Ago-Dez 2026 em 1.02s, 12.884 registros reais Jan-Jul intactos.

### MV V14 (`vw_api_produtos_sazonalidade`)
- Expõe `is_forecast`, `baseline_confianca`, `forecast_method`.
- Índices parciais: `idx_vw_sazonalidade_forecast` (WHERE is_forecast=TRUE), `idx_vw_sazonalidade_confianca` (DESC).

### Migrações Chave
- `27_fix_br_nacional_weighting.sql` — Hotfix: SP chama `sp_calcular_sazonalidade_preditiva()` em vez da legacy.
- `28_recalibracao_baseline_24_25.sql` — Recalibração do baseline para 2024-2025.
- `29_focus_2025_2026.sql` — Filtro temporal: apenas >= 2025, exclusão de B2B (INSUMO_AGRICOLA, MAQUINARIO, FLORES).
- `30_engine_preditiva_forecast_2026.sql` (v1) → (v2 ponderado) — **538 linhas**: baseline_25_26 DDL, CTE baseline_ponderado (FULL JOIN + CASE), CHECK 4 valores, remoção guarda confiança >= 25. Execução em 1.02s.
- `32_fn_regional_snapshot.sql` — Funções `fn_regioes_listar()` e `fn_resumo_regiao()` para filtro regional.

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
- `30_engine_preditiva_forecast_2026.sql` — SP forecast v2 ponderado + baselines + MV V14
- `32_fn_regional_snapshot.sql` — Funções regionais (`fn_resumo_regiao`, `fn_regioes_listar`)

## Migração Supabase (2026-07-17)

### Projeto
- **Nome:** Quero_Comprar_ext
- **Ref:** kxsqrcccaaxplpktmutl
- **Host:** db.kxsqrcccaaxplpktmutl.supabase.co
- **PostgreSQL:** 17.6.1.127
- **Região:** us-east-1

### Status
- Fase 0 (Backup): ✅ `backup_quero_comprar_pre_migracao.dump` (2.48 MB)
- Fase 1 (Projeto): ✅ Projeto criado e linkado
- Fase 2 (Schema): ✅ 12 migrações aplicadas via `supabase db push --linked`
- Fase 3 (Data): ⏳ Em andamento — dim_produto, dim_localidade, dim_categoria, fact_precos_mensais restaurados

### Comandos Úteis
```bash
# Listar projetos
npx supabase projects list

# Linkar ao projeto
npx supabase link --project-ref kxsqrcccaaxplpktmutl

# Push de migrações
npx supabase db push --linked

# Executar SQL no banco remoto
npx supabase db query --linked "SELECT 1;"

# Dump do schema remoto
npx supabase db dump --linked --schema public

# Dump de dados
npx supabase db dump --linked --data-only
```

### Connection Options
- **Direct (5432):** `postgresql://postgres:SENHA@db.kxsqrcccaaxplpktmutl.supabase.co:5432/postgres`
- **Transaction Pooler (6543):** `postgresql://postgres.kxsqrcccaaxplpktmutl:SENHA@aws-0-us-east-1.pooler.supabase.com:6543/postgres`
- **User pooler:** `postgres.{project_ref}`

### Notas
- DNS `db.kxsqrcccaaxplpktmutl.supabase.co` não resolve nesta máquina Windows
- Usar `supabase db query --linked` que usa tunnel interno da CLI
- Não combinar `--linked` com `--db-url` (conflito de flags)
- Para asyncpg com pooler: `statement_cache_size=0`
