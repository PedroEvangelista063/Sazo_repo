# 🔄 Runbook — Rollback do Sync Produção ➔ Homologação

> Data: 2026-08-12 · Script: `scripts/sync_db_prod_to_staging.sh` · Ambientes: Produção (Aiven) → Homologação (Físico/Local)
> Objetivo: restaurar o banco de homologação para o estado anterior a um sync mal-sucedido ou indesejado.

---

## 1. Visão geral do sync (o que ele faz com o destino)

| Ação no destino (homologação)                              | Detalhe                                                                                                   |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `DROP SCHEMA staging CASCADE` + `DROP SCHEMA mart CASCADE` | Recriados do dump da Produção (ou `TRUNCATE staging.*/mart.*` com `--truncate-only`)                      |
| Preserva `ops.*` e `raw.*`                                 | `ops.config_agente`, auditoria, landing zone — **nunca** tocados                                          |
| Preserva `audit.*`                                         | Schema excluído do dump (`--exclude-schema='audit'`)                                                      |
| Remove `EVENT TRIGGER ensure_rls`                          | Legado Supabase (dependência da função `public.rls_auto_enable`) — pré-drop antes do `pg_restore --clean` |
| Restore único `pg_restore --clean --if-exists`             | Sem `--jobs` (ordem drop/create determinística); erros `already exists` são benignos e contados           |

**Backups gerados pelo sync** (em `database/backups/`):

| Artefato                                | Origem      | Conteúdo                                                                  |
| --------------------------------------- | ----------- | ------------------------------------------------------------------------- |
| `prod2staging_schema_<TS>.sql`          | Produção    | Schema (sem `ops/raw/audit/auth/...`)                                     |
| `prod2staging_data_<TS>.dump`           | Produção    | Dados (custom, sem `ops/raw/audit`, sem dados de logs)                    |
| `prod2staging_schema_latest.sql`        | Produção    | Cópia "latest" (reusada por `--no-dump`)                                  |
| `prod2staging_data_latest.dump`         | Produção    | Cópia "latest"                                                            |
| **`backup_staging_pre_sync_<TS>.dump`** | **Destino** | **Snapshot completo da homologação ANTES do wipe — artefato de rollback** |

> ⚠️ O snapshot pré-sync do **destino** é a peça-chave do rollback. Sem ele, a única
> forma de voltar é reaplicar migrations locais + re-sync (mais frágil).

---

## 2. Casos de falha conhecidos do `pg_restore` (diagnóstico rápido)

O script **não aborta** em `pg_restore` exit≠0 de imediato — ele filtra erros e decide:

| Sintoma                                              | Causa raiz                                                                 | Classificação                        | Tratamento                                                               |
| ---------------------------------------------------- | -------------------------------------------------------------------------- | ------------------------------------ | ------------------------------------------------------------------------ |
| `pg_restore: error: ... already exists`              | Normal com `--clean` (objetos recriados 2× em ordem não ótima)             | ✅ **Benigno** (contado no log)      | Nenhum — o script loga `(N erros benignos 'already exists')`             |
| `... does not exist` / `no matching`                 | `--clean` tentando dropar objeto já ausente                                | ✅ **Benigno**                       | Nenhum                                                                   |
| `cannot drop ... because other objects depend on it` | Event trigger/objeto com dependência (ex.: `ensure_rls`↔`rls_auto_enable`) | ⚠️ **Crítico se recorrente**         | Pré-drop documentado no script; se reaparecer, dropar o dependente antes |
| `function public.fn_* already exists`                | Dump traz funções `public.*` que conflitam com o local                     | ⚠️ Observar                          | `--clean --if-exists` resolve na maioria dos casos                       |
| Dump vazio / `exit 1` no `pg_dump`                   | Erro transiente na origem (Aiven lento/free)                               | ❌ **Aborta antes de tocar destino** | Reexecutar o sync; o hardening de dump-vazio impede destruição           |
| `❌ Destino NÃO é local/físico`                      | `STAGING_URL` aponta fora de `localhost`                                   | ✅ **Proteção ativa**                | Usar `--force` somente com consciência                                   |

**Decisão prática**: se o sync terminar com `exit 0` → sucesso. Se terminar `exit 1`
mas os erros logados forem todos da lista benigna acima → o destino pode estar
consistente; **rode a validação manual (seção 4)** antes de decidir. Se houver
erro crítico real → **rollback imediato (seção 3)**.

---

## 3. Rollback — restaurar a homologação pré-sync

### Pré-requisito

Backup pré-sync do destino existe? (criado automaticamente pelo script a partir de agora):

```bash
ls -la database/backups/backup_staging_pre_sync_*.dump
```

> Se **não existir** (sync antigo): monte o estado anterior reaplicando o dump da MV
> `backup_mv_80_pre_*` (V22/V23) + reaplicando migrations locais não cobertas pelo Aiven
> (ex.: `backend/migrations/012_security_rls_readonly.sql`) — ou aceite o estado
> espelhado da Produção (que é o estado-alvo do sync).

### 3.1 Restaurar o snapshot completo (via pg_restore)

