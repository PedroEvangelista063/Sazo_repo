# STICH-GOOGLE-frontend

> **Mega resumo do frontend — prompt de refatoração para Google Stitch**
> Projeto: `quero_comprar_vg` · Repositório: `PedroEvangelista063/Sazo_repo` (renomeado de `Quero_Comprar_ext`)
> Fontes: `frontend/summary.md` (histórico e regras de produto, 2026-08-07) + estado real do código verificado em 2026-08-10 (package.json, src/, configs, testes).

---

## 0. ROLE & OBJECTIVE (instrução para o agente)

You are a senior frontend engineer and refactoring specialist. Your mission is to **refactor the React frontend described below** to make it leaner, more maintainable, and more consistent, **without changing product behavior** and **without violating any of the "Golden Rules"**. Work incrementally, preserve the existing test suite, and do not introduce new design systems. Deliver clean, typed, mobile-first, offline-first code with comments only where non-obvious.

**IMPORTANT — verify against the real codebase**: some packages and files mentioned in legacy docs no longer exist in `frontend/package.json`. Treat the "Current Stack" and "Verified File Tree" sections as ground truth; treat `frontend/summary.md` as product-history context only.

---

## 1. PRODUCT OVERVIEW

- **What**: "Quero Comprar" — a React **PWA** (offline-first, mobile-first) for Brazilian consumers of horticultural products (hortifrúti). It displays seasonal price **status** as a traffic-light color system (🟢 green = cheap, 🟡 yellow = medium, 🔴 red = expensive) for BR states/municipalities and CEASA/CONAB supply flows.
- **Critical product rule**: the UI **NEVER shows monetary values** (`R$`, `$`, numeric prices). Only colors derived from the API. Visual fallbacks use **emoji** (never images that can break layout).
- **Audience**: B2C mobile users in Brazil; design must work from **320px** width, touch targets ≥ 44px.
- **Status of data transparency**: the app must clearly distinguish real current data (`REAL_ATUAL`), historical anchor-year data (`HISTORICO_BASE`), and reference/fallback data (`FALLBACK_DIMENSAO`), including year-anchor badges and "(i)" transparency tooltips. Empty/unavailable months render as **gray (CINZA)** — with **null-safe frontend handling** (`?.`/`??`) because months without real data arrive with null fields.
- **Language**: product/domain text is pt-BR (UI strings, product names, regions). Keep pt-BR in all user-facing copy.

## 2. GOLDEN RULES (non-negotiable)

1. **No money on screen**: never render `R$`, `$`, or price numbers. Only colors (VERDE/AMARELO/VERMELHO) derived from the API.
2. **Offline-first**: PWA service worker; TanStack Query with high `staleTime`; persist user preferences; graceful offline UI.
3. **Mobile-first**: responsive from 320px; touch targets ≥ 44px.
4. **Visual fallback**: unicode emoji via `PRODUTO_EMOJI` map — never break layout.
5. **Tailwind + shadcn/ui is the default design system**; do not mix design systems (no MUI/Mantine/Rewind in new code — legacy ones are removed).
6. **No generic loading spinners**: use skeleton cards with `animate-pulse`.
7. **Streaming**: keep SSE data-stream support (`useDataStream`).
8. **Theme**: dark/light via `.dark` class on `<html>`, controlled by `useTheme`, persisted under `qcomprar-theme`.
9. **Forecast transparency**: forecast rows show `📊 Estimativa` badge with CSS tooltip for confidence; real rows get no indicator (note: recent V17 work replaced synthetic badges with anchor-year badges — see section 9).
10. **Data transparency (V17)**: `DataTransparencyInfo` renders `null` when `!tipo_dado` (additive contract — old consumers keep working). Never show `R$`.
11. **Brazil regional map**: 27-dot SVG map (one circle per UF) — never use polygon maps or the `dotted-map` package (it generated 5MB SVGs).
12. **Null safety E2E**: always use optional chaining / nullish coalescing when rendering backend data (gray status arrives with null fields: `ano_referencia`, `tipo_dado`, `mensagem_transparencia`).
13. **Vertical pill rail (Chips / Scroll Snap)**: filter chips, status pills, and quick-select options are rendered as **pills in a vertical scroll-snap rail** — a column of rounded chips inside a scroll container with `scroll-snap-type: y proximity` (or `mandatory` on short lists), each pill `scroll-snap-align: start`, ≥44px touch targets, sticky header offset respected (`scroll-padding-top`), scrollbar hidden on mobile, claymorphism styling. No overflow hidden without a snap container, no nested scroll traps, no wrapping grid that pushes layout.

