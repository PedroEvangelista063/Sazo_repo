# 🔌 Check de Conexão — Supabase Remoto

Script rápido para testar se o banco Supabase está acessível pelo terminal.

## 1. Teste de Rede (DNS + Firewall)

```bash
nc -zv aws-1-us-east-1.pooler.supabase.com 5432
```

**Esperado:** `Connection to aws-1-us-east-1.pooler.supabase.com ... succeeded!`

---

## 2. Conexão Direta com psql

```bash
psql "postgresql://postgres.kxsqrcccaaxplpktmutl:Marfia8976%2A@aws-1-us-east-1.pooler.supabase.com:5432/postgres" -c "SELECT version();"
```

**Esperado:** `PostgreSQL 17.6 on x86_64-pc-linux-gnu ...`

---

## 3. Listar Tabelas Existentes

```bash
psql "postgresql://postgres.kxsqrcccaaxplpktmutl:Marfia8976%2A@aws-1-us-east-1.pooler.supabase.com:5432/postgres" -c "\dt"
```

**Esperado:** Lista de tabelas ou `Did not find any tables.` (banco vazio).

---

## 4. Conexão via Python (asyncpg)

```bash
python3 -c "
import asyncio, asyncpg

async def test():
    conn = await asyncpg.connect(
        'postgresql://postgres.kxsqrcccaaxplpktmutl:Marfia8976%2A@aws-1-us-east-1.pooler.supabase.com:5432/postgres'
    )
    print('✅ Conectado! Versão:', await conn.fetchval('SELECT version()'))
    tables = await conn.fetch(
        \"SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public'\"
    )
    for t in tables:
        print(f'  📄 {t[\"tablename\"]}')
    await conn.close()

asyncio.run(test())
"
```

---

## 5. Verificar se o Backend Conecta (lendo do .env)

```bash
cd backend && python3 -c "
import os, asyncio, asyncpg
from dotenv import load_dotenv
load_dotenv()

async def test():
    conn = await asyncpg.connect(os.getenv('DATABASE_URL'))
    print('✅ Backend conecta ao Supabase!')
    print('Versão:', await conn.fetchval('SELECT version()'))
    await conn.close()

asyncio.run(test())
"
```

---

## 6. Verificar Migrations Aplicadas

```bash
psql "postgresql://postgres.kxsqrcccaaxplpktmutl:Marfia8976%2A@aws-1-us-east-1.pooler.supabase.com:5432/postgres" -c "SELECT * FROM supabase_migrations.schema_migrations;"
```

**Esperado:** Lista de migrations aplicadas ou erro `relation not found` (nenhuma aplicada ainda).

---

## 7. Aplicar Migrations Manualmente

```bash
# Aplicar uma migration específica
psql "postgresql://postgres.kxsqrcccaaxplpktmutl:Marfia8976%2A@aws-1-us-east-1.pooler.supabase.com:5432/postgres" -f supabase/migrations/000001_create_schemas.sql
```

> ⚠️ **Cuidado:** Aplicar migrations manualmente pode dessincronizar com o Supabase CLI.
> Prefira usar o sistema de migrations do backend (Alembic / SQLAlchemy) se disponível.

---

## 📌 Informações do Projeto

| Item | Valor |
|---|---|
| Project ID | `kxsqrcccaaxplpktmutl` |
| Host | `aws-1-us-east-1.pooler.supabase.com` |
| Porta Pooler | `5432` (transacional) |
| Porta Pooler (API) | `6543` (sessão) |
| PostgreSQL | `17` |
| Migrations locais | `supabase/migrations/` (15 arquivos) |
| Backend `.env` | `backend/.env` — chave `DATABASE_URL` |

---

## 🛠️ Instalação do Supabase CLI (opcional)

Se quiser gerenciar pelo CLI:

```bash
# Linux (via brew)
brew install supabase/tap/supabase

# Ou via npm
npm install -g supabase

# Linkar com o projeto remoto
supabase login
supabase link --project-ref kxsqrcccaaxplpktmutl
```
