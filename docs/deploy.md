# Deploy — Database e API

## ⚡ Visão Geral

O projeto tem **dois sistemas de migração** que coexistem:

| Sistema | Localização | Gerenciamento | Aplicado em |
|---------|-------------|---------------|-------------|
| **Supabase Migrations** | `supabase/migrations/000001-000012` | `supabase db push --linked` | Local + Supabase |
| **Custom DB Scripts** | `database/01-35.sql` | Manual via Python/psql | **Só local** |

**Estado atual (Jul/2026):**
- ✅ Supabase: 12 migrações → schema base + dados (174.240 linhas)
- ❌ Supabase: **sem as funções custom** das migrations 32–35 (`mart.fn_*`, views, paginação)
- ✅ Local: migrations 01–35 aplicadas (schema + funções + dados)

> **Consequência:** se você apontar a API pro Supabase hoje, endpoints que dependem de `mart.fn_*` ou `mart.vw_categorias` vão quebrar. O "deploy" real é fazer o **schema local chegar no Supabase**.

---

## 🧭 Roteiro Rápido

```
                        ┌──────────────────┐
                        │  database/35.sql  │  ← nova migration custom
                        └────────┬─────────┘
                                 ↓
          ┌──────────────────────────────────────┐
          │  Criar migration Supabase equivalente │
          │  supabase migration new descricao     │
          └────────────────┬─────────────────────┘
                           ↓
          ┌──────────────────────────────────────┐
          │  Copiar SQL (com ajustes se preciso)  │
          └────────────────┬─────────────────────┘
                           ↓
          ┌──────────────────────────────────────┐
          │  Aplicar no Supabase                  │
          │  supabase db push --linked            │
          └────────────────┬─────────────────────┘
                           ↓
          ┌──────────────────────────────────────┐
          │  Verificar schema drift              │
          │  supabase db dump --linked --schema  │
          │  vs pg_dump local                    │
          └──────────────────────────────────────┘
```

---

## 1. Pré-requisitos

```bash
# Supabase CLI instalada?
npx supabase --version

# Projeto linkado?
npx supabase link --project-ref kxsqrcccaaxplpktmutl
# (se não estiver linkado, pede a senha do banco)

# Verificar conexão
npx supabase db query --linked "SELECT 1 AS test;"
```

**Conexões disponíveis:**

| Tipo | URL | Uso |
|------|-----|-----|
| **Direct (5432)** | `postgresql://postgres:SENHA@db.kxsqrcccaaxplpktmutl.supabase.co:5432/postgres` | ETL, REFRESH MV, VACUUM, DDL |
| **Pooler (6543)** | `postgresql://postgres.kxsqrcccaaxplpktmutl:SENHA@aws-0-us-east-1.pooler.supabase.com:6543/postgres` | FastAPI (reads) |

> ⚠️ DNS `db.kxsqrcccaaxplpktmutl.supabase.co` **não resolve** nesta máquina Windows.
> Use `supabase db query --linked` (tunnel interno da CLI) ou configure `%WINDIR%\System32\drivers\etc\hosts`.

---

## 2. Schema Changes (DDL)

### 2.1 Fluxo Padrão

Toda alteração de schema começa no **local** (via `database/` ou diretamente no PostgreSQL) e depois é promovida ao Supabase.

```bash
# 1. Criar migration Supabase
npx supabase migration new descricao_da_alteracao
# → Cria: supabase/migrations/000013_descricao_da_alteracao.sql

# 2. Editar o arquivo criado com o SQL da alteração
#    (cuidado com schemas — local usa mart.*, staging.*;
#     Supabase também, mas verifique se o schema existe)

# 3. Aplicar no Supabase
npx supabase db push --linked

# 4. Verificar
npx supabase db query --linked "SELECT 1;"
```

### 2.2 Quando usar `database/` vs `supabase/migrations/`

