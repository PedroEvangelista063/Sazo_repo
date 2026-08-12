# Runbook — Migration 80 (Deep Fallback Janela 2023+, MV V23) — LOCAL + AIVEN

> Data: 2026-08-12 · Migration: `database/80_mv_fallback_janela_2023.sql`
> Escopo: aplicação e validação **nos dois bancos** — local (`quero_comprar`,
> localhost:5432) e Aiven (PRIMARY). Difere do runbook da 78 (que era
> local-only): a 80 está pendente também no remoto.

---

## 0. Mapa do ambiente (fatos confirmados em 2026-08-12)

| Item                  | Valor                                                                                     |
| --------------------- | ----------------------------------------------------------------------------------------- |
| **Banco local**       | `postgresql://postgres:…@localhost:5432/quero_comprar` — PostgreSQL 18.4 nativo (host)    |
| **Aiven (PRIMARY)**   | `sazo-db001-pedroedu0-a833.h.aivencloud.com:26536/defaultdb` (sslmode=require)            |
| **MV antes da 80**    | V22 (Deep Fallback, migration 78), 177.485 linhas, piso de ano **ausente**                |
| **MV depois da 80**   | V23 (janela histórica 2023+), 177.485 linhas, piso `h.ano >= Ano Atual − 3` no LATERAL hh |
| **Convenção backups** | `database/backups/*.dump` (gitignored)                                                    |

> ✅ **Já aplicado neste runbook (2026-08-12)**: migration 80 executada e validada
> em LOCAL e AIVEN (backups `backup_*_80_pre_*` em `database/backups/`), piso
> funcional nos dois bancos (0 âncoras `ano_referencia < 2023`).

---

## 1. O que a migration 80 (V23) faz

- Recria a MV `mart.vw_api_produtos_sazonalidade` (`DROP ... CASCADE` +
  `CREATE MATERIALIZED VIEW ... WITH DATA` — **popula na criação**; não inclui
  `REFRESH`, padrão 78).
- Adiciona o **piso deslizante** no `LEFT JOIN LATERAL hh` do Deep Fallback:
  ```sql
  AND h.ano >= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 3   -- hoje: 2023..2025
  ```
  Nenhuma âncora de projeção anterior a **Ano Atual − 3** (evita defasagem
  elevada + inflação acumulada de 2021/2022).
- Branches A/B/C, contrato da API e `fn_br_nacional_sazonalidade` **inalterados**
  (a fn já foi atualizada na 79).

---

## 2. Preparação

```bash
cd /home/pedroeduardo/projetos/quero_comprar_vg

# LOCAL
export DB_LOCAL="$(grep -E '^DATABASE_URL_LOCAL_BACKUP=' backend/.env | cut -d= -f2- | tr -d '"')"
psql "$DB_LOCAL" -Atc 'SELECT 1;'

# AIVEN (sem expor senha no histórico de shell)
set -a; source backend/.env; set +a
export DB_AIVEN="${DATABASE_URL_PRIMARY:-$DATABASE_URL}"
psql "$DB_AIVEN" -Atc 'SELECT 1;'
```

---

## 3. Backup de segurança (ANTES de qualquer alteração — nos DOIS bancos)

```bash
TS=$(date +%Y%m%d_%H%M%S)
mkdir -p database/backups

# (a) Checksum da migration — integridade do artefato
sha256sum database/80_mv_fallback_janela_2023.sql | tee database/backups/80_mv_fallback_janela_2023.sha256

# (b) LOCAL: dump schema + MV (usado no rollback)
pg_dump "$DB_LOCAL" -Fc -s -f "database/backups/backup_schema_80_pre_${TS}.dump"
pg_dump "$DB_LOCAL" -Fc -t 'mart.vw_api_produtos_sazonalidade' -f "database/backups/backup_mv_80_pre_${TS}.dump"

# (c) AIVEN: idem (pode demorar no plano free — usar timeout generoso)
pg_dump "$DB_AIVEN" -Fc -s -f "database/backups/backup_schema_80_pre_aiven_${TS}.dump"
pg_dump "$DB_AIVEN" -Fc -t 'mart.vw_api_produtos_sazonalidade' -f "database/backups/backup_mv_80_pre_aiven_${TS}.dump"
```

> Checksum real do arquivo (2026-08-12):
> `2c5eb33f9d0ff64cebc3df98c50fcac38aa74a5950acc1c4d2962e9df6587e6a`

---

## 4. Aplicação (LOCAL primeiro, depois AIVEN)

```bash
# LOCAL
psql "$DB_LOCAL" -v ON_ERROR_STOP=1 -f database/80_mv_fallback_janela_2023.sql

# AIVEN (a CREATE WITH DATA da MV grande pode demorar no free — aguardar)
psql "$DB_AIVEN" -v ON_ERROR_STOP=1 -f database/80_mv_fallback_janela_2023.sql
```

Saída esperada no final de cada execução (prova embutida da migration):

```
NOTICE:  QG-80: MV=177485 FALLBACK=18487 projecao_janela_2023=425
DO
COMMIT
```

> `CREATE MATERIALIZED VIEW ... WITH DATA` já popula a MV — **não é preciso
> REFRESH adicional**. (O refresh de segurança `REFRESH MATERIALIZED VIEW
mart.vw_api_produtos_sazonalidade` é opcional/redundante.)

---

