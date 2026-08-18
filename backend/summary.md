# summary.md — /backend (API B2C)

> 📦 **Repositório (2026-08-07):** `PedroEvangelista063/Sazo_repo` — renomeado de `Quero_Comprar_ext` (a URL antiga redireciona).

## Propósito

API HTTP assíncrona (FastAPI) que serve o frontend B2C. Consulta apenas views materializadas (`mart.vw_*`). Sem ORM. Sem lógica de transformação pesada. Endpoints protegidos contra Event Loop Starvation.

## Stack

- Python 3.13+, FastAPI (via `fastapi[standard]`), Pydantic v2, asyncpg, httpx
- Uvicorn com `--limit-concurrency` e timeouts estritos

## Regras de Ouro

1. **Sem ORM**: queries raw com asyncpg. Nada de SQLAlchemy, Django ORM ou Tortoise.
2. **Read-Only para a API**: o backend só lê de `mart.vw_*` e funções `fn_*` no banco. Escrita é exclusividade do pipeline.
3. **Event Loop Starvation**: toda rota deve ter timeout (`asyncio.wait_for` ou middleware `TimeoutMiddleware`). Nenhuma rota pode travar o event loop.
4. **Cache**: usar cache interno (`core/cache.py`) para respostas lentas. TTL definido por endpoint.
5. **Rate Limit**: `core/ratelimit.py` — proteção contra abuso por IP.
6. **Pydantic v2**: schemas de resposta em `schemas/responses.py`. Validação na borda, não no banco.
7. **CORS e Segurança**: configurado no `main.py`. RLS ativado via migration `000015_rls_security_layer.sql` (tabelas: `mart.sazonalidade_produto`, `staging.dim_produto`, `staging.fact_precos_mensais`, `ops.audit_logs`). `role_etl_writer` tem bypass total (`USING(true)`), `role_api_reader` tem SELECT apenas, `service_role` e `postgres` bypass automático.
8. **Janela Temporal**: endpoints de série temporal sempre aceitam `?ano_inicio=2024`.

## Fluxo dos Dados — Raw → API

```
Scraper → raw.coleta_bruta (15)
→ SortingEngine → staging.fact_precos_mensais (42.358)
→ sp_executar_carga_completa + LOCF + sintéticos + forecast → mart.sazonalidade_produto (145.740)
→ REFRESH MV → mart.vw_api_produtos_sazonalidade (139.255) ← API lê daqui
```

A API consulta **exclusivamente** `mart.vw_api_produtos_sazonalidade` (Materialized View V14) e funções `fn_*`. Nunca acessa `raw.*` ou `staging.*`. O pipeline (pasta `/pipeline`) é o único que escreve nessas camadas.

**Migração de dados (2026-07-18)**: 14 tabelas migradas — 174.240 linhas, 100% idênticas local ↔ Supabase. Schema fix: `fact_precos_mensais` ganhou `preco_curado`, `is_interpolado`, `fonte`. Sequences corrigidas com `setval()`. Trigger `trg_valida_anomalia_preco` reativada após importação.

## Mudanças Recentes (2026-08-13)

### Nenhuma mudança neste lote

- Lote `2026-08-13` concentrado em `database/`/`pipeline/`/`docs/`/`utilities/` (migration 82 — Normalização de Grandezas + Semáforo Sensível por CV, **COMMITADA e PUSHADA** em `feature/migration-82-semaforo-sensivel` @ `f1692db5`, pending apply). /backend inalterado — API segue consultando as views/MV como documentado.

## Mudanças Recentes (2026-08-12)

### Dual-Environment (FASE 2) — APP_ENV, pool dinâmico e banner de startup

