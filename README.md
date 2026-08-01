# QUERO COMPRAR — Sua Bússola de Sazonalidade para a Feira

**App B2C que revela a melhor época para comprar hortigranjeiros usando dados CONAB (2024-2026) e cotações CEASA.**  
Economia real na feira e no supermercado — sem achismo, com dados. Apenas cores, nunca valores monetários na tela.

> 🟢 **Barato** (safra) → 🟡 **Normal** → 🔴 **Caro** (entressafra)

---

## Índice

- [Arquitetura](#arquitetura)
- [Stack](#stack)
- [Pipeline — Motor de Extração (ELT)](#pipeline--motor-de-extração-elt)
- [Database — Medalhão (raw → staging → mart)](#database--medalhão-raw--staging--mart)
- [Backend — FastAPI](#backend--fastapi)
- [Frontend — PWA React](#frontend--pwa-react)
- [Arquitetura Híbrida — Supabase + Local](#arquitetura-híbrida--supabase--local)
- [RLS — Row Level Security](#rls--row-level-security)
- [Agentes de IA (agentget)](#agentes-de-ia-agentget)
- [Configuração Centralizada](#configuração-centralizada)
- [Setup Local](#setup-local)
- [Scripts Úteis](#scripts-úteis)
- [Comandos npm](#comandos-npm)
- [Deploy](#deploy)

---

## Arquitetura

```
┌────────────────────────────────────────────────────────────────────┐
│                        QUERO COMPRAR VG                            │
│                                                                    │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────────┐ │
│  │ PIPELINE │    │ DATABASE │    │ BACKEND  │    │   FRONTEND   │ │
│  │ (Garagem)│───▶│(Despensa)│───▶│ (Cozinha)│───▶│(Sala de Estar)│ │
│  │ ETL/ELT  │    │PostgreSQL│    │ FastAPI  │    │  React PWA   │ │
│  │ Scrapers │    │ Supabase │    │ asyncpg  │    │  TanStack Q  │ │
│  └──────────┘    └──────────┘    └──────────┘    └──────────────┘ │
│       │               │               │                            │
│       └── raw ──▶ staging ──▶ mart ──┘                            │
│                                                                    │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐                     │
│  │   CONFIG │    │ SCRIPTS  │    │UTILITIES │                     │
│  │ JSONs    │    │ Automação│    │Diagnóstico│                     │
│  └──────────┘    └──────────┘    └──────────┘                     │
└────────────────────────────────────────────────────────────────────┘
```

### Fluxo dos Dados

```
CONAB/CEASA ──→ Scraper ──→ raw.coleta_bruta ──→ SortingEngine
    ──→ staging.fact_precos_mensais ──→ sp_executar_carga_completa()
    ──→ mart.sazonalidade_produto ──→ REFRESH MV
    ──→ mart.vw_api_produtos_sazonalidade ◀── FastAPI (read-only)
    ──→ Frontend React (cores, nunca R$)
```

### Volumes Atuais

| Camada | Tabela | Registros |
|--------|--------|-----------|
| RAW | `raw.coleta_bruta` | 15 |
| STAGING | `staging.fact_precos_mensais` | 42.358 |
| MART | `mart.sazonalidade_produto` | 62.291 |
| MV | `mart.vw_api_produtos_sazonalidade` | 62.291 |
| OPS | `ops.quarentena_coleta` | 9 |

---

## Stack

### Backend
| Tecnologia | Versão | Função |
|------------|--------|--------|
| Python | 3.13+ | Runtime |
| FastAPI | — | API HTTP assíncrona |
| asyncpg | — | Pool de conexão PostgreSQL |
| Pydantic | v2 | Schemas de resposta e validação |
| httpx | — | HTTP client para scrapers |
| Uvicorn | — | Servidor ASGI |

### Frontend
| Tecnologia | Versão | Função |
|------------|--------|--------|
| React | 19 | Core UI |
| Vite | 6 | Bundler + PWA plugin |
| TailwindCSS | 3.4 | Utility classes + dark mode |
| shadcn/ui | — | Radix primitives + CVA |
| TanStack Query | 5 | Cache offline-first |
| TanStack Table | 8 | Tabela de dados |
| Zustand | 5 | Estado persistente |
| Framer Motion / Motion | 12 | Animações (springs, AnimatePresence) |
| React Bits | — | Beams, SpotlightCard, TiltedCard, BlurText |
| Three.js / R3F / Drei | — | Visualizações 3D |
| Recharts | — | Gráficos de linha/barra |
| Lucide React | — | Ícones |
| Vitest + RTL | — | Testes unitários |

### Database
| Tecnologia | Versão | Função |
|------------|--------|--------|
| PostgreSQL | 17 (Supabase) / 18 (local) | Banco relacional |
| PL/pgSQL | — | Stored Procedures (forecast) |
| Supabase CLI | — | Migrations e deploy |

### Pipeline
| Tecnologia | Função |
|------------|--------|
| Polars | Manipulação de dados (nunca pandas) |
| Playwright | Scraping de páginas web |
| HTTPX | Requisições HTTP assíncronas |
| asyncpg | Pool de conexão com banco |
| curl-cffi | Scraping com fingerprint de navegador |

---

## Pipeline — Motor de Extração (ELT)

> "Scrape Now, Parse Later" — extração nunca valida dados. Apenas deposita na Landing Zone.

### Micro-Motores

| Motor | Função |
|-------|--------|
| `scraper/micro_engines/` | Motores especialistas (um por layout de fonte) |
| `scraper/orchestrator.py` | `AutonomousOrchestrator` — cascata CEASA → Agregadores → Discovery |
| `scraper/discovery_engine.py` | Dorks de busca + anti-PDF |
| `scraper/circuit_breaker.py` | CircuitBreaker (5 falhas → 120s recovery) |
| `scraper/persistence.py` | Ciclo medalhão (SortingEngine + `sp_executar_carga_completa`) |
| `scraper/main_runner.py` | Entry point Run and Die (timeout 1200s) |

### Regras de Ouro

- **Run and Die**: sem `while True`. O processo acorda, colhe, descarrega e encerra.
- **Timeout Global**: `asyncio.wait_for(task, timeout=1200)` — 20 min de vida máxima.
- **Concorrência**: `asyncio.Semaphore(3)` por motor.
- **Janela Temporal**: estritamente 2024-2026.
- **Sem ORM no pipeline**: queries raw com asyncpg. Nada de SQLAlchemy.
- **Fontes centralizadas**: `config/sources_matrix.json` — configuration over code.

---

## Database — Medalhão (raw → staging → mart)

### Camadas

| Schema | Função |
|--------|--------|
| `raw` | Landing Zone sem barreiras — sem FKs, sem constraints |
| `staging` | Dados limpos com tipagem, UPSERT, dimensões |
| `mart` | Sazonalidade materializada + baselines para forecast |
| `ops` | Observabilidade: quarentena, audit logs, config |

### Forecast (100% SQL, v2 Ponderado)

O modelo preditivo roda integralmente no banco via `sp_calcular_forecast_2026()`:

```
Duas baselines permanentes:
  mart.sazonalidade_baseline_25_26 ── primária (moda 2025-2026, 32.581 linhas)
  mart.sazonalidade_baseline_24_25 ── fallback (moda 2024-2025, 23.449 linhas)

baseline_ponderado = FULL JOIN com CASE weighting:
  primary vence quando confianca >= 30
  fallback * 0.5 usado quando primary ausente ou confianca < 30

Colunas de rastreabilidade:
  is_forecast BOOLEAN ── TRUE = projeção, FALSE = dado real
  baseline_confianca NUMERIC(5,2) ── confiança efetiva (0-100)
  forecast_method TEXT ── método usado na projeção
  tendencia_futura TEXT ── QUEDA / ALTA / ESTAVEL
```

**Resultado**: 19.933 projeções para Ago-Dez 2026 em ~1s. 12.884 registros reais Jan-Jul intactos.

### Migrações Supabase (15 formais)

| Migration | Objetivo |
|-----------|----------|
| `000001-000012` | Schemas, tabelas RAW/STAGING/MART, funções, MV, roles, forecast v2, ops |
| `000013` | Reconciliação de drift Fase 4 (18 objetos) |
| `000014` | Trigger de anomalia por UF + auditoria |
| `000015` | RLS em 4 tabelas com 5 políticas |

### Materialized View (V14)

`mart.vw_api_produtos_sazonalidade` — a única fonte que a API consulta:
- JOIN: `sazonalidade_produto` + `dim_produto` + `dim_localidade` + `dim_categoria`
- Filtro: `categoria_b2c = 'ALIMENTO_VAREJO'`, exclusão de B2B
- Colunas: `is_forecast`, `baseline_confianca`, `forecast_method`, `tendencia_futura`

---

## Backend — FastAPI

API HTTP assíncrona que serve o frontend B2C. Consulta **exclusivamente** views materializadas e funções `fn_*`.

### Endpoints

| Rota | Função |
|------|--------|
| `GET /api/v1/sazonalidade` | Snapshot de sazonalidade (+ filtro regional `?regiao=`) |
| `GET /api/v1/sazonalidade/{uf}/{municipio}` | Por localidade |
| `GET /api/v1/sazonalidade/historico/{ano}/{mes}` | Série temporal |
| `GET /api/v1/regioes` | Lista 5 regiões com UFs e polos CEASA |
| `GET /api/v1/categorias` | Categorias de varejo |
| `GET /api/v1/ufs` | UFs disponíveis |
| `GET /api/v1/municipios?uf=SP` | Municípios por UF |
| `GET /api/v1/admin/coletar-global` | Coleta para todas as UFs |
| `GET /api/v1/stream/updates` | SSE para notificações em tempo real |
| `GET /health` | Health check |

### Regras de Ouro

- **Sem ORM**: queries raw com asyncpg. Nada de SQLAlchemy, Django ORM ou Tortoise.
- **Read-Only**: a API só lê de `mart.vw_*` e funções `fn_*`. Escrita é exclusividade do pipeline.
- **Event Loop Starvation**: toda rota com timeout (`asyncio.wait_for` ou `TimeoutMiddleware`).
- **Cache Interno**: LRU/TTL em `core/cache.py` (Redis opcional via `REDIS_URL`).
- **Rate Limit**: 60 requisições/minuto por IP (`core/ratelimit.py`).
- **Pydantic v2**: schemas de resposta validados na borda, não no banco.

---

## Frontend — PWA React

App offline-first, mobile-first. Interface de semáforo (verde/amarelo/vermelho) — **nunca exibe valores monetários**.

### Views

| View | Descrição |
|------|-----------|
| **Cards** | Grid de `ProductCard` com SpotlightCard + semáforo + status filter |
| **Mapa Regional** | `BrasilMap` (27 dots SVG por UF) + `RegiaoPanel` com polos CEASA e arcos de fluxo |
| **Grade Sazonal** | Grid BR Nacional (12 meses × produtos) sem filtro de mês |

### Flags Visuais

- `is_forecast=true` → badge `📊 Estimativa` com tooltip da % de confiança
- `tendencia_futura` → indicador de tendência (QUEDA/ALTA/ESTAVEL)

### Componentes

| Componente | Função |
|------------|--------|
| `ProductCard` | Card de produto (emoji + semáforo + forecast badge) |
| `BrasilMap` | Mapa com 27 dots SVG interativos (cores por região) |
| `RegiaoPanel` | Painel lateral com info da região e fluxos CEASA |
| `SazonalidadeNacional` | Grid sazonal BR completo |
| `BRNationalIcon` | Bandeira BR animada com frutas orbitando |
| `GameButton` | Botão com springs Framer Motion + loading + shake |
| `GameCard` | Card animado com entrada + confetti no verde |
| `Beams` | Background Three.js com feixes de luz |
| `SpotlightCard` | Card com spotlight que segue o mouse |
| `TiltedCard` | Card com 3D tilt ao hover |
| `BlurText` | Texto com blur/fade animado |

### Regras de Ouro

- **🚫 Nunca R$ na tela** — só cores (Verde/Amarelo/Vermelho).
- **🚫 Sem imagens** — emoji unicode exclusivamente.
- **Offline-first**: PWA + TanStack Query com `staleTime` alto.
- **Mobile-first**: design responsivo partindo de 320px. Touch targets ≥ 44px.
- **SkeletonCards** em vez de spinners genéricos.
- **Dark/Light mode** via classe `.dark` no `<html>`.

---

## Arquitetura Híbrida — Supabase + Local

```
REMOTO (PRIMARY — Active)              LOCAL (STANDBY — Backup/Sandbox)
───────────────────────────────        ────────────────────────────────────
Supabase kxsqrcccaaxplpktmutl          PostgreSQL 18 nativo Linux Mint
DATABASE_URL (5432) — DDL/ETL          localhost:5432/quero_comprar
DATABASE_URL_API (6543) — API reads    postgres / postgres_dev_local
DATABASE_URL_ETL (5432) — cargas

npm run dev → REMOTO (padrão)          npm run db:backup:restore → Remote ➔ Local
                                        NUNCA Local ➔ Remote automático
```

### Conexão (backend/.env)

```env
# REMOTO (PRIMARY)
DATABASE_URL          → Session Pooler :5432   (DDL, ETL)
DATABASE_URL_API      → Transaction Pooler :6543 (API reads)
DATABASE_URL_ETL      → Session Pooler :5432   (cargas)

# LOCAL (STANDBY)
DATABASE_URL_LOCAL_BACKUP → localhost:5432/quero_comprar
```

### Workflow Seguro

```bash
npm run dev              # Desenvolvimento → REMOTO (padrão)
npm run db:backup        # Backup de segurança (schema + dados)
npm run db:backup:restore # Backup + restaura no banco local
```

> ⚠️ Apenas migrations em `supabase/migrations/` podem ir Local ➔ Remote.  
> `statement_cache_size=0` é obrigatório quando usando pooler do Supabase.

---

## RLS — Row Level Security

Ativo via migration `000015_rls_security_layer.sql` em 4 tabelas:

| Tabela | role_etl_writer | role_api_reader |
|--------|----------------|-----------------|
| `mart.sazonalidade_produto` | ALL (bypass) | SELECT |
| `staging.dim_produto` | ALL (bypass) | ❌ sem acesso |
| `staging.fact_precos_mensais` | ALL (bypass) | ❌ sem acesso |
| `ops.audit_logs` | INSERT+SELECT | ❌ sem acesso |

- `role_etl_writer` tem bypass total (`USING(true)`)
- `role_api_reader` tem SELECT apenas nas tabelas de mart
- `service_role` e `postgres` bypass automático

---

## Agentes de IA (agentget)

67 agentes especializados instalados em `.agents/agents/` via [AgentGet](https://agentget.sh/) para auxiliar no desenvolvimento:

| Categoria | Agentes |
|-----------|---------|
| **Code Review** | `code-reviewer`, `python-reviewer`, `typescript-reviewer`, `react-reviewer`, `fastapi-reviewer`, `database-reviewer`, `security-reviewer`, `fsharp-reviewer`, `go-reviewer`, `java-reviewer`, `kotlin-reviewer`, `php-reviewer`, `rust-reviewer`, `swift-reviewer`, `cpp-reviewer`, `csharp-reviewer`, `flutter-reviewer`, `django-reviewer`, `vue-reviewer` |
| **Arquitetura** | `code-architect`, `architect`, `homelab-architect`, `network-architect` |
| **Build & Test** | `build-error-resolver`, `e2e-runner`, `pr-test-analyzer`, `harness-optimizer`, `react-build-resolver`, `rust-build-resolver`, `go-build-resolver`, `java-build-resolver`, `kotlin-build-resolver`, `django-build-resolver`, `cpp-build-resolver`, `dart-build-resolver`, `swift-build-resolver`, `pytorch-build-resolver`, `harmonyos-app-resolver` |
| **Planejamento** | `planner`, `tdd-guide`, `refactor-cleaner`, `loop-operator` |
| **Exploração** | `code-explorer`, `spec-miner`, `performance-optimizer`, `silent-failure-hunter`, `doc-updater`, `docs-lookup`, `comment-analyzer`, `conversation-analyzer` |
| **ML/AI** | `mle-reviewer`, `gan-evaluator`, `gan-generator`, `gan-planner`, `agent-evaluator` |
| **Outros** | `seo-specialist`, `marketing-agent`, `healthcare-reviewer`, `network-config-reviewer`, `network-troubleshooter`, `a11y-architect`, `chief-of-staff`, `code-simplifier`, `type-design-analyzer`, `opensource-forker`, `opensource-packager`, `opensource-sanitizer` |

---

## Configuração Centralizada

Arquivos JSON em `config/` — configuration over code:

| Arquivo | Conteúdo |
|---------|----------|
| `sources_matrix.json` | 24+ fontes em 4 categorias (core, agregadores, CEASAs diretas, periféricos) |
| `regions.json` | 5 regiões brasileiras com UFs e polos CEASA |
| `flows.json` | 166 fluxos de abastecimento CEASA/CONAB entre UFs |
| `sources_map.json` | Mapeamento produto → fontes regionais |

---

## Setup Local

### Pré-requisitos

- Python 3.13+
- Node.js ≥ 22.22.1
- npm ≥ 10.0.0
- PostgreSQL 17+ (opcional — Supabase remoto é o padrão)

### Instalação

```bash
# 1. Clone
git clone https://github.com/PedroEvangelista063/Quero_Comprar_ext.git
cd Quero_Comprar_ext

# 2. Ambiente Python
python3 -m venv .venv
source .venv/bin/activate  # Linux/Mac
pip install -r backend/requirements.txt

# 3. Dependências npm (raiz + frontend)
npm install
npm --prefix frontend install

# 4. Configure as variáveis de ambiente
cp .env.example .env
# Edite backend/.env com as credenciais do Supabase (veja backend/.env.example)

# 5. Rodar (desenvolvimento)
npm run dev:all
# Backend: http://localhost:8000
# Frontend: http://localhost:5173
```

### Docker (Backup Local Opcional)

```bash
docker compose up -d postgres-backup
# PostgreSQL 17 em localhost:5433 (não conflita com nativo :5432)
```

---

## Scripts Úteis

```bash
# Coleta manual de dados CEASA/CONAB
npm run scrape:manual

# Backup do banco remoto para local
npm run db:backup               # Apenas gerar backups
npm run db:backup:restore       # Gerar + restaurar no banco local
npm run db:backup:schema        # Apenas schema
npm run db:backup:data          # Apenas dados

# Testes
npm run dev:test               # Backend + frontend
make test                      # Mesmo, via Makefile

# Lint
make lint                      # ruff (Python) + prettier (TypeScript)

# Build PWA
npm run build:frontend

# Utilitários de diagnóstico
python utilities/_check_db.py               # Conexão com banco
python utilities/audit_full.py              # Auditoria completa
python utilities/validate_e2e.py            # Teste end-to-end
python database/scripts/validar_forecast.py # Validação do forecast
```

---

## Comandos npm

| Comando | O que faz |
|---------|-----------|
| `npm run dev:all` | Backend + Frontend em paralelo |
| `npm run dev:backend` | Apenas FastAPI (porta 8000) |
| `npm run dev:frontend` | Apenas Vite (porta 5173) |
| `npm run scrape:manual` | Coleta CEASA/CONAB sob demanda |
| `npm run build:frontend` | Build PWA de produção |
| `npm run db:backup` | Backup remoto → local |
| `npm run db:backup:restore` | Backup + restore no banco local |
| `npm run db:test:local` | Testes no banco local |
| `npm run db:test:remote` | Testes no banco remoto |
| `npm run install:all` | Instala dependências completas |

---

## Deploy

| Camada | Plataforma | Região |
|--------|-----------|--------|
| Banco | Supabase (PostgreSQL 17) | us-east-1 |
| API | Render (Web Service, Python) | Ohio |
| Frontend | Vercel (SPA, PWA) | Edge |

---

## Metáfora da Casa

O micro-monorepo segue a metáfora de uma **casa brasileira**:

- **🚗 Garagem** (`pipeline/`) — a máquina que transforma dados brutos em informação
- **🗄️ Despensa** (`database/`) — onde os dados são armazenados e organizados
- **🍳 Cozinha** (`backend/`) — onde a API prepara os dados para servir
- **🛋️ Sala de Estar** (`frontend/`) — onde o consumidor final aproveita
- **📐 Config** (`config/`) — plantas e especificações da casa
- **🔧 Scripts** (`scripts/`) — ferramentas de manutenção
- **🩺 Utilities** (`utilities/`) — diagnósticos e checkups
- **🤖 Agentes** (`.agents/`) — assistentes de IA especializados

---

**Feito com dados públicos CONAB/CEASA, amor ao código aberto, e a certeza de que comida não pode ser cara demais.**
