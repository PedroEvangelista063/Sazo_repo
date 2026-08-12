# summary.md — /database (Pomar e Triagem)

> 📦 **Repositório (2026-08-07):** `PedroEvangelista063/Sazo_repo` — renomeado de `Quero_Comprar_ext` (a URL antiga redireciona).

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

| Quem    | Onde encontrar dados brutos                | Como acessar                      |
| ------- | ------------------------------------------ | --------------------------------- |
| **DBA** | `raw.coleta_bruta` (banco)                 | `SELECT * FROM raw.coleta_bruta`  |
| **DBA** | `database/processed_data/01_raw/*.parquet` | `COPY` ou ferramenta de arquivos  |
| **Dev** | `raw.coleta_bruta` (via asyncpg)           | `pipeline/scraper/persistence.py` |
| **Dev** | `database/processed_data/01_raw/*.parquet` | `polars.read_parquet()`           |

## Volumes Atuais por Tabela (2026-07-30 — pós LOCF + sintéticos + forecast)

| Camada  | Tabela                              | Registros                                           |
| ------- | ----------------------------------- | --------------------------------------------------- |
| RAW     | `raw.coleta_bruta`                  | 15 (payloads brutos, UUID PK)                       |
| STAGING | `staging.fact_precos_mensais`       | 45.114 (dados limpos e tipados)                     |
| STAGING | `staging.dim_produto`               | 865 (produtos únicos)                               |
| STAGING | `staging.dim_localidade`            | 850 (localidades únicas)                            |
| STAGING | `staging.dim_categoria`             | 11 (categorias B2C)                                 |
| STAGING | `staging.confianca_baseline`        | 2.802 (confiança por produto/localidade)            |
| STAGING | `staging.baseline_2025_interpolado` | 2.802 (baseline interpolada)                        |
| STAGING | `staging.dim_conab_produto_mapping` | 20 (mapping CONAB ↔ produto)                        |
| STAGING | `staging.precos_rejeitados`         | 87 (anomalias detectadas por trigger)               |
| MART    | `mart.sazonalidade_produto`         | **145.740** (65.760 forecast, 0 INSUFICIENTE)       |
| MART    | `mart.sazonalidade_baseline_24_25`  | 23.449 (moda 2024-2025, fallback)                   |
| MART    | `mart.sazonalidade_baseline_25_26`  | 32.581 (moda 2025-2026, primária)                   |
| MV      | `mart.vw_api_produtos_sazonalidade` | **139.255** (exposta à API, filtro ALIMENTO_VAREJO) |
| OPS     | `ops.quarentena_coleta`             | 9 (rejeições com motivo + raw_id UUID)              |
| OPS     | `ops.config_agente`                 | 8 (configuração dos micro-motores)                  |

A **MV `vw_api_produtos_sazonalidade`** é a view final que a API B2C consulta. Definição em `26_forecast_baseline.sql:63`:

- JOIN: `sazonalidade_produto` + `dim_produto` + `dim_localidade` + `dim_categoria`
- Filtros: `categoria_b2c = 'ALIMENTO_VAREJO'`, `status_cor IN ('VERDE','AMARELO','VERMELHO')`, exclusão de `INSUMO_AGRICOLA`/`MAQUINARIO_FERRAMENTA`/`FLORES`/`OUTROS`
- Ordenação: `is_forecast` primeiro (FALSE = real antes de TRUE = projeção)

## Funções Regionais (Fase 32)

- `fn_regioes_listar()` — retorna as 5 regiões com seus polos CEASA (lê de `config/regions.json` via API, não SP)
- `fn_resumo_regiao(p_regiao_id TEXT, p_ano INT DEFAULT 2025)` — snapshot agregado por região: produtos com status_cor por UF. Cobertura mínima de 75% dos meses com dado real no ano. Usada por `GET /api/v1/sazonalidade?regiao=...`

## Camada de Mapas e Fluxos

