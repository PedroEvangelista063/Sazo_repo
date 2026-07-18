# Plano de Migração: PostgreSQL Local → Supabase

**Projeto:** Quero Comprar  
**Data:** 2026-07-17  
**Status:** Fase 0-2 Concluídas ✅

---

## Arquitetura Atual

```
FastAPI (asyncpg) ──→ DATABASE_URL_API ──┐
                                          ├──→ PostgreSQL Local
Pipeline ETL (psycopg2) ──→ DATABASE_URL ─┘    (localhost:5432)
```

- **ORM:** Nenhum — asyncpg + psycopg2 com SQL puro
- **Schemas:** raw, staging, mart, ops (Arquitetura Medalhão)
- **Roles:** `role_etl_writer` (escrita), `role_api_reader` (SELECT), `api_readonly` (RLS helper)
- **Migrations:** 34 scripts SQL em `database/`, 2 em `backend/migrations/`
- **Deploy:** Render + GitHub Actions

---

## Fase 0 — Backup Local (irreversível: preservar permanentemente)

**Objetivo:** Backup completo do banco local antes de qualquer alteração.

```bash
# Backup full (custom format, comprimido, paralelo)
pg_dump -U postgres -h localhost -d quero_comprar \
  -Fc -j 4 -f backup_quero_comprar_pre_migracao.dump

# Backup SQL puro (para diff entre local e Supabase)
pg_dump -U postgres -h localhost -d quero_comprar \
  --no-owner --no-acl -Fp > backup_quero_comprar_ddl.sql
```

**Riscos:** Nenhum — banco local não é modificado, só lido.

**Status:** ✅ Concluído em 2026-07-17 13:50
- `backup_quero_comprar_pre_migracao.dump` — 2.48 MB (custom format, pg_restore)
- `backup_quero_comprar_ddl.sql` — 23.69 MB (SQL puro, diff)
- PostgreSQL 17, 21 tabelas, ~46 MB total

---

## Fase 1 — Criar Projeto Supabase

**Opção A — Dashboard** (recomendado): `supabase.com/dashboard`
**Opção B — CLI:** `supabase projects create`

- Região: `sa-southeast-1` (São Paulo) se disponível
- Anotar: `Project Ref`, `DB Password`, `Connection String (pooler + direta)`

---

## Fase 2 — Schema Migration (alto risco)

**Problema:** Scripts SQL foram escritos para PostgreSQL standalone. Supabase gerencia o `postgres` e tem diferenças:

| Componente | Ação |
|---|---|
| `CREATE EXTENSION pgcrypto` | Já incluso — usar `IF NOT EXISTS` |
| `CREATE EXTENSION pg_stat_statements` | Pode exigir superadmin — tratar com `DO $$ EXCEPTION` |
| `CREATE ROLE role_etl_writer` | Criar via SQL no Supabase (funciona) |
| `CREATE ROLE role_api_reader` | Idem |
| Grants em schemas custom | Adaptar — Supabase gerencia `public` mas schemas `raw/staging/mart` são nossos |
| RLS policies | Adaptar — modelo de grants tradicional é mais simples que RLS pra esse caso |
| Materialized Views | `REFRESH MATERIALIZED VIEW CONCURRENTLY` funciona |

**Estrutura alvo:**

```
supabase/migrations/
├── 000001_create_schemas.sql
├── 000002_create_extensions.sql
├── 000003_raw_tables.sql
├── 000004_staging_tables.sql
├── 000005_mart_tables.sql
├── 000006_functions.sql
├── 000007_materialized_views.sql
├── 000008_roles_permissions.sql
├── 000009_forecast_v2.sql
├── 000010_staging_tables_v2.sql
├── 000011_ops_tables.sql
├── 000012_functions_v2.sql
```

**Status:** ✅ Concluído em 2026-07-17 14:40
- 12 migrações aplicadas com sucesso
- 21 tabelas criadas (raw: 4, staging: 9, mart: 3, ops: 4)
- 3 functions, 2 procedures, 1 MV
- Roles: role_etl_writer, role_api_reader
- Forecast v2: baselines 24-25 e 25-26

---

## Fase 3 — Data Migration

**Pipeline:**

```
pg_dump --data-only (local) → psql/pg_restore (Supabase)
```

**Ordem de restore (respeitar FK):**
1. `staging.dim_produto`, `staging.dim_localidade`
2. `staging.fact_precos_mensais`, `staging.precos_rejeitados`
3. `mart.sazonalidade_produto`, `mart.sazonalidade_baseline`
4. `raw.precos_uf`, `raw.precos_municipio`, `raw.controle_carga`
5. `REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade`

---

## Fase 4 — Roles e Permissões

Criar roles no SQL Editor do Supabase:

```sql
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_etl_writer') THEN
    CREATE ROLE role_etl_writer WITH LOGIN PASSWORD '...';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_api_reader') THEN
    CREATE ROLE role_api_reader WITH LOGIN PASSWORD '...';
  END IF;
END $$;
```

Aplicar grants idênticos ao `01_ddl_medalhao.sql` Seção 10.

---

## Fase 5 — Atualizar Conexões

| Arquivo | Chave | Ação |
|---|---|---|
| `.env` | `DATABASE_URL` | Supabase direta (:5432) |
| `.env` | `DATABASE_URL_API` | Supabase pooler (:6543) |
| `.env` | `DATABASE_URL_ETL` | Supabase direta (:5432) |
| `backend/app/db/session.py` | `create_pool()` | Adicionar `statement_cache_size=0` para pooler |

**Arquivos que leem `DATABASE_URL` da env var:** `pipeline/*.py` (~15 arquivos) — todos resolvidos pelo `.env`.

---

## Fase 6 — Validação

```python
# Para cada tabela crítica: COUNT(*) local vs Supabase
# Para cada MV: COUNT(*) → mesma contagem
# Para cada endpoint:
#   GET /api/v1/sazonalidade → 200
#   GET /api/v1/categorias → 200
#   GET /api/v1/health → 200
# Pipeline: carga de teste
```

---

## Fase 7 — Go Live

- Swap `.env` para apontar ao Supabase
- Restart FastAPI + pipeline
- Monitorar logs por 24h

---

## Rollback

**Trivial:** reverter `.env` para `localhost`.  
Banco local nunca é tocado — continua rodando em paralelo.

---

## Riscos

1. **asyncpg + PgBouncer:** prepared statements incompatíveis com pooler transaction mode → `statement_cache_size=0` ou porta 5432
2. **Superuser ops:** `pg_stat_statements` pode falhar sem superuser
3. **Network:** Render/GitHub Actions precisam de IP no allow list do Supabase
4. **Tamanho:** Verificar volume de dados antes
5. **RLS:** Policies existentes podem conflitar com modelo Supabase — preferir grants tradicionais

---

## Timeline

| Fase | Duração | Risco | Responsável |
|---|---|---|---|
| 0 — Backup | 30 min | Baixo | Orchestrator |
| 1 — Projeto | 15 min | Baixo | Orchestrator |
| 2 — Schema | 4-6h | Alto | Orchestrator |
| 3 — Data | 30-60 min | Médio | Orchestrator |
| 4 — Roles | 1h | Médio | Orchestrator |
| 5 — Conexões | 1h | Baixo | Orchestrator |
| 6 — Validação | 2h | Médio | Orchestrator |
| 7 — Go live | instantâneo | Baixo | Orchestrator |
