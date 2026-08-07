# 🛒 QUERO COMPRAR — O App que Te Avisa Quando a Fruta Está Barata

[![Tests & Build](https://github.com/PedroEvangelista063/Sazo_repo/actions/workflows/tests.yml/badge.svg)](https://github.com/PedroEvangelista063/Sazo_repo/actions/workflows/tests.yml)
[![Python](https://img.shields.io/badge/Python-3.13+-3776AB?logo=python&logoColor=white&style=flat)](https://www.python.org/)
[![React](https://img.shields.io/badge/React-19-61DAFB?logo=react&logoColor=black&style=flat)](https://react.dev/)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.115-009688?logo=fastapi&logoColor=white&style=flat)](https://fastapi.tiangolo.com/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-4169E1?logo=postgresql&logoColor=white&style=flat)](https://www.postgresql.org/)

> **"Comer bem não pode ser um luxo."** — esse é o lema.

O **Quero Comprar** é um app web que usa **dados reais do governo (CONAB) e cotações de CEASAs** para te dizer, em um piscar de olhos, **qual é a melhor época para comprar** hortifrúti na feira ou no supermercado. Sem achismo, sem tabela infinita de preços, sem letra miúda: só um **semáforo de cores** que qualquer um entende.

🟢 **Barato** (tá na safra) → 🟡 **Normal** → 🔴 **Caro** (entressafra, corre da compra!)

E o melhor: o app **nunca mostra R$ na tela**. Preço aqui é cor, não número — decisão rápida, sem poluição visual.

---

## 📌 Índice

| Pasta / Seção                                   | O que tem lá dentro                              |
| ----------------------------------------------- | ------------------------------------------------ |
| 🌍 [O Projeto](#-o-projeto)                     | A ideia, o público e a mágica do semáforo        |
| 🏗️ [Arquitetura](#️-arquitetura)                 | Como os dados viajam do governo até a sua tela   |
| 📁 [Estrutura de Pastas](#-estrutura-de-pastas) | Mapa da casa, com link para cada cômodo          |
| 🔧 [`pipeline/`](#-pipeline--a-garagem)         | Os robôs que caçam dados na internet             |
| 🗄️ [`database/`](#-database--a-despensa)        | O banco de dados medalhão (raw → staging → mart) |
| ⚙️ [`backend/`](#-backend--a-cozinha)           | A API FastAPI que serve dados prontos            |
| 🎨 [`frontend/`](#-frontend--a-sala-de-estar)   | A PWA React que você usa no celular              |
| 📐 [`config/`](#-config--as-plantas-da-casa)    | Toda a configuração em JSON                      |
| 🩺 [`utilities/`](#-utilities--o-checkup)       | Auditorias, diagnósticos e ferramentas CLI       |
| 🚀 [`scripts/`](#-scripts--os-ferramentais)     | Deploy, sync de banco e automação                |
| ☁️ [`supabase/`](#-supabase--a-nuvem)           | Migrations e RLS do banco remoto                 |
| 📚 [`docs/`](#-docs--a-biblioteca)              | Relatórios, arquitetura e decisões               |
| 🧪 [Testes](#-testes)                           | Como garantimos que nada quebra                  |
| 🚀 [Setup Local](#-setup-local)                 | Rode o projeto na sua máquina                    |
| 🧰 [Comandos Úteis](#-comandos-úteis)           | Atalhos que facilitam a vida                     |
| ☁️ [Deploy](#-deploy)                           | Onde cada pedaço vive em produção                |

---

## 🌍 O Projeto

**Pensa comigo:** todo mundo já chegou na feira, viu um tomate lindo e pagou caro — pra descobrir uma semana depois que estava na safra e custava metade. Injusto, né?

O **Quero Comprar** resolve isso com ciência de dados:

1. **Coletamos** cotações públicas de preços de hortifrúti (CONAB + CEASAs de todo o Brasil);
2. **Analisamos** a sazonalidade de cada produto: quando ele naturalmente fica barato (safra) e quando fica caro (entressafra);
3. **Entregamos** um semáforo de cores: verde = melhor época, amarelo = preço normal, vermelho = melhor esperar.

O resultado é uma **bússola de compras**: você abre o app, vê o mapa do Brasil, toca no seu estado e descobre o que vale a pena comprar agora. Economia real na feira, baseada em dados públicos e gratuitos.

### Por que isso importa?

- **Pra você**: para de gastar dinheiro à toa e aprende os ciclos naturais dos alimentos.
- **Pra sociedade**: dados públicos usados de verdade, virando valor pra todo mundo — open data com propósito.
- **Pro planeta**: menos desperdício, compra mais inteligente.

---

## 🏗️ Arquitetura

O projeto segue a metáfora de uma **casa brasileira** — cada pasta é um cômodo com um papel claro:

```
┌───────────────────────────────────────────────────────────────┐
│                       QUERO COMPRAR                           │
│                                                               │
│  ┌────────────┐   ┌──────────┐   ┌──────────┐   ┌───────────┐ │
│  │ pipeline/  │──▶│ database/│──▶│ backend/ │──▶│ frontend/ │ │
│  │ 🚗 Garagem │   │ 🗄️ Despensa│  │ ⚙️ Cozinha│  │ 🛋️ Sala    │ │
│  │ ETL/Scrap  │   │ PostgreSQL│  │  FastAPI │  │ React PWA │ │
│  └────────────┘   └──────────┘   └──────────┘   └───────────┘ │
│        │               │               │                      │
│        └── raw ──▶ staging ──▶ mart ──┘                      │
│                                                               │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌────────────┐   │
│  │ config/  │  │ scripts/ │  │ utilities/│  │ supabase/  │   │
│  │ 📐 Plantas│  │ 🚀 Auto  │  │ 🩺 Checkup│  │ ☁️ Nuvem    │   │
│  └──────────┘  └──────────┘  └───────────┘  └────────────┘   │
└───────────────────────────────────────────────────────────────┘
```

### Fluxo dos dados

```
CONAB / CEASA ──▶ 🚗 pipeline (scrapers) ──▶ raw.coleta_bruta
   ──▶ SortingEngine ──▶ staging.fact_precos_mensais
   ──▶ sp_executar_carga_completa() + LOCF + forecast ──▶ mart.sazonalidade_produto
   ──▶ REFRESH MV ──▶ mart.vw_api_produtos_sazonalidade
   ──▶ ⚙️ backend (FastAPI, read-only) ──▶ 🎨 frontend (cores, nunca R$)
```

> 🗄️ **Arquitetura Medalhão**: `raw` (bronze — dados crus, sem filtro) → `staging` (prata — limpos e tipados) → `mart` (ouro — prontos para consumo). A API só lê da camada ouro. Escrita? Só o pipeline.

---

## 📁 Estrutura de Pastas

```
quero_comprar_vg/
├── 🚗 pipeline/       # Motor de extração: scrapers, orquestrador, WAF bypass
├── 🗄️ database/       # 70+ migrations SQL, dados processados, scripts de forecast
├── ⚙️ backend/        # API FastAPI (Python 3.13+, asyncpg, Pydantic v2)
├── 🎨 frontend/       # PWA React 19 (Vite, Tailwind, shadcn/ui, Framer Motion)
├── 📐 config/         # JSONs: fontes, regiões, fluxos de abastecimento
├── 🩺 utilities/      # Auditorias E2E, backups, keep-alive, diagnósticos
├── 🚀 scripts/        # Deploy, sync local↔remoto, restauração
├── ☁️ supabase/       # Migrations (000001–000021) + RLS do banco remoto
├── 📚 docs/           # Relatórios técnicos, arquitetura, convenções
├── 🧪 tests/          # Testes de integração (banco + pipeline)
├── Makefile           # Atalhos: dev, test, lint, build
└── package.json       # Scripts npm do monorepo
```

---

## 🚗 `pipeline/` — A Garagem

> **"Scrape Now, Parse Later"** — o scraper não pensa, só colhe.

Micro-motores burros e focados extraem payloads crus (HTML/JSON/CSV) de fontes públicas e jogam tudo na **Landing Zone** (`raw.coleta_bruta`). Depois, um motor de parsing transforma em dados limpos.

| Peça                          | Função                                                               |
| ----------------------------- | -------------------------------------------------------------------- |
| `scraper/micro_engines/`      | Um motor especialista por layout de fonte (CONAB, CEASA, Prohort...) |
| `scraper/orchestrator.py`     | Orquestrador autônomo: CEASA direta → Agregadores → Discovery        |
| `scraper/transport/`          | WAF bypass, fingerprint de navegador, resolvers de captcha           |
| `scraper/circuit_breaker.py`  | Se falhar 5×, espera 120s e tenta de novo (sem pânico)               |
| `scraper/persistence.py`      | Ciclo medalhão: SortingEngine + `sp_executar_carga_completa()`       |
| `scraper/main_runner.py`      | "Run and Die": acorda, colhe, descarrega, morre. Sem daemon.         |
| `processor/sorting_engine.py` | Classifica e encaminha payloads para o schema certo                  |

**Regras de ouro:** nunca valida na extração • timeout global de 20 min • concorrência limitada (semáforo 3) • janela temporal **estrita 2024–2026** • fontes centralizadas em `config/sources_matrix.json`.

---

## 🗄️ `database/` — A Despensa

O coração do projeto: **PostgreSQL** organizado em camadas medalhão, com **70+ migrations SQL numeradas** (01 → 70) que evoluem o schema de forma idempotente.

| Schema    | Papel                                                                  |
| --------- | ---------------------------------------------------------------------- |
| `raw`     | Landing Zone sem barreiras — sem FK, sem constraint, velocidade máxima |
| `staging` | Dados limpos, tipados, com UPSERT (`ON CONFLICT`)                      |
| `mart`    | Sazonalidade materializada + baselines + forecasts                     |
| `ops`     | Observabilidade: quarentena de coleta, audit logs                      |

### Forecast 100% SQL

O modelo preditivo roda **inteiro no banco** (`sp_calcular_forecast_2026()`):

- Baselines ponderadas 2024–2025 e 2025–2026 com peso por confiança;
- Rastreabilidade completa: `is_forecast`, `baseline_confianca`, `forecast_method`, `tendencia_futura`;
- **Transparência total**: dado real (`is_forecast=false`) nunca é sobrescrito por projeção — `ON CONFLICT DO NOTHING`.

### Materialized View (fonte única da API)

`mart.vw_api_produtos_sazonalidade` — join entre fato + dimensões, filtrada para varejo (B2C). A API lê **só daqui**. Simples, rápido e seguro.

---

## ⚙️ `backend/` — A Cozinha

API HTTP **assíncrona** em **FastAPI** que prepara os dados e serve ao frontend. Filosofia: **zero ORM, queries raw com asyncpg, read-only**.

| Rota                                        | O que faz                                          |
| ------------------------------------------- | -------------------------------------------------- |
| `GET /api/v1/sazonalidade`                  | Snapshot de sazonalidade (filtro regional incluso) |
| `GET /api/v1/sazonalidade/{uf}/{municipio}` | Sazonalidade por localidade                        |
| `GET /api/v1/regioes`                       | As 5 regiões com UFs e polos CEASA                 |
| `GET /api/v1/ufs`                           | UFs disponíveis                                    |
| `GET /api/v1/municipios?uf=SP`              | Municípios por estado                              |
| `GET /api/v1/categorias`                    | Categorias de varejo                               |
| `GET /api/v1/fluxos`                        | Fluxos de abastecimento CEASA (mapa)               |
| `GET /api/v1/stream/updates`                | SSE — atualizações em tempo real                   |
| `GET /health`                               | Health check                                       |

**Defesas embutidas:** cache interno LRU/TTL • rate limit por IP • timeouts em toda rota (nada de travar o event loop) • validação na borda com Pydantic v2 • RLS no banco (`role_api_reader` = SELECT only).

---

## 🎨 `frontend/` — A Sala de Estar

**PWA offline-first, mobile-first.** Interface sem dinheiro na tela — só semáforo, emoji e animações gostosas.

### Views

| View              | O que é                                                                        |
| ----------------- | ------------------------------------------------------------------------------ |
| **Cards**         | Grid de produtos com cards animados (Framer Motion), semáforo e filtros        |
| **Mapa Regional** | `BrasilMap`: 27 dots SVG (um por UF) + painel com polos CEASA e arcos de fluxo |
| **Grade Sazonal** | Grade nacional 12 meses × produtos, agrupada em accordion por categoria        |

### Stack de orgulho

- **React 19 + Vite + PWA** — app rápido, instala no celular, funciona offline;
- **TailwindCSS 3 + shadcn/ui** — visual consistente, dark/light mode;
- **Framer Motion** — animações de verdade: springs, glow, tilt, blur reveal;
- **React Bits** — Beams (fundo 3D com Three.js), SpotlightCard, TiltedCard, BlurText;
- **TanStack Query v5 + Zustand 5** — cache e estado persistente;
- **Claymorphism** — botões "fofos" com sombras de argila (tokens `shadow-clay-*`);
- **Emoji em vez de imagem** — cada produto tem seu emoji, zero dependência de foto.

> 🧭 **Regra sagrada do frontend:** 🚫 nunca `R$` na tela, 🚫 sem imagens (só emoji), ✅ skeletons (sem spinner chato), ✅ touch ≥ 44px, ✅ dark/light mode.

---

## 📐 `config/` — As Plantas da Casa

**Configuration over code**: toda fonte, região e fluxo mora em JSON. O código só lê e executa.

| Arquivo               | Conteúdo                                                                           |
| --------------------- | ---------------------------------------------------------------------------------- |
| `sources_matrix.json` | 24+ fontes em 4 categorias (core, agregadores, CEASAs, periféricos)                |
| `regions.json`        | As 5 regiões com UFs e polos CEASA                                                 |
| `flows.json`          | **166 fluxos** de abastecimento entre UFs (origem, destino, produto, sazonalidade) |
| `sources_map.json`    | Mapeamento produto → fontes regionais                                              |

---

## 🩺 `utilities/` — O Checkup

Ferramentas CLI autônomas de diagnóstico e auditoria. **Read-only por padrão**, sem efeitos colaterais:

- `audit_full_stack.py` — auditoria E2E: banco primário + fallback + API + frontend;
- `validate_e2e.py` / `test_scraper_e2e.py` — validações ponta a ponta;
- `backup_local_db.sh` — backup versionado do banco local (retém os últimos 5);
- `supabase_keep_alive.py` — evita que a instância free "dorme" por inatividade;
- `_check_*.py` — micro-diagnósticos pontuais de banco/migrations.

---

## 🚀 `scripts/` — Os Ferramentais

Automação de ambiente, deploy e manutenção:

- `deploy_v13_prod.sh` — deploy de produção com purga de cache pós-deploy;
- `sync_db_remote_to_local.sh` — snapshot remoto → local (backup/restore);
- `sync_conab_local_to_remote.sh` — replica carga CONAB do local → remoto;
- `setup_organism.sh` / `.ps1` — setup do ecossistema (Linux/Windows);
- `restore/` — scripts de restauração de banco.

---

## ☁️ `supabase/` — A Nuvem

Migrations formais do banco remoto (**000001 → 000021**): schemas, tabelas, roles (`role_etl_writer`, `role_api_reader`), RLS (Row Level Security), views materializadas e o engine de forecast.

> 🔐 **RLS ativo** em 4 tabelas-chave: escritor do ETL tem bypass total; a API só lê com `SELECT`; e o `service_role`/`postgres` passam direto. Banco aberto para leitura, fechado para escrita indevida.

---

## 📚 `docs/` — A Biblioteca

Relatórios técnicos e decisões de arquitetura: `PROJECT_RULES.md`, `CONVENTIONS.md`, `DATABASE_ARCHITECTURE.md`, relatórios de auditoria E2E, claymorphism, limiares z-score, dado histórico real, plano de deploy e muito mais. A trilha de raciocínio do projeto fica registrada aqui.

---

## 🧪 Testes

| Camada           | Ferramenta               | Roda com                          |
| ---------------- | ------------------------ | --------------------------------- |
| Backend (Python) | pytest                   | `make test:backend`               |
| Frontend (TS)    | Vitest + Testing Library | `make test:frontend`              |
| Tudo             | pytest + vitest          | `make test` ou `npm run dev:test` |
| Lint             | ruff + prettier          | `make lint`                       |

---

## 🚀 Setup Local

### Pré-requisitos

- Python **3.13+**
- Node.js **≥ 22.22.1** e npm **≥ 10**
- PostgreSQL **17+** (opcional — o remoto pode ser o padrão)

### Instalação

```bash
# 1. Clone
git clone https://github.com/PedroEvangelista063/Sazo_repo.git
cd Sazo_repo

# 2. Ambiente Python
python3 -m venv .venv
source .venv/bin/activate          # Linux/Mac
pip install -r backend/requirements.txt

# 3. Dependências npm
npm install
npm --prefix frontend install

# 4. Configure o ambiente
cp backend/.env.example backend/.env
# Edite backend/.env com suas credenciais de banco

# 5. Rode tudo
npm run dev:all
# 🎨 Frontend: http://localhost:5173
# ⚙️ Backend:  http://localhost:8000
```

> 💡 **Banco local opcional:** `docker compose up -d postgres-backup` sobe um PostgreSQL 17 em `localhost:5433` para backups e testes.

---

## 🧰 Comandos Úteis

| Comando                     | O que faz                            |
| --------------------------- | ------------------------------------ |
| `npm run dev:all`           | Backend + frontend em paralelo 🔥    |
| `npm run dev:backend`       | Só a API FastAPI (porta 8000)        |
| `npm run dev:frontend`      | Só o Vite (porta 5173)               |
| `npm run scrape:manual`     | Coleta CEASA/CONAB sob demanda       |
| `npm run build:frontend`    | Build PWA de produção                |
| `npm run db:backup`         | Backup remoto → local                |
| `npm run db:backup:restore` | Backup + restore no banco local      |
| `make test`                 | Todos os testes (backend + frontend) |
| `make lint`                 | ruff + prettier                      |

---

## ☁️ Deploy

| Camada      | Plataforma                    | Região           |
| ----------- | ----------------------------- | ---------------- |
| 🗄️ Banco    | Supabase / Aiven (PostgreSQL) | us-east-1 / Ohio |
| ⚙️ API      | Render (Web Service)          | Ohio             |
| 🎨 Frontend | Vercel (SPA + PWA)            | Edge             |

---

## 🧠 Curiosidades do Projeto

- 🧮 O forecast roda **100% em SQL** — sem Python, sem servidor externo;
- 🗺️ O mapa do Brasil tem **27 dots SVG** desenhados à mão (um por capital), com arcos animados de fluxos de abastecimento;
- 🤖 O scraper é **anti-bot com honra**: bypass de WAF, fingerprint de navegador e até resolver de captcha;
- 📊 Dados **CONAB + 20 listas de cotações CEASA** processados em Polars (nunca pandas — regra da casa!);
- 🌙 Tema escuro, confete quando o produto está na melhor época e uma **bandeira do Brasil animada com frutas orbitando** 🍓🇧🇷.

---

**Feito com dados públicos CONAB/CEASA, muito café, e a certeza de que comida boa não pode ser cara demais.** 🥑❤️

> Quer ajudar? Pull requests são bem-vindos — e lembre-se das regras da casa: sem R$ na tela, sem pandas, e dados sempre com transparência.
