# PROXIMOS_PASSOS — Migration 80 (Deep Fallback Janela 2023+, MV V23)

> Data: 2026-08-11 · Autor: auditoria dos summary.md + validação runtime (local + Aiven) · Migration: `database/80_mv_fallback_janela_2023.sql`
> Escopo deste relatório: **apenas o que falta fazer** — nada foi alterado no banco nesta auditoria.

---

## 1. Resumo executivo

A migration **80 (V23)** está **commitada no repositório, mas NÃO aplicada em nenhum banco** (validado em 2026-08-11 em LOCAL `localhost:5432` e REMOTO/Aiven `sazo-db001-pedroedu0-a833.h.aivencloud.com:26536`). As migrations 78 (V22, Deep Fallback) e 79 (BR inclui projeção) **já estão aplicadas** nos dois bancos.

**Checklist (status em 2026-08-12):**

| #   | Item                                                                                        | Status                                    |
| --- | ------------------------------------------------------------------------------------------- | ----------------------------------------- |
| 1   | Aplicar `database/80_mv_fallback_janela_2023.sql` no banco **LOCAL**                        | ✅ aplicada                               |
| 2   | Aplicar a mesma migration no **AIVEN (PRIMARY)**                                            | ✅ aplicada                               |
| 3   | Validar o piso 2023+ (funcional) local + remoto                                             | ✅ validado                               |
| 4   | Purge de cache da API após o refresh (para o frontend ver a V23)                            | ✅ backend in-memory (ver nota seção 3.6) |
| 5   | (Recomendado) Criar runbook dedicado da 80 ou estender `docs/runbook_migration_78_local.md` | ✅ `docs/runbook_migration_80_local.md`   |

---

## 2. Estado atual validado (2026-08-11)

Queries read-only executadas via `psql` (local) e `psql "$DATABASE_URL_PRIMARY"` (Aiven, sem expor credenciais):

| Objeto                                                   | LOCAL                                                | AIVEN               | Conclusão                               |
| -------------------------------------------------------- | ---------------------------------------------------- | ------------------- | --------------------------------------- |
| `mart.vw_api_produtos_sazonalidade` (MV)                 | **177.485 linhas**                                   | **177.485 linhas**  | ✅ idênticos; pós quality-gate 76 (V21) |
| Marcador `DEEP_FALLBACK` na definição da MV              | posição 3328                                         | posição 3328        | ✅ **V22 aplicada** (migration 78)      |
| Marcador `PROJECAO_HISTORICA` na definição               | presente                                             | presente            | ✅ V22 aplicada                         |
| Piso `YEAR FROM CURRENT_DATE` na definição               | **ausente** (pos 0)                                  | **ausente** (pos 0) | ❌ **V23 NÃO aplicada** (migration 80)  |
| `fn_br_nacional_sazonalidade` — args                     | `(p_ano, p_categoria, p_min_ufs, p_limit, p_offset)` | idêntico            | ✅ migration 78 (paginação push-down)   |
| `fn_br_nacional_sazonalidade` — cita `FALLBACK_DIMENSAO` | sim (pos 1892)                                       | sim (pos 1892)      | ✅ migration 79 aplicada                |

> **Nota de sincronia**: o backend (commit `245c4155`) já chama a função de 5 args e emite mensagens V22 — como 78/79 estão aplicadas nos dois bancos, não há incompatibilidade pendente nesse ponto. Falta só o piso de ano da 80.

---

## 3. Pendência principal — aplicar a migration 80 (V23)

### 3.1 O que a migration faz (recapitulação)

- Recria a MV `mart.vw_api_produtos_sazonalidade` (**V23**) com `DROP MATERIALIZED VIEW IF EXISTS ... CASCADE` + `CREATE MATERIALIZED VIEW` (padrão `WITH DATA` → populada na criação).
- Adiciona o **piso deslizante** na subconsulta `LEFT JOIN LATERAL hh` do Deep Fallback (V22, 78:338-352):
  ```sql
  AND h.ano >= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 3   -- hoje: 2023..2025
  ```
  Nenhuma âncora de projeção anterior a **Ano Atual − 3** (evita defasagem elevada + inflação acumulada de 2021/2022).