## 3. CURRENT STACK (verified in `frontend/package.json` + node_modules)

### Production dependencies

| Package                                          | Version                                                                |
| ------------------------------------------------ | ---------------------------------------------------------------------- |
| react / react-dom                                | 19.2.8                                                                 |
| @tanstack/react-query                            | 5.101.4                                                                |
| @tanstack/react-table                            | 8.21.3                                                                 |
| zustand                                          | 5.0.14                                                                 |
| framer-motion                                    | 12.42.2                                                                |
| motion                                           | 12.42.2 (redundant duplicate of framer-motion — candidate for removal) |
| axios                                            | 1.18.1                                                                 |
| recharts                                         | 2.15.4 (only used by dead code)                                        |
| three / @react-three/fiber / @react-three/drei   | 0.180.0 / 9.6.1 / 10.7.7 (Three.js background)                         |
| canvas-confetti                                  | 1.9.4 (only used by dead code)                                         |
| idb-keyval                                       | 6.3.0 (only used by dead code)                                         |
| @radix-ui/react-dialog / -select / -slot / -tabs | ^1.x (shadcn primitives)                                               |
| lucide-react                                     | 0.460.0                                                                |
| class-variance-authority / clsx / tailwind-merge | cva 0.7.1 / clsx 2.1.1 / tw-merge 3.6.0                                |
| tailwindcss-animate                              | 1.0.7                                                                  |
| @fontsource-variable/fredoka                     | 5.3.0                                                                  |

### Dev dependencies

| Package                                              | Version                          |
| ---------------------------------------------------- | -------------------------------- |
| vite                                                 | 6.4.3                            |
| vite-plugin-pwa                                      | 0.21.2                           |
| vitest                                               | 4.1.10                           |
| @testing-library/react / jest-dom / user-event / dom | 16.3.2 / 6.9.1 / 14.6.1 / 10.4.1 |
| tailwindcss                                          | 3.4.19                           |
| typescript                                           | 5.9.3                            |
| @vitejs/plugin-react                                 | 4.3.0                            |
| prettier + prettier-plugin-tailwindcss               | 3.9.5 / 0.8.0                    |
| jsdom                                                | 29.1.1                           |
| postcss / autoprefixer                               | 8.4.0 / 10.4.0                   |

### NOT installed (despite legacy docs): react-router, react-router-dom, Redux Toolkit, react-redux, SWR, react-hook-form, zod, gsap, date-fns, @mui/material, @mantine, @rewind-ui/core, dotted-map. `node_modules` contains empty leftover dirs (`@mui`, `@mantine`, `@reduxjs`) from a pruned install — clean them.

## 4. VERIFIED FILE TREE (`frontend/src`)