- `staging.dim_fluxo_abastecimento` — dimensão de fluxos de abastecimento logístico por produto (originada em `44_dim_fluxo_abastecimento.sql`). Colunas: `id_fluxo`, `id_produto`, `produto_nome`, `origem_uf`, `origem_polo`, `destino_uf`, `destino_regiao_id`, `meses` (array int), `sazonalidade`, `preco_referencial`, `tipo` (`'exportado'`/`'importado'`/`'autossuficiente'`), `ano_referencia`, `criado_em`. Índices em `id_produto`, `origem_uf`, `destino_uf` e GIN em `meses`. **Fonte de verdade: `48_adicionar_novos_fluxos.sql`** — reimporta os 166 fluxos de 32 produtos com `DELETE` + `INSERT` e matching canônico via `ORDER BY` (produto com mais registros em `fact_precos_mensais`), `ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING`. `staging.fn_importar_fluxos_json()` (migration 44/49) está **DEPRECATED**: embute um JSON antigo de 104 fluxos e não deve ser usada como fonte. `staging.vw_fluxos_regionais` (migration 44) é a view amigável com joins em `dim_produto` e `descricao_tipo` (🟢 Envia para fora / 🔴 Recebe de fora / 🟡 Produção local), `periodicidade` e `regiao_destino_nome`; grants para `role_etl_writer`/`role_api_reader`. Observação de sincronização (2026-07-31): o banco de produção contém **165 registros únicos** (carga da migration 48 em 12:04:52 UTC-3 + complemento da migration 60). O `config/flows.json` tem 166 entradas, mas apenas **165 combinações únicas** `(id_produto, origem_uf, destino_uf, tipo)`: os fluxos Melão RN→CE id 25 (`Baixo`) e id 93 (`Médio`) compartilham a mesma rota/tipo e colidem na constraint `uq_fluxo_produto_uf` — o segundo é descartado pelo `ON CONFLICT DO NOTHING`. **`60_completar_fluxos_acai_castanha_melao.sql`** resolveu a lacuna original da migration 48 (160 registros; 6 fluxos sem match em `dim_produto`): expandiu `fn_normalizar_nome_produto` para colapsar `AÇAÍ/ACAI → ACAI`, `CASTANHA → CASTANHA`, `MELÃO/MELAO → MELAO`, cadastrou o canônico `AÇAÍ` (id 10454, padrão TANGERINA/MELANCIA/ALFACE) e inseriu 5 fluxos (Melão RN→CE `Baixo` + CE→RN, Castanha AC→RO, Açaí AP→PA + AC→AM), todos apontando para produtos com preços reais (MELÃO 10439 com 133 preços, Castanha Nacional 2434 com 1). O 6º bloco (Melão RN→CE `Médio`) é no-op esperado (colisão de chave). Açaí foi complementado por **`61_backfill_precos_acai_conab.sql`** (migration 61): 64 preços reais CONAB (fonte `CONAB`/LISTA1, R$/kg, janela 2025-06..2026-05, UFs AC/AM/AP/MA/PA/RO), `conab_id_produto = 8623` e `status_fonte = MAPEADA`; baselines 25_26/24_25 reconstruídas e forecast/sandwich reexecutados — AÇAÍ agora aparece na API (`mart.vw_api_produtos_sazonalidade`) com **100 linhas** (64 reais + 36 projeções 2026-06..12). Reexecutar a migration 48 isolada NÃO altera o resultado (voltaria a 160); o complemento está nas migrations 60 e 61.
- `mart.vw_mapa_regional_completo` — view consolidada do mapa regional (originada em `46_mapa_regional_completo.sql`). Consolida produtos × localidades × fluxos de abastecimento (origem/destino), tipo de preço (real/proxy/ausente). Suporta filtro por UF ou lista de UFs: `SELECT * FROM mart.vw_mapa_regional_completo WHERE uf = 'TO'` ou `WHERE uf IN ('AC','AM','AP')`.
- `staging.fn_relatorio_mapa_regional(p_uf TEXT)` — relatório consolidado do mapa regional por UF (originada em `46_mapa_regional_completo.sql`). Com `p_uf = NULL`, retorna todas as UFs (visão nacional). Uso: `SELECT * FROM staging.fn_relatorio_mapa_regional('AC')` ou `fn_relatorio_mapa_regional(NULL)`. Grants para `role_api_reader` e `role_etl_writer`.

## Mudanças Recentes (2026-08-12, follow-ups)

### Migration 80 (V23) aplicada + sync Prod→Homologação + revisão da 77

