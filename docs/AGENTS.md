Regras da Casa — quero_comprar_vg

Contexto para OpenCode, GGA e agentes AI

Tech Stack

Backend: Python 3.11+ (FastAPI, Polars, psycopg2, asyncpg)

Frontend: React 18+ com Vite (PWA, TailwindCSS, Zustand, React Query v5)

Database: PostgreSQL 16+

Infra: Docker, GitHub Actions, WSL2

Engenharia Geral

Nomes pt-BR para domínio de negócio B2C, EN-US para infraestrutura e variáveis genéricas.

Commits em conventional commits: feat:, fix:, refactor:, chore:

Engenharia de Dados & Backend

Type hints obrigatórios em todo Python.

Nunca use pandas — use polars para performance.

Nunca use INSERT linha por linha — use COPY ou execute_values.

Prefira PL/pgSQL sobre Python para lógica pesada de agregação.

Backend FastAPI: Evite ORM para leitura B2C em massa. Use Raw SQL (asyncpg) e faça cache com expiração.

Banco de Dados (Arquitetura Medalhão & Observability)

raw → dados como chegam (COPY direto).

staging → dimensões + fato limpos (Anomalias >500% vão para staging.precos_rejeitados).

mart → sazonalidade materializada para API (Acesso via vw_api_produtos_sazonalidade).

ops → schema de observabilidade monitorado pelo Ghost DBA.

role_etl_writer para pipeline, role_api_reader para API (SELECT only).

Engenharia de Frontend (B2C PWA)

Velocidade: PWA puramente client-side. Zero SSR pesado (Sem Next.js).

Proibido exibir preços: O Frontend B2C nunca mostra R$. Apenas status visual (Verde, Amarelo, Vermelho).

Estado e Cache: Zustand estritamente para estado persistente do usuário (UF/Cidade). React Query estritamente para cache de API (Offline-first).

UI: Mobile-first, uso de Skeletons (sem spinners bloqueantes), suporte a fallback com Emojis gigantes caso imagens WebP falhem.

Componentes:
- LocationSelector: input de cidade com `<datalist>` populado via `useMunicipios(uf)` hook. Prefetch dos dados de sazonalidade via `usePrefetchSazonalidade()` com debounce 600ms no `onChange`.
- ProductCard: NUNCA exibe preços. Mapeia `status_cor` → classes Tailwind (bg/border/text). Imagem WebP com `onError` → emoji fallback via `getProdutoEmoji()`.
- Dashboard: ordenação `STATUS_ORDER[status_cor]` (VERDE=0 no topo, VERMELHO=2 no fim). Skeleton cards enquanto `isLoading`.

API queries: TanStack Query com `staleTime: 12h` para sazonalidade, `24h` para lista de municípios. Prefetch dispara quando input de cidade recebe foco ou muda com debounce.

Ações:
- O usuário seleciona UF e cidade → salvo em `useUserStore` com persist → `useSazonalidade` dispara automaticamente (enabled: !!uf && !!municipio).
- Botão "Alterar" no header do Dashboard → `clearLocation()` → volta ao LocationSelector.
- `handleDismiss` no LocationSelector (modo edição) → limpa store e fecha.