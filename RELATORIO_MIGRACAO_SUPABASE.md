# Relatório de Migração: PostgreSQL Local → Supabase

**Data:** 2026-07-17  
**Projeto:** Quero Comprar  
**Status:** Fase 3 parcialmente concluída

---

## Resumo Executivo

Migração do banco PostgreSQL local para Supabase. Schema completo migrado com sucesso. Dados parcialmente restaurados devido a limitações de timeout na execução via API.

---

## Fases Concluídas

### ✅ Fase 0 — Backup Local
- `backup_quero_comprar_pre_migracao.dump` — 2.48 MB (custom format)
- `backup_quero_comprar_ddl.sql` — 23.69 MB (SQL puro)
- PostgreSQL 17, 21 tabelas, ~46 MB total

### ✅ Fase 1 — Projeto Supabase
- **Nome:** Quero_Comprar_ext
- **Ref:** kxsqrcccaaxplpktmutl
- **Host:** db.kxsqrcccaaxplpktmutl.supabase.co
- **PostgreSQL:** 17.6.1.127
- **Região:** us-east-1

### ✅ Fase 2 — Schema Migration
- 12 migrações aplicadas via `supabase db push --linked`
- 21 tabelas criadas (raw: 4, staging: 9, mart: 3, ops: 4)
- 3 functions, 2 procedures, 1 MV
- Roles: role_etl_writer, role_api_reader
- Forecast v2: baselines 24-25 e 25-26

---

## Fase 3 — Data Migration (Parcial)

### Dados Restaurados com Sucesso

| Tabela | Local | Supabase | Status |
|--------|-------|----------|--------|
| staging.dim_produto | 857 | 857 | ✅ 100% |
| staging.dim_localidade | 850 | 850 | ✅ 100% |
| staging.dim_categoria | 11 | 11 | ✅ 100% |
| staging.fact_precos_mensais | 42.358 | 39.358 | ⏳ 93% |
| staging.precos_rejeitados | 87 | 87 | ✅ 100% |
| mart.sazonalidade_produto | 62.291 | 25.200 | ⏳ 40% |
| mart.sazonalidade_baseline_24_25 | 23.449 | 13.100 | ⏳ 56% |

### Dados Pendentes

| Tabela | Local | Supabase | Status |
|--------|-------|----------|--------|
| mart.sazonalidade_baseline_25_26 | 32.581 | 0 | ⏳ Pendente |
| raw.coleta_bruta | 15 | 0 | ⏳ Pendente |
| raw.precos_uf | 0 | 0 | ⏳ Pendente |
| raw.precos_municipio | 0 | 0 | ⏳ Pendente |
| raw.controle_carga | 0 | 0 | ⏳ Pendente |
| staging.confianca_baseline | 0 | 0 | ⏳ Pendente |
| staging.baseline_2025_interpolado | 0 | 0 | ⏳ Pendente |
| staging.fato_cotacao_regional | 0 | 0 | ⏳ Pendente |
| staging.dim_conab_produto_mapping | 0 | 0 | ⏳ Pendente |
| ops.quarentena_coleta | 0 | 0 | ⏳ Pendente |
| ops.config_agente | 0 | 0 | ⏳ Pendente |
| ops.controle_erros_ddl | 0 | 0 | ⏳ Pendente |
| ops.audit_llm_queries | 0 | 0 | ⏳ Pendente |

---

## Schema Fixes Aplicados

1. `ALTER TABLE mart.sazonalidade_produto ADD COLUMN IF NOT EXISTS` — 8 colunas extras (preco_referencia, preco_atual, data_referencia_atual, usou_fallback_12m, metodo_calculo, variacao_mom_pct, preco_mes_anterior, preco_estimado)
2. `ALTER TABLE mart.sazonalidade_produto ALTER COLUMN ano DROP NOT NULL`
3. `ALTER TABLE mart.sazonalidade_produto ALTER COLUMN mes DROP NOT NULL`
4. `ALTER TABLE mart.sazonalidade_produto ALTER COLUMN preco_medio DROP NOT NULL`

---

## Descobertas Técnicas

1. **DNS:** `db.kxsqrcccaaxplpktmutl.supabase.co` não resolve nesta máquina Windows
2. **Solução:** Usar `supabase db query --linked` que usa tunnel interno da CLI
3. **Comando correto:** `npx supabase db query --linked --file "arquivo.sql"`
4. **Limitação API:** Arquivos > 23MB dão erro 413 (request entity too large)
5. **Schema mismatch:** Local tem mais colunas que Supabase — necessário ALTER TABLE
6. **Encoding:** Usar `PGCLIENTENCODING=UTF8` e `result.stdout.decode('utf-8', errors='replace')`
7. **Python subprocess:** `npx` não é encontrado — usar caminho completo `C:\Program Files\nodejs\npx.cmd`
8. **Connection options:** Direct (5432) para tudo, Transaction Pooler (6543) apenas FastAPI com `statement_cache_size=0`

---

## Arquivos Criados

| Arquivo | Descrição |
|---------|-----------|
| `migracao-supabase-plano.md` | Plano completo de migração |
| `restore_data.py` | Script de restore (encoding fix + column matching) |
| `restore_remaining.py` | Script para tabelas restantes |
| `restore_final.py` | Script final para baselines + raw + ops |
| `backup_data_only.sql` | Dump de dados local (23 MB) |
| `backup_cleaned.sql` | Dump limpo (sem comandos pg_dump) |
| `supabase/migrations/*.sql` | 12 migrações SQL |

---

## Próximos Passos

1. **Completar Fase 3:** Restaurar baseline_25_26 (32K rows), raw.*, ops.*
2. **Fase 4:** Criar roles e permissões no Supabase
3. **Fase 5:** Atualizar .env com connection strings do Supabase
4. **Fase 6:** Validar contagens local vs Supabase
5. **Fase 7:** Go Live — swap .env e monitorar

---

## Rollback

**Trivial:** reverter `.env` para `localhost`.  
Banco local nunca é tocado — continua rodando em paralelo.