- **NÃO inclui `REFRESH`** (padrão 78: DDL só, refresh posterior via psql).
- Branches A/B/C, contrato da API e `fn_br_nacional_sazonalidade` **inalterados** (a fn já foi alterada na 79 e NÃO é tocada aqui).

### 3.2 Pré-requisitos (antes de qualquer alteração)

```bash
cd /home/pedroeduardo/projetos/quero_comprar_vg
export DB_LOCAL="$(grep -E '^DATABASE_URL_LOCAL_BACKUP=' backend/.env | cut -d= -f2- | tr -d '"')"
psql "$DB_LOCAL" -Atc 'SELECT 1;'   # prova de conectividade → deve imprimir 1

TS=$(date +%Y%m%d_%H%M%S)
mkdir -p database/backups

# (a) Checksum do artefato (sha256 conhecido: 2c5eb33f…7e6a)
sha256sum database/80_mv_fallback_janela_2023.sql | tee database/backups/80_mv_fallback_janela_2023.sha256

# (b) Dump SCHEMA completo (segurança total)
pg_dump "$DB_LOCAL" -Fc -s -f "database/backups/backup_schema_80_pre_${TS}.dump"

# (c) Dump da MV (schema + dados) — usado no rollback
pg_dump "$DB_LOCAL" -Fc -t 'mart.vw_api_produtos_sazonalidade' -f "database/backups/backup_mv_80_pre_${TS}.dump"
```

> ⚠️ O mesmo backup deve ser feito no **AIVEN** antes de aplicar lá (ou confiar em `database/backups/*` mais recente + validação pós-aplicação).

### 3.3 Aplicar no banco LOCAL

```bash
psql "$DB_LOCAL" -v ON_ERROR_STOP=1 -f database/80_mv_fallback_janela_2023.sql
# Refresh de segurança (a CREATE usa WITH DATA; este passo garante consistência)
psql "$DB_LOCAL" -c '\timing on' -c 'REFRESH MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade;'
```

### 3.4 Validar no LOCAL

```bash
# (a) O piso 2023+ deve aparecer na definição (esperado: posição > 0)
psql "$DB_LOCAL" -t -c "SELECT position('YEAR FROM CURRENT_DATE' in definition) FROM pg_matviews WHERE matviewname='vw_api_produtos_sazonalidade'"

# (b) Contagem (esperado: 177.485, mesma de antes — o piso muda âncoras, não o nº de linhas)
psql "$DB_LOCAL" -t -c 'SELECT count(*) FROM mart.vw_api_produtos_sazonalidade;'

# (c) Projeções de set–dez 2026 devem usar âncoras >= 2023 (ano_referencia nunca < 2023)
psql "$DB_LOCAL" -t -c "SELECT min(ano_referencia) FROM mart.vw_api_produtos_sazonalidade WHERE tipo_dado='FALLBACK_DIMENSAO' AND ano=2026 AND mes BETWEEN 9 AND 12;"

# (d) Amostra visual
psql "$DB_LOCAL" -c "SELECT produto, uf, mes, status_cor, ano_referencia, mensagem_transparencia FROM mart.vw_api_produtos_sazonalidade WHERE tipo_dado='FALLBACK_DIMENSAO' AND ano=2026 AND mes=9 ORDER BY produto LIMIT 10;"
```

### 3.5 Aplicar no AIVEN (PRIMARY)

> O runbook da 78 (seção 0) explicitamente NÃO tocava o Aiven; para a 80 o **remoto também está pendente** (validado: piso ausente lá também).

```bash
# Via .env, sem expor a senha no histórico de shell
set -a; source backend/.env; set +a
psql "${DATABASE_URL_PRIMARY:-$DATABASE_URL}" -v ON_ERROR_STOP=1 -f database/80_mv_fallback_janela_2023.sql
psql "${DATABASE_URL_PRIMARY:-$DATABASE_URL}" -c 'REFRESH MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade;'
```

Repetir a seção 3.4 apontando para o AIVEN.

