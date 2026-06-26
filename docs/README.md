# QUERO COMPRAR

App B2C que indica a melhor época para comprar produtos agrícolas usando dados históricos da CONAB.
Uma ferramenta desenhada para ajudar o consumidor a economizar na feira e no supermercado.

## Stack

| Camada | Tecnologia |
|---|---|
| Pipeline ETL | Python 3.11+, Polars, httpx, psycopg2 |
| Backend | FastAPI + asyncpg (Raw SQL) |
| Cache | In-memory thread-safe com TTL (24h) |
| Database | PostgreSQL 16+ (Arquitetura Medalhão) |
| Frontend | React 18 + Vite + PWA (Service Worker) |
| Estilização | Tailwind CSS 3.4 (utility-first) |
| Estado | Zustand com persist (localStorage) |
| API Data Fetching | TanStack Query v5 (stale-while-revalidate) |
| Autocura | Ghost DBA Agent (LLM-driven SQL repair) |

## Estrutura do Projeto

```
quero_comprar_vg/
├── pipeline/               # ETL: ingestão CONAB → cálculo IS → PostgreSQL
│   ├── ingestao_conab.py   # Download resiliente com retry + backoff
│   ├── transform.py        # Limpeza Polars (encoding, tipos, outliers)
│   ├── seasonality.py      # Cálculo do IS por município + fallback UF
│   ├── load.py             # UPSERT em lote (execute_values)
│   ├── ghost_dba_agent.py  # Agente de autocura com LLM
│   └── tests/              # Testes unitários (validação, sazonalidade)
├── backend/                # FastAPI B2C
│   └── app/
│       ├── api/v1/
│       │   └── endpoints/
│       │       ├── produtos.py     # GET /api/v1/sazonalidade
│       │       ├── municipios.py   # GET /api/v1/municipios?uf=SP
│       │       └── internal.py     # GET/POST /api/v1/_internal/cache-clear
│       ├── core/           # config, cache, ratelimit
│       ├── db/             # conexão asyncpg (pool 10-50)
│       └── schemas/        # Pydantic V2 responses
├── frontend/               # PWA React + Vite Mobile-First
│   ├── src/
│   │   ├── store/          # Zustand: useUserStore (UF/Cidade)
│   │   ├── services/       # Axios + hooks TanStack Query
│   │   ├── components/     # ProductCard, LocationSelector
│   │   ├── pages/          # Dashboard
│   │   └── types.ts        # ProductSeasonality, UF_LIST, emojis
│   ├── vite.config.ts      # PWA plugin + proxy dev
│   └── tailwind.config.js  # Cores sazonais (verde/amarelo/vermelho)
├── database/               # DDLs (Arquitetura Medalhão + Observability)
├── docs/                   # Documentação
└── .env.example            # Template de variáveis de ambiente
```

## Configuração Inicial

```bash
# 1. Ambiente Python (Pipeline & Backend)
python -m venv .venv
source .venv/bin/activate  # Linux/Mac
pip install -r pipeline/requirements.txt
pip install -r backend/requirements.txt

# 2. Ambiente Frontend
cd frontend && npm install

# 3. Variáveis de ambiente
cp .env.example .env
# Edite .env com DATABASE_URL

# 4. Rodar (dois terminais)
uvicorn backend.app.main:app --reload --port 8000   # Backend
cd frontend && npm run dev                           # Frontend :5173
```

## Endpoints da API

| Método | Rota | Descrição |
|---|---|---|
| `GET` | `/api/v1/sazonalidade?uf=SP&municipio=...` | Lista produtos com filtros |
| `GET` | `/api/v1/sazonalidade/{uf}/{municipio}` | Atalho por localidade |
| `GET` | `/api/v1/municipios?uf=SP` | Lista municípios disponíveis |
| `GET` | `/api/v1/_internal/cache-clear` | Limpa cache (uso interno) |
| `GET` | `/health` | Health check |

## O Semáforo de Sazonalidade (Visão B2C)

O aplicativo **nunca exibe preços em R$** — apenas cores indicativas:

| Status | UX | Lógica (IS) |
|---|---|---|
| 🟢 **VERDE** | Melhor Época! | Preço < Média Anual (-15%) |
| 🟡 **AMARELO** | Preço Normal | Estabilizado na Média (±15%) |
| 🔴 **VERMELHO** | Péssima Época (Evite) | Preço > Média Anual (+15%) |
| ⚪ **INSUFICIENTE** | Sem Dados | Histórico < 6 meses |

## PWA (Offline-First)

- Service Worker com `StaleWhileRevalidate` para dados da API
- Cache via TanStack Query + persistência local
- Ícone instalável no celular (Add to Home Screen)
- Funciona em conexões 3G