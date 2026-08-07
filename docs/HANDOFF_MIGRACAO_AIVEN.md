# HANDOFF — Migração Supabase → Aiven (continuidade de sessão)

> **⚠️ ATENÇÃO**: Este arquivo contém credenciais reais. **NÃO commitar** — está fora do escopo do versionamento corretivo ainda em aberto. Tratar como sensível.
> **Autor**: gentle-orchestrator | **Data**: 2026-08-03 | **Branch**: `refatoracao-dado-historico/db`
>
> **📌 CONVENÇÃO (preferência do usuário)**: ao final de cada progresso/etapa concluída da migração, **atualizar este documento** (seção 0 — status dos itens + evidências) antes de encerrar o turno.
>
> **⚠️ ATENÇÃO (pivot)**: a partir de 2026-08-03 (2ª parte), o ambiente de DESENVOLVIMENTO é **100% local** (`localhost:5432/quero_comprar`). O Aiven (`pg-2d41b051`) fica como instância remota ociosa (free, 496MB/1GB) — **não confiar nele** (disco limitado, pode virar read-only). Os workflows GitHub (`data_pipeline`, `ingest`, keep-alive) ainda usam `secrets.DATABASE_URL` = DSN Aiven → **revisar/desativar** (GH runner não alcança localhost).

---

## 0. ✅ PROGRESSO 2026-08-03 (sessão de continuidade — concluído)

Migração de dados, apontamento do app **e infra GitHub concluídos e validados**. Nada pendente (só itens opcionais/segurança).

