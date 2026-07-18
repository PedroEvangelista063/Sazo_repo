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
7. **CORS e Segurança**: configurado no `main.py`. RLS ativado via migration `012_security_rls_readonly.sql`.
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

## Conexão Supabase (2026-07-17)

### Configuração no .env
```env
# Direct Connection (5432) — para ETL e migrações
DATABASE_URL=postgresql://postgres:SENHA@db.kxsqrcccaaxplpktmutl.supabase.co:5432/postgres

# Transaction Pooler (6543) — para FastAPI
DATABASE_URL_API=postgresql://postgres.kxsqrcccaaxplpktmutl:SENHA@aws-0-us-east-1.pooler.supabase.com:6543/postgres
```

### asyncpg Pool (session.py)
```python
pool = await asyncpg.create_pool(
    dsn=settings.DATABASE_URL_API,
    statement_cache_size=0,  # OBRIGATÓRIO para pooler
    min_size=2,
    max_size=10,
)
```

### Notas
- Usar Direct (5432) para operações que precisam de acesso completo (COPY, VACUUM, REFRESH MV)
- Usar Transaction Pooler (6543) apenas para queries simples do FastAPI
- `statement_cache_size=0` é obrigatório quando usando pooler
