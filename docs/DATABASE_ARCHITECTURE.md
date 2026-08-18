# 🏛️ Arquitetura Híbrida de Banco de Dados

> **Projeto:** Sazo Brasil
> **Última atualização:** 2026-07-25
> **Stack:** Supabase (PostgreSQL 17) + asyncpg + FastAPI + PostgreSQL 18 local

---

## 1. Filosofia: Remoto é o Primário

```
┌─────────────────────────────────────────────────────────────────┐
│                    REMOTO (PRIMARY — Active)                    │
│              Supabase kxsqrcccaaxplpktmutl                     │
│                                                                 │
│  ┌──────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │ Session  │  │ Transaction  │  │  Session     │              │
│  │ Pooler   │  │ Pooler       │  │  Pooler      │              │
│  │ :5432    │  │ :6543        │  │  :5432       │              │
│  │ DDL/ETL  │  │ API (reads)  │  │  Cargas      │              │
│  └──────────┘  └──────────────┘  └──────────────┘              │
│        │              │                │                        │
│        └──────┬───────┴────────────────┘                        │
│               │                                                 │
│        [asyncpg Pool — backend Python]                          │
│               │                                                 │
│        [FastAPI — API REST]                                     │
│               │                                                 │
│        [React Frontend — Vite]                                  │
└───────────────┬─────────────────────────────────────────────────┘
                │
                │ Sincronização manual (pg_dump)
                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    LOCAL (STANDBY — Backup/Sandbox)              │
│              PostgreSQL 18 nativo no Linux Mint                 │
│              localhost:5432 / quero_comprar                     │
│                                                                 │
│  ┌──────────────┐  ┌─────────────────┐                          │
│  │ Schema DDL   │  │ Dados curados   │                          │
│  │ (migration)  │  │ (data dump)     │                          │
│  └──────────────┘  └─────────────────┘                          │
│                                                                 │
│  USOS:                                                          │
│  • Backup de segurança (snapshot manual)                        │
│  • Testes de queries pesadas (sem travar Supabase)              │
│  • Sandbox para experimentos DDL                                │
└─────────────────────────────────────────────────────────────────┘
```

### Regra de Ouro

| Direção            | Permitido?                           | Como?                                                       |
| ------------------ | ------------------------------------ | ----------------------------------------------------------- |
| **Remote ➔ Local** | ✅ **Sim** — via `npm run db:backup` | `pg_dump` do Supabase → `pg_restore` no local               |
| **Local ➔ Remote** | ❌ **NUNCA** automaticamente         | Apenas via **migrations formais** em `supabase/migrations/` |
| **Dev diário**     | ✅ Remote (padrão)                   | `npm run dev` sempre usa `DATABASE_URL_API`                 |
| **Teste de query** | ✅ Local (com flag)                  | `DB_ENV=local npm run db:test:local`                        |

---

## 2. Estrutura dos Arquivos .env

### Arquivo de autoridade: `backend/.env`

```env
# ── Supabase Remoto (PRIMARY — Active) ──────────────────
DATABASE_URL          → Session Pooler :5432   (DDL, ETL)
DATABASE_URL_API      → Transaction Pooler :6543 (API reads)
DATABASE_URL_ETL      → Session Pooler :5432   (cargas)

# ── PostgreSQL Local (STANDBY — Backup) ─────────────────
DATABASE_URL_LOCAL_BACKUP → localhost:5432/quero_comprar
```

### Arquivos de ambiente

| Arquivo                | Propósito                                                  | Gitignored? |
| ---------------------- | ---------------------------------------------------------- | ----------- |
| `backend/.env`         | **Única fonte de verdade** para URLs de banco              | ✅ Sim      |
| `backend/.env.example` | Template para novos devs                                   | ❌ Não      |
| `.env` (raiz)          | Configs GLOBAIS (CORS, cache, LLM) - **sem URLs de banco** | ✅ Sim      |
| `.env.example`         | Template global público                                    | ❌ Não      |
| `frontend/.env`        | `VITE_API_URL` (aponta para backend)                       | ✅ Sim      |

### Rotas de conexão no código

O `pydantic-settings` (em `backend/app/core/config.py`) carrega automaticamente de `backend/.env`. O módulo `backend/app/db/session.py` cria dois pools:

```python
get_api_pool()  → DATABASE_URL_API (ou DATABASE_URL como fallback)
get_etl_pool()  → DATABASE_URL_ETL (ou DATABASE_URL como fallback)
```

---

## 3. Pipeline de Backup (Remote ➔ Local)

### Comando único

```bash
npm run db:backup          # Gera schema + data dump em database/backups/
npm run db:backup:restore  # Gera + restaura no PostgreSQL local
```

### Artefatos gerados