| Cenário | Onde escrever |
|---------|---------------|
| Schema novo (tabelas, colunas, views) | `supabase/migrations/` — commit no repositório |
| Funções PL/pgSQL novas | `supabase/migrations/` — commit no repositório |
| Experimentos locais (só seu DB) | `database/` — sem commit |
| Scripts de ETL/backfill | `database/scripts/` — executados manualmente |
| Hotfix rápido no Supabase | `supabase db query --linked -f fix.sql` |

### 2.3 Exemplo Prático: Promover migrations 32–35 para o Supabase

As migrations 32–35 existem em `database/` mas **não foram aplicadas no Supabase**. Para promovê-las:

```bash
# 1. Criar migrations Supabase para cada uma
npx supabase migration new fn_regional_snapshot
# → supabase/migrations/000013_fn_regional_snapshot.sql

npx supabase migration new paginacao_br_regional
# → supabase/migrations/000014_paginacao_br_regional.sql

npx supabase migration new vw_categorias_municipios
# → supabase/migrations/000015_vw_categorias_municipios.sql

npx supabase migration new drop_fn_overload
# → supabase/migrations/000016_drop_fn_overload.sql
```

> ⚠️ **Importante:** Copie o conteúdo de `database/32_fn_regional_snapshot.sql` para `000013`, depois **copie o conteúdo ATUALIZADO** (não o original 32, mas o que resultou das migrations 33–35). A ordem importa:
>
> 1. `000013`: CREATE 5-param `fn_regional_snapshot` + `fn_regional_por_mes` + `fn_br_nacional_por_mes` (conteúdo de `database/33_paginacao_br_regional.sql`)
> 2. `000014`: `mart.vw_categorias` + `mart.vw_municipios` (conteúdo de `database/34_*.sql`)
> 3. `000015`: DROP 3-param overload (conteúdo de `database/35_*.sql`)
>
> **Pule a migration 32** (3-param original) — ela é obsoleta e só causaria ambiguidade de novo.

---

## 3. Data Changes (DML)

### 3.1 Dados de configuração

Tabelas como `ops.config_agente` contêm JSONs de configuração. Para atualizar no Supabase:

```bash
# Opção A — SQL avulso (recomendado para alterações pequenas)
npx supabase db query --linked "
    INSERT INTO ops.config_agente (chave, valor)
    VALUES ('regioes', '[{\"id\":\"norte\",...}]'::json)
    ON CONFLICT (chave) DO UPDATE SET valor = EXCLUDED.valor;
"

# Opção B — Arquivo SQL
npx supabase db query --linked -f database/scripts/update_config.sql
```

### 3.2 Refresh da Materialized View

```bash
# Não funciona via pooler (5432) — use Direct connection
npx supabase db query --linked "
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
"

# Se der timeout, tente com statement_timeout maior:
npx supabase db query --linked "
    SET statement_timeout = '300s';
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
"
```

### 3.3 Backfill / Carga de dados

```bash
# Para volumes grandes, use chunks de ~2MB (limite da API Supabase é 413 >2.5MB)
python .opencode/plans/restore_final_v3.py
#   → usa ON CONFLICT DO NOTHING, 200 rows/chunk
```

---

## 4. Verificação e Diagnóstico

### 4.1 Detectar schema drift

```bash
# Dump do schema remoto
npx supabase db dump --linked --schema-only -f /tmp/supabase_schema.sql

# Dump do schema local
pg_dump -U postgres -h localhost -d quero_comprar --schema-only -f /tmp/local_schema.sql

# Comparar (ignore sequences, owners, ACLs)
diff --ignore-matching-lines='OWNER TO|GRANT|SEQUENCE' /tmp/local_schema.sql /tmp/supabase_schema.sql
```

### 4.2 Verificar functions

```sql
-- No Supabase via CLI
npx supabase db query --linked "
    SELECT proname, pronargs,
           pg_get_function_identity_arguments(oid) AS signature
    FROM pg_proc
    WHERE pronamespace = 'mart'::regnamespace
       OR pronamespace = 'public'::regnamespace
    ORDER BY proname, pronargs;
"
```

### 4.3 Verificar dados