- `app/core/config.py` — `Settings` ganhou `app_env` (`staging` | `production`, lido do OS environment), resolução dinâmica do `.env` (`backend/.env.<app_env>` → `.env.staging` → `.env`), pool autotunado por ambiente (`effective_pool_min_size`/`effective_pool_max_size`; staging máx. 30, production máx. 8 com teto 10) e rótulos `environment_label`/`database_target_label` (FÍSICO/AIVEN derivado do hostname real da URL primária).
- `app/db/session.py` — `_pool_params` passou a usar `effective_pool_*` (mantém failover primary/fallback intacto).
- `app/main.py` — banner visível no startup: `[!] INICIANDO SISTEMA NO AMBIENTE DE: {STAGING|PRODUCTION} — CONECTADO AO BANCO: {FÍSICO|AIVEN} (MODO ATIVO: ...)`.
- **Dependência dos Git Hooks**: commits/pushes neste repositório rodam `scripts/guard_commit.sh`/`guard_push.sh` (tsc, smoke de homologação `scripts/smoke_staging.sh`, pytest) — qualquer falha de tipagem/banco BLOQUEIA o commit. Bypass documentado via `SKIP_*` (ver `docs/ARQUITETURA_AMBIENTES_CI_CD.md`).
- `tests/test_ambiente_config.py` (novo) — 8 testes de APP_ENV/pool/env file; `tests/test_transparencia_dado_historico.py` — fragmento da mensagem FALLBACK_DIMENSAO atualizado para "baseline de dimensao" (V22).

## Mudanças Recentes (2026-08-11)

### Memoização do X-Last-Refresh + Mensagens V22 (245c4155)

- `app/api/v1/endpoints/produtos.py` (FASE 79, P1-2) — `_ultimo_refresh_mv_iso()` **memoizado**: valor em cache com TTL 30s (`saz:ultimo_refresh_mv`) + double-checked `asyncio.Lock`. Causa raiz do `ERR_ABORTED` (axios 10s) na 1ª carga do BR: a função era chamada até 2x por request, e CADA chamada fazia 2 round-trips ao Aiven (`pg_stat_file` + `audit.mv_refresh_log`, ~2,5-4s cada). TTL 30s < TTL do cache de dados (3600s) — o header X-Last-Refresh nunca fica desatualizado por mais de ~30s.
- `_compor_mensagem_transparencia()` — novo branch para `tipo_dado = 'FALLBACK_DIMENSAO'` (Deep Fallback V22): prioridade 1) mensagem exata gravada no `metadado_transparencia` da MV; 2) derivação por `ano_referencia` ("Projecao sazonal baseada no historico de N"); 3) baseline de dimensão.
- `frontend/src/services/api.ts` — timeout do axios no frontend ajustado (o commit trata o `ERR_ABORTED` que ocorria na 1ª carga do BR por causa da latência do refresh).

## Mudanças Recentes (2026-08-07)

### MV V20 — Expurgo de Produtos Fantasmas (banco; sem mudança de código)

- Banco recriou a MV `mart.vw_api_produtos_sazonalidade` na **V20** (`database/71_expurgo_produtos_sem_preco.sql`): produtos sem NENHUMA âncora real (`REAL_ATUAL`/`HISTORICO_BASE`) foram expurgados da `dim_produto` e suprimidos da MV.
- **Impacto na API**: a MV é a única fonte de leitura da API — ela deixa de servir automaticamente grades 12 meses CINZA (produtos fantasmas). Nenhuma mudança de código/endpoint neste lote; contratos e campos (`ano_referencia`, `tipo_dado`, etc.) permanecem os mesmos.

## Mudanças Recentes (2026-07-30)

### Cache TTL Reduzido: 24h → 1h

- `app/core/config.py`: `cache_ttl_seconds` alterado de `86400` (24h) para `3600` (1h)
- Garante que dados obsoletos não fiquem servidos por mais de 1 hora após atualização do banco

### MV Refresh em Background (main.py)

- `app/main.py`: MV refresh movido de `await asyncio.wait_for` bloqueante para `asyncio.create_task` em background
- O servidor agora inicia INSTANTANEAMENTE, sem esperar 2 minutos pelo MV refresh
- Cache é limpo automaticamente após cada MV refresh bem-sucedido
- Duas tentativas com timeout de 120s cada; se ambas falharem, logs de erro sem travar o servidor

### Endpoint de Cache Limpo (`POST /admin/cache/clear`)

- `app/api/v1/endpoints/admin.py` — novo endpoint protegido por API key
- Chama `clear_cache()` do `core/cache.py` e retorna status
- Permite forçar limpeza de cache sem reiniciar o servidor