| Item                                                                | Status                                | Evidência                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------- | ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **🔀 PIVOT LOCAL=PRIMARY / AIVEN=FALLBACK (2026-08-03, 3ª parte)**  | ✅                                    | `.env`: `DATABASE_URL/API/ETL/PRIMARY` = local; **`FALLBACK` = Aiven** (backup `.env.bak-fallback-20260803-165839`); `LOCAL_BACKUP` = local. **Aiven confirmado em disco read-only** (alerta 19:23 UTC — condiz com a notificação do usuário); serve LEITURAS normalmente → ideal p/ fallback                                                           |
| Validação full-stack (primary=local)                                | ✅                                    | Todos endpoints 200 (categorias, ufs, regioes, fluxos, municipios, sazonalidade, br-sazonalidade 613, com-preco 518); FE 25/25 testes; integração `:5173/api` → backend(local) → 200; 0 erros; resiliência 6/6                                                                                                                                          |
| **Prova do failover (remoto como fallback)**                        | ✅                                    | `DATABASE_URL_PRIMARY/API/ETL` = porta morta + `FALLBACK` = Aiven → log `[FAILOVER]` → `modo: fallback` → **`current_database()=defaultdb` (Aiven)** servindo 364k/280k linhas                                                                                                                                                                          |
| **🔀 PIVOT 100% LOCAL (2026-08-03, 2ª parte) — decisão do usuário** | ✅                                    | Aiven free relatado em read-only/disco cheio (medido: **writable, 496MB/1GB ~50%**, escrita OK — o "read-only" real visto foi artefato do MV refresh). Diretriz: zero-cost, dev 100% no Postgres local                                                                                                                                                  |
| FASE 1 — resgate do Aiven                                           | ✅                                    | Desnecessário como emergência (local == Aiven, 31/31 tabelas idênticas e atual). Rede de segurança: `pg_dump --schema-only` → `/tmp/aiven_schema.sql` (290KB)                                                                                                                                                                                           |
| FASE 2 — `.env` → local                                             | ✅                                    | `DATABASE_URL`, `API`, `ETL`, `PRIMARY`, `FALLBACK`, `LOCAL_BACKUP` → `localhost:5432/quero_comprar`. Backup: `backend/.env.bak-local-20260803-164957` (gitignored por `.env.bak-*`)                                                                                                                                                                    |
| FASE 3 — bootstrap local                                            | ✅                                    | Local já era cópia completa (364k saz, 2026/12, audit 318k); `sp_executar_carga_completa` presente; app 100% local OK (br 613, com-preco 518, MG 394, 0 erros); **test fix**: `test_db_timeout_isolation` patcheava `get_api_pool` (não usado após refactor) — agora patcha `_acquire` → 6/6 determinístico                                             |
| **Auditoria de sincronização 2026-08-03 (completa)**                | ✅                                    | 31/31 tabelas com `count(*)` IDÊNTICOS; 19/19 sequences iguais; 37/37 funções; índices/constraints/triggers/policies idênticos por schema; checksum: `sum(preco_atual)` de `mart.sazonalidade_produto` = 3226891.8618 IGUAL nos 2 bancos, `fact_precos_mensais` sum = 314448.7578 IGUAL; range anos 2021-2026/meses 1-12 iguais                         |
| **Validação full-stack 2026-08-03 (backend+API+FE+Aiven)**          | ✅                                    | Backend sobe 5s, `db_mode: primary`, 0 failover; endpoints 200: categorias, ufs, regioes, fluxos, municipios?uf=SP, sazonalidade?uf=SP, br-sazonalidade (613), com-preco (518, 5/5 200), localidade SP/CAMPINAS-SP (216); FE: 25/25 testes vitest, build tsc+vite OK, vite dev 2s; integração `:5173/api` → backend → Aiven OK                          |
| E2E API contra Aiven (modo primary)                                 | ✅                                    | `uvicorn` subiu em 5s, 0 erros/traceback/failover no log; `br-sazonalidade?ano=2025` total=613; `com-preco?uf=SP&ano=2025&mes=6` total=518 (ex.: ABACATE preco_atual 4.05, status AMARELO, tipo_dado REAL_ATUAL + mensagem transparência); `sazonalidade?uf=MG` total=394                                                                               |
| **⚠️ Achados (não bloqueiam)**                                      | 🔎                                    | (1) `com-preco` 500 TRANSITÓRIO 1x durante janela do refresh da MV em background (reteste 5/5 = 200); (2) `REFRESH MV CONCURRENTLY` falha no Aiven free (>120s num CPU → app serve MV stale — ver seção 8); (3) "SÃO PAULO" não existe no dataset (municípios CONAB têm formato `NOME-UF`; capital não é coberta)                                       |
| **Segunda leva 2026-08-03 (followups)**                             |                                       |                                                                                                                                                                                                                                                                                                                                                         |
| Órfãos `SUPABASE_URL/KEY` removidos do `.env` + comentários → Aiven | ✅                                    | `SUPABASE_URL`/`SUPABASE_KEY` fora do `.env`; `.env.example` virou template Aiven                                                                                                                                                                                                                                                                       |
| Segurança: backup com senha em texto puro                           | ✅                                    | `backend/.env.bak-20260803-153848` (senha Supabase) APAGADO; `.gitignore` ganhou `backend/.env.bak-*`                                                                                                                                                                                                                                                   |
| Git hygiene (seção 6)                                               | ✅                                    | `d1066db2` removido do histórico; `session.py` de volta ao working tree (` M`) p/ revisão; keep-alive recriado como `872213f0`; reflog preserva `62fc3226`/`d1066db2`                                                                                                                                                                                   |
| PAT no `opencode.jsonc`                                             | ✅ **MANTIDO POR DECISÃO DO USUÁRIO** | Token `ghp_bHIc...` restaurado no `opencode.jsonc` (key `env`) — usuário determinou que **não deve ser removido sem permissão explícita dele**. Validado via API (200, login PedroEvangelista063). MCP supabase `enabled:false`                                                                                                                         |
| Rotação do PAT                                                      | 🔄 **SUSPENSA (decisão do usuário)**  | Não rotacionar/revogar/remover o token sem permissão explícita do usuário. Se um dia ele autorizar: criar novo PAT no GitHub UI, trocar em `opencode.jsonc` + `~/.bashrc:132`, validar e revogar o antigo                                                                                                                                               |
| **Terceira leva 2026-08-03 (followups implementados)**              |                                       |                                                                                                                                                                                                                                                                                                                                                         |
| Teste half-open do circuito de failover                             | ✅                                    | fallback (Aiven) → cooldown 60s → log `[FAILOVER] Nuvem acessível novamente. Retornando ao banco remoto` → **primary local recuperado sozinho** (count 364.383) — circuito primário→fallback→half-open→primário completo                                                                                                                                |
| Cron dos workflows de escrita desativado                            | ✅                                    | `data_pipeline.yml` + `ingest.yml`: cron removido (rodam só on-demand/manual) — GH runner não alcança localhost, e Aiven está read-only → nada de escrita via CI. Commit **`c3e332c8`**                                                                                                                                                                 |
| Auditoria full-stack versionada                                     | ✅                                    | **`utilities/audit_full_stack.py`** (novo, commit **`f305573a`**): valida PRIMARY(local)/FALLBACK(Aiven) — contagens, MV, frescor — + API `/health` + `npm test` FE. Lê DSNs do `backend/.env` (sem secrets hardcoded); flags `--no-api`/`--no-frontend`; exit 0=OK. Rodado: ✅ tudo OK (ambos bancos 364.383/280.314/266.773/318.620, frescor 2026/12) |
| VACUUM FULL + REINDEX no local                                      | ✅                                    | `VACUUM (FULL, ANALYZE)` + `REINDEX DATABASE` → banco local de **~716MB → 468MB** (bloat eliminado; agora MENOR que o Aiven 496MB). Rodado sem backend ativo (sem lock)                                                                                                                                                                                 |
| **Quarta leva 2026-08-03 (followups 2/2)**                          |                                       |                                                                                                                                                                                                                                                                                                                                                         |
| Auditoria full-stack completa (backend de pé)                       | ✅                                    | `utilities/audit_full_stack.py` com backend no ar: `/health` 200 `db_mode: primary`, `br-sazonalidade` 613, FE **25/25**, 0 erros/failover, **exit 0**                                                                                                                                                                                                  |
| Backup local versionado                                             | ✅                                    | **`utilities/backup_local_db.sh`** (commit `40ae5bff`): `pg_dump -Fc` → `database/backups/` (gitignored), retenção `BACKUP_KEEP` (padrão 5), DSN lida do `backend/.env` ou env. Testado: dump 21M válido                                                                                                                                                |
| Commit do trabalho do branch                                        | ✅                                    | **6 commits cirúrgicos** (`7d367660` → `ea4224d2`): backend+db, frontend, pipeline+scripts, docs relatórios, openspec SDD, tooling/skills — **autorizado pelo usuário ("autorizar todos")**. SEMPRE excluídos: `opencode.jsonc` (token) e `docs/HANDOFF_MIGRACAO_AIVEN.md` (credenciais)                                                                |
| Expurgo de password local do histórico (commits novos)              | ✅                                    | `postgres_dev_local` removido dos commits DESTA sessão via fixup+autosquash (2×): `backend/.env.example` → `SUA_SENHA_LOCAL`, `scripts/sync_conab_local_to_remote.sh` → lê DSN do `.env`, `docs/RELATORIO_PROGRESSO_LIMIARES_ZSCORE.md` → placeholder. HEAD verificado: 0 ocorrências nos arquivos desta sessão                                         |
| Secret `DATABASE_URL` do CI                                         | ✅ **MANTIDO — DECISÃO DO USUÁRIO**   | "deixar [o Aiven] em fallback para caso do usuário acionar" → **Aiven permanece como FALLBACK armado**: secret do GitHub mantido, keep-alive (cron 12h, leitura) mantido, nada desmontado. Se um dia o usuário quiser: upgrade do Aiven → voltar a PRIMARY; ou remover secret + cron (limpeza total)                                                    |
| 5.1 — `backend/.env` apontado para Aiven                            | ✅                                    | 4 URLs remotas → DSN Aiven; fallback local preservado. (Backup antigo foi apagado — ver acima)                                                                                                                                                                                                                                                          |
| 5.2 — Migração de dados (dump → restore)                            | ✅                                    | `pg_dump -Fc` (21MB) → `pg_restore` no Aiven; contagens idênticas local vs Aiven (17 tabelas-chave + 36/36 tabelas + MVs populadas)                                                                                                                                                                                                                     |
| Backend conecta em modo `primary` (Aiven)                           | ✅                                    | `get_api_pool()` → PostgreSQL 18.4, `vw_api_produtos_sazonalidade` = 280.314 linhas                                                                                                                                                                                                                                                                     |
| Testes de resiliência                                               | ✅                                    | `pytest backend/tests/test_resilience.py` → 6 passed                                                                                                                                                                                                                                                                                                    |
| Keep-alive workflow aponta p/ Aiven                                 | ✅                                    | Commit `62fc3226` — `.github/workflows/supabase_keep_alive.yml` agora usa `secrets.DATABASE_URL`                                                                                                                                                                                                                                                        |
| Secret `DATABASE_URL` do GitHub = DSN Aiven                         | ✅                                    | Configurado via REST API (HTTP 201) com `GITHUB_PERSONAL_ACCESS_TOKEN` + libsodium; `SUPABASE_DATABASE_URL` não existia no repo                                                                                                                                                                                                                         |