- **Migration 80 (V23, janela 2023+) APLICADA nos DOIS bancos** (local + Aiven, 2026-08-12) com backups `backup_*_80_pre_*`; validada funcionalmente: 0 âncoras FALLBACK `ano_referencia < 2023`, `min(ano_referencia)` set–dez 2026 = 2023, MV 177.485 linhas, 0 `status_cor` nulo/CINZA. `CREATE ... WITH DATA` já popula — refresh redundante.
- **Sync Produção ➔ Homologação** executado: local espelha o Aiven (V23) — `ops.*`/`raw.*` preservados; event trigger `ensure_rls` (legado Supabase, ausente no Aiven) removido do local = topologia idêntica ao Aiven.
- **Migration 77 (nomenclatura DBA-friendly): APLICADA no LOCAL (homologação, 2026-08-12)** com backup `backup_schema_77_pre_*`. A 77 foi **reescrita** antes da aplicação: **wrappers de compatibilidade de 30 dias para as 9 funções renomeadas** (BLOCO 4.5) + **guard de idempotência** no BLOCO 4 (evita re-renomear wrappers na 2ª execução) + **BLOCO 4.6: corpos chamadores reescritos para os nomes novos** (`validar_anomalia_preco` chama `classificar_preco_anomalia`; `consolidar_produtos_duplicados` chama `relatorio_normalizacao_produtos`) — os wrappers ficam puramente vestigiais e a Fase 3 (drop 2026-09-30) é segura sem pré-requisito. **Validação pós-aplicação real**: 10 novos nomes + 9 wrappers, MV intacta (177.485), 0 nulo/CINZA, **trigger em runtime capturou preço anômalo R$99.999** (rejeição id 17841), wrappers delegando, 2ª execução no-op (0 renames), smoke do guard PASS (352 produtos). **Pendência**: aplicar no Aiven (PRIMARY) após aprovação — local segue adiante (homologação).

### Dual-Environment (FASE 2/4) — banco de homologação e sync de dados

- **Dependência dos Git Hooks**: o smoke de homologação (`scripts/smoke_staging.sh`, rodado no pre-commit) valida `/br-sazonalidade` sem HTTP 500 e com **0 status_cor nulo/CINZA** — a Regra de Ouro NO GRAY/NO NULL do Deep Fallback V22/V23 virou gate de commit.
- `scripts/sync_db_prod_to_staging.sh` (novo) — Produção (Aiven) ➔ Homologação (local) com `--dry-run`, preservando `ops.*` (ex.: `ops.config_agente`) e `raw.*` no destino; recusa destino não-local. NPM: `db:sync:staging` / `db:sync:staging:dry`.

## Mudanças Recentes (2026-08-11)

### Deep Fallback Histórico — MV V22 (78_deep_fallback_historico.sql)

- **Novo arquivo**: `database/78_deep_fallback_historico.sql` (commits `8d111df6` + runbook `docs/runbook_migration_78_local.md`). **✅ Aplicada (LOCAL + REMOTO/Aiven, validado 2026-08-11):** definição da MV contém `DEEP_FALLBACK`/`PROJECAO_HISTORICA` e `fn_br_nacional_sazonalidade` expõe `p_limit`/`p_offset` nos dois bancos (MV = 177.485 linhas). Auditoria E2E apontou meses futuros (set–dez 2026) da MV com linhas `FALLBACK_DIMENSAO` de `status_cor` fabricado (`AMARELO`) e `ano_referencia` NULL (m8-12 `REAL_ATUAL` = 0 linhas; m7 = 1.956 parcial; 9.055 linhas FALLBACK em m9-12). Decisão de arquitetura: **NO GRAY / NO NULL** — a grade permanece preenchida (VERDE/AMARELO/VERMELHO).
- Para linhas `FALLBACK_DIMENSAO` do ano corrente com `mes >= mes corrente`, o Deep Fallback define:
  - `status_cor` ← (1º) status do histórico real mais recente do mesmo `(id_produto, id_localidade, mes)` em anos anteriores (`tipo_dado IN ('REAL_ATUAL','HISTORICO_BASE')`, `ORDER BY ano DESC LIMIT 1`); (2º) `mart.sazonalidade_baseline.status_cor_mode`; (3º) `VERDE`.
  - `ano_referencia` ← ano histórico usado (NULL se caiu em baseline/VERDE); `metadado_transparencia` ← chaves originais + `PROJECAO_HISTORICA`/`DEEP_FALLBACK`/`mensagem_transparencia`.
  - **Contrato da API NÃO muda** — `tipo_dado` continua `REAL_ATUAL/HISTORICO_BASE/FALLBACK_DIMENSAO`; a proveniência vai nos metadados. Quality Gate da FASE 76 preservado integralmente.