```
src/
├── App.tsx                      # root: useTheme() + useDataStream(); renders SupermercadoView
├── main.tsx                     # entry: StrictMode > QueryClientProvider (staleTime 5min) > App; PWA auto-register
├── index.css                    # Tailwind directives + CSS vars light/dark + glass tokens + fruit-orbit keyframes
├── vite-env.d.ts                # import.meta.env types (VITE_API_URL)
├── components/
│   ├── ProductCard.tsx          # LIVE product card: SpotlightCard + emoji + status + V17 transparency badges + DataTransparencyInfo
│   ├── GameCard.tsx             # DEAD CODE (superseded by ProductCard) — duplicated PRODUTO_EMOJI/STATUS_CONFIG
│   ├── GameButton.tsx           # DEAD CODE (motion variants)
│   ├── LivingStatus.tsx         # DEAD CODE (status pill + StatusFilterChips)
│   ├── TabelaView.tsx           # DEAD CODE (TanStack Table; only consumer of useSazonalidadeComPreco)
│   ├── GraficosView.tsx         # DEAD CODE (Recharts; renders R$ — violates rule 1 — but unreachable)
│   ├── TiltedCard.tsx           # DEAD CODE (React Bits style 3D tilt)
│   ├── SkeletonCard.tsx         # loading state (ui/Skeleton, animate-pulse)
│   ├── DataTransparencyInfo.tsx # (i) tooltip: year anchor / tipo_dado / defasagem; null when no tipo_dado
│   ├── PainelTransparenciaRodape.tsx # global footer: transparencyStore lastRefresh + cache status
│   ├── CategoriesModal.tsx      # shadcn Dialog: category drill-down + product toggle + search
│   ├── GradeSazonalAcordeao.tsx # macrocategory accordion over SazonalidadeNacional (lazy mount, sticky headers)
│   ├── SazonalidadeNacional.tsx # 12-month grid: status cells, year-anchor badges, low-coverage warnings, null-safe empty cells
│   ├── RegiaoPanel.tsx          # side panel: region info, CEASA polos, status counts, flow lists
│   ├── BrasilMap.tsx            # 27-dot SVG Brazil map + convex-hull regions + animated flow arcs; /br-map.svg background
│   ├── DynamicBackground.tsx    # fixed bg: sliding Brazil map + UF flag (cards) OR 27-flag crossfade carousel (grade)
│   ├── BRNationalIcon.tsx       # 🇧🇷 circular button with orbiting fruit emoji (replaces UF dropdown in Grade/Mapa modes)
│   ├── Beams.tsx                # Three.js light-beam background (8% opacity, frameloop="always" — heavy)
│   ├── SpotlightCard.tsx        # mouse-tracked spotlight card wrapper (React Bits style)
│   ├── BlurText.tsx             # word-by-word blur reveal (motion/react)
│   ├── ThemeToggle.tsx          # Sun/Moon dark toggle
│   └── ui/                      # shadcn primitives: badge, button (variants light/clay), card, dialog, skeleton, tabs, table, select
├── hooks/
│   ├── useHortifruti.ts         # main seasonal query (3 internal queries: br-sazonalidade / meta / filter)
│   ├── useRegioes.ts            # ['regioes'] → /regioes (24h)
│   ├── useRegiaoResumo.ts       # ['regiao-resumo'] → /sazonalidade?regiao=
│   ├── useSazonalidadeComPreco.ts # ['sazonalidade-com-preco'] → /sazonalidade/com-preco (only dead views)
│   ├── useDataStream.ts         # SSE EventSource /stream/updates; invalidates 7 query families; backoff 1s→30s
│   ├── useCategorias.ts         # ['categorias'] → /categorias (24h)
│   ├── useUfs.ts                # ['ufs'] → /ufs (1h)
│   ├── useFluxos.ts             # ['fluxos'] → /fluxos (24h) + useFluxosPorRegiao (dead-ish, client filter)
│   ├── useTheme.ts              # theme + toggleTheme + isDark (localStorage qcomprar-theme)
│   └── useConfetti.ts           # canvas-confetti presets (only dead code)
├── lib/
│   ├── utils.ts                 # cn() = clsx + tailwind-merge
│   ├── motion-presets.ts        # gameButtonVariants, shakeX, glowPulse, stagger, slideUpFade, scaleSpring…
│   └── index.ts                 # barrel
├── services/
│   ├── api.ts                   # axios instance: baseURL VITE_API_URL ?? localhost:8000/api/v1, timeout 10s; response interceptor reads x-last-refresh/x-cache-status → transparencyStore
│   └── transparencyStore.ts     # tiny hand-rolled pub/sub (lastRefresh, cacheStatus)
├── store/
│   └── useUserStore.ts          # Zustand persist (IndexedDB via idb-keyval, key qcomprar-user) — DEAD CODE (never imported)
├── pages/
│   └── SupermercadoView.tsx     # ~746 lines — the ONLY page; owns ALL filter state locally; 3 tabs
├── types/
│   ├── domain.ts                # ALL domain types (see §6)
│   └── index.ts                 # incomplete barrel (only 4 of 13+ types re-exported)
├── utils/
│   ├── categorizacaoProdutos.ts # macrocategoria classifier (keyword → frutas/verduras/legumes/tuberculos/ovos_graos_diversos/outros)
│   └── bandeirasUf.ts           # BANDEIRAS_UF (27 Wikimedia SVG URLs) + MAPA_BRASIL_URL
└── test/
    ├── setup.ts                 # jest-dom
    ├── ProductCard.test.tsx     # 12 tests: semáforo, emoji fallback, no R$, V17 badges, no synthetic 📊/🪄, ano de apuração
    ├── DataTransparencyInfo.test.tsx  # 4 tests: additive contract, labels, no R$
    ├── SazonalidadeNacional.test.tsx  # 4 tests: year badge, (i) icon, empty cell, no R$
    ├── BRNationalIcon.test.tsx  # 5 tests: render, pulse, orbit, fallback, UF toggle
    ├── DynamicBackground.test.tsx     # map layer, flags, carousel, error isolation
    ├── GradeSazonalAcordeao.test.tsx  # destaque auto-open, lazy mount, aria-expanded, sticky
    ├── PainelTransparenciaRodape.test.tsx # null without lastRefresh, date fmt, HIT/MISS
    ├── categorizacaoProdutos.test.ts  # classifier precedence, whole-word, grouping
    └── smoke_e2e.mjs             # Playwright smoke (orphaned: not in scripts; playwright not a devDep)
```