**Detalhes do restore (importantes p/ entender o que foi feito):**

- Aiven estava vazio (0 tabelas) → alvo limpo; origem = Postgres local (STANDBY), 36 tabelas, Postgres 18.4.
- Restore usado: `pg_restore --clean --if-exists --no-owner --no-privileges --exit-on-error` (≈3,5min no plano free).
- **Roles criados manualmente no Aiven** (dump de banco único não traz roles, e políticas RLS os referenciam): `anon`, `authenticated`, `service_role`, `role_api_reader`, `role_etl_writer`.
- **`EVENT TRIGGER ensure_rls` EXCLUÍDO do restore** (via filtro no TOC `/tmp/toc.lst`): exigia superuser (Aiven `avnadmin` não é superuser) e é mecanismo RLS automático do Supabase, inútil no Aiven. A função `public.rls_auto_enable()` foi restaurada (inofensiva).
- Única extensão: `plpgsql` (built-in). Sem collations custom.

**Decisões do usuário nesta sessão:**

1. **API/ETL**: todas as URLs remotas apontam para o **mesmo DSN Aiven** `:26536` (não existe separação de portas no Aiven — era artefato do pooler Supabase). `database_url_api/etl` ficam preenchidas com o mesmo DSN.
2. **Escopo**: .env + dump/restore + workflows GitHub.

