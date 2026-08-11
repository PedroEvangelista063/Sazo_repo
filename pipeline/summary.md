# summary.md — /pipeline (Motor de Extração)

> 📦 **Repositório (2026-08-07):** `PedroEvangelista063/Sazo_repo` — renomeado de `Quero_Comprar_ext` (a URL antiga redireciona).

## Propósito

Pipeline de coleta ELT (`Scrape Now, Parse Later`). Micro-motores burros e focados extraem payloads sujos (HTML/JSON/CSV) e os depositam na Landing Zone (`raw.coleta_bruta`). Proibido validar, transformar ou filtrar dados durante a extração.

## Stack

- Python 3.13+, Polars, Playwright, HTTPX, asyncio, curl-cffi, patchright
- asyncpg (pool) para conexão com PostgreSQL
- Pydantic v2 (apenas para schemas de coleta, não para validação na borda)

## Regras de Ouro

1. **Scrape Now, Parse Later**: a extração NUNCA valida dados. Joga o payload bruto na `raw.coleta_bruta` e morre.
2. **Run and Die**: sem `while True`, sem daemon. O processo acorda, colhe, descarrega e encerra com `sys.exit(0)`.
3. **Timeout Global**: `asyncio.wait_for(task, timeout=1200)` — 20 min de vida máxima do job.
4. **Timeouts Locais**: HTTPX 15s, Playwright 20s. Sempre `try/finally` para fechar conexões.
5. **Concorrência Controlada**: `asyncio.Semaphore(3)` por motor. CircuitBreaker com 5 falhas → 120s de recovery.
6. **Micro-Motores**: cada engine é especialista em UM layout (`base_engine.py` → classe concreta).
7. **Janela Temporal**: ESTRITAMENTE 2024-2026. Qualquer request para ano < 2024 ou > 2026 é erro.
8. **Discovery**: dorks SEM AND/OR/filetype:. Apenas `""`, `site:`, `inurl:`, `intext:`, `*`. Rejeitar PDFs.
9. **Orquestrador**: cascata CEASA direta → Agregadores → Discovery. Log `[AUDIT]` a cada pivotagem.
10. **Fontes**: centralizadas em `config/sources_matrix.json` — configuration over code.

## Mudanças Recentes (2026-08-11)

### Nenhuma mudança neste lote

- Lote `2026-08-11` concentrado em `database/` (migrations 74-80: deep fallback V22/V23, quality gates, nomenclatura), `frontend/` (claymorphism UI, manifest PWA, círculos na grade, abas reordenadas) e `backend/` (memoização do refresh da MV + mensagens V22). /pipeline inalterado — coleta e ciclo medalhão seguem como documentado.

## Mudanças Recentes (2026-08-07) — FASE 1/2 (Qualidade > Quantidade)

### Malha Fina de Preço — defesa em profundidade (FASE 1)

Preço nulo, vazio, não-numérico ou `<= 0` NÃO entra em `staging.fact_precos_mensais`. A validação existe em 3 camadas independentes:

- `pipeline/ingestao_conab.py` — `_copy_to_fact()`: descarta linhas com `preco is None`, não-numérico ou `<= 0`, com contador `descartados_preco` + warning no log.
- `pipeline/processor/sorting_engine.py` — malha fina no parse: item com preço inválido NÃO prossegue e é registrado em `ops.quarentena_coleta` com motivo individual `malha_fina: preco_invalido: <valor>` (rastreabilidade, sem descarte silencioso). Log de resumo `descartados pela malha fina` por linha processada (commit `16aa9537`).
- `pipeline/run_scraper_historico.py` — `_load_mes_into_fact()`: última barreira antes do INSERT (idêntica à da ingestão CONAB).

### Bloqueio de Produtos Órfãos na Master List (FASE 1)

- `pipeline/load_master_list.py` — produto novo só entra em `staging.dim_produto` se JÁ existir preço real na `fact_precos_mensais` (check `SELECT EXISTS`). Sem preço → NÃO cadastra e registra em `ops.quarentena_coleta` com motivo `sem_preco_real` (nome do produto no motivo). Elimina os "produtos fantasmas" que poluíam sazonalidade e frontend.
  - **Fix (commit `16aa9537`)**: `raw_id` é `UUID NOT NULL` — a quarentena agora usa `uuid.uuid5(NAMESPACE_OID, "master_list:<nome>")` (UUID determinístico e idempotente) em vez da string `master_list:<nome>` (que quebraria com `invalid input syntax for type uuid`).
