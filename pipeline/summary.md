# summary.md — /pipeline (Motor de Extração)

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

## Pós-Coleta — Ciclo Medalhão (executar_ciclo_medalhao)
O ciclo completo em `persistence.py` executa 5 passos:
1. **SortingEngine** — raw.coleta_bruta → staging.fact_precos_mensais
2. **sp_executar_carga_completa()** — staging → mart.sazonalidade_produto
3. **REFRESH MV** — atualiza `vw_api_produtos_sazonalidade` com dados reais
4. **Recálculo do baseline + forecast** — `calcular_baseline()` + `projetar_2026()` em Python
5. **REFRESH MV final** — atualiza MV com os dados de forecast recém-inseridos

Passos 4-5 garantem que após toda carga de dados reais, o baseline fica mais preciso e os gaps de 2026 são preenchidos automaticamente.

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
- `staging.fact_precos_mensais`: 27.545 registros (dados tipados, UPSERT por `ON CONFLICT`)
- `staging.dim_produto`: 831 produtos únicos
- `staging.dim_localidade`: 850 localidades únicas
- Rejeitados vão para `ops.quarentena_coleta`

### 3. MART — Negócio + API (gold)
```
staging ──→ sp_executar_carga_completa() ──→ mart.sazonalidade_produto
```
- `mart.sazonalidade_produto`: 37.013 registros totais
  - 25.403 reais (`is_forecast=FALSE`)
  - 11.610 forecast (`is_forecast=TRUE`)
- `mart.sazonalidade_baseline`: 17.300 combinações (moda do status_cor)

### 4. MV — View Materializada
```
mart ──→ REFRESH MV ──→ mart.vw_api_produtos_sazonalidade
```
- 36.684 linhas disponíveis para a API
- JOIN entre `sazonalidade_produto`, `dim_produto`, `dim_localidade`, `dim_categoria`
- Filtra apenas `categoria_b2c = 'ALIMENTO_VAREJO'` e `status_cor IN ('VERDE','AMARELO','VERMELHO')`
- A API é **read-only** — consulta exclusivamente a MV, nunca `raw` ou `staging`

## Mapa Rápido
- `scraper/main_runner.py` — entry point Run and Die (pool asyncpg + timeout 1200s)
- `scraper/orchestrator.py` — `AutonomousOrchestrator` (cascata 3 passos + auditoria)
- `scraper/micro_engines/base_engine.py` — ABC + Semaphore(3) + CircuitBreaker
- `scraper/micro_engines/ConabApiEngine.py` — motor CONAB Pentaho/Portal (exemplo concreto)
- `scraper/discovery_engine.py` — `SimpleDorkGenerator` + `DiscoveryEngine` (anti-PDF)
- `scraper/circuit_breaker.py` — CircuitBreaker reutilizável (CLOSED/OPEN/HALF-OPEN)
- `processor/` — esteira de triagem (pós-coleta, NÃO faz parte da extração)
- `scraper/persistence.py` — `executar_ciclo_medalhao` (5 passos, inclui baseline + forecast)
