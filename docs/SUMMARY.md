# QUERO COMPRAR — Documentação

## Visão Geral

| Documento | Descrição |
|---|---|
| [README.md](./README.md) | Visão geral, setup, semáforo de sazonalidade |
| [AGENTS.md](./AGENTS.md) | Regras da casa para OpenCode/GGA |

## Arquitetura

| Documento | Descrição |
|---|---|
| [Plano Técnico](./quero_comprar_plano_tecnico.md) | Arquitetura completa — Fase 1, 2 e 3 |
| [Fase 2 — Autocura](./fase2_arquitetura_autocura.md) | Observability, Self-Healing DB, FastAPI |

## Database

| Caminho | Descrição |
|---|---|
| `database/01_ddl_medalhao.sql` | DDL: schemas raw/staging/mart, tabelas, índices, roles |
| `database/02_observability.sql` | Observabilidade: schema ops, erro DDL, auditoria LLM |

## Pipeline

| Caminho | Descrição |
|---|---|
| `pipeline/ingestao_conab.py` | Pipeline ETL: download → transform → COPY |
| `pipeline/transform.py` | Limpeza e normalização com Polars |
| `pipeline/seasonality.py` | Cálculo do IS por município + fallback UF |
| `pipeline/load.py` | UPSERT em lote no PostgreSQL |
| `pipeline/ghost_dba_agent.py` | Agente de autocura com LLM |
| `pipeline/requirements.txt` | Dependências Python do pipeline |
| `pipeline/tests/` | Testes unitários (validação, sazonalidade) |

## Backend (FastAPI)

| Caminho | Descrição |
|---|---|
| `backend/app/main.py` | Bootstrap FastAPI com CORS, lifespan, routers |
| `backend/app/core/config.py` | Settings via pydantic-settings (env_file) |
| `backend/app/core/cache.py` | Cache in-memory thread-safe com TTL |
| `backend/app/core/ratelimit.py` | Rate limiting por IP |
| `backend/app/db/session.py` | Pool asyncpg (10-50 conexões) |
| `backend/app/schemas/responses.py` | Pydantic V2: SazonalidadeResponse, MunicipioListResponse |
| `backend/app/api/v1/endpoints/produtos.py` | `GET /api/v1/sazonalidade` com filtros |
| `backend/app/api/v1/endpoints/municipios.py` | `GET /api/v1/municipios?uf=SP` |
| `backend/app/api/v1/endpoints/internal.py` | `GET/POST /api/v1/_internal/cache-clear` |
| `backend/requirements.txt` | Dependências Python do backend |

## Frontend (PWA)

| Caminho | Descrição |
|---|---|
| `frontend/vite.config.ts` | Vite + PWA Plugin (Service Worker) + proxy dev |
| `frontend/tailwind.config.js` | Cores sazonais personalizadas |
| `frontend/src/store/useUserStore.ts` | Zustand + persist (UF/Cidade no localStorage) |
| `frontend/src/services/api.ts` | Axios + hooks TanStack Query |
| `frontend/src/components/ProductCard.tsx` | Card com semáforo visual + emoji fallback + skeleton |
| `frontend/src/components/LocationSelector.tsx` | UF dropdown + city datalist + prefetch |
| `frontend/src/pages/Dashboard.tsx` | Grid ordenado (VERDE → AMARELO → VERMELHO) |
| `frontend/src/types.ts` | Interfaces, UF_LIST, emoji map, STATUS_ORDER |

## Mapa do Projeto

```
quero_comprar_vg/
├── pipeline/               # ETL + Agentes Python
├── backend/                # FastAPI B2C
├── frontend/               # React + Vite PWA
│   ├── vite.config.ts
│   ├── tailwind.config.js
│   └── src/
│       ├── components/     # ProductCard, LocationSelector
│       ├── pages/          # Dashboard
│       ├── services/       # api.ts (Axios + React Query)
│       └── store/          # useUserStore (Zustand)
├── database/               # DDLs PostgreSQL
└── docs/                   # Documentação
```