### Paginação Otimizada: COUNT + OFFSET (produtos.py)

- `app/api/v1/endpoints/produtos.py` — substituiu paginação em memória (fetch ALL + slice Python) por COUNT + LIMIT/OFFSET SQL
- Novas funções `_fetch_count_br_snapshot()`, `_fetch_count_br_por_mes()`, `_fetch_page_br_snapshot()`, `_fetch_page_br_por_mes()`
- As funções `fn_br_nacional_snapshot` e `fn_br_nacional_por_mes` agora aceitam parâmetros `limit` e `offset`
- Ganho de performance significativo para grades com 500+ produtos

### confianca_baseline Real (não mais hardcoded None)

- `_build_br_response()`, `_query_regional_snapshot()`, `_query_regional_por_mes()`:
  - Antes: `confianca_baseline=None` hardcoded
  - Agora: lê `r["confianca_baseline"]` do banco e converte para `float`
- A API agora retorna a confiança real do baseline em vez de None

## Mudanças Recentes (2026-08-03)

### Transparência de Dados Históricos na API (MV V17)

A API passou a expor o **ano âncora** do dado exibido (última cotação real), seguindo a refatoração do banco (database/63 + MV V17 — dado histórico real N → N-1 → N-2 em vez de projeções sintéticas):

- `schemas/responses.py` — `SazonalidadeResponse`, `SazonalidadeComPrecoResponse` e `MesSazonalidade` ganham 4 campos novos: `ano_referencia` (`int | None`, ano da última cotação real), `tipo_dado` (`REAL_ATUAL | HISTORICO_BASE | FALLBACK_DIMENSAO`), `mensagem_transparencia` (texto de proveniência, sem R$) e `is_dado_legado` (bool, `True` quando `ano_referencia` < ano corrente). `FlowItem.ano_referencia` deixou de ser `int = 2024` fixo e virou `int | None`.
- `endpoints/produtos.py` — todas as funções de montagem de resposta (`_build_br_response`, `_query_regional_snapshot`, `_query_regional_por_mes`, grade BR, por-mês, etc.) agora leem `v.ano_referencia`, `v.tipo_dado` e `v.idade_dado_anos` da MV e preenchem os novos campos.
- Helper `_compor_mensagem_transparencia(tipo_dado, ano_referencia, idade)` gera o texto: `REAL_ATUAL` → "Coleta efetiva — cotação real da CONAB no ano de referência N"; `HISTORICO_BASE` → "Dado histórico real — última cotação real da CONAB em N (defasagem)"; fallback → "Sem histórico real para este período — valor de referência da dimensão (fallback)".
- Helper `_is_dado_legado(ano_referencia)` — `True` quando `ano_referencia < ano corrente`.

### Fix Pool / Failover Primário → Fallback (session.py)

- `app/db/session.py` reescrito com **modo ativo** (`_active_mode`: `"primary"` | `"fallback"`) e failover automático:
  - `_primary_url()` (env `DATABASE_URL_PRIMARY` ou `database_url` legado) e `_fallback_url()` (env `DATABASE_URL_FALLBACK` ou `DATABASE_URL_LOCAL_BACKUP`).
  - `_create_verified_pool()` — cria pool e força `SELECT 1` (vence o `create_pool` lazy).
  - `_build_current_pool()` — se o primary está inacessível (erro de conexão: `asyncpg.PostgresError`/`TimeoutError`/`OSError`, ex. Supabase pausado 57P03), redireciona o tráfego para o banco local.
  - `_try_recover_primary()` — probe **half-open** após cooldown de 60s para revalidar o banco remoto e voltar ao modo primary automaticamente.
  - `_acquire(kind)` — adquire conexão do modo atual; em erro de conexão no modo primary, faz failover e tenta de novo. `fetch`/`fetchrow`/`fetch_etl`/`fetchrow_etl` passam a usar `_acquire`.
  - `get_active_mode()` — expõe o modo atual; `config.py` ganhou `database_url_primary`, `database_url_fallback`, `database_url_local_backup` e `bootstrap_schema_path`.
  - Dica de recuperação em log: restaurar instância Supabase pausada no dashboard e aguardar o half-open (~60s) reconectar.

