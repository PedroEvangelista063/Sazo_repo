# GOOGLE STUDIO — Alinhamento "HortiSazonal" ao Backend Real (Sazo_repo)

> **Mega prompt sênior — refatorar/alinhar a versão "HortiSazonal" do frontend gerada no Google Studio
> com o backend real do projeto: FastAPI + PostgreSQL remoto (Aiven) que alimenta todas as views.**
> Projeto: `quero_comprar_vg` · Repositório: `PedroEvangelista063/Sazo_repo`
> Fontes: `docs/STICH-GOOGLE-frontend.md` + exploração do código real verificada em 2026-08-10
> (backend/app, frontend/src, database/*.sql, config/regions.json, render.yaml, vercel.json).

---

## 0. ROLE & OBJECTIVE (instrução para o agente)

You are a **senior frontend engineer and PWA specialist**. Your mission is to **refactor and align the
"HortiSazonal" React version to the REAL backend contract of this project** — a FastAPI service backed by
a remote PostgreSQL (Aiven) — so every screen consumes real API data and real database-driven views.
Work incrementally, **preserve product behavior and the "Golden Rules"**, keep the existing test suite
green, and do not introduce new design systems.

**IMPORTANT — verify against the real codebase**: some features and packages of the Google Studio version
may not exist or may conflict with the real project. Treat the "Real Backend Contract" (§3), "Feature →
Endpoint Map" (§4), "Prohibited" (§5), "Stack" (§6) and "Verified File Tree" (§7) sections as **ground
truth**. Anything in the Google Studio version that is not backed by the real API or the Golden Rules must
be adapted or removed. Do NOT invent backend fields or endpoints.

**Product**: "HortiSazonal" (rebrand of "Quero Comprar") — a React **PWA** (offline-first, mobile-first)
for Brazilian consumers of hortifrúti. It shows seasonal price **status** as a traffic-light color system
(🟢 green = cheap/safra, 🟡 yellow = medium, 🔴 red = expensive/entressafra) for BR states and CEASA/CONAB
supply flows. **The UI NEVER shows monetary values** — only colors derived from the API. Visual fallbacks
use **emoji** (never images that can break layout). Audience: **B2C mobile, 15–72 years old** — legible,
inclusive, accessible.

---

## 1. GOLDEN RULES (non-negotiable)

1. **No money on screen**: never render `R$`, `$`, or price numbers. Only colors (VERDE/AMARELO/VERMELHO)
   derived from the API. The backend analytic endpoint `/sazonalidade/com-preco` returns prices but is
   **NOT B2C** — it must never be consumed by user-facing views.
2. **Offline-first**: PWA service worker; TanStack Query with high `staleTime`; persist user preferences;
   graceful offline UI (OfflineBanner). Runtime caching MUST keep `/api/v1/sazonalidade*`
   StaleWhileRevalidate + backgroundSync, images 30d, fonts 60d; `navigateFallback '/'` denying `/api/`.
3. **Mobile-first**: responsive from **320px**; touch targets ≥ **44px**; respect safe-area insets.
4. **Visual fallback**: unicode emoji via `PRODUTO_EMOJI` map — never break layout. The backend sends
   `icone_url` as `null` (see §5.1) — do not build any feature that depends on backend-provided images.
5. **Design system**: Tailwind + shadcn/ui is the default. Do not mix design systems (no MUI/Mantine/Rewind).
   Tokens are claymorphic (`shadow-clay-*`, `rounded-clay*`) + new **glass tokens** (§9.2).
6. **No generic loading spinners**: use skeleton cards with `animate-pulse`.
7. **Streaming**: keep SSE data-stream support (`/api/v1/stream/updates`) that invalidates query families
   on `ETL_FINISHED`.
8. **Theme**: dark/light via `.dark` class on `<html>`, controlled by `useTheme`, persisted under
   `qcomprar-theme`.
9. **Data transparency (V17)**: `DataTransparencyInfo` renders `null` when `!tipo_dado` (additive
   contract — old consumers keep working). Year anchors N → N-1 → N-2; `tipo_dado` values
   `REAL_ATUAL | HISTORICO_BASE | FALLBACK_DIMENSAO`; automatic lag label when `is_dado_legado`.
   Grade Sazonal always shows current year + button "Ver N-1 (histórico)".
10. **Brazil regional map**: 27-dot SVG map (one circle per UF) — **never** polygon maps or the
    `dotted-map` package (5MB SVGs).
11. **Null safety E2E**: always use `?.` / `??` when rendering backend data — gray (CINZA) months arrive
    with null fields (`ano_referencia`, `tipo_dado`, `mensagem_transparencia`).
12. **Vertical pill rail (Pílulas de Rolagem Vertical)**: filter chips, status pills, and quick-select
    options are a **vertical scroll-snap rail** — a column of rounded chips inside a scroll container
    with `scroll-snap-type: y proximity` (or `mandatory` on short lists), each pill
    `scroll-snap-align: start`, ≥44px touch targets, `scroll-padding-top` offset for the sticky header,
    scrollbar hidden on mobile, glassmorphism + clay styling, dark-mode safe. No overflow hidden without a
    snap container, no nested scroll traps, no wrapping grid that pushes layout. Use ONE shared `PillRail`
    component; do not duplicate snap markup.
13. **Language**: product/domain text is pt-BR (UI strings, product names, regions). Keep pt-BR in all
    user-facing copy. Code/comments in English.

---

## 2. REAL ARCHITECTURE & DATA FLOW

```
Browser (Vite PWA :5173) ── axios/SSE ──→ FastAPI (:8000, prefix /api/v1) ── asyncpg ──→ PostgreSQL Aiven (PRIMARY)
                                             │   cache TTL 1h, headers X-Cache-Status / X-Last-Refresh
                                             └── SSE /api/v1/stream/updates (ETL_FINISHED)
```

- **URLs**:
  - Local dev: frontend `http://localhost:5173`, proxy `/api` → `http://localhost:8000`
    (axios default `VITE_API_URL ?? 'http://localhost:8000/api/v1'`).
  - Produção: Vercel SPA/PWA → rewrite `"/api/(.*)" → "https://sazo-repo.onrender.com/api/$1"` (Render),
    CORS origins in `render.yaml`; Aiven PostgreSQL is PRIMARY, local Postgres is fallback/standby.
- **CORS**: `expose_headers=["X-Cache-Status","X-Last-Refresh"]` — read these in the axios response
  interceptor and publish to the transparency store (`PainelTransparenciaRodape`: lastRefresh + cache HIT/MISS).
- **Cache**: backend TTL 3600s (1h); `X-Cache-Status` HIT/MISS and `X-Last-Refresh` ONLY on `/sazonalidade*`
  routes. Do not display fake freshness elsewhere.
- **Failover**: backend falls back to local DB automatically (circuit breaker 60s). The frontend must
  handle `502/503/timeout` gracefully (retry 2, skeleton + error state with retry button, offline banner).
- **Rate limit**: 60/min default (120/min on Render) — avoid abusive parallel fetches; use TanStack Query
  caching (staleTime 5min, retry 2, refetchOnWindowFocus).

---

## 3. REAL BACKEND CONTRACT (FastAPI `/api/v1` — verificado)

### 3.1 Endpoints (all GET unless noted; pagination `pagina`/`por_pagina`, `por_pagina ≤ 2000`)

| Method + Path                        | Query params                                                                                                                                                                   | Key response fields                                                                                                                                                                                                                          |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /sazonalidade`                  | `regiao`, `uf` (2 chars; `BR`=nacional), `municipio`, `produto`, `status_cor` (VERDE\|AMARELO\|VERMELHO), `categoria`, `ano` (2024–2030), `mes` (1–12), `pagina`, `por_pagina` | `data[]: SazonalidadeResponse` (27 campos, §3.2), `total`, `pagina`, `por_pagina`                                                                                                                                                            |
| `GET /sazonalidade/br-sazonalidade`  | `ano` (**obrigatório**), `categoria`, `min_ufs` (1–27, default 1), `pagina`, `por_pagina`                                                                                      | `data[]: {produto, classificao_produto, categoria, meses[]: MesSazonalidade (10 campos), total_ufs}`, `total`, `pagina`, `por_pagina`                                                                                                        |
| `GET /sazonalidade/com-preco`        | `uf`, `produto`, `ano`, `mes`, `pagina`, `por_pagina`                                                                                                                          | **Analítico, NÃO B2C** (R$). Only used by dead views — do NOT consume.                                                                                                                                                                       |
| `GET /sazonalidade/{uf}/{municipio}` | `categoria`, `ano`, `mes`, `pagina`, `por_pagina`                                                                                                                              | Idem rota raiz                                                                                                                                                                                                                               |
| `GET /categorias`                    | —                                                                                                                                                                              | `data[]: {nome, descricao, total_produtos, icone}` (emoji icon hardcoded), `total`                                                                                                                                                           |
| `GET /municipios`                    | `uf` (**obrigatório**)                                                                                                                                                         | `data[]: string`, `total`                                                                                                                                                                                                                    |
| `GET /ufs`                           | —                                                                                                                                                                              | `{data: ["BR", ...ufs], total}`                                                                                                                                                                                                              |
| `GET /regioes`                       | —                                                                                                                                                                              | `{regioes[]: {id, nome, papel, ufs[], polos[]: {nome, uf, municipio, fonte_id, papel}, total_ufs}}` (static `config/regions.json`)                                                                                                           |
| `GET /fluxos`                        | —                                                                                                                                                                              | `data[]: {id, item, origem_uf, origem_polo, destino_regiao_id, destino_uf, meses[], sazonalidade, preco_referencial (string), tipo, descricao_tipo, periodicidade, regiao_destino_nome, categoria, cor_indicadora, ano_referencia}`, `total` |
| `GET /stream/updates` (SSE)          | —                                                                                                                                                                              | events `connected`, `ETL_FINISHED`, `PIPELINE_DONE`; keepalive 30s                                                                                                                                                                           |

Internal/admin (`/_internal/*`, `/admin/*`) are backend-only — never called by the frontend.

### 3.2 `SazonalidadeResponse` — campos exatos (fonte `backend/app/schemas/responses.py`)

`id_produto`, `nome_produto`, `icone_url` (**always null**), `uf`, `municipio`, `municipio_id`, `ano`, `mes`,
`data_referencia_atual`, `preco_estimado`, `usou_fallback_12m`, `status_cor` (Literal VERDE/AMARELO/VERMELHO),
`fonte`, `categoria`, `tendencia_futura` (QUEDA|ALTA|ESTAVEL), `is_forecast`, `confianca_baseline`,
`forecast_method`, `regiao`, `ano_referencia`, `tipo_dado` (REAL_ATUAL|HISTORICO_BASE|FALLBACK_DIMENSAO),
`mensagem_transparencia`, `is_dado_legado`.

`MesSazonalidade` (em `/br-sazonalidade`): `mes`, `status_cor`, `is_forecast`, `baseline_confianca`,
`forecast_method`, `calculado_em`, + V17 transparency fields.

### 3.3 Typo "canônicos" — MANTER (não "corrigir")

`classificao_produto` (schema + SQL + tipo TS), `meses`, `status_cor`. Alinhar os tipos TS exatamente a
esses nomes.

---

## 4. FEATURE → ENDPOINT MAP (cada tela/alimentada pelo backend real)

| Feature (HortiSazonal)                  | Endpoint real                                                                    | Observações de alinhamento                                                                                                                                                              |
| --------------------------------------- | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Cards** (modo cards)                  | `GET /sazonalidade?uf=&por_pagina=1000` (+ `ano`/`mes` p/ filtro)                | Card = emoji + status + badges de transparência V17 + `DataTransparencyInfo`; tendência (`tendencia_futura`); contagem de UFs produtoras derivada de `/fluxos` (client-side)            |
| **Grade Sazonal** (global BR)           | `GET /sazonalidade/br-sazonalidade?ano=&por_pagina=1000`                         | Apresentação GLOBAL (Brasil inteiro), 12 meses (J–D), dividida por macrocategorias; **sem seletor de UF**, **sem filtro de mês**; chips/categorias em PillRail vertical; "Ver N-1" link |
| **Mapa Regional**                       | `GET /regioes` + `GET /sazonalidade?regiao=&ano=&por_pagina=500` + `GET /fluxos` | 27-dot SVG; arcos animados entre UFs produtoras (origem `/fluxos`) e centros consumidores; `RegiaoPanel` com polos CEASA (`fonte_id`); `tipo="autossuficiente"` → "Produção local"      |
| **Barra de filtros** (status/categoria) | client-side sobre dados reais                                                    | vira **Bottom Sheet** no mobile (ver §9.3); status VERDE/AMARELO/VERMELHO/Todos; categorias via `/categorias`                                                                           |
| **Busca rápida** (modal)                | client-side sobre dados reais                                                    | `Dialog` centralizado no desktop, **Bottom Sheet** no mobile; chips de sugestão (produto/estado) em PillRail                                                                            |
| **Seletor de mês**                      | `GET /sazonalidade?uf=&ano=&mes=` / br-sazonalidade                              | Modal calendário Jan–Dez com indicador do mês atual; recalcula safras via query                                                                                                         |
| **Seletor de UF**                       | `GET /ufs`                                                                       | Dropdown nativo OU Bottom Sheet; fallback hardcoded SP/RS/PR/SC/MG/RJ/ES enquanto carrega                                                                                               |
| **Categorias (modal)**                  | `GET /categorias`                                                                | Drill-down por categoria + toggle de produto + busca                                                                                                                                    |
| **OfflineBanner**                       | `navigator.onLine` + PWA SW                                                      | Mostra dados em cache; reconnect automático; dados vieram do SW                                                                                                                         |
| **Painel de Transparência**             | headers `X-Cache-Status`/`X-Last-Refresh`                                        | Rodapé global: lastRefresh + cache HIT/MISS; metodologia CEASA/CONAB; legenda de cores                                                                                                  |
| **Header/TopAppBar**                    | —                                                                                | sticky, glassmorphism (§9.2), busca, mês, tema, instalar PWA                                                                                                                            |
| **Instalar App PWA**                    | manifest.json + SW                                                               | Botão dinâmico (evento `beforeinstallprompt`)                                                                                                                                           |

---

## 5. PROHIBITED / GAPS — o que a versão Google Studio deve ADAPTAR ou REMOVER

1. **Imagens HD / Copiar URL / Gerador de Tag HTML**: o backend envia `icone_url = null` e a regra do
   produto é **emoji como fallback visual** (nunca imagens que quebram layout). Remover as features de
   "links diretos de imagem HD", "copiar URL da imagem" e "gerador de tag `<img>`". Se quiser alguma
   identidade visual rica, use **emoji + claymorphism + gradientes** — nunca dependa do backend p/ imagens.
2. **`ufs_produtoras` / UFs produtoras na grade BR**: o backend NÃO expõe esse campo na grade.
   Derivar client-side a partir de `/fluxos` (`origem_uf` por produto) quando aplicável.
3. **Endpoint "CEASAs" dedicado**: não existe. Usar polos de `/regioes` (`fonte_id`) + nomes de polo em
   `/fluxos`.
4. **R$ / valores monetários**: proibido em qualquer view B2C, inclusive tooltips e atributos aria.
   `preco_referencial` em `/fluxos` é string — nunca exibir como preço.
5. **`/sazonalidade/com-preco`**: NÃO consumir em telas de usuário (código morto no frontend atual).
6. **Mapas poligonais / `dotted-map`**: proibido. Sempre o SVG de 27 pontos.
7. **Novos design systems / libs de UI**: proibido (sem MUI/Mantine/Rewind/outros). Sem novas deps de
   runtime salvo justificativa estrita (ex.: glassmorphism já é nativo com `backdrop-blur`).
8. **"Corrigir" typos canônicos**: proibido (§3.3).
9. **Dados mockados/hardcoded**: qualquer tela precisa consumir os endpoints reais. Não simular
   respostas da API. Dados de fallback visual (skeleton/empty) sim, dados falsos não.
10. **Redundância de queries**: não duplicar chamadas de `/sazonalidade` (meta vs filter). Uma query por
    intenção; alinhar query keys ao padrão atual (`['hortifruti-meta', uf]`, `['hortifruti-filter', uf, ano, mes]`,
    `['br-sazonalidade', ano]`, `['regiao-resumo', regiaoId, ano]`, `['regioes']`, `['ufs']`,
    `['categorias']`, `['fluxos']`). SSE invalida: hortifruti-meta, hortifruti-filter, categorias,
    br-sazonalidade, regiao-resumo, regioes (+ adicionar fluxos/ufs se o backend passar a publicar).
11. **Synthetic badges**: nada de `📊 Estimativa`/`🪄 Estimado` — badges V17 de transparência (ano âncora).

---

## 6. STACK (verificado em `frontend/package.json`)

react/react-dom 19, @tanstack/react-query 5, @tanstack/react-table 8 (só código morto), zustand 5 (só código
morto), framer-motion 12, axios, recharts 2 (só código morto), three/@react-three/fiber/drei (background
`Beams` — reduzir custo, `frameloop="demand"` ou remover), canvas-confetti/idb-keyval (código morto),
@radix-ui/react-dialog/select/slot/tabs, lucide-react, cva/clsx/tailwind-merge, tailwindcss-animate,
@fontsource-variable/fredoka. Dev: vite 6, vite-plugin-pwa, vitest 4, @testing-library/react, tailwind 3.4,
typescript 5.9, prettier. **NÃO instalado**: react-router, Redux, SWR, react-hook-form, zod, gsap, MUI,
Mantine, dotted-map — não reintroduzir.

---

## 7. VERIFIED FILE TREE (frontend/src — referência para manter o padrão)

```
App.tsx / main.tsx / index.css
components/  ProductCard, DataTransparencyInfo, PainelTransparenciaRodape, CategoriesModal,
             GradeSazonalAcordeao, SazonalidadeNacional, RegiaoPanel, BrasilMap, DynamicBackground,
             BRNationalIcon, Beams, SpotlightCard, BlurText, ThemeToggle, SkeletonCard,
             ui/ (badge, button, card, dialog, skeleton, tabs, table, select — regenerar p/ clay+glass)
hooks/  useHortifruti, useRegioes, useRegiaoResumo, useSazonalidadeComPreco (morto→remover),
        useDataStream, useCategorias, useUfs, useFluxos, useTheme, useConfetti (morto→remover)
lib/    utils.ts (cn), motion-presets.ts, index.ts (barrel)
services/ api.ts (axios + interceptors headers → transparencyStore), transparencyStore.ts
store/  useUserStore.ts (morto → remover)
pages/  SupermercadoView.tsx (~746 linhas — quebrar em componentes/hooks, manter 3 abas)
types/  domain.ts (alinhar campos exatos com §3.2, incluir forecast_method)
utils/  categorizacaoProdutos.ts (macrocategorias), bandeirasUf.ts (27 UFs + MAPA_BRASIL_URL)
test/   ProductCard.test.tsx, DataTransparencyInfo.test.tsx, SazonalidadeNacional.test.tsx,
        BRNationalIcon.test.tsx, DynamicBackground.test.tsx, GradeSazonalAcordeao.test.tsx,
        PainelTransparenciaRodape.test.tsx, categorizacaoProdutos.test.ts
```

---

## 8. TECHNICAL DEBT (manter no radar da refatoração)

1. Remover código morto: `GameCard`, `GameButton`, `LivingStatus`, `TabelaView`, `GraficosView` (renderiza
   R$! inalcançável), `TiltedCard`, `useConfetti`, `useUserStore`, `useFluxosPorRegiao` + deps órfãs
   (`recharts`, `@tanstack/react-table`, `canvas-confetti`, `idb-keyval`, `motion` duplicado de framer-motion).
2. `ui/select.tsx`, `ui/table.tsx`, `ui/tabs.tsx` regenerados com `oklch()` inexistente na config
   (`cssVariables: false`) → re-tokenizar para o sistema sazonal/clay/glass.
3. `SupermercadoView` monolítico → extrair filtros/selectors/tabs; considerar URL params p/ estado
   compartilhável.
4. `Beams` (Three.js `frameloop="always"`) pesado → `frameloop="demand"` / remover / GPU-friendly.
5. `types/index.ts` barrel incompleto → completar.
6. Sem ESLint (só `tsc --noEmit`); Playwright smoke órfão; `'use client'` em SPA → limpar.

---

## 9. NOVOS REQUISITOS DE UI/UX (prioridade do cliente)

### 9.1 Público 15–72 anos — melhores práticas de UI/UX (obrigatório)

- **Legibilidade**: base ≥16px; hierarquia clara; contraste AA (texto sobre glass/clay em dark e light).
- **Alvo de toque ≥44px** em tudo (chips, botões, abas, selects); espaçamento generoso.
- **Simplifique**: linguagem pt-BR simples, sem jargão; estados vazios explicativos (ex.: "Sem dados
  reais para este mês" com badge CINZA/transparência).
- **Microinterações**: Framer Motion para transições sutis; respeitar `prefers-reduced-motion`
  (desabilitar parallax/blur pesado e orbit).
- **Feedback**: skeleton (nunca spinner bloqueante); estados de erro com botão "Tentar novamente";
  toasts suaves; foco visível.
- **Dark/light**: completo, sem perda de contraste; `prefers-color-scheme` + toggle persistido.
- **Acessibilidade**: semântica, aria-labels, foco trap em modais/sheets, ESC fecha, backdrop dismiss.

### 9.2 Glassmorphism (morfismo de vidro / Backdrop Blur)

- Superfícies flutuantes (header sticky, modais, bottom sheets, painéis, chips) com
  `backdrop-blur` + fundo translúcido (`bg-white/60`, `dark:bg-slate-900/60`), borda sutil
  (`border-white/20`, `dark:border-white/10`), sombras suaves.
- **Equilíbrio**: cards e botões continuam claymorphic; glass é para sobreposição/camadas que flutuam
  sobre o conteúdo (header, sheets, dialogs, painéis laterais).
- **Performance**: evitar blur em área gigante fixa; limitar layers de blur (máx. 2–3 simultâneas);
  GPU-friendly; fallback sólido se `backdrop-filter` não suportado (fundo quase opaco).
- Definir tokens no tailwind.config.js: `glass`, `glass-dark`, `glass-border`, `shadow-glass`.

### 9.3 Bottom Sheet vs Dialog / Modal

- **Bottom Sheet** (mobile, <768px): desliza de baixo para cima — filtros, seleção de mês, busca rápida,
  seleção de UF, ações. Com alça de arrasto, snap points (ex.: 50%/100%), safe-area bottom,
  backdrop dismiss + ESC, focus trap, ≥44px.
- **Dialog / Modal** (desktop, ≥768px): centralizado — modal de detalhes, categorias, metodologia.
- Usar `@radix-ui/react-dialog` (já instalado) como base e customizar com clay+glass; NÃO adicionar lib
  de bottom sheet — implementar com Radix + Framer Motion ou componente próprio pequeno.
- Transição: `slide-up` no mobile, `scale/fade` no desktop; reduzir movimento se
  `prefers-reduced-motion`.

### 9.4 Pílulas de Rolagem Vertical (mobile) — Golden Rule 12

- Chips de filtro (status, categorias, macrocategorias da Grade, sugestões de busca) = **PillRail
  vertical com scroll-snap**: `scroll-snap-type: y proximity`, `scroll-snap-align: start`,
  `scroll-padding-top` (offset do header sticky), scrollbar oculto no mobile, targets ≥44px,
  clay+glass styling, dark-safe.
- **Um único componente `PillRail` compartilhado** — sem duplicar markup de snap; sem grid que quebra
  layout; sem scroll trap aninhado.

---

## 10. CONSTRAINTS & DELIVERABLE

- **Não alterar** o contrato do backend, endpoints ou formas de resposta.
- **Não regredir** as Golden Rules (§1), especialmente "sem R$" e badges de transparência.
- **Manter testes verdes**: `cd frontend && npm test` (Vitest + RTL, jsdom). Ajustar/adicionar testes para
  módulos extraídos e novos componentes (PillRail, BottomSheet, GlassHeader).
- **Type-check**: `npm run lint` (`tsc --noEmit`). TypeScript estrito, sem `any`.
- **Style**: Tailwind + shadcn/ui + tokens clay/glass; Framer Motion; sem novas deps de runtime sem
  justificativa; sem novo design system.
- **Output**: plano faseado (o que remover → o que corrigir → o que extrair → verificação), depois
  implementar incrementalmente com commits conventional (`refactor:`, `feat:`, `fix:`, `chore:`).
- **Verificar contra o código real** antes de cada fase (não confiar só neste documento).
