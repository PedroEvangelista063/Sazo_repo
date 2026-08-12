# summary.md — /scripts (Automação)

> 📦 **Repositório (2026-08-07):** `PedroEvangelista063/Sazo_repo` — renomeado de `Quero_Comprar_ext` (a URL antiga redireciona).

## Propósito

Scripts de automação do ambiente de desenvolvimento, deploy e manutenção do projeto Quero Comprar VG.

## Mudanças Recentes (2026-08-12)

### Guardiões do Git + DB Sync CLI (FASE 3/4 — Dual-Environment)

- `guard_commit.sh` (novo) — guardião do pre-commit: `tsc --noEmit` + smoke de homologação.
- `smoke_staging.sh` (novo) — smoke: backend `/health` (sobe uvicorn temporário se offline), `/br-sazonalidade` sem 500 e sem `status_cor` nulo/CINZA (NO GRAY/NO NULL).
- `guard_push.sh` (novo) — garantia final do pre-push: guard_commit + pytest (backend) + vitest (frontend).
- `sync_db_prod_to_staging.sh` (novo) — Produção (Aiven) ➔ Homologação (físico/local): dump seletivo (exclui `ops.*`/`raw.*`), `--dry-run`, `--truncate-only`, `--no-dump`, `--refresh-mv`, `--force`; recusa destino não-local.
- Hooks `.husky/pre-commit` (atualizado) e `.husky/pre-push` (novo) chamam os guards. Bypasses: `SKIP_TSC`, `SKIP_STAGING_SMOKE`, `SKIP_PUSH_TESTS`, `SKIP_GUARD_COMMIT/PUSH`.

## Mudanças Recentes (2026-08-11)

### Nenhuma mudança neste lote

- Lote `2026-08-11` concentrado em `database/`, `frontend/` e `backend/` (deep fallback V22/V23, quality gates, claymorphism UI, PWA). /scripts inalterado.

## Mudanças Recentes (2026-08-07)

### Nenhuma mudança neste lote (FASE 1/2)

- Lote `08e87f6d` concentrado em `pipeline/`, `database/` e `query_DBA/` (malha fina de preço, bloqueio de órfãos, expurgo de fantasmas, kit DBA). /scripts inalterado.

## Mudanças Recentes (2026-08-03)

### Purga de cache pós-deploy (deploy_v13_prod.sh)

- `scripts/deploy_v13_prod.sh` — novo passo 9: dispara `POST /admin/cache/clear` (endpoint protegido por API key) após REFRESH MV + pipeline, para que o próximo GET traga dados frescos da MV V17 (`ano_referencia`/`tipo_dado`).
- Endpoint/configuráveis via env: `CACHE_PURGE_URL` (default `http://localhost:8000/api/v1/admin/cache/clear`) e `CACHE_PURGE_KEY` (default `qc_cache_purge_2026`).
- HTTP 200 = sucesso; senão loga AVISO com instrução de purge manual.

### Novo script: `sync_conab_local_to_remote.sh`

- Replica a carga CONAB executada no banco LOCAL (enquanto o Supabase remoto estava em hot standby 57P03) para o remoto quando este voltar:
  1. `pg_dump` local das dimensões + fato (`staging.dim_produto`, `staging.dim_localidade`, `staging.fact_precos_mensais`);
  2. `pg_restore --clean` no remoto (conflitos de PK ignorados);
  3. `CALL staging.sp_executar_carga_completa()` no remoto (ciclo medalhão + MV);
  4. Backfill de transparência (63) idempotente — seta `ano_referencia`, `idade_dado_anos`, `tipo_dado`, `metadado_transparencia`, `preco_exibido`;
  5. Refresh MV `vw_api_produtos_sazonalidade`;
  6. Validação final (contagens fact/sazonalidade/mv) + lembrete de purge de cache da API.
- Uso: `DATABASE_URL_REMOTO="postgresql://..." ./scripts/sync_conab_local_to_remote.sh` (env `DATABASE_URL` ou `backend/.env` para a URL local).

### Novo script: `verify_synthetic_off.sql`

- Script RED/GREEN (TDD) que prova que as engines sintéticas estão DESATIVADAS e a migração 63 aplicada:
  - (a) `pg_proc` — `sp_executar_carga_completa` NÃO contém `CALL` ativo para `sp_calcular_forecast_2026_v13` nem `sp_project_sandwich_prices_2026` (regex exige `CALL` no início da linha — `-- CALL` comentado não casa);
  - (b) `pg_constraint` — sobrevivência de `uq_sazonalidade`, `uq_sazonalidade_data_ref`, `chk_sazonalidade_tipo_dado`, `chk_data_ref_ano_mes`;
  - (c) MV V17 — branch B só em ano atual com `ano_referencia < ANO_ATUAL`, sem duplicatas `(id_produto, id_localidade, ano, mes)`, colunas de transparência presentes; blocker REL-01: **0 linhas com `status_cor NULL`** na MV;
  - (d) assertions de arquivo (grep) para database/63 e supabase/000021.
- Qualquer assertion violada → `RAISE EXCEPTION` → psql exit != 0.

## Scripts

### `sync_db_remote_to_local.sh` — Remote ➔ Local Snapshot Sync

**Criado em:** 2026-07-25 (FASE 2 da Arquitetura Híbrida)

**Propósito:** Espelha o banco REMOTO (Supabase, primary/active) para o banco LOCAL (PostgreSQL nativo no Linux Mint, cold-standby).

**Uso:**

```bash
bash scripts/sync_db_remote_to_local.sh              # só gera backups
bash scripts/sync_db_remote_to_local.sh --restore     # gera + restaura local
bash scripts/sync_db_remote_to_local.sh --schema-only # só schema DDL
bash scripts/sync_db_remote_to_local.sh --data-only   # só dados
```

**O que faz:**

1. Lê `DATABASE_URL_ETL` e `DATABASE_URL_LOCAL_BACKUP` de `backend/.env`
2. Gera `database/backups/backup_schema_latest.sql` (DDL, 184 objetos, excluindo schemas do Supabase)
3. Gera `database/backups/backup_data_latest.dump` (custom format, 1.6MB, excluindo logs e raw)
4. `--restore`: limpa schemas `staging`/`mart`/`ops` locais → aplica schema → restaura dados
5. Limpeza automática de backups >30 dias

**Segurança:**

- NUNCA faz o caminho inverso (Local ➔ Remote)
- Usa `--exclude-schema` para pular `auth`, `storage`, `realtime`, `vault`, etc.
- Exclui tabelas de log: `ops.audit_logs`, `ops.audit_llm_queries`, `ops.quarentena_coleta`, `raw.*`
- Backups salvos em `database/backups/` (gitignored)

### `setup_organism.sh` — Setup inicial do ambiente

Script de bootstrap do projeto (instala dependências, configura hooks, etc.)

### `restore/` — Scripts de restore da migração Supabase

Conjunto de scripts Python usados na migração inicial dos dados locais para o Supabase remoto (2026-07-17).

## NPM Scripts Relacionados

```json
{
  "db:backup": "bash scripts/sync_db_remote_to_local.sh",
  "db:backup:restore": "bash scripts/sync_db_remote_to_local.sh --restore",
  "db:backup:schema": "bash scripts/sync_db_remote_to_local.sh --schema-only",
  "db:backup:data": "bash scripts/sync_db_remote_to_local.sh --data-only",
  "db:test:local": "DATABASE_URL=$DATABASE_URL_LOCAL_BACKUP python -m pytest tests/ -v",
  "db:test:remote": "DATABASE_URL=$DATABASE_URL python -m pytest tests/ -v"
}
```
