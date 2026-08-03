# 📋 RELATÓRIO — Correção: Supabase Pausado (failover ativo / 57P03)

> **Objetivo deste relatório:** instruir o **opencode** a corrigir o problema abaixo.
> O opencode DEVE buscar a correção e o contexto completo no **Engram** (memória persistente)
> usando as instruções da seção [7. Engram](#7-engram---onde-buscar-a-correção-persistida).

---

## 1. Contexto

- **Comando reproduzido:** `npm run dev:all` (raiz do repo `quero_comprar_vg`).
- **Data:** 2026-08-03 (~12:05).
- **Ambiente:** Linux local; banco local `localhost:5432/quero_comprar` ATIVO.
- **Projeto Supabase:** `kxsqrcccaaxplpktmutl` — `aws-1-us-east-1.pooler.supabase.com` (PostgreSQL 17, plano free).

## 2. Sintoma (log colado pelo usuário)

```
[BE] WARNING: [FAILOVER] Nuvem inacessível. Redirecionando tráfego para Banco Local...
     (motivo: (EAUTHQUERY) authentication query failed: connection to database not available)
[BE] INFO: api pool conectado.
[BE] INFO: etl pool conectado.
[BE] INFO: Banco ativo: fallback (local)
[BE] INFO: [BOOTSTRAP] Banco local já possui schema — bootstrap ignorado.
[BE] INFO: Application startup complete.
```

Além disso, o Vite logou repetidamente:

```
[FE] 12:05:30 [vite] http proxy error: /api/v1/categorias
[FE] Error: connect ECONNREFUSED 127.0.0.1:8000
```

## 3. Diagnóstico (já investigado e confirmado)

Há **dois problemas distintos** no log — NÃO confundir:

| #   | Fenômeno                                                                         | Natureza                                                                                                                          | Ação                                   |
| --- | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| 1   | `ECONNREFUSED 127.0.0.1:8000` no proxy do Vite                                   | **Ruído de startup** — o frontend sobe antes do backend e tenta chamá-lo antes de existir (race do `concurrently`). Some sozinho. | Ignorar / não corrigir código por isso |
| 2   | `[FAILOVER] Nuvem inacessível... (EAUTHQUERY)` + `Banco ativo: fallback (local)` | **Problema real:** banco remoto Supabase **PAUSADO**                                                                              | Corrigir (seções 4–6)                  |

**Evidências coletadas:**

- `pg_isready localhost:5432` → `aceitando conexões` (fallback local OK).
- TCP nas portas do pooler (`5432` transacional e `6543` sessão) → **conectam** (não é rede/firewall).
- `SELECT 1` executado contra o projeto via ferramenta do Supabase → erro:

```
FATAL: 57P03: the database system is not accepting connections.
DETAIL: Hot standby mode is disabled.
```

- A pesquisa web confirma: `57P03` + `Hot standby mode is disabled` é a assinatura de **projeto Supabase pausado** (free tier pausa após ~7 dias sem atividade).

## 4. Causa raiz

O projeto Supabase `kxsqrcccaaxplpktmutl` está **PAUSADO** por inatividade (plano free).
O pooler (Supavisor) responde `EAUTHQUERY: connection to database not available`, que disparou o
circuit breaker de failover do backend (`backend/app/db/session.py`), que redirecionou para o
Postgres local — que está com schema e **funcionando** (modo `fallback`).

> ⚠️ **Importante:** o projeto pausado **não revive por ping** — o keep-alive só evita a pausa
> se estiver ativo enquanto o projeto está online. É necessária ação manual de restore no dashboard.

## 5. Correção — o que DEVE ser feito

### 5.1 Ação humana (fora do escopo de código — informar ao usuário)

1. Abrir https://supabase.com/dashboard → organização → projeto `kxsqrcccaaxplpktmutl`.
2. Clicar **Resume project** / **Restore project** (status "Paused") e confirmar.
3. Aguardar alguns minutos até o compute voltar.

> Após o restore, o backend **auto-recupera** (circuit breaker half-open com cooldown de 60s) —
> não precisa reiniciar o processo; ou basta rodar `npm run dev:all` novamente.

### 5.2 Correções de código que o opencode deve executar

1. **Commitar o mecanismo de keep-alive** (hoje `untracked` → GitHub Actions NÃO roda):
   - `.github/workflows/supabase_keep_alive.yml` (cron a cada 12h + `workflow_dispatch`).
   - `utilities/supabase_keep_alive.py` e `utilities/github_supabase_ping.py`.
   - Verificar que o secret `SUPABASE_DATABASE_URL` está configurado no repositório GitHub
     (o workflow usa `secrets.SUPABASE_DATABASE_URL`).
2. **Opcional — robustez local:** criar unit systemd user (`~/.config/systemd/user/supabase-keep-alive.service`)
   rodando `utilities/supabase_keep_alive.py` em loop (já documentado no docstring do script), para o
   keep-alive não depender só do GitHub Actions.
3. **Opcional — observabilidade:** avaliar log mais claro em `backend/app/db/session.py` quando o modo
   ativo for `fallback` (ex.: incluir erro original e instrução de restore) e/ou endpoint de health já existente
   expondo o modo ativo (`get_active_mode()`).
4. **NÃO aplicar migrations nem alterar schema** — o problema não é de schema.

### 5.3 Segurança (achado adicional — tratar com prioridade)

- `docs/CHECK_CONEXAO_SUPABASE.md` está **commitado** e contém a **senha do banco em texto puro**.
  - Recomenda-se: remover a senha do documento (referenciar `backend/.env`), rotacionar a senha do banco
    e, se necessário, limpar o histórico git (BFG/filter-repo) — avaliar com o usuário.
- Regra do projeto: **nunca hardcodar secrets em arquivos versionados** (usar `backend/.env`).

## 6. Validação (critérios de aceite para o opencode)

- [ ] `psql`/`asyncpg` conectando no Supabase → `SELECT version()` responde `PostgreSQL 17.x`.
- [ ] `python3 utilities/supabase_keep_alive.py --once` retorna `[KEEP-ALIVE] Supabase Ping OK` (exit 0).
- [ ] `.github/workflows/supabase_keep_alive.yml`, `utilities/supabase_keep_alive.py` e
      `utilities/github_supabase_ping.py` rastreados pelo git.
- [ ] `npm run dev:all` sobe sem `[FAILOVER]` (modo `primary`) e sem `Banco ativo: fallback`.
- [ ] `docs/CHECK_CONEXAO_SUPABASE.md` sem segredo em texto puro.

## 7. Engram — onde buscar a correção persistida

A investigação completa foi salva na memória persistente do projeto. Busque ANTES de alterar código:

- **MCP (ferramentas do engram):**
  - `mem_get_observation` com **id = 151** (sync `obs-e8007892834bcd17`)
    → título: _"Supabase pausado — failover local (57P03 hot standby)"_ (type `bugfix`).
  - `mem_search` com termos: `Supabase pausado`, `57P03 hot standby`, `failover`, `keep-alive`.
- **CLI (fallback):**
  - `engram search "Supabase pausado"` (e variações: `57P03`, `failover`, `keep-alive`).

## 8. Arquivos envolvidos

| Arquivo                                     | Papel                                                                                     |
| ------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `backend/.env`                              | URLs de conexão (`DATABASE_URL_PRIMARY`, `DATABASE_URL_FALLBACK`, `DATABASE_URL_API/ETL`) |
| `backend/app/db/session.py`                 | Failover / circuit breaker (probe `SELECT 1`, cooldown 60s, half-open)                    |
| `backend/app/db/bootstrap.py`               | Garante schema no banco local de fallback                                                 |
| `backend/app/core/config.py`                | `Settings` (pydantic) — lê `backend/.env`                                                 |
| `utilities/supabase_keep_alive.py`          | Keep-alive em loop (ping `SELECT 1` a cada 300s; `--once` para cron)                      |
| `utilities/github_supabase_ping.py`         | Ping usado pelo GitHub Actions                                                            |
| `.github/workflows/supabase_keep_alive.yml` | Workflow cron 12h (untracked hoje)                                                        |
| `docs/CHECK_CONEXAO_SUPABASE.md`            | Checklist manual de conexão — **contém senha em texto puro (corrigir)**                   |
| `.env.example`                              | Template com `DATABASE_URL_PRIMARY`/`DATABASE_URL_FALLBACK`                               |

## 9. Não fazer

- ❌ Não aplicar migrations / DDL no banco remoto (não é o problema).
- ❌ Não remover o mecanismo de failover — ele funcionou corretamente e é a resiliência desejada.
- ❌ Não hardcodar senha em nenhum arquivo versionado.
- ❌ Não assumir que ping em projeto pausado o revive — depende do restore manual no dashboard.