- `fn_br_nacional_sazonalidade` ganha `p_limit`/`p_offset` — paginação push-down no nível de PRODUTO (grade de 12 meses), mantendo o contrato do endpoint `/br-sazonalidade`.

### BR Sazonalidade Inclui Projeção (79_br_sazonalidade_inclui_projecao.sql)

- **Novo arquivo**: `database/79_br_sazonalidade_inclui_projecao.sql` (commit `a84e6a76`, P1-1). **✅ Aplicada (validado 2026-08-11):** `fn_br_nacional_sazonalidade` referencia `FALLBACK_DIMENSAO` em LOCAL e REMOTO (mesma assinatura `p_ano, p_categoria, p_min_ufs, p_limit, p_offset`). Auditoria E2E real detectou que `fn_br_nacional_sazonalidade` filtrava `tipo_dado IN ('REAL_ATUAL','HISTORICO_BASE')` — as 9.055 linhas `FALLBACK_DIMENSAO` projetadas pelo V22 nunca chegavam ao endpoint (13/352 produtos com grade incompleta, ex.: Carapau = 2 meses reais).
- Solução: incluir as linhas FALLBACK projetadas na saída nacional. **Precedência REAL > projeção**: agregação condicional (MODE que ignora NULL) — se QUALQUER localidade real existe na UF-mês, o status usa o MODE das linhas reais (`fonte_prioridade = 0`); a projeção só entra quando a UF-mês é 100% projetada. Mesma assinatura (5 args) e mesmo `RETURNS TABLE` (13 colunas).

### Janela Histórica 2023+ no Deep Fallback — MV V23 (80_mv_fallback_janela_2023.sql)

- **Novo arquivo**: `database/80_mv_fallback_janela_2023.sql` (commit `7f92c39f`, decisão do usuário). **⚠️ COMMITADA mas NÃO aplicada (validado 2026-08-11):** a definição real da MV (LOCAL e REMOTO) NÃO contém o piso `YEAR FROM CURRENT_DATE` — aplicar o DDL + `REFRESH MATERIALIZED VIEW` via psql (padrão 78: DDL só, refresh posterior) para subir a MV para V23. Sem piso de ano, o LATERAL `hh` do V22 (78:338-352) podia usar âncoras de 2021/2022 (defasagem elevada + inflação acumulada).
- Piso deslizante em TODA subconsulta da MV que lê histórico com intenção de âncora de projeção: `AND ano >= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 3` (hoje: âncoras 2023..2025, piso = Ano Atual − 3). Branches A/B/C e contrato INALTERADOS. DDL só (sem REFRESH — refresh posterior via psql); `fn_br_nacional_sazonalidade` NÃO é tocada (já alterada na 79).

### Nomenclatura DBA-Friendly (77_refatoracao_nomenclatura_dba_friendly.sql)

- **Novo arquivo (DRAFT — NÃO aplicado)**: `database/77_refatoracao_nomenclatura_dba_friendly.sql` (commit `1d03d911` + `docs/auditoria_nomenclatura_2026-08.md`). Renomeia tabelas para nomes DBA-friendly (`raw.precos_uf → raw.preco_conab_uf`, `raw.precos_municipio → raw.preco_conab_municipio`, `staging.dim_conab_produto_mapping → staging.dim_mapeamento_produto_conab`, etc.) com views temporárias de 30 dias para compatibilidade. **Executar SOMENTE após backup completo + aprovação do time** — NÃO toca MV `vw_api_produtos_sazonalidade`, roles, `fact_precos_mensais` nem `sp_executar_carga_completa`.

## Mudanças Recentes (2026-08-07)

### Expurgo de Produtos Sem Preço — MV V20 (71_expurgo_produtos_sem_preco.sql)

