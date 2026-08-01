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

## Volumes Atuais por Tabela (2026-07-30 — pós LOCF + sintéticos + forecast)
| Camada | Tabela | Registros |
|--------|--------|-----------|
| RAW | `raw.coleta_bruta` | 15 (payloads brutos, UUID PK) |
| STAGING | `staging.fact_precos_mensais` | 45.114 (dados limpos e tipados) |
| STAGING | `staging.dim_produto` | 865 (produtos únicos) |
| STAGING | `staging.dim_localidade` | 850 (localidades únicas) |
| STAGING | `staging.dim_categoria` | 11 (categorias B2C) |
| STAGING | `staging.confianca_baseline` | 2.802 (confiança por produto/localidade) |
| STAGING | `staging.baseline_2025_interpolado` | 2.802 (baseline interpolada) |
| STAGING | `staging.dim_conab_produto_mapping` | 20 (mapping CONAB ↔ produto) |
| STAGING | `staging.precos_rejeitados` | 87 (anomalias detectadas por trigger) |
| MART | `mart.sazonalidade_produto` | **145.740** (65.760 forecast, 0 INSUFICIENTE) |
| MART | `mart.sazonalidade_baseline_24_25` | 23.449 (moda 2024-2025, fallback) |
| MART | `mart.sazonalidade_baseline_25_26` | 32.581 (moda 2025-2026, primária) |
| MV | `mart.vw_api_produtos_sazonalidade` | **139.255** (exposta à API, filtro ALIMENTO_VAREJO) |
| OPS | `ops.quarentena_coleta` | 9 (rejeições com motivo + raw_id UUID) |
| OPS | `ops.config_agente` | 8 (configuração dos micro-motores) |

A **MV `vw_api_produtos_sazonalidade`** é a view final que a API B2C consulta. Definição em `26_forecast_baseline.sql:63`:
- JOIN: `sazonalidade_produto` + `dim_produto` + `dim_localidade` + `dim_categoria`
- Filtros: `categoria_b2c = 'ALIMENTO_VAREJO'`, `status_cor IN ('VERDE','AMARELO','VERMELHO')`, exclusão de `INSUMO_AGRICOLA`/`MAQUINARIO_FERRAMENTA`/`FLORES`/`OUTROS`
- Ordenação: `is_forecast` primeiro (FALSE = real antes de TRUE = projeção)

## Funções Regionais (Fase 32)
- `fn_regioes_listar()` — retorna as 5 regiões com seus polos CEASA (lê de `config/regions.json` via API, não SP)
- `fn_resumo_regiao(p_regiao_id TEXT, p_ano INT DEFAULT 2025)` — snapshot agregado por região: produtos com status_cor por UF. Cobertura mínima de 75% dos meses com dado real no ano. Usada por `GET /api/v1/sazonalidade?regiao=...`

## Camada de Mapas e Fluxos
- `staging.dim_fluxo_abastecimento` — dimensão de fluxos de abastecimento logístico por produto (originada em `44_dim_fluxo_abastecimento.sql`). Colunas: `id_fluxo`, `id_produto`, `produto_nome`, `origem_uf`, `origem_polo`, `destino_uf`, `destino_regiao_id`, `meses` (array int), `sazonalidade`, `preco_referencial`, `tipo` (`'exportado'`/`'importado'`/`'autossuficiente'`), `ano_referencia`, `criado_em`. Índices em `id_produto`, `origem_uf`, `destino_uf` e GIN em `meses`. **Fonte de verdade: `48_adicionar_novos_fluxos.sql`** — reimporta os 166 fluxos de 32 produtos com `DELETE` + `INSERT` e matching canônico via `ORDER BY` (produto com mais registros em `fact_precos_mensais`), `ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING`. `staging.fn_importar_fluxos_json()` (migration 44/49) está **DEPRECATED**: embute um JSON antigo de 104 fluxos e não deve ser usada como fonte. `staging.vw_fluxos_regionais` (migration 44) é a view amigável com joins em `dim_produto` e `descricao_tipo` (🟢 Envia para fora / 🔴 Recebe de fora / 🟡 Produção local), `periodicidade` e `regiao_destino_nome`; grants para `role_etl_writer`/`role_api_reader`. Observação de sincronização (2026-07-31): o banco de produção contém 160 registros (IDs 1–160, carga única da migration 48 em 12:04:52 UTC-3). O `config/flows.json` tem 166 fluxos, mas a migration 48 insere 160 porque **6 fluxos não têm match em `dim_produto`** e são silenciosamente ignorados: Açaí (2 fluxos), Castanha (1) e Melão (3) — produtos não existem na dimensão. Os fluxos 161–170 (Tangerina MG→DF/SP→MG, Alface SP→RJ/MG→RJ/SP→DF/PR→SC, Manteiga RS→SP/SC→RJ/MG→GO/MG→DF) **já estão no banco**. Reexecutar a migration 48 NÃO altera o resultado (voltaria a 160); para chegar a 166 é preciso antes cadastrar Açaí, Castanha e Melão em `dim_produto`.
- `mart.vw_mapa_regional_completo` — view consolidada do mapa regional (originada em `46_mapa_regional_completo.sql`). Consolida produtos × localidades × fluxos de abastecimento (origem/destino), tipo de preço (real/proxy/ausente). Suporta filtro por UF ou lista de UFs: `SELECT * FROM mart.vw_mapa_regional_completo WHERE uf = 'TO'` ou `WHERE uf IN ('AC','AM','AP')`.
- `staging.fn_relatorio_mapa_regional(p_uf TEXT)` — relatório consolidado do mapa regional por UF (originada em `46_mapa_regional_completo.sql`). Com `p_uf = NULL`, retorna todas as UFs (visão nacional). Uso: `SELECT * FROM staging.fn_relatorio_mapa_regional('AC')` ou `fn_relatorio_mapa_regional(NULL)`. Grants para `role_api_reader` e `role_etl_writer`.