- Resumo final agora imprime `blocked (sem preço real)` além de inserted/updated.

### Suporte a Municípios no Scraper Histórico (FASE 1)

- `pipeline/run_scraper_historico.py`:
  - `_ensure_dimensions()` reescrita: `dim_localidade` usa índices ÚNICOS PARCIAIS (estado vs município) — cada nível declara seu próprio `index_predicate` no `ON CONFLICT` (`WHERE municipio_id IS NULL` / `WHERE municipio_id IS NOT NULL`); strings vazias viram `None/NULL` antes do `execute()`.
  - `_extrair_localidades()` — extrai `(uf, municipio_id, municipio_nome)`; sem código IBGE → nível Estado.
  - `_load_mes_into_fact()` resolve localidade no nível Município (código IBGE) com fallback para o nível Estado.
  - `_extrair_ufs()` removido (substituído por `_extrair_localidades`).

### Novo Script: `pipeline/load_parquet_to_db.py`

- Hotfix de carga rápida do parquet `database/processed_data/01_raw/scraper_hortifruti_historico.parquet` — **BYPASS de rede** (não refaz requisições web), replicando a lógica CORRIGIDA do `run_scraper_historico.py`: índices parciais com `index_predicate` por nível + malha fina de preço.
- Flags: `--parquet`, `--skip-medalhao`, `--skip-refresh-mv`, `--skip-notify`; executa `sp_executar_carga_completa()` + REFRESH MV + purge de cache ao final.

## Mudanças Recentes (2026-07-30)

### Ingestão CONAB Aprimorada (ingestao_conab.py)

- `pipeline/ingestao_conab.py` — Expansão de +351 linhas
- Melhorias no parsing dos dados CONAB (cotação semanais)
- Normalização de produtos e variedades para o schema staging
- Tratamento de dados duplicados e consistência temporal

## Mudanças Recentes (2026-08-02/03)

### Guard is_forecast — re-levanta GuardIsForecastError (run_bulk_historical_fill.py)

- `pipeline/run_bulk_historical_fill.py` — o guard que monitora `count(is_forecast=TRUE)` antes/depois do recálculo agora **aborta em vez de engolir** (R4-001 blocker / R-ADD-06):
  - Nova exceção `GuardIsForecastError(RuntimeError)` — falha do guard: `count(is_forecast=TRUE)` cresceu após o recálculo (indica que engines sintéticas V13/sanduíche foram (re)ativadas e o deploy está errado).
  - `except GuardIsForecastError: raise` — re-levantada ANTES do catch genérico (`except Exception`), que antes engolia o erro e continuava como "sucesso". Com o re-raise, o pipeline aborta com exit != 0 e CI/operador enxergam a falha.
- Commit `20970929` (slice 1d) já havia adicionado o guard (com `raise RuntimeError`) + desativado as engines sintéticas no pipeline; `245c9d1d` transformou o raise em exceção específica re-levantada.

### Ingestão CONAB — correções de parsing (ingestao_conab.py)

- `pipeline/ingestao_conab.py` (commit 39199a29) — correções funcionais sobre o parsing CONAB:
  - Filtro de preço: `preco_medio >= 0.01` (antes `> 0`) — valores residuais de divisão arredondam p/ 0 no CHECK numérico do banco (`fact_precos_mensais_preco_medio_check: preco > 0`).
  - Precedência corrigida: `& (pl.col("uf").str.len_chars() == 2)` — parênteses obrigatórios (bug histórico de regressão: Python dá precedência maior a `&` que a `==`).
  - Helper `_qtd_valor_to_float(col)` — converte qtd/valor via String + troca de vírgula só quando texto; cast direto quando numérico (bug histórico: `.str.replace` em coluna i64 → InvalidOperation).
  - Demais mudanças são formatação/refactor (dicts expansivos, loggers multi-linha).

## Pós-Coleta — Ciclo Medalhão (executar_ciclo_medalhao)

