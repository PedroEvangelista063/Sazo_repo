# summary.md — /utilities

## Propósito

Ferramentas CLI autônomas para diagnóstico, auditoria, validação E2E e verificação de health-check. Scripts descartáveis e de uso único — sem lógica compartilhada com o pipeline principal.

## Stack

Python 3.13+, asyncpg, httpx, argparse (ou entrada via env vars).

## Regras de Ouro

1. **Autônomo**: cada script deve funcionar isoladamente. Sem imports cruzados entre scripts de /utilities.
2. **Diagnóstico, não Produção**: esses scripts NUNCA são chamados pelo pipeline ou pela API. Exclusivamente para uso manual em CLI.
3. **Sem Side Effects Permanentes**: scripts de `_check_*`, `validate_*`, `audit_*` devem ser read-only por padrão. Qualquer escrita deve ser explícita via flag `--apply`.

## Mudanças Recentes (2026-08-07)

### Nenhuma mudança neste lote (FASE 1/2)

- Lote `08e87f6d` concentrado em `pipeline/`, `database/` e `query_DBA/` (malha fina de preço, bloqueio de órfãos, expurgo de fantasmas, kit DBA). /utilities inalterado.

## Mudanças Recentes (2026-08-03)

### Backup Local Versionado (backup_local_db.sh)

- `utilities/backup_local_db.sh` (novo, commit `40ae5bff`) — backup do PostgreSQL local (`quero_comprar`) com `pg_dump -Fc`:
  - Lê a DSN de `DATABASE_URL_PRIMARY` (ou `DATABASE_URL`) do `backend/.env`, ou da env var `DATABASE_URL` (override via `DATABASE_URL="..." utilities/backup_local_db.sh`).
  - Gera `database/backups/quero_comprar-<timestamp>.dump` (diretório gitignored) e mantém apenas os últimos K backups (`BACKUP_KEEP`, default 5) — retenção automática de históricos.
  - Exit 0 = OK; exit 1 = erro (DSN ausente, `pg_dump` falhou).

### Auditoria Full-Stack (audit_full_stack.py)

- `utilities/audit_full_stack.py` (novo, commit `dfc489d4`) — auditoria de integridade do banco PRIMARY/fallback + API + frontend, sem expor segredos (lê URLs do `backend/.env`):
  1. Banco **PRIMARY** (local) — conexão, contagens-chave (`mart.sazonalidade_produto`, MV `vw_api_produtos_sazonalidade`, `staging.fact_precos_mensais`, `ops.audit_logs`), MV populada e frescor (max ano/mês);
  2. Banco **FALLBACK** (remoto) — conexão e leituras (funciona mesmo em read-only; aviso se `DATABASE_URL_FALLBACK` vazio);
  3. **API** — `/health` (db_mode) + 1 endpoint (`/br-sazonalidade?ano=2025`), ignorável se backend offline (`--no-api`);
  4. **Frontend** — roda `npm test` (vitest) em `frontend/` (`--no-frontend` para pular).
  - Exit 0 = tudo OK; exit 1 = alguma checagem falhou.

### Keep-Alive Supabase (supabase_keep_alive.py + github_supabase_ping.py)

- `utilities/supabase_keep_alive.py` (novo, commit `1a540641`) — keep-alive para a instância Supabase free (evita pause por inatividade):
  - Loop infinito com ping `SELECT 1;` a cada 300s (modo serviço via systemd/nohup); `--once` para uma única execução (modo cron).
  - Resolve a URL: env → `backend/.env` (via python-dotenv) → `DATABASE_URL` → `DATABASE_URL_PRIMARY` → `DATABASE_URL_API`. Erros transitórios NÃO derrubam o script; encerramento gracioso em SIGINT/SIGTERM.
- `utilities/github_supabase_ping.py` (novo, commit `1a540641`) — ping único para o GitHub Actions:
  - Lê `DATABASE_URL` SOMENTE do ambiente (injetada pelo workflow `supabase_keep_alive.yml` a partir do secret `SUPABASE_DATABASE_URL`); conecta, executa `SELECT 1;` e encerra.
  - Exit 0 = sucesso; exit 1 = falha (job do GH Actions marcado como falho).

## Mapa Rápido

- `_check_db.py` — verifica conexão e estado do banco
- `_check_pos_scraping.py` — valida dados pós-coleta
- `_check_cols.py` — diagnóstico de colunas nas tabelas
- `_check_migration_15.py` — valida migração 15 aplicada
- `_check_pos_migration.py` — sanity check pós-migração
- `_debug_single_uf.py` — debug de coleta para uma UF específica
- `_fix_mv.py` — correção de materialized view
- `_fix_mv_migration_15.py` — hotfix MV para migração 15
- `_test_agregador.py` — teste isolado de agregador
- `audit_full.py` — auditoria completa (cobertura, consistência)
- `audit_full_stack.py` — auditoria full-stack (banco primary/fallback + API + vitest)
- `backup_local_db.sh` — backup local versionado (`pg_dump -Fc` + retenção K)
- `supabase_keep_alive.py` — keep-alive Supabase (ping 300s; `--once` p/ cron)
- `github_supabase_ping.py` — ping único para GitHub Actions (env `DATABASE_URL`)
- `validate_e2e.py` — teste end-to-end (insere dado fake, verifica fluxo)
- `teste_apication/` — testes de aplicação (seasonality, baseline)
  - `backend/` — testes de conexão com backend
  - `pipeline/` — testes de ingestão, transform, seasonality, baseline
  - `root/` — testes avulsos (ex: CEPEA)
  - `scraper/` — testes de coleta por micro-motor

## Validação de Forecast

- `database/scripts/validar_forecast.py` — script de validação do modelo forecast (matriz densidade, gaps 2026, sem regressão, confiança baseline, MV)
- Executado manualmente em CLI após recálculo do baseline
- Exit 0 se OK, 1 se falha
- Valida também as colunas novas: `baseline_confianca`, `forecast_method`, `tendencia_futura`