---

## 1. Objetivo da próxima sessão

Finalizar a **migração da persistência do Postgres de Supabase para Aiven**, sem quebrar a arquitetura híbrida remoto=PRIMARY / local=FALLBACK (STANDBY) do app.

**Decisão tomada**: trocar o **provedor de Postgres**, NUNCA o motor. Nada de Appwrite/BaaS. App aponta para A: `pg-2d41b051` (PostgreSQL 18.4, plan free-1-1gb, do-sfo, connection limit 20).

**Estado atual**: ✅ migração de dados + .env + keep-alive workflow concluídos (seção 0). Próxima sessão deve: (a) configurar o secret `DATABASE_URL` do GitHub; (b) opcionalmente remover órfãos (`SUPABASE_URL`/`SUPABASE_KEY` do .env, secret `SUPABASE_DATABASE_URL` do GitHub); (c) se desejado, git hygiene da seção 6.

---

## 2. Estado do incidente Supabase

- Projeto `kxsqrcccaaxplpktmutl` estava **PAUSADO** (free tier) → `57P03 Hot standby mode is disabled` → failover apontou para local.
- Restaurado no dashboard mas **NUNCA voltou**: +20min, todas camadas `unhealthy`, banner "exhausting multiple resources... performance is affected".
- Testes: pooler `aws-1-us-east-1.pooler.supabase.com:5432/6543` → TCP ok, mas `EAUTHQUERY: connection to database not available`; host direto `db.kxsqrcccaaxplpktmutl.supabase.co:5432` → **No route to host** (instância nunca subiu).
- Conclusão: Supabase **descartado** como PRIMARY. **Não usar mais** `SUPABASE_URL`/`SUPABASE_KEY`/`secrets.SUPABASE_*`.

