# Runbook — Migration 78 (Deep Fallback) no ambiente LOCAL

> Data: 2026-08-11 · Autor: DBA (via auditoria E2E) · Migration: `database/78_deep_fallback_historico.sql`
> Escopo: aplicação e validação **no banco local** (`quero_comprar`, localhost:5432). O Aiven (PRIMARY) não é tocado neste runbook.

---

## 0. Mapa do ambiente (fatos confirmados)

| Item                     | Valor                                                                                                       |
| ------------------------ | ----------------------------------------------------------------------------------------------------------- |
| **Banco local (alvo)**   | `postgresql://postgres:…@localhost:5432/quero_comprar` — PostgreSQL 18.4 nativo (host)                      |
| **Container Docker**     | `qcomprar-pg-backup` (postgres:17) na porta 5433 — NÃO é o alvo                                             |
| **Aiven (PRIMARY)**      | `sazo-db001-pedroedu0-a833.h.aivencloud.com:26536/defaultdb` (sslmode=require) — não é tocado neste runbook |
| **Função atual**         | `mart.fn_br_nacional_sazonalidade(p_ano integer, p_categoria text, p_min_ufs integer)` — 3 args             |
| **MV atual**             | 177.485 linhas; refresh local stale (2026-08-08) vs Aiven fresh (2026-08-11 16:03 GMT)                      |
| **Convenção de backups** | `database/backups/*.dump` (gitignored; já existe `backup_quero_comprar_pre_migracao.dump`)                  |

---

## 1. Preparação

```bash
cd /home/pedroeduardo/projetos/quero_comprar_vg

# Constrói a string de conexão local a partir do .env SEM expor a senha
export DB_LOCAL="$(grep -E '^DATABASE_URL_LOCAL_BACKUP=' backend/.env | cut -d= -f2- | tr -d '"')"

# Prova de conectividade (deve imprimir "1")
psql "$DB_LOCAL" -Atc 'SELECT 1;'
```

---

## 2. Backup de segurança (ANTES de qualquer alteração)

```bash
TS=$(date +%Y%m%d_%H%M%S)
mkdir -p database/backups

# (a) Checksum da migration — integridade do artefato a aplicar
sha256sum database/78_deep_fallback_historico.sql | tee database/backups/78_deep_fallback_historico.sha256

# (b) Dump SCHEMA completo (custom) — segurança total
pg_dump "$DB_LOCAL" -Fc -s -f "database/backups/backup_schema_78_pre_${TS}.dump"

# (c) Dump da MV (schema + DADOS) — o único objeto pesado; usado no rollback
pg_dump "$DB_LOCAL" -Fc -t 'mart.vw_api_produtos_sazonalidade' \
  -f "database/backups/backup_mv_78_pre_${TS}.dump"

# (d) Definição textual da função (belt-and-braces)
psql "$DB_LOCAL" -Atc \
  "SELECT pg_get_functiondef(f.oid) || E'\n'
     FROM pg_proc f JOIN pg_namespace n ON n.oid = f.pronamespace
    WHERE n.nspname = 'mart' AND f.proname = 'fn_br_nacional_sazonalidade';" \
  > "database/backups/fn_br_nacional_sazonalidade_78_pre_${TS}.sql"

# (e) Sanidade dos dumps
pg_restore -l "database/backups/backup_mv_78_pre_${TS}.dump" | head -20
```

**Pré-cheque CASCADE** (o que o `DROP MATERIALIZED VIEW ... CASCADE` derrubaria):

```sql
WITH mv AS (
  SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'mart' AND c.relname = 'vw_api_produtos_sazonalidade'
)
SELECT pg_describe_object(d.classid, d.objid, d.objsubid) AS dependente, d.deptype
  FROM pg_depend d, mv
 WHERE d.refclassid = 'pg_class'::regclass AND d.refobjid = mv.oid
   AND d.deptype IN ('a','i','n');
```

Resultado esperado: apenas os 7 índices da própria MV (deptype `i`). Se aparecer qualquer objeto normal (`n`), PARE.

---

## 3. Aplicação

```bash
psql "$DB_LOCAL" -v ON_ERROR_STOP=1 -f database/78_deep_fallback_historico.sql
```

Saída esperada no final:

```
NOTICE:  QG-78: MV=... FALLBACK=... deep_fallback_projetado=... fn_br_nacional_sem_limit=...
COMMIT
```

**Pós-aplicação (crítico):** a MV recriada pode estar vazia (depende de `WITH NO DATA`). Refrescar antes de ler:

```bash
psql "$DB_LOCAL" -c '\timing on' -c 'REFRESH MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade;'
```

> O `main.py` do backend também refresca no startup e limpa o cache — o refresh manual é para validação controlada.

---

## 4. Validação rápida

```bash
psql "$DB_LOCAL" -c '\df mart.fn_br_nacional_sazonalidade'
psql "$DB_LOCAL" -c 'SELECT COUNT(*) FROM mart.vw_api_produtos_sazonalidade;'
```

**Deep Fallback — `mensagem_transparencia` e `ano_referencia`:**