- **Novo arquivo**: `database/71_expurgo_produtos_sem_preco.sql` (FASE 2 do "Qualidade > Quantidade") — expurga os **produtos fantasmas** (sem NENHUM registro em `fact_precos_mensais`) e recria a MV **V20** suprimindo produtos sem âncora real:
  - **Baseline medido (pré-migração)**: `staging.dim_produto` = 2.869 (627 sem fact), `staging.fact_precos_mensais` = 266.773, `mart.sazonalidade_produto` = 364.383 (10.518 órfãs), MV = 260.487 (~10.176 linhas de fantasmas).
  - **1) Backup**: tabelas em `ops` (`dim_produto_expurgado_backup`, `sazonalidade_orfao_backup`, `dim_produto_canonico_expurgado_backup`) para rollback manual sem perda.
  - **2) DELETE defensivo**: órfãos em `status_fonte_produto`, `dim_fluxo_abastecimento` e `mart.sazonalidade_produto` (sem FK) + `mart.dim_produto_canonico` (tem FK p/ dim_produto — bloqueava o DELETE).
  - **3) DELETE** dos fantasmas em `staging.dim_produto` (`NOT EXISTS` na fato).
  - **4) MV V20** (`DROP + CREATE`, `WITH DATA`): adiciona CTE `produtos_com_ancora AS MATERIALIZED` (produtos com PELO MENOS uma linha `REAL_ATUAL`/`HISTORICO_BASE` na âncora) + `JOIN` final de supressão — **produto 12 meses CINZA (sem nenhuma âncora real) nunca mais chega ao frontend**. Branch C sem COALESCE morto (FASE 68 preservado), 7 índices padrão + GRANT.
  - **5) Prova embutida**: bloco `DO` com `RAISE NOTICE 'EXPURGO-71: ...'` com contagens pós-expurgo.
  - 100% transacional (`BEGIN`/`COMMIT`), idempotente via `DROP IF EXISTS`/`DROP MATERIALIZED VIEW IF EXISTS`.

### Novos Arquivos (database/)

- `71_expurgo_produtos_sem_preco.sql` — Expurgo de produtos sem preço + supressão na MV V20 (FASE 2)

### Mapa Rápido — adicionado

- `71_expurgo_produtos_sem_preco.sql` — Expurgo de fantasmas + MV V20 (supressão de produtos sem âncora real)

## Mudanças Recentes (2026-08-03)

### Limiares Dinâmicos de Cor — Z-Score por Volatilidade (65_limiares_cores_dinamicos_zscore.sql)

- **Novo arquivo**: `database/65_limiares_cores_dinamicos_zscore.sql` (752 linhas) — substitui o semáforo ESTÁTICO (±25% fixo na view/MV 63:88, ±15% fixo na procedure 59) por limiares DINÂMICOS baseados no desvio padrão histórico de cada `(id_produto, id_localidade)` sobre os últimos 24 meses REAIS de `staging.fact_precos_mensais`:
  - **VERDE** se `preco_exibido < preco_referencia - 1.0 * desvio_padrao`; **VERMELHO** se `> + 1.0 * desvio_padrao`; **AMARELO** caso contrário (inclui base insuficiente/sem estatística).
  - Piso de segurança (CV mínimo 10%): produtos com desvio nulo/zero ou CV < 10% usam `desvio_efetivo = 10% da média` (banda mínima não-degenerada).
- **Fase 1** — `staging.fn_estatisticas_volatilidade_24m()`: AVG/STDDEV/COUNT por `(id_produto, id_localidade)` na janela dos últimos 24 meses reais (STDDEV amostral, igual à Fase 10).
- **Fase 2** — `staging.fn_status_cor_zscore(preco_exibido, preco_referencia, desvio_padrao)`: semáforo dinâmico ±1σ.
- **Fase 3** — propagação ao mart:
  1. 3 colunas novas em `mart.sazonalidade_produto` (`desvio_padrao_historico`, `limite_superior`, `limite_inferior`);
  2. UPDATE full da base (regra dinâmica + limites);
  3. `sp_calcular_sazonalidade()` — CASE ±15% substituído pela regra dinâmica via LATERAL + gravação das 3 colunas;
  4. `mart.vw_anchor_sazonalidade` — `status_cor` dinâmico via LATERAL + 3 colunas novas no output;
  5. MV `mart.vw_api_produtos_sazonalidade` **V18** (DROP+CREATE, `WITH DATA`, MESMOS 3 branches / colunas / 7 índices / GRANTs da V17 — apenas 3 colunas adicionadas).
