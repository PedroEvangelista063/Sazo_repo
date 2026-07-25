# summary.md — /backend (API B2C)

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
→ sp_executar_carga_completa → mart.sazonalidade_produto (62.291)
→ REFRESH MV → mart.vw_api_produtos_sazonalidade (62.291) ← API lê daqui (local: 54.715 — aguardando refresh)
```

A API consulta **exclusivamente** `mart.vw_api_produtos_sazonalidade` (Materialized View V14) e funções `fn_*`. Nunca acessa `raw.*` ou `staging.*`. O pipeline (pasta `/pipeline`) é o único que escreve nessas camadas.

**Migração de dados (2026-07-18)**: 14 tabelas migradas — 174.240 linhas, 100% idênticas local ↔ Supabase. Schema fix: `fact_precos_mensais` ganhou `preco_curado`, `is_interpolado`, `fonte`. Sequences corrigidas com `setval()`. Trigger `trg_valida_anomalia_preco` reativada após importação.

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
- `app/core/config.py` — settings via Pydantic (DATABASE_URL, etc)
- `app/core/cache.py` — cache interno LRU/TTL
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

| Tabela | role_etl_writer | role_api_reader | postgres/service_role |
|--------|----------------|-----------------|----------------------|
| `mart.sazonalidade_produto` | ALL (bypass) | SELECT | bypass automático |
| `staging.dim_produto` | ALL (bypass) | ❌ sem acesso | bypass automático |
| `staging.fact_precos_mensais` | ALL (bypass) | ❌ sem acesso | bypass automático |
| `ops.audit_logs` | INSERT+SELECT | ❌ sem acesso | bypass automático |

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