```sql
SELECT tipo_dado,
       COUNT(*)                                                  AS total,
       COUNT(*) FILTER (WHERE mensagem_transparencia IS NOT NULL) AS com_mensagem
  FROM mart.vw_api_produtos_sazonalidade
 GROUP BY tipo_dado
 ORDER BY tipo_dado;

-- projeções históricas: esperado ≈ 9.055 linhas (meses futuros set–dez 2026)
SELECT COUNT(*) AS projetadas_historico
  FROM mart.vw_api_produtos_sazonalidade
 WHERE tipo_dado = 'FALLBACK_DIMENSAO'
   AND ano = 2026 AND mes BETWEEN 9 AND 12
   AND mensagem_transparencia LIKE 'Projecao sazonal baseada no historico de %';

-- amostra visual (status_cor agora vem do histórico/baseline, não 'AMARELO' fabricado)
SELECT produto, uf, mes, status_cor, ano_referencia, mensagem_transparencia
  FROM mart.vw_api_produtos_sazonalidade
 WHERE tipo_dado = 'FALLBACK_DIMENSAO' AND ano = 2026 AND mes = 9
 ORDER BY produto LIMIT 10;
```

**Paginação push-down:**

```sql
-- 5 produtos × 12 meses ≤ 60 linhas (página por PRODUTO)
SELECT COUNT(*), COUNT(DISTINCT produto) FROM mart.fn_br_nacional_sazonalidade(2025, NULL, 1, 5, 0);

-- total real (sem paginação): ~350 produtos
SELECT COUNT(DISTINCT produto) FROM mart.fn_br_nacional_sazonalidade(2025, NULL, 1, NULL, 0);

-- prova de custo: página 1 vs página 30
\timing on
SELECT * FROM mart.fn_br_nacional_sazonalidade(2025, NULL, 1, 100, 0);
SELECT * FROM mart.fn_br_nacional_sazonalidade(2025, NULL, 1, 100, 3000);
```

---

## 5. Sincronia FastAPI (após subir o backend)

| Rota                                                          | Objeto lido                                 | Fonte                    |
| ------------------------------------------------------------- | ------------------------------------------- | ------------------------ |
| `GET /api/v1/categorias`                                      | `mart.vw_categorias`                        | categorias.py:22         |
| `GET /api/v1/municipios`                                      | `mart.vw_municipios`                        | municipios.py:13         |
| `GET /api/v1/fluxos`                                          | `staging.vw_fluxos_regionais`               | fluxos.py:28             |
| `GET /api/v1/sazonalidade`, `/{uf}/{municipio}`, `/com-preco` | `mart.vw_api_produtos_sazonalidade` (MV)    | produtos.py:351/528/1011 |
| `GET /api/v1/sazonalidade/br-sazonalidade`                    | `mart.fn_br_nacional_sazonalidade` (5 args) | produtos.py:1099         |

```bash
curl -s 'http://localhost:8000/api/v1/sazonalidade/br-sazonalidade?ano=2026&por_pagina=5' | python3 -m json.tool | head -40
curl -sI 'http://localhost:8000/api/v1/sazonalidade/br-sazonalidade?ano=2026&por_pagina=5' | grep -iE 'x-cache-status|x-last-refresh|content-length'
```

---

## 6. Rollback (contingência)

**Falha no meio da aplicação:** nada persiste (transação única). Sem ação.

**Validação reprovou:**

```bash
TS=...   # mesmo timestamp do backup da etapa 2

# (a) Restaura a MV ANTIGA (definição + dados + índices); --clean derruba a nova
pg_restore --clean --if-exists -d "$DB_LOCAL" "database/backups/backup_mv_78_pre_${TS}.dump"

# (b) Deruba a função de 5 args e restaura a de 3 args
psql "$DB_LOCAL" -v ON_ERROR_STOP=1 -c \
  'DROP FUNCTION IF EXISTS mart.fn_br_nacional_sazonalidade(integer, text, integer, integer, integer);'
psql "$DB_LOCAL" -v ON_ERROR_STOP=1 -f "database/backups/fn_br_nacional_sazonalidade_78_pre_${TS}.sql"

# (c) Re-refresca a MV antiga
psql "$DB_LOCAL" -c 'REFRESH MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade;'
```

Verificação pós-rollback: `\df` → 3 args; COUNT → 177.485; coluna `mensagem_transparencia` não existe mais.

---

## 7. Integridade Local × Aiven + governança

```sql
-- LOCAL  (psql "$DB_LOCAL")
SELECT (SELECT COUNT(*) FROM mart.vw_api_produtos_sazonalidade) AS mv_rows,
       (SELECT refreshed_at FROM audit.mv_refresh_log ORDER BY refreshed_at DESC LIMIT 1) AS refreshed_at;

-- AIVEN  (psql "$DATABASE_URL_PRIMARY" — via .env)
SELECT (SELECT COUNT(*) FROM mart.vw_api_produtos_sazonalidade) AS mv_rows,
       (SELECT refreshed_at FROM audit.mv_refresh_log ORDER BY refreshed_at DESC LIMIT 1) AS refreshed_at;
```

⚠️ **Risco de sincronia**: o backend commitado já chama a função de 5 args. Enquanto a 78 não rodar no Aiven, não exponha o backend novo a produção — no Aiven existe só a 3 args (`function does not exist` no `/br-sazonalidade`).
