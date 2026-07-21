# Sync Local → Supabase — Fase 4 Concluída

**Projeto:** Quero Comprar
**Data:** 2026-07-20
**Status:** ✅ Fase 1–4 executadas — API conectada ao Supabase Pooler

---

## Resumo do que foi feito

### Fase 1 — Schema (migrations)

Aplicadas via `npx supabase db query --linked`:

| Migration | Objetivo | Status |
|-----------|----------|--------|
| `31_remove_year_filter_mv.sql` | Recria MV `vw_api_produtos_sazonalidade` sem filtro de ano | ✅ |
| `33_paginacao_br_regional.sql` | 4 funções paginadas (`fn_br_nacional_snapshot`, `fn_br_nacional_por_mes`, `fn_regional_snapshot`, `fn_regional_por_mes`) | ✅ |
| `34_mart_vw_categorias_municipios.sql` | Views `mart.vw_categorias` e `mart.vw_municipios` | ✅ |

Também foram adicionadas colunas `descricao` e `icone_url` em `staging.dim_categoria`.

### Fase 2 — Dados sincronizados

| Tabela | Registros | Chunks | Método |
|--------|-----------|--------|--------|
| `mart.sazonalidade_produto` | 62.291 | 13 | `pg_dump --column-inserts` + `ON CONFLICT DO NOTHING` |
| `staging.fact_precos_mensais` | 42.358 | 9 | `pg_dump --column-inserts` + `ON CONFLICT DO NOTHING` |
| `staging.dim_produto` | 857 | 1 | `pg_dump --column-inserts` + `ON CONFLICT DO NOTHING` |

### Fase 3 — Auditoria

- REFRESH MATERIALIZED VIEW CONCURRENTLY executado
- Contagens 13/14 OK. Único diff: `precos_rejeitados` (local=87, Supabase=92 — 5 extras do pipeline rodando contra Supabase)

### Fase 4 — Conexão FastAPI ao Supabase

**Problemas enfrentados e soluções:**

| Problema | Causa | Solução |
|----------|-------|---------|
| Senha não funcionava | Senha `Marfia8976*` com `*` não é URL-safe | Usar `Marfia8976%2A` (URL-encoded) na connection string |
| Pooler rejeitava conexão | Usuário `cli_login_postgres.{ref}` não tem permissão no pooler | Usar `postgres.{ref}` com a senha do usuário `postgres` |
| `asyncpg` hanging/queries timeout | Prepared statements incompatíveis com PgBouncer (transaction mode) | `statement_cache_size=0` em `_init_pool()` no `session.py` |
| `Start-Process` + uvicorn trava | Processo detached sem timeout → bash tool trava | Usar `subprocess.Popen` com `proc.kill()` no finally |

**Connection strings finais no `.env`:**

```env
DATABASE_URL=postgresql://postgres.kxsqrcccaaxplpktmutl:Marfia8976%2A@aws-1-us-east-1.pooler.supabase.com:5432/postgres
DATABASE_URL_API=postgresql://postgres.kxsqrcccaaxplpktmutl:Marfia8976%2A@aws-1-us-east-1.pooler.supabase.com:6543/postgres
DATABASE_URL_ETL=postgresql://postgres.kxsqrcccaaxplpktmutl:Marfia8976%2A@aws-1-us-east-1.pooler.supabase.com:5432/postgres
```

- **5432** = Session Pooler (ETL, queries longas)
- **6543** = Transaction Pooler (API, FastAPI/asyncpg)

### Arquivos alterados

| Arquivo | O que mudou |
|---------|-------------|
| `.env` (raiz) | Connection strings trocadas de localhost para Supabase Pooler |
| `backend/.env` | Idem |
| `backend/app/db/session.py` | `statement_cache_size=0` no `_init_pool()` |

---

## Problemas conhecidos (pós-Fase 4)

### Endpoints da API retornando vazios ou erros

| Endpoint | Status | Causa Raiz |
|----------|--------|------------|
| `GET /api/v1/sazonalidade` | 200 (0 items) | MV `vw_api_produtos_sazonalidade` filtra `status_cor IS NOT NULL` — todos os registros têm dados V15 com colunas `ano`, `mes`, `preco_medio` NULL. Verificar se a view está capturando dados corretamente. |
| `GET /api/v1/categorias` | 200 (0 items) | A view `mart.vw_categorias` tem `JOIN ... AND p.categoria_b2c = 'ALIMENTO_VAREJO'` hardcoded → só casa uma categoria. E todos os 857 produtos em `dim_produto` têm `categoria_b2c IS NULL`. |
| `GET /api/v1/municipios?uf=PR` | 422 sem `uf` | Funciona com UF. Mas a view `mart.vw_municipios` reference `staging.dim_localidade` que NÃO EXISTE no Supabase. A view foi criada mas está quebrada. |
| `GET /api/v1/regioes` | 200 (0 items) | `staging.dim_regiao` não existe no Supabase. |
| `GET /api/v1/ufs` | 200 (1 item) | `staging.dim_uf` não existe no Supabase. |
| `GET /api/v1/produtos/com-preco` | ? | Não testado — depende de `vw_categorias` |
| `GET /api/v1/sazonalidade/{uf}/{municipio}` | ? | Não testado — depende de dados de `sazonalidade_produto` filtrados por localidade |

### Tabelas ausentes no Supabase (vs local)

| Schema | Tabela | Onde é usada |
|--------|--------|-------------|
| `staging` | `dim_localidade` | `mart.vw_municipios` (quebrada) |
| `staging` | `dim_municipio` | Potencialmente usada por outras queries |
| `staging` | `dim_regiao` | `GET /regioes` |
| `staging` | `dim_uf` | `GET /ufs` |
| `mart` | `sazonalidade_baseline_24_25` | Sazonalidade |
| `mart` | `sazonalidade_baseline_25_26` | Sazonalidade |

### Bug na migration 34

A view `mart.vw_categorias` foi criada com:

```sql
LEFT JOIN staging.dim_produto p
    ON p.id_categoria = c.id_categoria
   AND p.categoria_b2c = 'ALIMENTO_VAREJO'
```

Isso é um bug — o filtro `categoria_b2c = 'ALIMENTO_VAREJO'` deveria ser dinâmico ou removido. Além disso, `dim_produto.categoria_b2c` está NULL para todos os 857 registros (a classificação B2C nunca foi populada no Supabase).

---

## Histórico de comandos úteis

```bash
# Conectar via CLI (funciona sempre — usa tunnel interno)
npx supabase db query --linked "SELECT 1"

# Testar pooler direto com Python
python -c "import asyncpg, asyncio; ...
  asyncpg.connect('postgresql://postgres.{ref}:{pw}@aws-1-us-east-1.pooler.supabase.com:6543/postgres')"

# Refresh MV
npx supabase db query --linked "REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade"
```