### 3.6 Purge de cache da API (pós-refresh)

```bash
curl -s -X POST 'http://localhost:8000/api/v1/admin/cache/clear' \
  -H "X-API-Key: ${CACHE_PURGE_KEY:-qc_cache_purge_2026}"
# HTTP 200 = cache limpo; o próximo GET do frontend lê a MV V23
```

### 3.7 Sincronia Local × Aiven

```sql
-- LOCAL e AIVEN (idênticos esperados)
SELECT (SELECT COUNT(*) FROM mart.vw_api_produtos_sazonalidade) AS mv_rows,
       (SELECT refreshed_at FROM audit.mv_refresh_log ORDER BY refreshed_at DESC LIMIT 1) AS refreshed_at;
```

### 3.8 Rollback (contingência)

```bash
TS=...   # timestamp dos dumps da seção 3.2
# Restaura a MV V22 pré-80 (definição + dados + índices); --clean derruba a V23
pg_restore --clean --if-exists -d "$DB_LOCAL" "database/backups/backup_mv_80_pre_${TS}.dump"
psql "$DB_LOCAL" -c 'REFRESH MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade;'
# Verificação: o piso YEAR FROM CURRENT_DATE some da definição (pos 0)
```

---

## 4. Outras pendências (fora do escopo da 80)

| #   | Item                                                                                                                 | Status                                                                          | Onde                                                                                              |
| --- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| 1   | **Migration 77** (nomenclatura DBA-friendly) — DRAFT, NÃO aplicada                                                   | ⏳ aguarda backup completo + aprovação do time                                  | `database/77_refatoracao_nomenclatura_dba_friendly.sql`, `docs/auditoria_nomenclatura_2026-08.md` |
| 2   | `query_DBA/07_migrations.sql` **removido** no commit `8f7ea7de` (dependia de `supabase_migrations`, legado Supabase) | ✅ documentado; validar versão da MV via `04_sazonalidade.sql` ou query do piso | `query_DBA/summary.md`                                                                            |
| 3   | Runbook dedicado da 80 (ou extensão do runbook 78 com os passos V23)                                                 | ⏳ recomendado                                                                  | `docs/runbook_migration_78_local.md`                                                              |
| 4   | `query_DBA/conectar_dba.sh` sem bit de execução (uso local via `bash script.sh` ou `chmod +x`)                       | ✅ chmod aplicado localmente; `git core.filemode` pode ignorar na commit        | `query_DBA/conectar_dba.sh`                                                                       |
| 5   | Frontend (círculos claymorphism, abas reordenadas) e summary.md das 9 pastas — **não commitados**                    | ✅ neste commit                                                                 | `frontend/`, `*/summary.md`, `docs/SUMMARY.md`                                                    |

---

## 5. Comandos de validação "prontos" (pós-implementação)

```bash
# V23 aplicada? (esperado > 0 em LOCAL e AIVEN)
bash query_DBA/conectar_dba.sh "SELECT position('YEAR FROM CURRENT_DATE' in definition) AS v23_piso FROM pg_matviews WHERE matviewname='vw_api_produtos_sazonalidade'"
```

---

## 6. Resultado da aplicação (2026-08-12)

Migration 80 **aplicada e validada nos DOIS bancos** seguindo o checklist 3.2–3.8 (backups `backup_*_80_pre_*` em `database/backups/`; checksum `2c5eb33f…7e6a` confere). Validação **funcional** (a correta):

| Checagem                                     | LOCAL   | AIVEN   |
| -------------------------------------------- | ------- | ------- |
| Âncoras FALLBACK `ano_referencia < 2023`     | **0**   | **0**   |
| `min(ano_referencia)` projeções set–dez 2026 | 2023    | 2023    |
| `status_cor` nulo/CINZA                      | 0       | 0       |
| MV count                                     | 177.485 | 177.485 |

> ⚠️ **Correção de marcador**: `position('YEAR FROM CURRENT_DATE' in definition)`
> retorna 0 mesmo com V23 aplicada — o deparser normaliza para `EXTRACT(year
FROM CURRENT_DATE)` (case-sensitive quebrado). **Usar a validação funcional**
> (âncoras < 2023 = 0) — documentado no `docs/runbook_migration_80_local.md` §5.