O ciclo completo em `persistence.py` executa **2 passos** (simplificado — forecast agora é 100% SQL):

1. **SortingEngine** — raw.coleta_bruta → staging.fact_precos_mensais
2. **sp_executar_carga_completa()** — pipeline completo em uma SP:
   - `sp_carregar_landing_para_staging()`
   - `sp_limpar_e_normalizar_staging()`
   - `sp_sincronizar_variedades_conab()`
   - `sp_calcular_sazonalidade_v11()` — baseline 25-26
   - `sp_calcular_forecast_2026()` — projeção via baseline 24-25 (Moda)
   - `REFRESH MATERIALIZED VIEW CONCURRENTLY`

A lógica de forecast foi migrada dos scripts Python (`calcular_baseline.py`, `projetar_2026.py`) para a SP `sp_calcular_forecast_2026()`. Os scripts Python permanecem disponíveis para uso standalone mas não são mais chamados pelo pipeline.

## Fluxo dos Dados — Volumes Reais

### 1. RAW — Landing Zone (bronze)

```
Scraper → raw.coleta_bruta
```

15 registros (payloads brutos JSONB, sem constraints). `raw.precos_uf` e `raw.precos_municipio` para carga CONAB 1:1.

### 2. STAGING — Dados Limpos (silver)

```
raw.coleta_bruta ──→ SortingEngine ──→ staging.fact_precos_mensais
```

- `staging.fact_precos_mensais`: **45.114** registros (dados tipados, UPSERT por `ON CONFLICT`)
- `staging.dim_produto`: **865** produtos únicos
- `staging.dim_localidade`: 850 localidades únicas
- Rejeitados vão para `ops.quarentena_coleta`

### 3. MART — Negócio + API (gold)

```
staging ──→ sp_executar_carga_completa() ──→ mart.sazonalidade_produto
```

- `mart.sazonalidade_produto`: **145.740** registros totais (pós LOCF + sintéticos + forecast)
  - **79.980** reais (`is_forecast=FALSE`)
  - **65.760** forecast (`is_forecast=TRUE`)
  - **0** INSUFICIENTE
- `mart.sazonalidade_baseline`: **23.449** (24_25) + **32.581** (25_26) combinações (moda do status_cor)

### 4. MV — View Materializada

```
mart ──→ REFRESH MV ──→ mart.vw_api_produtos_sazonalidade
```

- **139.255** linhas disponíveis para a API (filtro ALIMENTO_VAREJO + status_cor válido)
- JOIN entre `sazonalidade_produto`, `dim_produto`, `dim_localidade`, `dim_categoria`
- Filtra apenas `categoria_b2c = 'ALIMENTO_VAREJO'` e `status_cor IN ('VERDE','AMARELO','VERMELHO')`
- A API é **read-only** — consulta exclusivamente a MV, nunca `raw` ou `staging`

## Orquestrador Global

- `AutonomousOrchestrator.coletar_global(competencia)` — dispatch único por competência que executa micro-engines (ceagesp, conab) para TODAS as UFs sem filtrar por UF específica
- Usado pelo endpoint `POST /api/v1/admin/coletar-global` no backend
- Substitui múltiplas chamadas `_coletar_interno` por UF quando o objetivo é coletar dados nacionais

## Mapa Rápido

- `scraper/main_runner.py` — entry point Run and Die (pool asyncpg + timeout 1200s)
- `scraper/orchestrator.py` — `AutonomousOrchestrator` (cascata 3 passos + auditoria + coletar_global)
- `scraper/micro_engines/base_engine.py` — ABC + Semaphore(3) + CircuitBreaker
- `scraper/micro_engines/ConabApiEngine.py` — motor CONAB Pentaho/Portal (exemplo concreto)
- `scraper/discovery_engine.py` — `SimpleDorkGenerator` + `DiscoveryEngine` (anti-PDF)
- `scraper/circuit_breaker.py` — CircuitBreaker reutilizável (CLOSED/OPEN/HALF-OPEN)
- `processor/` — esteira de triagem (pós-coleta, NÃO faz parte da extração)
- `scraper/persistence.py` — `executar_ciclo_medalhao` (2 passos: SortingEngine + SP completa)
