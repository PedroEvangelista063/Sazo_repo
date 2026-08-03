# 🔌 Check de Conexão — Supabase Remoto

Script rápido para testar se o banco Supabase está acessível pelo terminal.

> ⚠️ **Segurança:** a credencial do banco NÃO deve aparecer aqui nem em qualquer
> arquivo versionado. Leia a URL de conexão do `backend/.env`
> (`DATABASE_URL_PRIMARY` / `DATABASE_URL`) e exporte-a antes de usar os comandos abaixo.

```bash
# Carrega a URL de conexão do .env do backend (sem expor o segredo no arquivo)
export DATABASE_URL="$(grep -E '^DATABASE_URL_PRIMARY=' backend/.env | cut -d= -f2-)"
```

---

## 1. Teste de Rede (DNS + Firewall)

```bash
nc -zv aws-1-us-east-1.pooler.supabase.com 5432
```

**Esperado:** `Connection to aws-1-us-east-1.pooler.supabase.com ... succeeded!`

---

## 2. Conexão Direta com psql

```bash
psql "$DATABASE_URL" -c "SELECT version();"
```

**Esperado:** `PostgreSQL 17.6 on x86_64-pc-linux-gnu ...`

---

## 3. Listar Tabelas Existentes

```bash
psql "$DATABASE_URL" -c "\dt"
```

**Esperado:** Lista de tabelas ou `Did not find any tables.` (banco vazio).

---

## 4. Conexão via Python (asyncpg)

```bash
python3 -c "
import asyncio, asyncpg, os

async def test():
    conn = await asyncpg.connect(os.environ['DATABASE_URL'])
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
psql "$DATABASE_URL" -c "SELECT * FROM supabase_migrations.schema_migrations;"
```

**Esperado:** Lista de migrations aplicadas ou erro `relation not found` (nenhuma aplicada ainda).

---

## 7. Aplicar Migrations Manualmente

```bash
# Aplicar uma migration específica
psql "$DATABASE_URL" -f supabase/migrations/000001_create_schemas.sql
```

> ⚠️ **Cuidado:** Aplicar migrations manualmente pode dessincronizar com o Supabase CLI.
> Prefira usar o sistema de migrations do backend (Alembic / SQLAlchemy) se disponível.

---

## 8. Erros Comuns

| Erro                                            | Significado                             | Ação                            |
| ----------------------------------------------- | --------------------------------------- | ------------------------------- |
| `FATAL: 57P03 ... Hot standby mode is disabled` | Instância **pausada** (free tier)       | Restaurar no dashboard Supabase |
| `EAUTHQUERY: ... database not available`        | Instância pausada (via pooler)          | Restaurar no dashboard          |
| `ECONNREFUSED 127.0.0.1:8000`                   | Race de startup (Vite antes do uvicorn) | Ignorar; some sozinho           |

---

## 📌 Informações do Projeto

| Item               | Valor                                                            |
| ------------------ | ---------------------------------------------------------------- |
| Project ID         | `kxsqrcccaaxplpktmutl`                                           |
| Host               | `aws-1-us-east-1.pooler.supabase.com`                            |
| Porta Pooler       | `5432` (transacional)                                            |
| Porta Pooler (API) | `6543` (sessão)                                                  |
| PostgreSQL         | `17`                                                             |
| Credencial         | `backend/.env` — chave `DATABASE_URL_PRIMARY` (nunca versionada) |
| Migrations locais  | `supabase/migrations/` (15 arquivos)                             |

> 🔑 **Credencial:** a senha do banco fica exclusivamente em `backend/.env`
> (gitignored). Rotacione-a no dashboard se ela tiver vazado em algum arquivo
> versionado.

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
