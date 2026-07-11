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

## Mapa Rápido
- `main_runner.py` — entry point Run and Die (pool asyncpg + timeout 1200s)
- `orchestrator.py` — `AutonomousOrchestrator` (cascata 3 passos + auditoria)
- `micro_engines/base_engine.py` — ABC + Semaphore(3) + CircuitBreaker
- `micro_engines/ConabApiEngine.py` — motor CONAB Pentaho/Portal (exemplo concreto)
- `discovery_engine.py` — `SimpleDorkGenerator` + `DiscoveryEngine` (anti-PDF)
- `circuit_breaker.py` — CircuitBreaker reutilizável (CLOSED/OPEN/HALF-OPEN)
- `processor/` — esteira de triagem (pós-coleta, NÃO faz parte da extração)
- `scraper/persistence.py` — `executar_ciclo_medalhao` (5 passos, inclui baseline + forecast)