## 5. ARCHITECTURE & DATA FLOW

```
Browser (Vite PWA, :5173) ─── axios/SSE ───→ Backend FastAPI (:8000) ─── asyncpg ───→ PostgreSQL/Supabase
        VITE_API_URL (prod: /api rewritten to https://sazo-repo.onrender.com/api via vercel.json)
```

- **Single page, no router**: `App.tsx` renders `SupermercadoView` directly. (Legacy docs claim React Router 7 — **not installed**.)
- **Data fetching**: TanStack Query v5 (client: `staleTime 5min`, `retry 2`, `refetchOnWindowFocus`). Query keys per hook (§ file tree).
- **State**: all filter state (UF/year/month/products/status/region/mapUF) is **local `useState` inside SupermercadoView**; Zustand store exists but is dead code; no URL sync.
- **SSE live updates**: `useDataStream` opens `EventSource /api/v1/stream/updates`; on `ETL_FINISHED` invalidates 7 query families; exponential backoff reconnect 1s→30s.
- **PWA**: vite-plugin-pwa `autoUpdate`; manifest pt-BR "Quero Comprar — Sazonalidade de Hortigranjeiros", `theme_color #16a34a`; Workbox runtime caching: `/api/v1/sazonalidade*` StaleWhileRevalidate 7d + backgroundSync `sync-sazonalidade`, `/api/v1/municipios*` CacheFirst 24h (unused code path), images 30d, fonts 60d; `navigateFallback '/'` (deny `/api/`).
- **Theme**: `darkMode: 'class'`; `index.html` inline script flips `theme-color` from localStorage `qcomprar-theme` or `prefers-color-scheme`.
- **Build**: target es2020, manualChunks (vendor-react, vendor-icons=lucide, vendor-store=zustand+query, vendor-http=axios).

## 6. DOMAIN TYPES (`types/domain.ts`)

- `StatusCor = 'VERDE' | 'AMARELO' | 'VERMELHO'`
- `ProdutoVarejo` — `id_produto`, `nome_produto`, `icone_url`, `uf`, `municipio(_id)`, `ano`, `mes`, `data_referencia_atual`, `preco_estimado`, `usou_fallback_12m`, `status_cor`, `fonte`, `categoria`, `is_forecast`, `confianca_baseline`, `tendencia_futura ('QUEDA'|'ALTA'|'ESTAVEL'|null)`, `regiao` + V17 optional: `ano_referencia`, `tipo_dado ('REAL_ATUAL'|'HISTORICO_BASE'|'FALLBACK_DIMENSAO')`, `mensagem_transparencia`, `is_dado_legado`
- `Categoria { nome, descricao, total_produtos, icone }`, `CategoriaListResponse`
- `SazonalidadeResponse { data, total, pagina, por_pagina }`, `MunicipioResponse { data: string[], total }`
- `MesSazonalidade { mes, status_cor, is_forecast, baseline_confianca, forecast_method, calculado_em, …V17 }`
- `SazonalidadeNacionalItem { produto, classificao_produto, categoria, meses[], total_ufs }` + Response
- `PoloInfo { nome, uf, municipio, fonte_id, papel? }`, `RegiaoInfo { id, nome, papel?, ufs[], polos[], total_ufs }`
- `FlowItem { id, item, origem_uf, origem_polo, destino_regiao_id, destino_uf, meses[], sazonalidade, preco_referencial, tipo, … }`, `FlowListResponse`
- `UFCoords`, `ArcFlow` (map arcs)

## 7. API ENDPOINTS CONSUMED (all GET via axios `api` or SSE)

| Endpoint                                                                            | Consumer                                                    |
| ----------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `/sazonalidade` (params uf/ano/mes/regiao)                                          | useHortifruti (meta+filter), useRegiaoResumo                |
| `/sazonalidade/br-sazonalidade` (ano, por_pagina=1000)                              | useHortifruti (BR 12-month grid)                            |
| `/sazonalidade/com-preco`                                                           | useSazonalidadeComPreco (only dead TabelaView/GraficosView) |
| `/categorias`                                                                       | useCategorias                                               |
| `/regioes`                                                                          | useRegioes                                                  |
| `/ufs`                                                                              | useUfs                                                      |
| `/fluxos`                                                                           | useFluxos                                                   |
| SSE `/api/v1/stream/updates`                                                        | useDataStream                                               |
| Dev proxy `/api` → localhost:8000; prod Vercel rewrite → sazo-repo.onrender.com/api | —                                                           |