- **Fase 4** — proof query executada pelo orchestrator após o apply.
- Idempotência: `CREATE OR REPLACE` / `ADD COLUMN IF NOT EXISTS` / `DROP IF EXISTS`; MV recriada com DROP + CREATE (não existe `CREATE OR REPLACE` para MV) + `WITH DATA`. Não toca em `backup_schema_latest.sql` (regenerado automaticamente).

### Dado Histórico Real + Transparência (63_dado_historico_real_transparencia.sql)

- **Novo arquivo**: `database/63_dado_historico_real_transparencia.sql` (refatoracao-dado-historico) — substitui as projeções SINTÉTICAS (Sanduíche Sazonal + Engine V13) por DADO HISTÓRICO REAL com transparência temporal (ano âncora N → N-1 → N-2):
  - `sp_executar_carga_completa()` — steps sintéticos (5-6) viram no-op guards + `RAISE NOTICE`; novo step 7 = `REFRESH MATERIALIZED VIEW CONCURRENTLY` da MV (o orchestrator vira dono do refresh).
  - 5 colunas novas em `mart.sazonalidade_produto`: `ano_referencia`, `tipo_dado`, `metadado_transparencia`, `idade_dado_anos`, `preco_exibido` (+ CHECK `chk_sazonalidade_tipo_dado`).
  - Backfill único: real → `REAL_ATUAL`/`HISTORICO_BASE`; `FLUXO_PROXY`/`is_forecast` → `FALLBACK_DIMENSAO` (nunca deletado).
  - View auxiliar `mart.vw_anchor_sazonalidade` (âncora N→N-1→N-2 via LATERAL, SEM CROSS JOIN — evita padrão OOM da Fase 62).
  - MV `mart.vw_api_produtos_sazonalidade` **V17**: 3 branches UNION ALL (A reais, B âncora em ano atual, C fallback dimensão) + 7 índices + GRANT.
  - `fn_br_nacional_sazonalidade` recriada com `ano_referencia`, `tipo_dado`.
  - Constraints preservadas: `uq_sazonalidade`, `uq_sazonalidade_data_ref`, `chk_data_ref_ano_mes`.
- **Fixes subsequentes (05c7407f, 3e3d224b)**: idempotência do CHECK + ordem do rollback 64 + `pg_attribute`; branch C da MV V17 emite `COALESCE(f.status_cor,'AMARELO')` — elimina `status_cor NULL` (bloqueador REL-01: pydantic ValidationError → HTTP 500).

### Rollback do Dado Histórico (64_rollback_dado_historico.sql)

- **Novo arquivo**: `database/64_rollback_dado_historico.sql` — rollback-ONLY (não roda em deploy; acionado manualmente via `psql`). Desfaz database/63 + 000021:
  1. Restaura `sp_executar_carga_completa` com engines sintéticas ATIVAS (corpo original da Fase 62);
  2. Remove MV V17 + as 5 colunas de transparência + CHECK + comentários;
  3. Remove `mart.vw_anchor_sazonalidade`;
  4. Recria MV `vw_api_produtos_sazonalidade` V16 (padrão Fase 36) + refresh;
  5. Restaura `fn_br_nacional_sazonalidade` (sem `ano_referencia`/`tipo_dado`).
- Reaplicar database/63 após rollback reaplica a refatoração (idempotente).

### Engine Forecast V13 (62_engine_forecast_2024_2025_v13.sql)

- **Novo arquivo**: `database/62_engine_forecast_2024_2025_v13.sql` — motor de BASELINE PONDERADA 2024→2025 (precede e é substituído pelo 63):
  - Nova tabela `mart.sazonalidade_baseline_ponderada` com Matriz de Decisão (60% âncora 2024 + 40% margem 2025) e cadeia de fallbacks: `ANCHOR_2024_MARGIN_2025 → PROXY_CATEGORIA_UF → LOCF_MES_ANTERIOR`.
  - `sp_calcular_forecast_2026_v13()` projeta 2026 preservando linhas reais (`is_forecast = FALSE` no ON CONFLICT).
  - `fn_br_nacional_sazonalidade` recriada com `forecast_method` + `calculado_em`.
