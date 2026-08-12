# 🚀 Arquitetura de Ambientes e CI/CD (Homologação Física vs Produção Nuvem)

> **Status:** Implementada em 2026-08-12 (FASE 2–6). Separação estrita entre o
> **servidor físico** (homologação/staging) e a **nuvem Aiven** (produção).
> Fail-Fast: o Git é o guardião — nenhum `commit`/`push` passa com código quebrado.

---

## 1. Visão Geral — Dual-Environment Pipeline

```
┌─────────────────────────────┐        ┌──────────────────────────────┐
│  HOMOLOGAÇÃO (STAGING)      │        │  PRODUÇÃO (PRODUCTION)       │
│  Servidor FÍSICO / Local    │        │  Nuvem (Aiven + Render/Vercel)│
│                             │        │                              │
│  PostgreSQL localhost:5432  │  ───►  │  PostgreSQL Aiven (primary)  │
│  APP_ENV=staging            │        │  APP_ENV=production          │
│  Pool folgado (máx. 30)     │        │  Pool estrito (máx. 8)       │
│  DEBUG=true (logs verbosos) │        │  DEBUG=false (WARNING/ERROR) │
│  Git Hooks rodam aqui       │        │  Blindado — nada entra sem   │
│                             │        │  passar pela homologação     │
└─────────────────────────────┘        └──────────────────────────────┘
        ▲ dados frescos (db sync)                │
        └────────────────────────────────────────┘
```

**Regra de ouro:** nada chega à produção sem antes ter sido validado no
ambiente físico (homologação). A fronteira é **configuração como código**
(variáveis de ambiente), nunca achismo.

---

## 2. A Fronteira: `APP_ENV`

A variável `APP_ENV` (valores: `staging` | `production`) dita **qual arquivo
`.env` o backend carrega** e **como o pool de conexões se comporta**.

| APP_ENV            | Env file carregado        | Destino do banco       | Pool asyncpg (autotuning) | Log           |
| ------------------ | ------------------------- | ---------------------- | ------------------------- | ------------- |
| `staging` (padrão) | `backend/.env.staging`    | Físico/local (PRIMARY) | min 2 / max 30            | DEBUG         |
| `production`       | `backend/.env.production` | Aiven (PRIMARY)        | min 2 / max 8 (teto 10)   | WARNING/ERROR |

Resolução do arquivo (pydantic-settings, `backend/app/core/config.py`):

```
1. backend/.env.<APP_ENV>     (ex.: backend/.env.production)
2. backend/.env.staging       (fallback explícito de dev)
3. backend/.env               (legado)
```

> `POOL_MIN_SIZE`/`POOL_MAX_SIZE` explícitos **vencem** o autotuning, mas a
> produção respeita um teto rígido (`effective_pool_max_size <= 10`) para não
> estourar o limite de conexões do Aiven free/basic.

### Como alternar entre ambientes

```bash
# Homologação (servidor físico) — PADRÃO
export APP_ENV=staging
npm run dev:backend            # → lê backend/.env.staging (localhost)

# Produção (nuvem) — no Render, APP_ENV=production já está no render.yaml
export APP_ENV=production
npm run dev:backend            # → lê backend/.env.production (Aiven)
```

**Frontend (Vite):** os modos do Vite carregam o `.env` correspondente:

```bash
npm run dev               # frontend/.env           (dev legado)
npm run dev:staging       # frontend/.env.staging   (backend local :8000)
npm run dev:production    # frontend/.env.production (backend na nuvem)
npm run build             # frontend/.env.production
```

### Banner de inicialização (lifespan do FastAPI)

Ao subir o backend, o terminal exibe de forma **visível**:

```
[!] INICIANDO SISTEMA NO AMBIENTE DE: PRODUCTION — CONECTADO AO BANCO: AIVEN (nuvem) (MODO ATIVO: primary, APP_ENV=production)
[!] INICIANDO SISTEMA NO AMBIENTE DE: STAGING — CONECTADO AO BANCO: FÍSICO (local) (MODO ATIVO: primary, APP_ENV=staging)
```

O rótulo do banco é derivado do **hostname real** da URL primária (não só do
`APP_ENV`) — o banner nunca mente mesmo com `.env` legado apontando para a nuvem.

---

## 3. Fail-Fast — Guardiões do Git (Hooks)