## 8. VIEW MODES (SupermercadoView — 3 tabs, Radix Tabs + AnimatePresence)

1. **Cards** (default): status filter chips + grid of `ProductCard` (SpotlightCard + semáforo + V17 badges + DataTransparencyInfo). UF selected via native `<select>`.
2. **Mapa Regional**: `BrasilMap` (27 dots, region legend, UF selection with blue "recebe de" / green "envia para" animated arcs) + `RegiaoPanel` (region info, CEASA polos, flows from `config/flows.json` — 166 real CEASA/CONAB flows; `tipo="autossuficiente"` → "Produção local" panel). UF dropdown replaced by `BRNationalIcon`.
3. **Grade Sazonal** — **apresentação GLOBAL (Brasil inteiro)**: 12-month grid via `GradeSazonalAcordeao` + `SazonalidadeNacional`. Os dados exibidos vêm da **tabela BR** (`/sazonalidade/br-sazonalidade`, `por_pagina=1000`) — snapshot consolidado de **todos os estados**, já filtrados e preenchidos no backend (BR Nacional), sem seletor de UF (substituído por `BRNationalIcon`) e sem filtro de mês (grade completa de 12 meses). A lista é **dividida por categorias** (macrocategorias via `GradeSazonalAcordeao` + `agruparPorMacrocategoria` — frutas/verduras/legumes/tuberculos/ovos_graos_diversos/outros). Year-anchor badge per cell; "Ver N-1 (histórico)" link; low-coverage warning (<3 UFs). **As categorias/chips desta view seguem o padrão Pílulas de Rolagem vertical (Golden Rule 13 — PillRail com scroll-snap).**

Also: sticky header (logo, month Select, ThemeToggle, categories button), `DynamicBackground` + `Beams` backdrop, `PainelTransparenciaRodape` footer, `CategoriesModal`.

## 9. RECENT PRODUCT/DATA CONTEXT (from summary.md — behavior to preserve)

- **V20 (2026-08-07)**: DB purged products with no real price — the app no longer receives "12-month gray ghost" products. Gray fallback UI still works but only with legitimate data. No component changes needed.
- **V17 / Data transparency (2026-08-03)**: year anchor N → N-1 → N-2; `tipo_dado` REAL_ATUAL → "Dado Atual" + "Coleta Efetiva"; HISTORICO_BASE → "Ano de Origem: N" + "Histórico Real CONAB"; otherwise "Referência". Automatic lag label ("Histórico de N ano(s) atrás") when `is_dado_legado` + `ano_referencia` < current year. Badges replaced the synthetic `📊 Estimativa` / `🪄 Estimado` labels. Grade Sazonal always shows current year; button "Ver N-1 (histórico)".
- **Claymorphism (2026-08-03)**: tokens `shadow-clay-*` + `rounded-clay*` (28/20/32px) in tailwind.config.js; 3-layer tinted shadows (green drop + dark bottom inset + light top inset). Applied to shadcn base (card/button variant `clay`/badge/dialog), ProductCard, GameCard, SkeletonCard, GameButton, DataTransparencyInfo. Dark variants `dark:shadow-clay-dark`. Tables/charts/header intentionally NOT changed.

## 10. TECHNICAL DEBT & REFACTORING OPPORTUNITIES (verified)