Pós-aplicação: **sync Produção ➔ Homologação executado** (`scripts/sync_db_prod_to_staging.sh`)
— local espelha o Aiven (MV V23, fact 245.362, sazonalidade 346.961) com
`ops.*`/`raw.*` preservados; smoke do guard PASS pós-sync.

---

## 7. Conclusão

A pendência crítica é **uma**: aplicar a migration 80 nos dois bancos (LOCAL + AIVEN) e validar o piso 2023+. As demais pendências são documentais (runbook da 80) ou de governança (migration 77 aguardando aprovação). Nenhuma mudança de código é necessária — o backend já está alinhado (fn de 5 args + mensagens V22 em produção).

---

## 8. Próximos passos sugeridos (follow-ups)

- [x] **Aplicar a migration 80 (V23)** seguindo o checklist deste relatório (seções 3.2–3.7) — banco **local** e **Aiven**, com backup + validação do piso 2023+ e purge de cache da API. **FEITO em 2026-08-12** (ver seção 6).
- [x] **Criar `docs/runbook_migration_80_local.md`** seguindo o padrão do runbook da 78 (backup, DDL, refresh, validação, rollback). **FEITO** (inclui gotchas: marcador case-sensitive, CREATE WITH DATA no Aiven free).
- [x] **Revisar e aplicar a migration 77** (nomenclatura DBA-friendly) — **HOLD RESOLVIDO e APLICADA nos DOIS bancos (LOCAL + AIVEN) em 2026-08-12**: a 77 foi **reescrita** com wrappers de compatibilidade de 30 dias (BLOCO 4.5, DEFAULTs replicados), guard de idempotência no BLOCO 4 e **corpos chamadores reescritos para os nomes novos (BLOCO 4.6)** — `validar_anomalia_preco` chama `classificar_preco_anomalia` e `consolidar_produtos_duplicados` chama `relatorio_normalizacao_produtos` (wrappers vestigiais, Fase 3 segura). **Validação pós-aplicação nos 2 bancos**: 10 nomes novos + 9 wrappers, MV intacta (177.485), 0 nulo/CINZA, trigger em runtime capturando preço anômalo R$99.999, defaults 0-arg OK, 2ª execução no-op, smoke PASS. **Consistência local×Aiven pós-sync**: idênticos. **Fase 3 agendada**: `database/fase3_drop_compat_77.sql` (guard temporal até 2026-09-30 — validado: aborta antes da data).
- [x] **Fase 2 da auditoria de nomenclatura — subconjunto seguro (migration 81) APLICADO nos DOIS bancos (LOCAL + AIVEN) em 2026-08-12** — ver `docs/auditoria_nomenclatura_2026-08.md` §Fase 2. Renomeadas: 4 funções sem refs em código vivo (`fn_normalizar_nome_produto` → `normalizar_nome_produto`, `fn_estatisticas_volatilidade_24m` → `estatisticas_volatilidade_24m`, `fn_status_cor_zscore` → `calcular_semaforo_preco`, `fn_encontrar_produto_pai` → `encontrar_produto_pai`) + `staging.baseline_2025_interpolado` → `baseline_sazonal_interpolado` + `staging.vw_fluxos_regionais` → `vw_abastecimento_logistico`. **7 corpos PL/pgSQL + 2 views do mart reescritos na mesma transação** (gerados do catálogo, fidelidade 100%); wrappers + views de compat (30 dias); 2ª execução no-op; MV 177.485, 0 nulo/CINZA, smoke PASS, `/fluxos` total=143. **Pendente (não aprovado)**: `raw.coleta_bruta`/`controle_carga`, cadeia sandwich (`fn_fator_sazonal_mensal`, `fn_preco_base_2026`, `fn_sandwich_historical_price`, `fn_status_cor_regra_15/25`), `sp_calcular_sazonalidade` e `mart.fator_kg_produto_uf` (exigem recriação de procedures de produção).