```bash
cd /home/pedroeduardo/projetos/quero_comprar_vg
DB_STAGING="$(grep -E '^DATABASE_URL_LOCAL_BACKUP=' backend/.env.staging | cut -d= -f2- | tr -d '"')"
[ -z "$DB_STAGING" ] && DB_STAGING="$(grep -E '^DATABASE_URL_LOCAL_BACKUP=' backend/.env | cut -d= -f2- | tr -d '"')"

SNAP=$(ls -t database/backups/backup_staging_pre_sync_*.dump | head -1)
echo "Restaurando: $SNAP"

# Pré-drop do event trigger (mesmo quirk do sync, se o snapshot ainda o tiver)
psql "$DB_STAGING" -c "DROP EVENT TRIGGER IF EXISTS ensure_rls;" >/dev/null 2>&1 || true

# Capturar o exit ANTES de filtrar (com pipe, $? seria do head/grep)
LOG=$(mktemp)
pg_restore --dbname="$DB_STAGING" --format=custom --no-owner --no-acl \
    --clean --if-exists "$SNAP" >"$LOG" 2>&1
rc=$?
grep -iE 'error:' "$LOG" | grep -viE 'does not exist|already exists|no matching' | head -10
rm -f "$LOG"
echo "pg_restore exit=$rc (0 = OK; 1 = valide os erros acima)"
```

> Alternativa ao `--clean` (mais cirúrgica): `DROP SCHEMA IF EXISTS staging CASCADE; DROP SCHEMA IF EXISTS mart CASCADE;` + `pg_restore` SEM `--clean` (só recria staging/mart e objetos ausentes, preservando `public.*` do local).

### 3.2 Restaurar apenas dados (sem tocar schema)

Se só os dados ficaram errados (ex.: re-sync com dump errado):

```bash
# TRUNCATE + restore de dados do snapshot (preserva schema local)
psql "$DB_STAGING" -v ON_ERROR_STOP=1 -c \
  "DO \$\$ DECLARE r record; BEGIN
     FOR r IN SELECT schemaname, tablename FROM pg_tables
              WHERE schemaname IN ('staging','mart') LOOP
       EXECUTE format('TRUNCATE TABLE %I.%I CASCADE', r.schemaname, r.tablename);
     END LOOP;
   END \$\$;"
pg_restore --dbname="$DB_STAGING" --format=custom --no-owner --no-acl \
    --data-only "$SNAP"
```

---

## 4. Validação pós-rollback (obrigatória)

```bash
DB_STAGING="$(grep -E '^DATABASE_URL_LOCAL_BACKUP=' backend/.env | cut -d= -f2- | tr -d '"')"

# (a) Contagens restauradas (conferir com o log do backup pré-sync)
psql "$DB_STAGING" -c "
  SELECT 'fact=' || COUNT(*) FROM staging.fact_precos_mensais
  UNION ALL SELECT 'dim_produto=' || COUNT(*) FROM staging.dim_produto
  UNION ALL SELECT 'mv=' || COUNT(*) FROM mart.vw_api_produtos_sazonalidade;"

# (b) Regra de Ouro NO GRAY / NO NULL
psql "$DB_STAGING" -tA -c \
  "SELECT count(*) FROM mart.vw_api_produtos_sazonalidade WHERE status_cor IS NULL OR status_cor='CINZA';"
# → esperado: 0

# (c) V23 (piso 2023+) presente? (validação FUNCIONAL — o marcador textual é case-sensitive quebrado)
psql "$DB_STAGING" -tA -c \
  "SELECT count(*) FROM mart.vw_api_produtos_sazonalidade WHERE tipo_dado='FALLBACK_DIMENSAO' AND ano_referencia IS NOT NULL AND ano_referencia < 2023;"
# → esperado: 0

# (d) Schemas vitais preservados
psql "$DB_STAGING" -tA -c "SELECT count(*) FROM ops.config_agente;"
# → esperado: > 0

# (e) Smoke do guardião (sobe backend temporário contra o local)
SMOKE_START_BACKEND=1 SMOKE_WAIT=90 bash scripts/smoke_staging.sh 2>&1 | tail -8
```

---

## 5. Checklist do administrador

- [ ] Backup pré-sync do destino existe antes de todo sync novo (`backup_staging_pre_sync_*.dump`)
- [ ] `--dry-run` sempre antes do sync completo (valida conectividade + plano)
- [ ] Sync concluído com `exit 0` ou com erros 100% benignos (filtro da seção 2)
- [ ] Validação pós-sync executada (seção 4 — contagens + NO GRAY/NO NULL + V23 + ops preservados)
- [ ] Purge do cache da API pós-sync: `curl -s -X POST 'http://localhost:8000/api/v1/admin/cache/clear' -H "X-API-Key: ${CACHE_PURGE_KEY:-qc_cache_purge_2026}"`
- [ ] Falha crítica → rollback (seção 3) + validação (seção 4) + causa raiz documentada antes de re-sync

---

## 6. Lições registradas (2026-08-12)

1. **`ensure_rls` é legado Supabase, ausente no Aiven** (`docs/HANDOFF_MIGRACAO_AIVEN.md`): exigia superuser e foi excluído de propósito do restore Aiven. O sync deixa o local **idêntico ao Aiven** (função `rls_auto_enable` presente, event trigger ausente) — comportamento desejado, não bug.
2. **O dump de schema em `.sql` via psql conflitava** com schemas preservados no destino (ex.: `CREATE SCHEMA audit`) — por isso o restore foi unificado em **um único `pg_restore --clean --if-exists`** com o dump custom.
3. **Filtro de erro do pg_restore** usa `pg_restore: error:` (minúsculo) — o prefixo `ERROR` maiúsculo do psql não se aplica a ele.
4. **Dump-vazio aborta o sync** (hardening): nunca prossegue com schema/dados vazios (evita destruir a homologação com snapshot truncado de origem).