### 3.1 `pre-commit` (`.husky/pre-commit`)

Roda **antes de cada commit**. Se qualquer etapa falhar → `exit 1` → commit
ABORTADO:

1. **`npx lint-staged`** — Ruff (`--fix`) + Prettier apenas nos arquivos staged.
2. **`bash scripts/guard_commit.sh`**:
   - `tsc --noEmit` (typecheck TypeScript do frontend);
   - `bash scripts/smoke_staging.sh` — smoke de **homologação**:
     - backend respondendo `GET /health` (se offline, sobe uvicorn temporário);
     - `GET /api/v1/sazonalidade/br-sazonalidade?ano=2025` **sem HTTP 500**;
     - **Regra de Ouro**: `status_cor` da grade sem valores `null`/`CINZA`
       (NO GRAY / NO NULL — Deep Fallback preservado).

### 3.2 `pre-push` (`.husky/pre-push`)

Roda **antes de cada push** (impede deploy de código quebrado no GitHub →
Vercel/Render):

1. Guardião do commit (typecheck + smoke);
2. **Suíte de testes integrados**: `pytest backend/tests` + `vitest` (frontend).

### 3.2.1 Fast-path (evita atrito em commits que não tocam código)

O `guard_commit.sh` detecta o **escopo dos arquivos STAGED** (o commit é
definido pelo index; o lint-staged re-stage os fixes antes do guard):

- Só `*.md`/`*.json`/`*.yml`/READMEs/`.gitignore` staged → **smoke pulado**;
- Nenhum `*.ts`/`*.tsx` do frontend staged → **tsc pulado**;
- Qualquer arquivo de código staged (`.py`, `.sh`, `.ts`, `.tsx`, `.sql`, …)
  → guard completo (tsc + smoke + testes no push).

```
# commit só de docs → libera instantâneo:
[guarda] fast-path: sem código TS/TSX alterado — tsc pulado.
[guarda] fast-path: só docs/JSON/yml mudaram — smoke de homologação pulado.
[guarda] ✓ PORTÃO ABERTO — commit liberado.
```

### 3.3 Bypasses de emergência (documentados — usar com critério)

```bash
SKIP_TSC=1            git commit ...   # pula typecheck
SKIP_STAGING_SMOKE=1  git commit ...   # pula smoke (banco local desligado)
SKIP_PUSH_TESTS=1     git push ...     # pula suíte de testes no push
SKIP_GUARD_COMMIT=1 / SKIP_GUARD_PUSH=1  # desliga o guardião inteiro (emergência real)
```

> ⚠️ Falhar rápido é o comportamento desejado: se o hook bloqueia, há um
> problema real a corrigir. Os bypasses existem para cenários de indisponibilidade
> de infraestrutura, não para conveniência.

---

## 4. Sincronização de Dados — Produção ➔ Homologação

Para homologar features com **dados frescos** de produção:

```bash
# 1) Validação prévia (não altera nada):
npm run db:sync:staging:dry        # ou: bash scripts/sync_db_prod_to_staging.sh --dry-run

# 2) Sync completo:
npm run db:sync:staging            # ou: bash scripts/sync_db_prod_to_staging.sh
```

**O que o script faz:**

1. Lê a URL de **produção** (`backend/.env.production` → Aiven) e de
   **homologação** (`backend/.env.staging` → localhost);
2. Dump seletivo da produção (schema + dados), excluindo `ops.*`, `raw.*` e
   schemas auxiliares;
3. No destino: `DROP SCHEMA staging+mart CASCADE` (ou `--truncate-only`) →
   aplica schema → restaura dados;
4. Valida contagens pós-restore (`fact_precos_mensais`, `dim_produto`,
   `sazonalidade_produto`, MV).

**Segurança Zero-Waste:**

- **Nunca toca em `ops.*`** (ex.: `ops.config_agente`, auditoria), **`raw.*`**
  (landing zone) nem **`audit.*`** (runtime log) do destino — usuários/
  senhas/configurações locais preservados;
- **Restore = um único `pg_restore --clean --if-exists`** (o dump custom contém
  schema+dados): recria o que existe no destino a partir da produção (ex.:
  funções `public.*`) e remove objetos que não existem na produção (ex.:
  event trigger `ensure_rls`, legado Supabase — ver `docs/HANDOFF_MIGRACAO_AIVEN.md`);