### Bootstrap do Banco Local de Standby (bootstrap.py — novo)

- `app/db/bootstrap.py` (novo) — quando o failover ativa o modo `fallback`, garante schema mínimo no banco local:
  - `run_bootstrap_once()` — inspeciona o banco local (`to_regclass` na MV `mart.vw_api_produtos_sazonalidade` ou contagem de tabelas); se vazio, aplica `database/backups/backup_schema_latest.sql` via binário `psql` com `-v ON_ERROR_STOP=1` (timeout 120s).
  - Nunca derruba o startup: falhas apenas logam; máximo 1x por processo.

### Fix MV Refresh — Conexão Dedicada + Startup Resiliente (main.py)

- `main.py`:
  - MV refresh movido para **conexão dedicada** (`asyncpg.connect` fora do pool) em `_refresh_mv_once()` — antes rodava via `fetch_etl` + `asyncio.wait_for`, causando corrida de dupla liberação (`InterfaceError: connection has been released back to the pool`) que corrompia o pool e gerava 500 transitórios.
  - `_connect_pool_with_retry()` — startup aguarda os pools com backoff (máx. 120s) em vez de derrubar o processo; se o modo ativo virar `fallback`, chama `run_bootstrap_once()`.
  - Timeout do refresh aumentado para 300s; log avisa que no Aiven free o `REFRESH MV CONCURRENTLY` da MV grande (~280k linhas) pode ser encerrado pelo servidor — a MV segue servida do último refresh/restore.
  - `/health` agora retorna `{"status": "ok", "db_mode": mode}`.
- `tests/test_resilience.py` — `test_db_timeout_isolation` passa a patch `session._acquire` (não mais `get_api_pool`), eliminando dependência da latência do banco real.

### Outras alterações de backend desde 2026-07-30

- `883981c8` — `GET /sazonalidade/br` aceita `?min_ufs` (1-27), com cache key incluindo `min_ufs`.
- `d448e4f5` — grade sazonal BR expõe `forecast_method` e `calculado_em`.
- `20fc66c5` — correção "full amarelo": `FlowItem` com schema descritivo completo (id, item, origem/destino, meses, tipo, cor_indicadora) e `ORDER BY` no endpoint de fluxos.
- `1da773b7` — hotfix pipeline/auditoria; `requirements.txt` ganhou `supabase==2.31.0`.
- `ea4224d2` — `backend/.env.example` atualizado com as novas URLs primary/fallback/local.

## Forecast — Transparência

- `SazonalidadeResponse` inclui `is_forecast: bool` (false = dado real coletado), `confianca_baseline: float | None` (% de confiança), `tendencia_futura: str | None` (QUEDA/ALTA/ESTAVEL)
- A query SQL em `produtos.py` seleciona diretamente da MV V14 (`is_forecast`, `baseline_confianca`, `forecast_method`, `tendencia_futura`)
- Dados de forecast NUNCA substituem dados reais na resposta — a MV expõe ambos com `is_forecast` distinguindo a origem
- MV V14 inclui colunas novas: `baseline_confianca`, `forecast_method` para rastreabilidade

## Rotas que expõem is_forecast

- `GET /api/v1/sazonalidade` — snapshot (último mês de cada produto) + filtro regional `?regiao=`
- `GET /api/v1/sazonalidade/{uf}/{municipio}` — por localidade
- `GET /api/v1/sazonalidade/historico/{ano}/{mes}` — série temporal

## Filtro Regional

- `GET /api/v1/regioes` — lista as 5 regiões com UFs e polos CEASA (lê de `config/regions.json`, não do banco)
- `GET /api/v1/sazonalidade?regiao={id}&ano={ano}` — snapshot agregado por região, chamando `fn_resumo_regiao()` no banco
- `RegiaoInfo`, `PoloInfo`, `RegioesResponse` em `schemas/responses.py`
- O admin panel (`admin.py`) orquestra `coletar_global()` que invoca o pipeline para todas as UFs em background

## Mapa Rápido