---

## 3. Ambiente A: CLI, autenticação e serviço

| Item                | Valor                                                                                                                        |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Aiven CLI           | `aiven-client 4.16.0` no `.venv` do projeto → binário `.venv/bin/avn`                                                        |
| Projeto             | **`pedroedu0-a833`** (cloud `do-sfo`)                                                                                        |
| Serviço             | **`pg-2d41b051`** — type `pg`, plan `free-1t-1gb`, STATE `RUNNING`                                                           |
| DB name             | `defaultdb`                                                                                                                  |
| User                | `avnadmin` (único, type primary)                                                                                             |
| Host                | `pg-2d41b051-pedroedu0-a833.i.aivencloud.com`                                                                                |
| Port                | `26536`                                                                                                                      |
| SSL                 | `sslmode=require` (dsn) — asyncpg 0.30.0 aceita `?sslmode=require` na DSN (testado OK)                                       |
| **Senha do banco**  | `AVNS_olfvadUVAIbGKhTddQP` (fornecida/validada pelo usuário; asyncpg OK)                                                     |
| **Aiven API token** | token real usado com sucesso; salvo em `~/.config/aiven/aiven-credentials.json` (chmod 600). Valor em histórico da conversa. |

> ⚠️ **`avnadmin` NÃO é superuser no Aiven**: não pôde criar `EVENT TRIGGER` (ver seção 0). Consequência prática: qualquer DDL que exija superuser precisa de ajuste.

Comandos úteis do CLI:

```bash
.venv/bin/avn service connection-info pg uri pg-2d41b051
.venv/bin/avn service connection-info pg string pg-2d41b051
.venv/bin/avn project list
.venv/bin/avn users service list
export AIVEN_AUTH_TOKEN='<token>' && .venv/bin/avn user login --token 'local@opencode.dev'
```

> CLI/API **redigem a senha** (`<redacted>`) — não dá para recuperá-la via `service get`. A senha real veio do usuário.

---

## 4. Estado do `backend/.env` (histórico — Aiven; ESTADO ATUAL = seção 0, pivot local=PRIMARY)

> ⚠️ Este snapshot é da era Aiven (1ª parte). Estado vigente (3ª parte): `DATABASE_URL/API/ETL/PRIMARY/LOCAL_BACKUP` = local; `FALLBACK` = Aiven.

Chaves na era Aiven (senha mascarada):

- `DATABASE_URL="postgresql://avnadmin:<pass>@pg-2d41b051-pedroedu0-a833.i.aivencloud.com:26536/defaultdb?sslmode=require"`
- `DATABASE_URL_API="...:26536/defaultdb?sslmode=require"` (mesmo DSN — decisão do usuário)
- `DATABASE_URL_ETL="...:26536/defaultdb?sslmode=require"` (mesmo DSN)
- `DATABASE_URL_PRIMARY="...:26536/defaultdb?sslmode=require"`
- `DATABASE_URL_FALLBACK="postgresql://postgres:<pass>@localhost:5432/quero_comprar"` (inalterado)
- `DATABASE_URL_LOCAL_BACKUP="postgresql://postgres:<pass>@localhost:5432/quero_comprar"` (inalterado)
- `SUPABASE_URL`/`SUPABASE_KEY` → **órfãos** (opcional remover)

Linhas padrão do app (`backend/app/core/config.py`):

```python
database_url:                 # legado, default localhost:5432/quero_comprar
database_url_primary:         # "" se vazio usa database_url
database_url_api: str = ""    # kind "api"
database_url_etl: str = ""    # kind "etl"
database_url_fallback:        # "" → database_url_local_backup → database_url
database_url_local_backup: str = ""
pool_min_size / pool_max_size / pool_statement_timeout_ms
```