## 5. Validação — funcional (a correta!)

> ⚠️ **Não usar** `position('YEAR FROM CURRENT_DATE' in definition)` como
> marcador: o deparser do PostgreSQL normaliza para `EXTRACT(year FROM
CURRENT_DATE)` com `CURRENT_DATE` em MAIÚSCULAS — o marcador do relatório
> (case-sensitive) retorna 0 mesmo com V23 aplicada. **A validação definitiva é
> funcional** (âncoras < 2023 = 0).

```sql
-- (a) PROVA FUNCIONAL: nenhuma âncora de projeção anterior a 2023 (esperado 0)
SELECT count(*) FROM mart.vw_api_produtos_sazonalidade
 WHERE tipo_dado = 'FALLBACK_DIMENSAO' AND ano_referencia IS NOT NULL
   AND ano_referencia < 2023;

-- (b) Piso ativo nas projeções futuras (esperado 2023)
SELECT min(ano_referencia) FROM mart.vw_api_produtos_sazonalidade
 WHERE tipo_dado = 'FALLBACK_DIMENSAO' AND ano = 2026 AND mes BETWEEN 9 AND 12;

-- (c) Regra de Ouro NO GRAY/NO NULL (esperado 0)
SELECT count(*) FROM mart.vw_api_produtos_sazonalidade
 WHERE status_cor IS NULL OR status_cor = 'CINZA';

-- (d) Contagem (esperado 177.485 — o piso muda âncoras, não o nº de linhas)
SELECT count(*) FROM mart.vw_api_produtos_sazonalidade;

-- (e) Amostra visual (mensagem de projeção com âncora 2023)
SELECT produto, uf, mes, status_cor, ano_referencia, mensagem_transparencia
  FROM mart.vw_api_produtos_sazonalidade
 WHERE tipo_dado = 'FALLBACK_DIMENSAO' AND ano = 2026 AND mes = 9
 ORDER BY produto LIMIT 10;
```

**Resultados reais (2026-08-12, LOCAL e AIVEN idênticos):**

| Checagem                         | LOCAL   | AIVEN   |
| -------------------------------- | ------- | ------- |
| Âncoras FALLBACK < 2023          | 0       | 0       |
| min(ano_referencia) set–dez 2026 | 2023    | 2023    |
| status_cor nulo/CINZA            | 0       | 0       |
| MV count                         | 177.485 | 177.485 |

---

## 6. Sincronia Local × Aiven + purge de cache da API

```sql
-- LOCAL e AIVEN (idênticos esperados)
SELECT (SELECT COUNT(*) FROM mart.vw_api_produtos_sazonalidade) AS mv_rows,
       (SELECT refreshed_at FROM audit.mv_refresh_log ORDER BY refreshed_at DESC LIMIT 1) AS refreshed_at;
```

Purge do cache da API (in-memory — com o backend de pé; se estiver parado,
o próximo startup já sobe com cache limpo):

```bash
curl -s -X POST 'http://localhost:8000/api/v1/admin/cache/clear' \
  -H "X-API-Key: ${CACHE_PURGE_KEY:-qc_cache_purge_2026}"
# HTTP 200 = cache limpo; o próximo GET do frontend lê a MV V23
```

---

## 7. Rollback (contingência)

```bash
TS=...   # mesmo timestamp dos dumps da seção 3

# Restaura a MV V22 pré-80 (definição + dados + índices); --clean derruba a V23
pg_restore --clean --if-exists -d "$DB_LOCAL" "database/backups/backup_mv_80_pre_${TS}.dump"
psql "$DB_LOCAL" -c 'REFRESH MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade;'

# AIVEN: idem com os dumps *aiven*
pg_restore --clean --if-exists -d "$DB_AIVEN" "database/backups/backup_mv_80_pre_aiven_${TS}.dump"
```

Verificação pós-rollback: a checagem funcional (5a) volta a mostrar âncoras
< 2023 > 0 (ex.: 2021/2022) — indicando que o piso saiu.

---

## 8. Gotchas registrados (2026-08-12)

1. **Marcador case-sensitive quebra**: `position('YEAR FROM CURRENT_DATE' in
definition)` retorna 0 mesmo com V23 aplicada (deparser normaliza para
   `EXTRACT(year FROM CURRENT_DATE)`). Usar a validação funcional da seção 5.
2. **`CREATE WITH DATA` no Aiven free**: a criação da MV (~177k linhas) demora
   mais que o limite de statement do plano (que derruba `REFRESH MV
CONCURRENTLY` em ~25s). A migration 80 rodou OK via psql com timeout
   generoso; se estourar, repetir (transação única — nada persiste).
3. **Backups do Aiven demoram** (~minutos no free): usar timeout ≥ 300s nos
   `pg_dump`/`psql` remotos.

---

## 9. Integração com o Dual-Environment (FASE 2)

- O **sync Produção ➔ Homologação** (`scripts/sync_db_prod_to_staging.sh`)
  espelha a MV V23 do Aiven no local — rodar após a aplicação da 80 nos dois
  bancos para manter a homologação com dados frescos e a mesma definição de MV.
- O **smoke de homologação** (`scripts/smoke_staging.sh`, gate do pre-commit)
  valida `/br-sazonalidade` sem HTTP 500 e sem `status_cor` nulo/CINZA — após
  a 80, continuou PASS (grade com 352 produtos).