## Mudanças Recentes (2026-07-30)

### Fix Crítico: Forecast 2026 (ON CONFLICT, DISTINCT ON, ano+mes)
- `database/30_engine_preditiva_forecast_2026.sql` — Correções na `sp_calcular_forecast_2026()`:
  - **ON CONFLICT corrigido**: antes usava `(id_produto, id_localidade, data_referencia_atual)`, agora usa `(id_produto, id_localidade, ano, mes)` — alinhado com a constraint real `uq_sazonalidade`
  - **Colunas `ano` + `mes` adicionadas**: extraídas de `data_referencia_atual` via `SPLIT_PART` em todas as CTEs
  - **DISTINCT ON**: `SELECT DISTINCT ON (id_produto, id_localidade, ano, mes)` com `ORDER BY is_forecast ASC` — dado real (FALSE) sempre vence projeção (TRUE)
  - Executada em ambos os ambientes (local: 33.578 linhas, remoto: 34.557 linhas)

### LOCF Real — Preenchimento de Gaps (39_locf_real_gaps_sazonalidade.sql)
- **Novo arquivo**: `database/39_locf_real_gaps_sazonalidade.sql`
- Algoritmo **group-and-max**: para cada produto+localidade, preenche gaps de preço carregando para frente o último valor não-nulo (LOCF — Last Observation Carried Forward)
- Fallback triplo: preço real → LOCF (grupo) → NOCB (próximo valor disponível) → média do produto
- `ON CONFLICT (id_produto, id_localidade, ano, mes) DO UPDATE` — idempotente
- Proteção: `status_cor = 'AMARELO'` não sobrescreve VERDE/VERMELHO existentes; `fonte = 'municipio'` preservado
- Resultado local: 65.724 linhas inseridas/atualizadas
- Resultado remoto: 15.021 gaps preenchidos (56.925→41.904 preços NULL)

### Injeção Sintética Cold-Start
- **Novo arquivo**: `database/scripts/injetar_sintetico_coldstart.py`
- Gera preços sintéticos com variação Gaussiana (30%) para produtos com histórico insuficiente
- Produtos-alvo: Abobrinha Brasileira, Abobrinha Italiana, Coco Seco, Coco Verde, MILHO
- Fallback para produtos sem preços reais: preço default R$5,00 (em vez de pular)
- Resultado: 4.000 registros sintéticos no remoto, 3.776 no local
- MILHO saltou de 5→10 meses, Abobrinhas de 7→10 meses, Coco Verde de 7→10 meses

### Cold-Start Proxy Hierárquico (calcular_baseline.py)
- `database/scripts/calcular_baseline.py` — Adicionado **Fase 2d: Cold-Start Proxy Hierárquico**
- Se produtos têm baseline esparso (< 6 meses), recebem baseline derivado do "Produto Pai" (raiz do nome)
- Ex: 'Alface Crespa Hidropônica' → raiz 'ALFACE' → herda sazonalidade do pai com confiança reduzida (penalidade 0.7)
- Fonte marcada como `BASELINE_HIERARQUICO` para rastreabilidade
- DSN corrigido: `postgres:postgres_dev_local`

### Cold-Start Fallback (projetar_2026.py)
- `database/scripts/projetar_2026.py` — Adicionado fallback de preço por produto:
  - Antes: pulava produtos sem preço na combinação produto+localidade
  - Agora: busca último preço conhecido do PRODUTO (independente da localidade) como fallback