`session.py`: `_primary_url()` = primary or url; `_fallback_url()` = fallback or local_backup or url; `asyncpg.create_pool(url, min_size, max_size, command_timeout, statement_cache_size=0)` — `statement_cache_size=0` era exigência do **rapidBouncer** do Supabase; para A: **pode manter sem problema** (não interfere).

> **PERMISSÕES opencode**: Leitura/Edição de `**/.env` é **negada**. Para alterar `backend/.env`, usar **bash** (`grep`/`sed`/`export`), não os tools `read`/`edit`.

---

> ## 5. PENDÊNCIAS DE MIGRAÇÃO (status atualizado)
>
> ⚠️ Seções 5.1–5.3 descrevem a era Aiven (histórico). Estado vigente = seção 0 (pivot local=PRIMARY, Aiven=FALLBACK).

**5.1 — Ajustar `backend/.env` para A: ✅ CONCLUÍDO** (feito via bash, backup `backend/.env.bak-20260803-153848`)

- 4 URLs remotas (PRIMARY, `DATABASE_URL`, API, ETL) → DSN A `:26536` única (decisão do usuário, sem pools/portas separadas).
- `DATABASE_URL_FALLBACK` e `DATABASE_URL_LOCAL_BACKUP` mantidos em `localhost:5432/quero_comprar` (local STANDBY).

**5.2 — Migrar os dados: ✅ CONCLUÍDO** (dump local → restore Aiven; ver seção 0 p/ detalhes e TOC filtrado)

- Comandos usados:
  ```bash
  pg_dump "$DATABASE_URL_FALLBACK" -Fc -f /tmp/quero.bak
  pg_restore -l /tmp/quero.bak > /tmp/toc.lst        # filtrar EVENT TRIGGER
  sed -i '/EVENT TRIGGER/d' /tmp/toc.lst
  pg_restore -L /tmp/toc.lst -d "$AIVEN_DSN" --clean --if-exists --no-owner --no-privileges --exit-on-error /tmp/quero.bak
  ```
- Pós-restore: contagens iguais local vs Aiven; `SELECT 1` OK; MVs populadas.

**5.3 — apontar a infra para Aiven: ✅ CONCLUÍDO**

- ✅ `.github/workflows/supabase_keep_alive.yml` editado e commitado (`62fc3226`): agora usa `secrets.DATABASE_URL` (era `secrets.SUPABASE_DATABASE_URL`).
- ✅ `data_pipeline.yml`/`ingest.yml` já usam `secrets.DATABASE_URL` → cobertos pelo mesmo secret.
- ✅ Secret `DATABASE_URL` do repo `PedroEvangelista063/Sazo_repo` (ex-`Quero_Comprar_ext`) = DSN Aiven (via REST API, HTTP 201). `SUPABASE_DATABASE_URL` **não existia** no repo (lista vazia antes) → nada a remover.
- ✅ Ping simulado localmente: `DATABASE_URL=<dsn> python3 utilities/github_supabase_ping.py` → EXIT 0.
- ⚠️ Obs.: o log dos scripts de keep-alive ainda diz "Supabase Ping OK" (string genérica; cosmético, sem mudança de código).
- Opcional: remover `SUPABASE_URL`/`SUPABASE_KEY` do `backend/.env` (órfãos).

---

## 6. PENDÊNCIA de git hygiene (NÃO concluída — IMPORTANTE)

Branch **`refatoracao-dado-historico/db`** estava **12 commits à frente de `origin/main`** (0 atrás); agora 13 (adicionado `62fc3226`). HEAD anterior = `d1066db2`.

⚠️ **Estado atual (2026-08-03 segunda leva)**:

1. ✅ **`d1066db2` REMOVIDO do histórico** (via `git reset --soft HEAD~2` + re-commit). O hint (`_RESTORE_HINT`) só existe dentro do código refatorado (o original em `1a540641` não tem failover) → a separação literal "commit só com o hint" é **inviável**; o resultado prático é o desejado: `session.py` (refactor+hint) voltou ao working tree como ` M` (em revisão) e o histórico ficou limpo. HEAD atual: `872213f0` (keep-alive) → `1a540641` → ... O reflog preserva `62fc3226`/`d1066db2` (recovery via `git reflog`).
2. ✅ **PAT RESTAURADO no `opencode.jsonc`** (key `env`, valor hardcoded) por **decisão explícita do usuário**: "não deve ser removido a não ser por permissão do usuário". ⚠️ NÃO rotacionar/revogar/remover sem permissão explícita. Nota de risco registrada (o token esteve em histórico de commits/conversa), mas a decisão do usuário prevalece.
3. ✅ Ascii de senha do Supabase: backup `.env.bak-20260803-153848` (com senha `Marfia8976%2A`) foi APAGADO do disco; `.gitignore` cobre `.env.bak-*`. O que vazou em histórico git (docs antigos) permanece — `git filter-repo`/BFG só com confirmação do usuário (a senha já perdeu validade: Supabase descartado).

---

## 7. Estado do keep-alive (✅ ajustado para A)

- `.github/workflows/supabase_keep_alive.yml` — cron `0 */12 * * *`, agora usa `secrets.DATABASE_URL` (commit `62fc3226`). Nome do workflow: "Keep-Alive Postgres (Aiven)".
- `utilities/supabase_keep_alive.py` (loop 300s, `--once`) e `utilities/github_supabase_ping.py` (ping) — **sem mudança de código** (lêem `DATABASE_URL` do env). A instância Aiven **não dá autopause** (free Aiven é sempre RUNNING) → keep-alive é redundância, manter.
- ⚠️ O ping do GitHub Actions só funciona após o secret `DATABASE_URL` ser atualizado (seção 5.3).

---

## 8. Decisões/contexto acumulado (síntese)