1. **Dead code**: `GameCard`, `GameButton`, `LivingStatus`, `TabelaView`, `GraficosView` (renders R$! but unreachable), `TiltedCard`, `useConfetti`, `useUserStore`, `useFluxosPorRegiao` — plus deps they alone use: `recharts`, `@tanstack/react-table`, `canvas-confetti`, `idb-keyval`. **Remove dead code + unused deps.**
2. **Design-system inconsistency**: `ui/select.tsx`, `ui/table.tsx`, `ui/tabs.tsx` were regenerated with raw `oklch(...)` Tailwind classes that do NOT exist in this Tailwind config (`cssVariables: false`) → broken/odd-looking primitives (visible month-select in header). **Regenerate or re-tokenize to the sazonal/clay system.**
3. **Dual motion imports**: `framer-motion` and `motion` at same version 12.42.2 — `motion` is redundant. **Unify to one.**
4. **Duplicated constants**: `PRODUTO_EMOJI` + `STATUS_CONFIG` copy-pasted in GameCard + ProductCard; status configs re-declared in 7+ files (LivingStatus, RegiaoPanel, SazonalidadeNacional, TabelaView, GraficosView, SupermercadoView `STATUS_FILTERS`). **Extract to `lib/` or `constants/`.**
5. **Monolithic page**: `SupermercadoView.tsx` ~746 lines owns every filter; no URL sync; dead Zustand store. **Split into focused components/hooks; consider URL params for shareable state.**
6. **Query overlap**: `useHortifruti` runs 3 parallel queries (br/meta/filter) with overlapping `/sazonalidade` calls; filter query duplicates meta when no filter.
7. **Performance**: `Beams` (Three.js, frameloop="always") is heavy for an 8%-opacity background; `DynamicBackground` background-position animation is non-GPU. **Consider `frameloop="demand"` / CSS transform animations / `content-visibility`.**
8. **No ESLint** (lint = `tsc --noEmit` only); no prettier script; **Playwright smoke test orphaned** (not in scripts, playwright not a devDep).
9. **Incomplete barrel** `types/index.ts` (4 of 13+ types) → inconsistent imports (`../types/domain` vs `@/types/domain`).
10. **Noise**: `'use client'` directives in SPA files; unused Workbox runtime cache for `/api/v1/municipios*`; empty leftover `node_modules/@mui|@mantine|@reduxjs` dirs.
11. **Legacy docs drift**: `frontend/summary.md` documents many libs no longer installed — do NOT reintroduce them.

## 11. REFACTORING MISSION (prioritized directives)

1. **Remove dead code and unused dependencies** (see §10.1) — confirm each removal with `tsc --noEmit` + `vitest run`.
2. **Fix the broken shadcn primitives** (select/table/tabs) to match the claymorphism + sazonal token system (`cssVariables: false`); ensure the header month-select renders correctly in light/dark.
3. **Unify motion imports** to a single library and **extract shared constants** (PRODUTO_EMOJI, STATUS_CONFIG, status meta) into one module.
4. **Break down SupermercadoView**: extract selectors, filter logic, and tab content into smaller components/hooks; keep behavior identical; keep the 3 tabs and their interactions.
5. **Apply the vertical pill rail (Chips / Scroll Snap)**: convert `StatusFilterChips` / `STATUS_FILTERS` and any filter/quick-select chips into the vertical scroll-snap pill rail per Golden Rule 13 — `scroll-snap-type: y proximity`, `scroll-snap-align: start`, `scroll-padding-top` for the sticky header, ≥44px targets, scrollbar hidden, clay tokens, dark-mode safe. **Includes the macrocategory pills of the Grade Sazonal view (global BR list divided by categories — Golden Rule 13).** Reuse one shared `PillRail` component; do not duplicate snap markup.
6. **Clean up query layer**: reduce redundant `/sazonalidade` calls in `useHortifruti`; align query keys; remove dead `useSazonalidadeComPreco` if TabelaView/GraficosView are deleted.
7. **Performance pass**: lower cost of `Beams`/`DynamicBackground`; add GPU-friendly animations.
8. **Housekeeping**: complete `types/index.ts` barrel; drop `'use client'` noise; remove orphaned Workbox cache entry; add lint/prettier scripts if useful; wire or remove `smoke_e2e.mjs`.
9. **Keep**: PWA config, SSE stream, TanStack Query caching strategy, theme system, V17 transparency components, 27-dot map, all existing tests passing.

## 12. CONSTRAINTS & DELIVERABLE

- **Do not change** the backend API contract, endpoints, or response shapes.
- **Do not regress** the Golden Rules (§2), especially "no money on screen" and transparency badges.
- **Keep tests green**: `cd frontend && npm test` (Vitest + RTL, jsdom). Add/adjust tests for new extracted modules where behavior is non-trivial.
- **Type-check**: `npm run lint` (`tsc --noEmit`). Keep strict TS, no `any`.
- **Style**: Tailwind utility classes + shadcn/ui; Framer Motion for animation; no new design-system dependencies; no new runtime deps unless strictly justified.
- **Pills**: status/filter chips must use the vertical scroll-snap pill rail (Golden Rule 13) — one shared `PillRail` component, no duplicated snap markup, no wrapping grids for filters.
- **Output**: propose a phased plan (what to delete → what to fix → what to extract → verification steps), then implement incrementally with small commits using conventional commits (`refactor:`, `chore:`, `fix:`).
