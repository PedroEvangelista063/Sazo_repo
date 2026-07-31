# Proposal: contingencia-gaps-conab

## Problem

O pipeline CONAB tem lacunas críticas de cobertura identificadas na auditoria 2024-2026:

- **R2 (Prioridade Máxima):** `staging.fato_cotacao_regional` tem 0 registros. O arquivo `ProhortMensal.txt` nunca é baixado pelo scraper atual — só existe a engine `ConabApiEngine` (ProhortDiario). A função `transform_prohort()` existe em `ingestao_conab.py` mas não é invocada pelo ecossistema de micro-engines.

- **R1 (Alta):** 8 UFs (AC, AM, AP, MS, PI, RO, RR, SE) sem nenhum dado de 2024. Sem baseline histórico, o modelo de sazonalidade não pode gerar semáforo para esses estados.

- **R3 (Média):** A CONAB substitui `PrecosMensalUF.txt` periodicamente (~12 meses). Sem snapshot automático, perde-se o mês anterior se o scraper não rodar antes da substituição.

- **R4 (Média):** SP tem 1.245 gaps em 2026. Destes, apenas jan-jun são reais (jul-dez são meses futuros, preenchidos pelo scraper mensal). É necessário investigar a causa real.

## Scope

**Dentro do escopo:**

1. **R2 — ProhortMensalEngine**: Nova micro-engine em `pipeline/scraper/micro_engines/` que baixa `ProhortMensal.txt` da CONAB, faz parse CSV e calcula `preco_medio = valor_comercializado / qtd_comercializada_kg`. Registro no `orchestrator.py` como `"conab-prohort-mensal"`. Carga inicial backfill para popular `staging.fato_cotacao_regional`.

2. **R1 — PrecosiagrowebEngine**: Nova micro-engine para CONAB Precosiagroweb (HTML table via POST). ~96 requisições (8 UFs × 12 meses), `asyncio.Semaphore(3)`. Fallback para CONAB Série Histórica ou CEPEA/ESALQ.

3. **R3 — Snapshot pós-carga**: `COPY TO parquet` automático após cada execução do scraper. Checkpoint JSON expandido para registrar mês vigente de cada fonte. Alerta no Ghost DBA Agent se `_ultima_carga > 45 dias`.

4. **R4 — Investigação SP**: Queries SQL de diagnóstico para entender por que SP tem 1.245 gaps jan-jun/2026. Comparação de produtos cobertos em 2025 vs 2026.

**Fora do escopo:**
- R5 (Ghost DBA Agent) — já implementado e funcional
- Meses futuros jul-dez/2026 — preenchidos pelo scraper mensal normal, não por contingência
- Implementação de CEPEA/ESALQ como fonte primária — apenas fallback documentado

## Approach

### R2 — ProhortMensalEngine

1. Criar `pipeline/scraper/micro_engines/prohort_mensal_engine.py`:
   - Herdar de `BaseMicroEngine`
   - `extract()` → GET com httpx, timeout 180s, semáforo herdado
   - Parsear CSV com `csv.DictReader` (delimitador `;`)
   - Calcular `preco_medio = valor_comercializado / qtd_comercializada_kg`
   - Payload no formato esperado por `SortingEngine._extrair_de_dict()`

2. Registrar em `orchestrator.py`:
   - Em `_resolver_motor()`: retornar `ProhortMensalEngine()` para `"conab-prohort-mensal"`
   - Adicionar no `_FONTE_ID_PARA_ALVO` e `sources_matrix.json`

3. Carga inicial: executar backfill para jan-jun/2026 e todo 2025

### R1 — PrecosiagrowebEngine

1. Criar `pipeline/scraper/micro_engines/precosiagroweb_engine.py`:
   - POST com parâmetros: periodo_inicial, periodo_final, produto, uf, nivel_comercializacao
   - Parsear HTML table retornada via BeautifulSoup/lxml
   - `asyncio.Semaphore(3)` + CircuitBreaker
   - ~96 requisições: 8 UFs × 12 meses (2024)

2. **Fallback A — CONAB Série Histórica**: tentar download CSV único via `ingestao_conab.py`

3. **Fallback B — CEPEA/ESALQ**: hook no SmartRouter (já mapeado em `sources_matrix.json`)

### R3 — Snapshot pós-carga

1. No `main_runner.py`, após `executar_ciclo_medalhao()`:
   - `COPY staging.fact_precos_mensais TO '.../01_raw/snapshot_YYYY_MM.parquet'`
2. Expandir `database/processed_data/01_raw/ultimate_backfill_checkpoint.json` com mês vigente por fonte
3. Ghost DBA Agent: verificar `_ultima_carga` e alertar se > 45 dias

### R4 — Investigação SP

1. SQL: comparar produtos ativos em 2025 vs 2026 para SP
2. Verificar se `categoria_b2c` no `SortingEngine` está dropando produtos SP válidos
3. Verificar se `dim_localidade` mapeia corretamente municípios SP

## Deliverables

| # | Artefato | Tipo |
|---|----------|------|
| 1 | `pipeline/scraper/micro_engines/prohort_mensal_engine.py` | Engine |
| 2 | `pipeline/scraper/micro_engines/precosiagroweb_engine.py` | Engine |
| 3 | Modificação em `pipeline/scraper/orchestrator.py` | Registro de engines |
| 4 | Modificação em `pipeline/scraper/main_runner.py` | Snapshot + checkpoint |
| 5 | Checkpoint expandido | Config |
| 6 | SQL queries diagnóstico SP | Documentação |
| 7 | Testes R2 + R1 | `pipeline/tests/` |

## Risks

| Risco | Severidade | Mitigação |
|-------|-----------|-----------|
| CONAB Precosiagroweb muda HTML table | Alta | Strategies B/C (Série Histórica, CEPEA) |
| ProhortMensal.txt >10MB, timeout | Média | httpx timeout 180s, CircuitBreaker |
| Rate limit CONAB no POST | Média | `asyncio.Semaphore(3)`, backoff exponencial |
| SP gaps serem CONAB, não bug | Baixa | Investigação R4 define causa |
| Snapshot parquet ocupa disco | Baixa | Reter últimos 13 meses, rotacionar |

## Non-Goals

- R5 Ghost DBA Agent — já coberto, nenhuma ação
- Meses futuros jul-dez/2026 — não são gaps reais
- CEPEA/ESALQ como fonte primária — apenas fallback R1
- Refatoração do `ingestao_conab.py` — apenas reuso de `transform_prohort()`
- Migração de schema no banco — schemas já existem