- `app/main.py` — app FastAPI, middlewares, lifespan
- `app/api/v1/endpoints/` — rotas: produtos, categorias, ufs, municipios, regioes, stream, admin, internal
- `app/api/v1/endpoints/regioes.py` — endpoint `GET /api/v1/regioes` (lê `config/regions.json`)
- `app/api/v1/endpoints/produtos.py` — `GET /api/v1/sazonalidade` com suporte a `?regiao=` e `fn_resumo_regiao()`
- `app/api/v1/endpoints/admin.py` — `coletar_global()` → pipeline para todas as UFs
- `app/core/config.py` — settings via Pydantic (DATABASE_URL, cache TTL, etc)
- `app/core/cache.py` — cache interno LRU/TTL (com `clear_cache()`)
- `app/core/ratelimit.py` — rate limiter por IP
- `app/core/timeout.py` — middleware Starlette (TimeoutMiddleware, retorna 504)
- `app/core/events.py` — EventBroadcaster (filas SSE para publish/subscribe)
- `app/db/session.py` — pools asyncpg (api + etl)
- `app/schemas/responses.py` — Pydantic response models (inclui `is_forecast`, `confianca_baseline`, `RegiaoInfo`, `PoloInfo`)
- `migrations/` — scripts SQL incrementais (RLS, limpeza diária)
- `tests/` — testes de resiliência e concorrência

## Conexão Supabase (2026-07-25) — Arquitetura Híbrida

### Filosofia: Remoto é o Primário, Local é o Backup

```
REMOTO (PRIMARY — Active)           LOCAL (STANDBY — Backup/Sandbox)
─────────────────────────────       ─────────────────────────────────
Supabase remoto                     PostgreSQL 18 nativo Linux Mint
(kxsqrcccaaxplpktmutl)              localhost:5432/quero_comprar
                                    postgres / postgres_dev_local

npm run dev → REMOTO (padrão)       npm run db:backup → Remote ➔ Local
                                    NUNCA Local ➔ Remote automático
```

### Configuração no `backend/.env` (centralizado)

```env
# ── REMOTO (PRIMARY) ──────────────────────────────────
DATABASE_URL          → Session Pooler :5432   (DDL, ETL)
DATABASE_URL_API      → Transaction Pooler :6543 (API reads)
DATABASE_URL_ETL      → Session Pooler :5432   (cargas)

# ── LOCAL (STANDBY) ────────────────────────────────────
DATABASE_URL_LOCAL_BACKUP → localhost:5432/quero_comprar
```

### asyncpg Pool (session.py)

```python
pool = await asyncpg.create_pool(
    dsn=settings.DATABASE_URL_API,  # sempre aponta para Supabase remoto
    statement_cache_size=0,          # OBRIGATÓRIO para pooler
    min_size=2,
    max_size=10,
)
```

### RLS — Tabelas com Row Level Security

| Tabela                        | role_etl_writer | role_api_reader | postgres/service_role |
| ----------------------------- | --------------- | --------------- | --------------------- |
| `mart.sazonalidade_produto`   | ALL (bypass)    | SELECT          | bypass automático     |
| `staging.dim_produto`         | ALL (bypass)    | ❌ sem acesso   | bypass automático     |
| `staging.fact_precos_mensais` | ALL (bypass)    | ❌ sem acesso   | bypass automático     |
| `ops.audit_logs`              | INSERT+SELECT   | ❌ sem acesso   | bypass automático     |

### Workflow Seguro

```bash
# Desenvolvimento diário → REMOTO (padrão)
npm run dev

# Antes de migration arriscada → snapshot local
npm run db:backup:restore

# Testar query pesada → LOCAL
DB_ENV=local psql $DATABASE_URL_LOCAL_BACKUP -f minha_query.sql
```

### Notas

- `statement_cache_size=0` é obrigatório quando usando pooler
- `.env` (raiz) NÃO contém URLs de banco — só configs globais (CORS, cache, LLM)
- `DATABASE_URL_API` usa Transaction Pooler (6543) para queries simples do FastAPI
- `DATABASE_URL_ETL` usa Session Pooler (5432) para COPY, VACUUM, REFRESH MV, DDL
- O script `scripts/sync_db_remote_to_local.sh` gera backups em `database/backups/` (gitignored)
- Migrations formais em `supabase/migrations/` são o ÚNICO caminho Local ➔ Remote
