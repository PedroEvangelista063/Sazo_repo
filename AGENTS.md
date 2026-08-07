# Code Review Rules — quero_comprar_vg

Regras da casa para revisão de código por IA (GGA, OpenCode e demais agentes).
Documentos completos: `docs/PROJECT_RULES.md` e `docs/CONVENTIONS.md`.

## Stack

- Backend: Python 3.13+, FastAPI[standard], Pydantic v2, asyncpg, httpx, Uvicorn, Polars
- Frontend: React 19, Vite PWA, TailwindCSS 3, shadcn/ui (Radix + CVA), Framer Motion, Zustand 5, TanStack Query v5, TanStack Table v8, Recharts, Lucide
- Database: PostgreSQL 16+ (Aiven / PostgreSQL local)

## Engenharia Geral

- Nomes pt-BR para domínio de negócio B2C; EN-US para infraestrutura e variáveis genéricas
- Commits em conventional commits: `feat:`, `fix:`, `refactor:`, `chore:`

## Python / Backend

- Type hints obrigatórios em todo Python
- Nunca use pandas — use polars
- Nunca use INSERT linha por linha — use COPY ou `execute_values`
- Prefira PL/pgSQL sobre Python para lógica pesada de agregação
- Backend: sem ORM — Raw SQL com asyncpg, cache com expiração
- Timeout em toda rota (Event Loop Starvation); rate limit por IP; Pydantic v2 na borda
- Pipeline de ingestão usa psycopg2-binary (scripts síncronos ETL)

## Frontend

- Nunca exibir preços (R$) — apenas status visual (Verde, Amarelo, Vermelho)
- Mobile-first (320px, touch >= 44px); offline-first (service worker)
- Zustand para estado persistente do usuário; TanStack Query para cache de API
- Zero MUI/Ant Design/Mantine — só shadcn/ui + Tailwind + Framer Motion
- Skeleton (sem spinners bloqueantes); emoji unicode nos produtos (sem imagens); dark/light mode

## Database

- DDL idempotente (IF NOT EXISTS, OR REPLACE)
- Landing Zone sem FKs/UNIQUE/CHECK; UPSERT com ON CONFLICT
- Janela Temporal 2024-01 a 2026-12
- `role_etl_writer` para pipeline; `role_api_reader` (SELECT only) para API

## Governança do Projeto (regras fundamentais)

### Banco Local como primário

O projeto opera prioritariamente no PostgreSQL Local (localhost) devido a limitações de disco no plano gratuito do Aiven. Mantenha as configurações locais de `.env` como as primárias para testes.

### Quality Gate (Transparência de Dados)

Qualquer nova view agregada ou projeção de dados (BR ou UF) NÃO pode preencher meses futuros com dados de `FALLBACK_DIMENSAO` (ex: 2023). O limite de âncora histórica é o Ano Atual - 1. Sem dados recentes, o status deve ser CINZA.

### Null Safety E2E (React)

Sempre implemente null safety operators (`?.`, `??`) no Frontend ao lidar com dados do backend, devido ao status CINZA (meses sem dados reais chegam com campos nulos — `ano_referencia`, `tipo_dado`, `mensagem_transparencia`).
