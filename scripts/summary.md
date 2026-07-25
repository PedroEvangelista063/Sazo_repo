# summary.md — /scripts (Automação)

## Propósito
Scripts de automação do ambiente de desenvolvimento, deploy e manutenção do projeto Quero Comprar VG.

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