- **Recusa sobrescrever um destino que não seja local/físico** (host !=
  localhost → aborta; use `--force` só com consciência);
- `--dry-run` valida conectividade e imprime o plano completo sem alterar nada.

| Flag                | Efeito                                                    |
| ------------------- | --------------------------------------------------------- |
| `--dry-run`         | Valida + mostra plano (nada é alterado)                   |
| `--no-dump`         | Reusa os backups `prod2staging_*_latest`                  |
| `--truncate-only`   | `TRUNCATE` de staging+mart em vez de DROP dos schemas     |
| `--refresh-mv`      | `REFRESH MV` no destino após o restore                    |
| `--skip-validation` | Pula a checagem de contagens pós-restore                  |
| `--force`           | Permite destino não-local (perigoso — documente o motivo) |

> Alternativa existente: `bash scripts/sync_db_remote_to_local.sh` (Remote ➔
> Local Snapshot Sync, com `--restore`). O `sync_db_prod_to_staging.sh` é a
> versão **Dual-Environment** com dry-run e proteção de `ops.*`.

---

## 5. Arquivos do Dual-Environment

| Arquivo                                     | Papel                                               | Versionado?     |
| ------------------------------------------- | --------------------------------------------------- | --------------- |
| `backend/.env.example`                      | Template seguro (documenta staging/production)      | ✅              |
| `backend/.env.staging`                      | Credenciais da homologação física (APP_ENV=staging) | ❌ (gitignored) |
| `backend/.env.production`                   | Credenciais da produção Aiven (APP_ENV=production)  | ❌ (gitignored) |
| `backend/.env`                              | Legado/fallback (mesmo conteúdo do staging)         | ❌              |
| `frontend/.env.example`                     | Template do frontend (VITE_API_URL)                 | ✅              |
| `frontend/.env.staging` / `.env.production` | Modos Vite por ambiente                             | ❌              |
| `scripts/guard_commit.sh`                   | Guardião do pre-commit (tsc + smoke)                | ✅              |
| `scripts/guard_push.sh`                     | Garantia final do pre-push (+ testes)               | ✅              |
| `scripts/smoke_staging.sh`                  | Smoke de homologação (health + br-sazonalidade)     | ✅              |
| `scripts/sync_db_prod_to_staging.sh`        | Sync Produção ➔ Homologação (dry-run)               | ✅              |
| `.husky/pre-commit` / `.husky/pre-push`     | Hooks husky                                         | ✅              |

**Importante:** crie `backend/.env.staging` copiando `backend/.env.example` e
preenchendo com as credenciais locais (ou copie seu `backend/.env` atual). A
API de produção no Render usa `APP_ENV=production` (declarado no `render.yaml`)
e as URLs vêm do dashboard do Render.

---

## 6. Regra de Ouro Mantida: NO GRAY / NO NULL

A refatoração de ambientes **não altera** a semântica do semáforo:

- A MV `mart.vw_api_produtos_sazonalidade` (Deep Fallback V22/V23) continua
  preenchendo meses futuros com `VERDE`/`AMARELO`/`VERMELHO` — sem `CINZA`
  e sem `status_cor` nulo;
- O smoke de homologação (`scripts/smoke_staging.sh`) **valida isso a cada
  commit**: `0 status_cor nulo/CINZA` na grade do `/br-sazonalidade`;
- O contrato da API (`ano_referencia`, `tipo_dado`, `mensagem_transparencia`)
  permanece intacto nos dois ambientes.

---

## 7. Checklist do Administrador (antes de homologar uma feature)

1. **Sincronizar dados**: `npm run db:sync:staging:dry` → `npm run db:sync:staging`;
2. **Subir o backend de homologação**: `APP_ENV=staging npm run dev:backend`
   (conferir o banner `[!] INICIANDO SISTEMA NO AMBIENTE DE: STAGING — ... FÍSICO`);
3. **Testar**: `npm run test-backend` + `npm run test-frontend` (ou o próprio
   `pre-push` ao enviar);
4. **Commit/Push**: os hooks `pre-commit`/`pre-push` validam lint, typecheck,
   smoke e testes — **se o portão fecha, corrige antes de subir**;
5. **Produção**: deploy no Render (APP_ENV=production) apenas após a etapa 4
   com portão aberto.
