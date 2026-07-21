# Plano de Sync Local → Supabase
**Projeto:** Quero Comprar  
**Data:** 2026-07-20  
**Status:** ⚠️ Bloqueado — 7 objetos faltantes + dados divergentes

---

## Diagnóstico

O Supabase tem as 12 migrations iniciais (000001–000012) aplicadas. O banco local
avançou mais 23 scripts (13–35) depois disso. Resultado:

| Categoria | Local | Supabase |
|---|---|---|
| Migrations aplicadas | 35 scripts | 12 (000001–000012) |
| Funções mart.* | ✅ 5 funções | ❌ 0 |
| Views mart.vw_categorias / vw_municipios | ✅ | ❌ |
| Dados (contagens) | referência | ≈ idênticas¹ |
| Dados (linhas específicas) | mais recente | desatualizado |

¹ Contagens idênticas na auditoria de 18/07, mas amostras divergem — dados foram inseridos
localmente depois da migração e não foram replicados.

**Objetos que FALTAM no Supabase usados pela API:**

```
mart.vw_categorias
mart.vw_municipios
mart.fn_br_nacional_snapshot(text, int, int)
mart.fn_br_nacional_por_mes(int, int, text, int, int)
mart.fn_br_nacional_sazonalidade(int, int)   ← alias do snapshot
mart.fn_regional_snapshot(text[], int, text, int, int)
mart.fn_regional_por_mes(text[], int, int, int, text, int, int)
```

---

## Decisão de Autoridade dos Dados

> **LOCAL é a verdade.** O banco local é a única fonte que recebe novas coletas do
> scraper, executa a SP de forecast, e tem todos os scripts aplicados. O Supabase
> precisa ser trazido ao nível do local — não o contrário.

---

## Plano em 4 Fases

### Fase 1 — Aplicar Migrations Faltantes (schema-only)
**Objetivo:** Criar os 7 objetos ausentes no Supabase.  
**Risco:** Baixo — todos os scripts são idempotentes (`CREATE OR REPLACE`).  
**Tempo estimado:** ~30 minutos.

Os scripts do local que precisam ser aplicados no Supabase, em ordem:

| Ordem | Script local | O que cria |
|---|---|---|
| 1 | `32_fn_regional_snapshot.sql` | `public.fn_resumo_regiao`, `public.fn_regioes_listar` |
| 2 | `33_paginacao_br_regional.sql` | `mart.fn_br_nacional_snapshot`, `mart.fn_br_nacional_por_mes`, `mart.fn_regional_snapshot`, `mart.fn_regional_por_mes` |
| 3 | `34_mart_vw_categorias_municipios.sql` | `mart.vw_categorias`, `mart.vw_municipios` |
| 4 | `35_drop_fn_regional_snapshot_overload.sql` | Remove sobrecarga ambígua de `fn_regional_snapshot` |

> **⚠️ Atenção:** O script 32 cria funções no schema `public`, não `mart`. Verificar
> se o Supabase já tem essas (foram aplicadas via 000012_functions_v2.sql).
> Se já existirem, pular e ir direto para o 33.

**Execução via CLI:**

```bash
# Criar 4 novas migrations no formato Supabase
npx supabase migration new fn_regional_snapshot_32
npx supabase migration new paginacao_br_regional_33
npx supabase migration new vw_categorias_municipios_34
npx supabase migration new drop_fn_snapshot_overload_35

# Copiar conteúdo de cada database/NN_*.sql para o arquivo gerado em supabase/migrations/
# (cada migration gerada terá um timestamp prefix, ex: 20260720_fn_regional_snapshot_32.sql)

# Aplicar no Supabase
npx supabase db push --linked
```

**Alternativa mais rápida (sem criar migration formal):**

```bash
# Executar direto no banco remoto — útil para correções urgentes
npx supabase db query --linked -f database/32_fn_regional_snapshot.sql
npx supabase db query --linked -f database/33_paginacao_br_regional.sql
npx supabase db query --linked -f database/34_mart_vw_categorias_municipios.sql
npx supabase db query --linked -f database/35_drop_fn_regional_snapshot_overload.sql
```

> **Prefira a alternativa rápida** se o objetivo é desbloquear a API agora.
> Crie as migrations formais quando houver tempo — elas garantem rastreabilidade
> e facilitam recriar o ambiente do zero.

---

### Fase 2 — Sincronizar os Dados
**Objetivo:** Trazer o Supabase ao mesmo estado de dados do local.  
**Risco:** Médio — envolve inserção de dados e potenciais conflitos de chave.  
**Tempo estimado:** ~60 minutos.

**Estratégia: `UPSERT` seletivo nas tabelas divergentes.**

As tabelas com divergência de amostras segundo a auditoria:
- `staging.fact_precos_mensais`
- `staging.dim_produto`
- `mart.sazonalidade_produto`

A abordagem mais segura é um dump parcial das tabelas que mudaram:

```bash
# 1. Dump somente das 3 tabelas divergentes (banco local)
pg_dump -U postgres -d quero_comprar \
  --data-only \
  --table=staging.fact_precos_mensais \
  --table=staging.dim_produto \
  --table=mart.sazonalidade_produto \
  --inserts \
  --on-conflict-do-nothing \
  -f sync_delta_20260720.sql

# 2. Verificar tamanho do arquivo
# Se > 2 MB, cortar em chunks de ~1.5 MB (limite do Supabase API é ~2.5 MB)
# Ver seção "Limite 413" abaixo

# 3. Aplicar no Supabase
npx supabase db query --linked -f sync_delta_20260720.sql
```

**Sobre o limite 413 do Supabase:**

```bash
# Quebrar arquivo grande em pedaços menores
split -l 5000 sync_delta_20260720.sql chunk_
# Aplicar cada chunk em sequência
for f in chunk_*; do
  npx supabase db query --linked -f "$f"
done
```

**Após o sync:**

```bash
# Atualizar MV (obrigatório depois de inserir em mart.sazonalidade_produto)
npx supabase db query --linked \
  "REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;"
```

---

### Fase 3 — Validação
**Objetivo:** Confirmar que tudo passa antes de trocar o `.env`.  
**Risco:** Nenhum — só leitura.  
**Tempo estimado:** ~15 minutos.

```bash
# Reexecutar o script de auditoria apontando pro Supabase
# (editar DATABASE_URL temporariamente ou passar como env var)

DATABASE_URL="postgresql://postgres.kxsqrcccaaxplpktmutl:SENHA@aws-0-us-east-1.pooler.supabase.com:6543/postgres" \
  python utilities/audit_full.py

# Meta: 44/44 ✅ (100%)
# Mínimo aceitável para avançar: 42/44 com os únicos falhos sendo cache hit timing
```

**Checklist manual pós-Fase 1:**

```sql
-- Verificar que os objetos existem no Supabase
SELECT routine_name, routine_schema
FROM information_schema.routines
WHERE routine_name IN (
  'fn_br_nacional_snapshot', 'fn_br_nacional_por_mes',
  'fn_regional_snapshot', 'fn_regional_por_mes'
)
ORDER BY routine_name;

SELECT table_name, table_schema
FROM information_schema.views
WHERE table_name IN ('vw_categorias', 'vw_municipios')
  AND table_schema = 'mart';
```

---

### Fase 4 — Conectar FastAPI ao Supabase
**Objetivo:** Trocar o `.env` para que a API consuma o Supabase.  
**Risco:** Alto (produção) — fazer só após Fase 3 verde.  
**Tempo estimado:** 5 minutos.

**Alterar `.env`:**

```bash
# ANTES (local)
DATABASE_URL_API=postgresql://postgres:postgres@localhost:5432/quero_comprar

# DEPOIS (Supabase via Transaction Pooler — porta 6543 para FastAPI/asyncpg)
DATABASE_URL_API=postgresql://postgres.kxsqrcccaaxplpktmutl:SENHA@aws-0-us-east-1.pooler.supabase.com:6543/postgres
```

> **Obrigatório:** `statement_cache_size=0` já deve estar configurado em
> `backend/app/db/session.py`. Verificar antes de fazer o swap.

**Rollback em 30 segundos:**

```bash
# Reverter .env para localhost e reiniciar FastAPI
DATABASE_URL_API=postgresql://postgres:postgres@localhost:5432/quero_comprar
```

O banco local NUNCA é tocado por este processo — rollback é trivial.

---

## Pipeline de Atualização Contínua

Após as 4 fases acima, cada vez que um novo script `NN_*.sql` for criado:

```bash
# 1. Testar localmente
psql -U postgres -d quero_comprar -f database/NN_novo_script.sql

# 2. Aplicar no Supabase
npx supabase db query --linked -f database/NN_novo_script.sql

# OU via migration formal
npx supabase migration new descricao_da_mudanca
# (copiar conteúdo do script para supabase/migrations/TIMESTAMP_descricao.sql)
npx supabase db push --linked

# 3. Se envolver mart.sazonalidade_produto ou MV: refresh
npx supabase db query --linked \
  "REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;"
```

---

## Gotchas Conhecidos

| Problema | Causa | Solução |
|---|---|---|
| Erro 413 | Arquivo SQL > ~2.5 MB via CLI | Quebrar em chunks de ~1.5 MB |
| DNS não resolve | `db.kxsqrcccaaxplpktmutl.supabase.co` não resolve no Windows | Usar `--linked` (tunnel interno) |
| `AmbiguousFunctionError` | Overload de 3 params da fn_regional_snapshot ainda presente | Aplicar migration 35 |
| asyncpg + pooler | Prepared statements incompatíveis com PgBouncer mode | `statement_cache_size=0` |
| Trigger bloqueante | `trg_valida_anomalia_preco` barra inserts com preço anômalo | Desativar, inserir, reativar |
| Sequence dessincronizada | SERIAL não atualiza com `INSERT ... ON CONFLICT DO NOTHING` | `setval()` pós-restore |

---

## Referências

- `database/summary.md` — mapa de todas as migrations e conexão Supabase
- `docs/archive/migracao-supabase-plano.md` — histórico da migração inicial (Fase 0-3)
- `database/scripts/restore_final_v3.py` — script de restore usado em 2026-07-17
- `database/fix_sequences.sql` — correção de sequences se necessário