- Colunas adicionadas: `fonte` (para data lineage) e `baseline_confianca` na projeção
- DSN corrigido: `postgres:postgres_dev_local`

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

### Migrações Chave (database/*.sql — scripts históricos)
- `27_fix_br_nacional_weighting.sql` — Hotfix: SP chama `sp_calcular_sazonalidade_preditiva()` em vez da legacy.
- `28_recalibracao_baseline_24_25.sql` — Recalibração do baseline para 2024-2025.
- `29_focus_2025_2026.sql` — Filtro temporal: apenas >= 2025, exclusão de B2B (INSUMO_AGRICOLA, MAQUINARIO, FLORES).
- `30_engine_preditiva_forecast_2026.sql` (v1) → (v2 ponderado) — **538 linhas**: baseline_25_26 DDL, CTE baseline_ponderado (FULL JOIN + CASE), CHECK 4 valores, remoção guarda confiança >= 25. Execução em 1.02s.
- `32_fn_regional_snapshot.sql` — Funções `fn_regioes_listar()` e `fn_resumo_regiao()` para filtro regional.

### Migrações Formais (supabase/migrations/*.sql — reconciliadas no remoto)

| Migration | Data | O que fez |
|-----------|------|-----------|
| `000013_reconciliacao_drift_fase4.sql` | 2026-07-25 | Reconciliou 18 objetos do delta database/*.sql no Supabase remoto: 8 tabelas (dim_categoria, dim_conab_produto_mapping, fato_cotacao_regional, baseline_2025_interpolado, confianca_baseline, sazonalidade_baseline_24_25, sazonalidade_baseline_25_26, status_fonte_produto), 2 views (vw_categorias, vw_municipios), 1 MV (vw_api_produtos_sazonalidade V15 + 7 índices), 5 funções de agregação, 2 procedures, grants para roles |
| `000014_triggers_anomalia_audit.sql` | 2026-07-25 | Trigger UF-based: `staging.trg_valida_anomalia_preco` atualizada para comparar preço por UF (não município). Infra de auditoria: `ops.audit_logs` + `ops.trg_audit_status_cor` (AFTER UPDATE em sazonalidade_produto) + `ops.vw_ultimas_mudancas_status` + grants |
| `000015_rls_security_layer.sql` | 2026-07-25 | RLS ativo em 4 tabelas (mart.sazonalidade_produto, staging.dim_produto, staging.fact_precos_mensais, ops.audit_logs) com 5 políticas. Schema USAGE grants. ALTER DEFAULT PRIVILEGES para objetos futuros. Grants faltantes corrigidos (role_api_reader em sazonalidade_baseline e vw_api_produtos_sazonalidade) |

## Scripts Python (database/scripts/)
- `backfill_2024.py` — insere dados de 2024 no mart replicando a lógica de classificação da SP V9
- `calcular_baseline.py` — lê dados reais 2024-2025, calcula moda do status_cor e confiança. **Legado** — não é mais chamado pelo pipeline.
- `projetar_2026.py` — projeta meses de 2026 sem dado real. **Legado** — substituído por `sp_calcular_forecast_2026()`.
- `validar_forecast.py` — validação automatizada (matriz densidade, gaps, sem regressão, confiança, MV)

## Conexão Externa (DBeaver / psql)

### Banco Local (Standby / Sandbox)

| Parâmetro | Valor |
|-----------|-------|
| **Host** | `localhost` |
| **Porta** | `5432` |
| **Database** | `quero_comprar` |
| **Username** | `postgres` |
| **Password** | `postgres_dev_local` |
| **URL** | `postgresql://postgres:postgres_dev_local@localhost:5432/quero_comprar` |

> ⚡ No DBeaver, vá em **Driver properties → PostgreSQL** e marque `Show all schemas` para visualizar `raw`, `staging`, `mart`, `ops`.

### Banco Remoto (Primary — Supabase)

| Parâmetro | Pooler Transaction (API) | Pooler Session (ETL/DDL) |
|-----------|-------------------------|--------------------------|
| **Host** | `aws-1-us-east-1.pooler.supabase.com` | `aws-1-us-east-1.pooler.supabase.com` |
| **Porta** | `6543` | `5432` |
| **Database** | `postgres` | `postgres` |
| **Username** | `postgres.kxsqrcccaaxplpktmutl` | `postgres.kxsqrcccaaxplpktmutl` |
| **URL env** | `DATABASE_URL_API` | `DATABASE_URL` / `DATABASE_URL_ETL` |

## Novos Arquivos (database/)
- `39_locf_real_gaps_sazonalidade.sql` — LOCF multi-fallback para preencher gaps de preço
- `scripts/injetar_sintetico_coldstart.py` — Geração de preços sintéticos para cold-start

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
- `30_engine_preditiva_forecast_2026.sql` — SP forecast v2 ponderado + baselines + MV V14 (FIX: ON CONFLICT, DISTINCT ON, ano+mes)
- `32_fn_regional_snapshot.sql` — Funções regionais (`fn_resumo_regiao`, `fn_regioes_listar`)
- `36_fix_dedup_dim_localidade.sql` — Dedup de localidades duplicadas
- `37_fix_br_regional_functions.sql` — Fix funções BR regionais
- `38_add_qualidade_column.sql` — Coluna de qualidade para produtos
- `39_locf_real_gaps_sazonalidade.sql` — LOCF real para gaps de preço

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
- Fase 3 (Data): ✅ **Completo** — 14 tabelas, 174.240 linhas, 100% idênticas local vs Supabase

### Fase 3 — Desafios Resolvidos
1. **Schema drift**: `raw.coleta_bruta` e `ops.quarentena_coleta` usam UUID PK (não SERIAL) — schema original via migração usava tipos incorretos, recriado via DROP/CREATE.
2. **Colunas faltantes**: `staging.fact_precos_mensais` não tinha `preco_curado`, `is_interpolado`, `fonte` — migração incompleta. Corrigido com `ALTER TABLE ADD COLUMN`.
3. **Trigger bloqueante**: `trg_valida_anomalia_preco` barrava inserts com preço >500% da média histórica. Trigger desativada, dados importados, reativada.
4. **Sequences dessincronizadas**: Restore com `id` explícito não atualizou `SERIAL` sequences — `precos_rejeitados_id_rejeitado_seq` em 1 quando max era 89. Corrigido com `setval()` para todas as tabelas.
5. **413 do Supabase API**: Arquivos SQL >~2.5MB via `supabase db query --file` retornam `413 request entity too large`. Solução: chunks de ~2MB.

### Scripts de Restore
- `restore_supabase_final.py` — restore v1 (row_to_json + INSERT em lote)
- `restore_remaining_v2.py` — restore v2 (apenas tabelas faltantes)
- `restore_final_v3.py` — restore v3 (200 rows/chunk, ON CONFLICT DO NOTHING)
- `restore_chunks/fix_schema_v3.sql` — recriação raw.coleta_bruta e ops.quarentena_coleta com UUID PK
- `fix_sequences.sql` — correção de sequences dessincronizadas

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

## 🏛️ Arquitetura Híbrida (2026-07-25)

```
REMOTO (PRIMARY — Active)              LOCAL (STANDBY — Backup)
──────────────────────────────         ─────────────────────────────
Supabase kxsqrcccaaxplpktmutl          PostgreSQL 18 nativo Linux Mint
DATABASE_URL (5432) — DDL/ETL          localhost:5432/quero_comprar
DATABASE_URL_API (6543) — API reads    postgres / postgres_dev_local
DATABASE_URL_ETL (5432) — cargas       
                                       
npm run dev → REMOTO (padrão)          npm run db:backup → Remote ➔ Local
                                        NUNCA Local ➔ Remote automático
```

### Comandos do Workflow

```bash
# Backup de segurança (schema + dados)
npm run db:backup

# Backup + restaura no banco local
npm run db:backup:restore

# Apenas schema
npm run db:backup:schema

# Apenas dados
npm run db:backup:data
```

### Artefatos de Backup (gitignored)

```
database/backups/
├── backup_schema_latest.sql       → DDL completo (184 objetos)
├── backup_data_latest.dump        → Dados curados (custom format)
├── backup_schema_20260725.sql     → Snapshot versionado (30 dias)
└── backup_data_20260725.dump      → Snapshot versionado (30 dias)
```

### Pipeline de Backup (scripts/sync_db_remote_to_local.sh)

1. `pg_dump --schema-only` do Supabase remoto (exclui schemas auth/storage/realtime)
2. `pg_dump --format=custom` dos dados (exclui ops.audit_logs, ops.audit_llm_queries, ops.quarentena_coleta, raw.*)
3. `--restore`: DROP dos schemas staging/mart/ops locais → `psql` schema → `pg_restore` dados
4. Limpeza automática de backups >30 dias

### Travas de Segurança

| Direção | Permitido? | Método |
|---------|-----------|--------|
| **Remote ➔ Local** | ✅ Sim | Sync script (pg_dump → pg_restore) |
| **Local ➔ Remote** | ❌ Nunca automático | Apenas via migrations formais em `supabase/migrations/` |
| **Dev diário** | ✅ Remote | `npm run dev` conecta ao Supabase |
| **Teste query pesada** | ✅ Local | `psql $DATABASE_URL_LOCAL_BACKUP -f query.sql` |