- `database/57_expurgo_e_recalibragem.sql` — ajustado para preservar `forecast_method v13` no expurgo/recalibragem.

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
- `74_quality_gate_12_meses.sql` (2026-08-08, commit `71c2a8f5`) — Expurgo físico: só permanecem produtos com `COUNT(DISTINCT mes) = 12` na janela 2024–2026 em `staging.fact_precos_mensais` (critério FRACO: meses espalhados entre anos passam — 863 produtos, 0 com 36/36).
- `75_restaura_sazonalidade_baseline.sql` (2026-08-08, commit `732f5408`) — Restaura `mart.sazonalidade_baseline` (tabela ativa no LEFT JOIN dos endpoints /sazonalidade) dropada por engano (incidente HTTP 500 prod). 20.088 linhas / 140 produtos.
- `76_quality_gate_completude_serie.sql` (2026-08-10) — **QUALITY GATE DE COMPLETUDE (vitrine perfeita)**: recria a MV `mart.vw_api_produtos_sazonalidade` (V21) com CTE `produtos_completos` — só entram produtos com série mensal COMPLETA (12/12 meses REAIS, `NOT COALESCE(is_interpolado,FALSE)`) em 2024 OU 2025. JOIN final filtra sumariamente o grupo Z (gaps em todos os anos). Pós: MV 210.367→177.485 linhas, 468→358 produtos, FALLBACK 31.799→18.487; `ops.serie_incompleta_backup` (146 produtos) para auditoria. Aplicada LOCAL + REMOTO (Aiven) com números idênticos.

### Migrações Formais (supabase/migrations/*.sql — reconciliadas no remoto)

