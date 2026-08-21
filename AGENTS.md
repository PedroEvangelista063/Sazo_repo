# Code Review Rules — Sazo Brasil

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

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:

- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

### Obsidian Auto-Sync (ALWAYS ACTIVE)

Graphify automatically syncs to Obsidian after significant changes. This is MANDATORY — not optional.

**Obsidian Vault Path**: `/home/pedroeduardo/Documentos/Obsidian Vault/Graphify_SAZO-REPO/`

**When to sync** (proactive triggers — do NOT wait for user to ask):

- After completing a feature, fix, or refactor
- After modifying 3+ files in a single task
- After architecture or design decisions
- After database schema changes
- After significant documentation updates
- At session end (before saying "done")

**How to sync**:

```bash
# Full rebuild with Obsidian output
graphify . --obsidian --obsidian-dir "/home/pedroeduardo/Documentos/Obsidian Vault/Graphify_SAZO-REPO"

# Or incremental update (faster, code-only)
graphify update . --obsidian --obsidian-dir "/home/pedroeduardo/Documentos/Obsidian Vault/Graphify_SAZO-REPO"
```

**What gets synced**:

- `graph.html` — interactive visualization
- `GRAPH_REPORT.md` — plain-language architecture report
- `graph.json` — GraphRAG-ready JSON
- `manifest.json` — audit trail

**Post-commit hook**: The graphify post-commit hook auto-rebuilds the graph after every git commit. The Obsidian sync runs as part of this hook when `GRAPHIFY_OBSIDIAN_DIR` is set.

**Verification**: After syncing, confirm files exist:

```bash
ls -la "/home/pedroeduardo/Documentos/Obsidian Vault/Graphify_SAZO-REPO/"
```