```sql
npx supabase db query --linked "
    SELECT schemaname, tablename, n_live_tup AS estimated_count
    FROM pg_stat_user_tables
    ORDER BY schemaname, tablename;
"
```

---

## 5. Fluxo Completo: Alterar Backend → Subir pro Supabase

Quando você altera o backend (endpoint, schema, query) e precisa refletir no Supabase:

```
┌────────────────────────────────────────────────────────┐
│ 1. Altera o schema local (tabela, função, view)        │
│    (via database/XX.sql ou direto no psql)             │
└────────────────────────┬───────────────────────────────┘
                         ↓
┌────────────────────────────────────────────────────────┐
│ 2. Testa localmente                                    │
│    (uvicorn, pytest, query direta)                     │
└────────────────────────┬───────────────────────────────┘
                         ↓
┌────────────────────────────────────────────────────────┐
│ 3. Cria migration Supabase                              │
│    supabase migration new descricao                    │
│    → copia o SQL para supabase/migrations/             │
└────────────────────────┬───────────────────────────────┘
                         ↓
┌────────────────────────────────────────────────────────┐
│ 4. Aplica no Supabase                                   │
│    supabase db push --linked                           │
└────────────────────────┬───────────────────────────────┘
                         ↓
┌────────────────────────────────────────────────────────┐
│ 5. Verifica schema e dados                             │
│    (diff, query de teste)                              │
└────────────────────────┬───────────────────────────────┘
                         ↓
┌────────────────────────────────────────────────────────┐
│ 6. Se necessário: atualiza .env com nova connection    │
│    string se algo mudou (raro)                         │
└────────────────────────────────────────────────────────┘
```

### Exemplo completo: adicionar uma coluna

```bash
# 1. Local: altera a tabela
psql -U postgres -d quero_comprar -c "
    ALTER TABLE mart.sazonalidade_produto ADD COLUMN nova_coluna TEXT;
"

# 2. Testa local
python -c "import asyncio, asyncpg; ..."   # ou via API

# 3. Migration Supabase
npx supabase migration new add_nova_coluna
# → edita supabase/migrations/000013_add_nova_coluna.sql:
#   ALTER TABLE mart.sazonalidade_produto ADD COLUMN nova_coluna TEXT;

# 4. Push
npx supabase db push --linked

# 5. Verifica
npx supabase db query --linked "
    SELECT column_name, data_type
    FROM information_schema.columns
    WHERE table_schema = 'mart'
      AND table_name = 'sazonalidade_produto'
      AND column_name = 'nova_coluna';
"
```

---

## 6. Troubleshooting

| Problema | Causa | Solução |
|----------|-------|---------|
| `413 Request Entity Too Large` | SQL > ~2.5MB | Dividir em chunks de ~2MB |
| `statement_cache_size` error | Pooler não suporta prepared statements | `statement_cache_size=0` na string de conexão |
| DNS não resolve (`db.kxsqrcccaaxplpktmutl.supabase.co`) | Firewall Windows | Usar `supabase db query --linked` |
| `AmbiguousFunctionError` | Múltiplas overloads de função | Dropar a overload obsoleta (ver `database/35_*.sql`) |
| `relation "mart.fn_*" does not exist` no Supabase | Função custom nunca foi migrada | Criar migration no Supabase (seção 2.3) |
| Migration conflict (`supabase db push` falha) | Migração local vs remota fora de sync | `supabase db push --linked --dry-run` primeiro |
| Trigger bloqueia INSERT | `trg_valida_anomalia_preco` muito restritiva | `ALTER TABLE ... DISABLE TRIGGER trg_valida_anomalia_preco;` executar o INSERT, reativar |

---

## 7. Referências

- **Conexões:** `backend/summary.md` (pooler, direct, .env)
- **Schema completo:** `database/summary.md`
- **Pipeline:** `pipeline/summary.md` (ciclo medalhão, coleta)
- **Supabase CLI docs:** `supabase db --help`
- **Migrações aplicadas:** `database/summary.md` seção "Migração Supabase" (linha 158)
- **Scripts de restore:** `database/summary.md` seção "Scripts de Restore" (linha 180)