| Migration                              | Data       | O que fez                                                                                                                                                                                                                                                                                                                                                                                                                           |
| -------------------------------------- | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `000013_reconciliacao_drift_fase4.sql` | 2026-07-25 | Reconciliou 18 objetos do delta database/*.sql no Supabase remoto: 8 tabelas (dim_categoria, dim_conab_produto_mapping, fato_cotacao_regional, baseline_2025_interpolado, confianca_baseline, sazonalidade_baseline_24_25, sazonalidade_baseline_25_26, status_fonte_produto), 2 views (vw_categorias, vw_municipios), 1 MV (vw_api_produtos_sazonalidade V15 + 7 índices), 5 funções de agregação, 2 procedures, grants para roles |
| `000014_triggers_anomalia_audit.sql`   | 2026-07-25 | Trigger UF-based: `staging.trg_valida_anomalia_preco` atualizada para comparar preço por UF (não município). Infra de auditoria: `ops.audit_logs` + `ops.trg_audit_status_cor` (AFTER UPDATE em sazonalidade_produto) + `ops.vw_ultimas_mudancas_status` + grants                                                                                                                                                                   |
| `000015_rls_security_layer.sql`        | 2026-07-25 | RLS ativo em 4 tabelas (mart.sazonalidade_produto, staging.dim_produto, staging.fact_precos_mensais, ops.audit_logs) com 5 políticas. Schema USAGE grants. ALTER DEFAULT PRIVILEGES para objetos futuros. Grants faltantes corrigidos (role_api_reader em sazonalidade_baseline e vw_api_produtos_sazonalidade)                                                                                                                     |

## Scripts Python (database/scripts/)

- `backfill_2024.py` — insere dados de 2024 no mart replicando a lógica de classificação da SP V9
- `calcular_baseline.py` — lê dados reais 2024-2025, calcula moda do status_cor e confiança. **Legado** — não é mais chamado pelo pipeline.
- `projetar_2026.py` — projeta meses de 2026 sem dado real. **Legado** — substituído por `sp_calcular_forecast_2026()`.
- `validar_forecast.py` — validação automatizada (matriz densidade, gaps, sem regressão, confiança, MV)

## Conexão Externa (DBeaver / psql)

### Banco Local (Standby / Sandbox)

| Parâmetro    | Valor                                                                   |
| ------------ | ----------------------------------------------------------------------- |
| **Host**     | `localhost`                                                             |
| **Porta**    | `5432`                                                                  |
| **Database** | `quero_comprar`                                                         |
| **Username** | `postgres`                                                              |
| **Password** | `postgres_dev_local`                                                    |
| **URL**      | `postgresql://postgres:postgres_dev_local@localhost:5432/quero_comprar` |

> ⚡ No DBeaver, vá em **Driver properties → PostgreSQL** e marque `Show all schemas` para visualizar `raw`, `staging`, `mart`, `ops`.

### Banco Remoto (Primary — Supabase)

| Parâmetro    | Pooler Transaction (API)              | Pooler Session (ETL/DDL)              |
| ------------ | ------------------------------------- | ------------------------------------- |
| **Host**     | `aws-1-us-east-1.pooler.supabase.com` | `aws-1-us-east-1.pooler.supabase.com` |
| **Porta**    | `6543`                                | `5432`                                |
| **Database** | `postgres`                            | `postgres`                            |
| **Username** | `postgres.kxsqrcccaaxplpktmutl`       | `postgres.kxsqrcccaaxplpktmutl`       |
| **URL env**  | `DATABASE_URL_API`                    | `DATABASE_URL` / `DATABASE_URL_ETL`   |

## Novos Arquivos (database/)

- `39_locf_real_gaps_sazonalidade.sql` — LOCF multi-fallback para preencher gaps de preço
- `scripts/injetar_sintetico_coldstart.py` — Geração de preços sintéticos para cold-start
- `62_engine_forecast_2024_2025_v13.sql` — Engine V13 (baseline ponderada 2024→2025)
- `63_dado_historico_real_transparencia.sql` — Dado histórico real + transparência (ano âncora, MV V17)
- `64_rollback_dado_historico.sql` — Rollback-ONLY da refatoração (desfaz 63 + 000021)
- `65_limiares_cores_dinamicos_zscore.sql` — Limiares dinâmicos de cor (Z-Score ±1σ, MV V18)
- `71_expurgo_produtos_sem_preco.sql` — Expurgo de fantasmas + MV V20
- `74_quality_gate_12_meses.sql` — Quality gate de 12 meses (expurgo físico)
- `75_restaura_sazonalidade_baseline.sql` — Restaura `sazonalidade_baseline` (fix 500 prod)
- `76_quality_gate_completude_serie.sql` — Quality gate de completude de série (MV V21)
- `77_refatoracao_nomenclatura_dba_friendly.sql` — Nomenclatura DBA-friendly (DRAFT, não aplicado)
- `78_deep_fallback_historico.sql` — Deep Fallback histórico (MV V22, NO GRAY/NO NULL)
- `79_br_sazonalidade_inclui_projecao.sql` — /br-sazonalidade inclui projeção FALLBACK (P1-1)
- `80_mv_fallback_janela_2023.sql` — Deep Fallback janela 2023+ (MV V23)

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
- `62_engine_forecast_2024_2025_v13.sql` — Engine V13 (baseline ponderada 2024→2025, Matriz de Decisão)
- `63_dado_historico_real_transparencia.sql` — Dado histórico real + transparência temporal (ano âncora, MV V17)
- `64_rollback_dado_historico.sql` — Rollback-ONLY do dado histórico (desfaz 63 + 000021)
- `65_limiares_cores_dinamicos_zscore.sql` — Limiares dinâmicos de cor (Z-Score ±1σ, MV V18)
- `71_expurgo_produtos_sem_preco.sql` — Expurgo de fantasmas + MV V20
- `74_quality_gate_12_meses.sql` — Quality gate 12 meses
- `75_restaura_sazonalidade_baseline.sql` — Restaura baseline (fix 500)
- `76_quality_gate_completude_serie.sql` — Completude de série (MV V21)
- `77_refatoracao_nomenclatura_dba_friendly.sql` — Nomenclatura DBA-friendly (DRAFT)
- `78_deep_fallback_historico.sql` — Deep Fallback (MV V22)
- `79_br_sazonalidade_inclui_projecao.sql` — BR inclui projeção (P1-1)
- `80_mv_fallback_janela_2023.sql` — Janela 2023+ (MV V23)

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

| Direção                | Permitido?          | Método                                                  |
| ---------------------- | ------------------- | ------------------------------------------------------- |
| **Remote ➔ Local**     | ✅ Sim              | Sync script (pg_dump → pg_restore)                      |
| **Local ➔ Remote**     | ❌ Nunca automático | Apenas via migrations formais em `supabase/migrations/` |
| **Dev diário**         | ✅ Remote           | `npm run dev` conecta ao Supabase                       |
| **Teste query pesada** | ✅ Local            | `psql $DATABASE_URL_LOCAL_BACKUP -f query.sql`          |