- Refatoração do failover em `session.py`: `_primary_url/_fallback_url`, `_resolve_pool_url(kind)`, `_url_for_current_mode`, `_is_conn_error`, `_init_pool`, `_create_verified_pool`, `_pool_params`, `_activate_fallback/_activate_primary`, `_cooldown_elapsed` (60s), `_try_recover_primary`, `_RESTORE_HINT`. **NÃO tocar** além do necessário — é mudança sob review.
- `.venv` = projeto (backend). asyncpg **não** está lá → **`python3` do sistema** (`/usr/bin/python3`, Python 3.12.3, asyncpg 0.30.0) é que roda testes do backend com sucesso via `pytest backend/tests`. `uv`/`uvx` ausentes; `docker` em `/usr/bin/docker`.
- test resilience: `python3 -m pytest backend/tests/test_resilience.py -q` OK (**6 passed**, determinístico após fix do patch `_acquire`).
- **⚠️ Gotcha de config (importante)**: o pool `api`/`etl` usa `database_url_api`/`database_url_etl` COM PRECEDÊNCIA sobre `database_url_primary` (`_resolve_pool_url`). Para testar failover via env override é preciso anular as 3 (`PRIMARY`, `API`, `ETL`) — senão o pool usa a URL API (ex.: local) e nunca falha. (Discriminador de origem: `current_database()` — local=`quero_comprar`, Aiven=`defaultdb`.)
- **⚠️ MV refresh no Aiven free**: `main.py` faz `REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade` com timeout `_REFRESH_TIMEOUT=120s`; no plano free (1 CPU) leva mais de 120s → `asyncio.wait_for` cancela e a 2ª tentativa usa conexão quebrada (erro "read-only transaction" é artefato de conexão cancelada, não do banco — `default_transaction_read_only=off` no Aiven). App tolera (serve MV stale; dados vêm do dump). Recomendação futura: aumentar `_REFRESH_TIMEOUT` ou refrescar fora do boot.
- **Gotchas do restore p/ Aiven free** (descobridos nesta sessão): `avnadmin` não é superuser → event triggers falham; roles não vêm no dump de banco único → criar antes; restore de 21MB leva ~3,5min (não matar com timeout curto); wrapper de terminal mata processos em background ao expirar → rodar restore em foreground com timeout longo.
- **Auditoria full-stack versionada**: `python3 utilities/audit_full_stack.py` (opções `--no-api`, `--no-frontend`; lê DSNs de `backend/.env`; exit 0 = OK). Pré-commit hook roda `ruff` no `.py` — o script precisa de shebang+exec (`chmod +x`), sem `try-except-pass` (S110) e `subprocess.run(check=False)` (PLW1510).
- **Otimização do banco local**: `VACUUM (FULL, ANALYZE)` + `REINDEX DATABASE quero_comprar` → **468MB** (era ~716MB com bloat; agora menor que o Aiven 496MB). Rodar com backend parado (locks exclusivos).
- **CI no estado atual**: `data_pipeline`/`ingest` SEM cron (commit `c3e332c8`); keep-alive mantém cron mas só faz leitura (compatível com Aiven read-only). Secret `DATABASE_URL` mantido (decisão: usuário não escolheu; ver seção 0).
- **⚠️ Password local `postgres_dev_local` PRÉ-EXISTENTE no branch** (commitado antes desta sessão, NÃO nos commits novos): `README.md`, `backend/summary.md`, `database/summary.md`, `database/39_locf_real_gaps_sazonalidade.sql`, `database/scripts/{calcular_baseline,injetar_sintetico_coldstart,projetar_2026}.py`, `docker-compose.yml`, `docs/DATABASE_ARCHITECTURE.md`, `utilities/dry_run_sanduiche.py` (10 arquivos). É senha de dev localhost (risco baixo), mas viola a regra de não-hardcodar — **recomendação: expurgar via `git filter-repo` quando o branch for mergear para `main`**.
- **⚠️ Token MCP github commitado em `102718f3`** (pré-existente, anterior a esta sessão) — MANTIDO por decisão explícita do usuário ("não remover sem permissão"). Já considerado exposto no handoff seção 6/9.
- **Aiven = FALLBACK armado (decisão do usuário, 2026-08-03)**: PRIMARY local, FALLBACK Aiven — nada de remoção/desmonte; disponível para quando o usuário acionar (ex.: upgrade do plano). Circuito failover/half-open já provado (seção 0, terceira leva).
- **Hook de pre-commit (husky)**: roda `ruff check --fix` (py) + `prettier` (json/md/yml) + `package.json` — arquivos novos de `.py` precisam de `check=False` (PLW1510), sem `except Exception` (BLE001) e exec bit (EXE001).

---

## 9. Arquivos sensíveis conhecidos

| Arquivo                                              | Conteúdo                                                                                                                                                                                                                                    |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `~/.config/aiven/aiven-credentials.json`             | token da AAPI Aiven (chmod 600)                                                                                                                                                                                                             |
| `backend/.env`                                       | `DATABASE_URL*`, `INTERNAL_API_KEY`, etc (gitignore) — DSN Aiven; **sem** `SUPABASE_URL/KEY` (removidos)                                                                                                                                    |
| `~/.bashrc:132`                                      | `export GITHUB_PERSONAL_ACCESS_TOKEN=...` — **token ANTIGO (vazado) até a rotação**                                                                                                                                                         |
| `docs/HANDOFF_MIGRACAO_AIVEN.md`                     | **ESTE ARQUIVO** (sensível, não commitar)                                                                                                                                                                                                   |
| `opencode.jsonc` (projeto)                           | token MCP github restaurado (key `env`) por DECISÃO DO USUÁRIO (não remover sem permissão); **commitado no branch em `102718f3` (pré-existente)** — expurgar junto com o filter-repo se um dia o usuário autorizar; MCP supabase desativado |
| `/tmp/quero.bak`, `/tmp/toc.lst`, `/tmp/restore.log` | artefatos do dump/restore (descartáveis)                                                                                                                                                                                                    |

> Mantas: nunca `git add` este relatório nem `.env`.