```
database/backups/
├── backup_schema_latest.sql     → DDL: tables, views, functions, triggers
├── backup_data_latest.dump      → Dados curados (custom format, comprimido)
├── backup_schema_20260725.sql   → Snapshot versionado (retido 30 dias)
└── backup_data_20260725.dump    → Snapshot versionado (retido 30 dias)
```

### O que é excluído do dump de dados

- Schemas do Supabase: `auth`, `storage`, `realtime`, `vault`, etc.
- Tabelas de log: `ops.audit_logs`, `ops.audit_llm_queries`, `ops.quarentena_coleta`
- Schema `raw` (dados brutos de scraper)

### Script: `scripts/sync_db_remote_to_local.sh`

```
USAGE:
  bash scripts/sync_db_remote_to_local.sh              # só gera backups
  bash scripts/sync_db_remote_to_local.sh --restore     # gera + restaura local
  bash scripts/sync_db_remote_to_local.sh --schema-only # só schema
  bash scripts/sync_db_remote_to_local.sh --data-only   # só dados
```

---

## 4. Banco Local (Standby)

### Opção A: PostgreSQL Nativo (Linux Mint) — RECOMENDADO ✅

Já instalado e configurado:

| Item     | Valor                |
| -------- | -------------------- |
| Host     | `localhost`          |
| Porta    | `5432`               |
| Database | `quero_comprar`      |
| Usuário  | `postgres`           |
| Senha    | `postgres_dev_local` |
| Versão   | PostgreSQL 18.4      |

### Opção B: Docker (Alternativa)

Se precisar de um banco isolado sem tocar no PostgreSQL nativo:

```bash
# Porta 5433 para não conflitar
docker compose up -d postgres-backup
# URL de conexão:
# postgresql://postgres:postgres_dev_local@localhost:5433/quero_comprar
```

> ⚠️ **ATENÇÃO:** O container Docker não tem os schemas `staging`, `mart` e `ops` populados até que você execute `npm run db:backup:restore`.

---

## 5. Rodrigues de Segurança

### 🔒 Trava 1: Migrations são o Único Caminho para o Remoto

```bash
# ❌ ERRADO — NUNCA faça:
psql $DATABASE_URL_ETL -f script_avulso.sql

# ✅ CERTO — Sempre via migration:
supabase migration new minha_mudanca
# ... editar o arquivo ...
supabase db push  # ou aplicar manualmente via psql
```

### 🔒 Trava 2: Backup Antes de Migration Arriscada

Sempre que for criar ou aplicar uma migration que pode dar problema:

```bash
# 1. Snapshot de segurança
npm run db:backup:restore

# 2. Cria e aplica a migration
supabase migration new minha_mudanca
# ... edita ...
supabase db push
```

### 🔒 Trava 3: Sandbox Local para Queries Pesadas

Para testar queries pesadas ou DDL de risco sem travar o Supabase:

```bash
# 1. Atualiza o espelho local
npm run db:backup:restore

# 2. Executa o script localmente
DB_ENV=local psql $DATABASE_URL_LOCAL_BACKUP -f scripts/meu_teste.sql

# 3. Se funcionou, cria uma migration e aplica no remoto
```

### 🔒 Trava 4: RLS com Bypass para Backend

O RLS está ativo nas tabelas `mart.sazonalidade_produto`, `staging.dim_produto`, `staging.fact_precos_mensais` e `ops.audit_logs`. As políticas permitem:

- **`role_etl_writer`** (usado pelo backend asyncpg): Acesso total (`USING(true)` + `WITH CHECK(true)`)
- **`role_api_reader`** (usado pela API): SELECT apenas
- **`postgres`** (superusuário): Bypass automático — sem bloqueio
- **`service_role`** (Supabase): Bypass automático — sem bloqueio

Isso garante que o backend Python, o OpenCode e as migrations nunca sejam bloqueados pelo RLS no dia a dia.

---

## 6. Migrations Aplicadas (Schema Drift Reconciliado)

| Migration                              | Data       | O que fez                                                        |
| -------------------------------------- | ---------- | ---------------------------------------------------------------- |
| `000013_reconciliacao_drift_fase4.sql` | 2026-07-25 | Reconciliou 18 objetos entre scripts database/ e Supabase remoto |
| `000014_triggers_anomalia_audit.sql`   | 2026-07-25 | Trigger UF-based + audit trail (ops.audit_logs)                  |
| `000015_rls_security_layer.sql`        | 2026-07-25 | RLS + grants + default privileges                                |

---

## 7. Checklist Diário

```bash
# Iniciar desenvolvimento
npm run dev

# Antes de alterar o schema
npm run db:backup

# Para testar query local
npm run db:backup:restore
psql $DATABASE_URL_LOCAL_BACKUP -f minha_query.sql

# Para aplicar migration no remoto
PGPASSWORD='senha' psql -h aws-1-us-east-1.pooler.supabase.com -U postgres.kxsqrcccaaxplpktmutl -d postgres -f supabase/migrations/NNNNN_nome.sql
```
