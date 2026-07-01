Regras da Casa — quero_comprar_vg

Contexto para OpenCode, GGA e agentes AI

Tech Stack

Backend: Python 3.11+ (FastAPI, Polars, psycopg2, asyncpg, rapidfuzz)

Frontend: React 18.3+ com Vite 6 (PWA, TailwindCSS 3.4, Zustand 5, TanStack Query v5)

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

Classificação de Produtos (Categoria B2C)

A separação entre ALIMENTO_VAREJO e as demais categorias (MAQUINARIO_FERRAMENTA, INSUMO_AGRICOLA, SERVICO_LOGISTICA, MATERIA_PRIMA_B2B) é feita por motor de regex no pipeline Python — tanto em ingestao_conab.py quanto em process_to_files.py.

Regras de classificação:
  - ALIMENTO_VAREJO: itens de consumo doméstico direto (carne, hortifrúti, arroz, feijão, pão, etc.). É a ÚNICA categoria que chega ao app B2C.
  - MAQUINARIO_FERRAMENTA: tratores, escadas, botas, luvas, paquímetros (regex: TRATOR|ESCADA|BOTA|LUVAS|TRAPICHO etc.).
  - INSUMO_AGRICOLA: agroquímicos, sementes, óleos vegetais (regex: SEMENTE|NEMAT|FLUIL|NATIVO|SENCOR etc.).
  - SERVICO_LOGISTICA: transporte, passagem, pátio, tratamento (regex: TRANSPORTE|PASSAGEM|PATIO|TRATAMENTO).
  - MATERIA_PRIMA_B2B: categoria residual — tudo que não casa com as regras acima.

As REGRAS_CATEGORIAS estão definidas em ingestao_conab.py (linhas 457-475) e replicadas em process_to_files.py (linhas 65-74).

Banco de Dados (Arquitetura Medalhão & Observability)

raw → dados como chegam (COPY direto).

staging → dimensões + fato limpos (Anomalias >500% vão para staging.precos_rejeitados).

mart → sazonalidade materializada para API (Acesso via vw_api_produtos_sazonalidade).

ops → schema de observabilidade monitorado pelo Ghost DBA.

role_etl_writer para pipeline, role_api_reader para API (SELECT only).

Sazonalidade — Baseline Híbrido 2025 + Fallback Condicional (Fase 6)
⚠ ATENÇÃO: A MÉDIA MÓVEL CONTÍNUA (rolling window) FOI ABANDONADA.
   Mas existe um FALLBACK DE 12 MESES para produtos NOVOS (sem 2025).
   NUNCA aplique média móvel para produtos COM baseline 2025.

Modelo híbrido atual:
  - Baseline primário: média do produto em 2025 (Ano Âncora Absoluto).
    Prevalece sempre que existir: COALESCE(media_2025, media_12m).
  - Fallback condicional: para produtos que NÃO existiam em 2025
    (ex: começaram a ser catalogados pela CONAB em 2026), o sistema
    calcula a média dos ÚLTIMOS 12 MESES disponíveis como âncora provisória.
    Requer no mínimo 3 meses de dados históricos.
  - Semáforo: compara o preco_atual contra preco_referencia:
    - VERDE:     preco_atual < preco_referencia * 0.85 (≥15% abaixo)
    - AMARELO:   preco_atual entre ±15% da referência
    - VERMELHO:  preco_atual > preco_referencia * 1.15 (>15% acima)
    - INSUFICIENTE: sem 2025 E sem fallback (dados insuficientes)
  - Flag usou_fallback_12m: TRUE se a âncora veio do fallback (não de 2025).
    O frontend usa para exibir: "*Comparado aos últimos 12 meses".
  - Tabela mart.sazonalidade_produto: snapshot por (id_produto, id_localidade).
    Colunas: preco_referencia, preco_atual, data_referencia_atual,
    usou_fallback_12m, status_cor.
  - SP principal: sp_calcular_sazonalidade_baseline().
    Usa 4 CTEs (set-based): base_2025 → ultimos_precos → fallback_12m → master_join.
  - MV vw_api_produtos_sazonalidade: expõe preco_referencia, preco_atual,
    usou_fallback_12m. Filtra ALIMENTO_VAREJO. UNIQUE INDEX para CONCURRENTLY.

Engenharia de Frontend (B2C PWA)

Velocidade: PWA puramente client-side. Zero SSR pesado (Sem Next.js).

Proibido exibir preços: O Frontend B2C nunca mostra R$. Apenas status visual (Verde, Amarelo, Vermelho).

Estado e Cache: Zustand 5 estritamente para estado persistente do usuário (UF/Cidade, persist via IndexedDB com idb-keyval). TanStack Query v5 estritamente para cache de API (Offline-first, stale-while-revalidate).

UI: Mobile-first, uso de Skeletons (sem spinners bloqueantes). Produtos usam emoji unicode exclusivamente — sem imagens (jpg, png, webp, svg, avif).

Componentes:
- LocationSelector: input de cidade com `<datalist>` populado via `useMunicipios(uf)` hook.
- ProductCard: NUNCA exibe preços. Usa emoji unicode via `PRODUTO_EMOJI` map. Mapeia `status_cor` → classes Tailwind (bg/border/text).
- Dashboard: seções colapsáveis para "Monte sua Lista" e grid de produtos (ChevronDown com rotação). Ordenação `STATUS_ORDER[status_cor]` (VERDE=0 no topo, VERMELHO=2 no fim). Skeleton cards enquanto `isLoading`.

API queries: `useHortifruti(ano?, mes?)` executa duas queries TanStack Query: `hortifruti-meta` (snapshot sem filtro, para metadados) e `hortifruti-filter` (ativada apenas com ano+mes, para cards). `staleTime: 12h` para sazonalidade, `24h` para lista de municípios.

Cache do backend: os dados mensais históricos usam cache imutável de 24h com chave apenas de dimensões (ano, mês, UF, município, categoria). Requisições com diferentes filtros de produto/semáforo/páginação são servidas de memória.

Ações:
- O usuário seleciona UF e cidade → salvo em `useUserStore` com persist → `useHortifruti` dispara automaticamente (enabled: !!uf && !!municipio).
- Botão "Alterar" no header do Dashboard → `clearLocation()` → volta ao LocationSelector.
- `handleDismiss` no LocationSelector (modo edição) → limpa store e fecha.