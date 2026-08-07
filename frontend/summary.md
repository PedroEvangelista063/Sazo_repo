# summary.md — /frontend (Aplicativo B2C)

> 📦 **Repositório (2026-08-07):** `PedroEvangelista063/Sazo_repo` — renomeado de `Quero_Comprar_ext` (a URL antiga redireciona).

## Propósito

App React PWA (offline-first, mobile-first). Interface de cores (verde/amarelo/vermelho) para preços de hortifrúti — NUNCA exibe valores monetários. Fallbacks visuais com emojis.

## Stack

- React 19, Vite + PWA plugin (vite-plugin-pwa), TailwindCSS 3 + tailwindcss-animate
- **shadcn/ui**: Card, Button, Dialog, Badge, Skeleton, Tabs, Table, Select
- **React Router 7** (`react-router` — pacote único; `react-router-dom` foi fundido no v7)
- **TanStack Table** (TabelaView), **Recharts** (GraficosView)
- **Framer Motion** / **Motion** (animações: hover/tap springs, loading, pulse glow, shake, tab transitions), **GSAP 3** (animações avançadas — instalado, uso a definir)
- **React Bits**: Beams (Three.js background), SpotlightCard (mouse spotlight), TiltedCard (3D tilt), BlurText (blur reveal)
- **Three.js** + **@react-three/fiber** + **@react-three/drei** (motor 3D do Beams)
- Radix UI primitives (Dialog, Slot, Select, Tabs, Tooltip)
- Estado global: Zustand 5 (persist) **e** Redux Toolkit 2 + React-Redux 9 — definir fronteira de uso (ex.: Redux p/ fluxos complexos, Zustand p/ preferências/cache leve)
- Data fetching: TanStack Query v5 **e** SWR 2 — TanStack é o padrão atual; SWR instalado p/ uso pontual/referência
- Formulários: React Hook Form 7 + validação **Zod 4** (atenção: breaking changes vs Zod 3)
- **Material UI 9** (@mui/material + @mui/icons-material + @emotion/react + @emotion/styled) — instalado p/ componentes novos/escopados
- **Claymorphism** (2026-08-03): tokens `shadow-clay-*` + `rounded-clay*` no tailwind.config.js; sombras de 3 camadas tintadas (ver docs/RELATORIO_CLAYMORPHISM.md)
- **Rewind UI 0.20** (@rewind-ui/core + @tailwindcss/forms + @tailwindcss/typography + tailwind-scrollbar) — componentes Tailwind; requer React 18 (instalado com `--legacy-peer-deps`, sem suporte oficial a React 19)
- **date-fns 4** (datas), class-variance-authority, clsx, tailwind-merge
- Lucide React (ícones), canvas-confetti (efeitos de celebração)
- dotted-map (instalado para referência, não usado em produção — mapa custom com 27 dots manuais)
- **Testes**: Vitest + React Testing Library

## Regras de Ouro

1. **Sem Dinheiro na Tela**: NUNCA exibir `R$`, `$`, ou valores numéricos de preço. Apenas cores (Verde = barato, Amarelo = médio, Vermelho = caro) derivadas da API.
2. **Offline-first**: PWA com service worker. TanStack Query com `staleTime` alto e cache persistente via Zustand.
3. **Mobile-first**: design responsivo partindo de 320px. Touch targets >= 44px.
4. **Fallback Visual**: emoji unicode via `PRODUTO_EMOJI` map — nunca quebrar layout.
5. **Tailwind + shadcn/ui (padrão)**: UI principal com Tailwind utility classes + componentes shadcn. Material UI 9 e Mantine estão instalados — usá-los apenas de forma escopada (ex.: componentes novos complexos), sem misturar os 3 design systems no mesmo componente. React Bits como biblioteca de efeitos animados.
6. **Sem Loading Spinners Genéricos**: usar SkeletonCards com animação de pulsar via Tailwind animate-pulse.
7. **Streaming**: `useDataStream` hook para receber dados em SSE (Server-Sent Events) do backend.
8. **Tema**: suporte a dark/light mode via classe `.dark` no `<html>`, controlado por `useTheme` hook.
9. **Transparência no Forecast**: dados estimados (is_forecast=true) exibem badge `📊 Estimativa` com tooltip CSS da % de confiança do baseline histórico. Dados reais (is_forecast=false) NÃO ganham indicador visual.
10. **React Bits Registry**: configurado em `components.json` com `registries: { "@react-bits": "https://reactbits.dev/r/{name}.json" }`. Instalação via `npx shadcn@latest add @react-bits/ComponentName-TS-TW`.
11. **Mapa Regional em Dots**: `BrasilMap.tsx` usa 27 círculos SVG (um por UF) em vez de polígonos ou `dotted-map` (gerava 5MB de SVG). Cores por região, interativo com hover/click/glow.

## Forecast — Badge de Transparência

- `ProdutoVarejo` type em `domain.ts` inclui `is_forecast: boolean` e `confianca_baseline: number | null`
- `ProductCard.tsx` renderiza `<Badge variant="outline">📊 Estimativa</Badge>` com tooltip via CSS `group-hover`
- Badge posicionado ao lado do semáforo, não abaixo do card
- Nenhuma alteração em fetch/staleTime — apenas renderização condicional

## View Modes (3 modos na SupermercadoView)

A SupermercadoView oferece 3 modos de visualização com Tabs shadcn + Framer Motion AnimatePresence:

- **Cards** (padrão) — grid de `ProductCard` com SpotlightCard + semáforo + status filter chips
- **Mapa Regional** — `BrasilMap` (27 dots por UF) + `RegiaoPanel` (SpotlightCard com polos CEASA)
- **Grade Sazonal** — `SazonalidadeNacional` grid (apenas BR Nacional sem filtro de mês)

## Juicy UI — Game-Inspired Components

- `GameButton.tsx` — Framer Motion button com hover/tap springs, loading spinner, pulse glow, shake on error
- `GameCard.tsx` — Card animado com entrada Framer Motion, badge forecast, hover scale, confetti on VERDE
- `LivingStatus.tsx` — Indicador de status com animação pulsante e transições suaves
- `useConfetti.ts` — Hook canvas-confetti para efeitos de celebração

## Mapa Regional — Filtro por Região + Seleção por UF

A aba "Mapa Regional" implementa:

- `useRegioes()` — fetch `GET /api/v1/regioes` → lista de 5 regiões com UFs, polos CEASA
- `useRegiaoResumo(regiaoId, ano)` — fetch `/api/v1/sazonalidade?regiao={id}&ano={ano}` → snapshot de produtos
- `BrasilMap.tsx` — 27 círculos SVG posicionados por coordenada real de cada UF, coloridos por região
  - Duas camadas de interação: clique na **legenda da região** (seleciona região) ou clique no **dot do estado** (seleciona UF específica)
  - Quando UF selecionada: arcos **azuis** (recebe de) e **verdes** (envia para) com animação de path drawing
  - Dot da UF selecionada fica branco com glow + nome completo + legenda "Recebe / Envia"
- `RegiaoPanel.tsx` — SpotlightCard com info da região, status counts, lista de polos CEASA clicáveis
  - Quando **selectedUF** está ativa: mostra painel "Recebe de" (agrupado por UF origem), "Envia para" (agrupado por UF destino) e "Produção local" baseado em `flows.json`
  - Dados de fluxo vêm de `config/flows.json` (166 fluxos reais CEASA/CONAB, todas as 27 UFs como origem e destino)
  - Fluxos com `tipo="autossuficiente"` (origem == destino, ex.: Carne Bovina TO→TO) aparecem como painel "Produção local"
- Clicar num polo navega para a UF correspondente na aba Cards

## Mudanças Recentes (2026-08-07)

### MV V20 — Fim das Grades 12 Meses CINZA (dados; sem mudança de código)

- O banco (migration `database/71_expurgo_produtos_sem_preco.sql`) expurgou produtos sem NENHUM preço real e suprimiu-os da MV `vw_api_produtos_sazonalidade` (**V20**).
- **Impacto no frontend**: o app nunca mais recebe produtos 12 meses CINZA (fantasmas) — a UI de fallback CINZA continua funcionando como está, mas com dados legítimos apenas. Nenhum componente foi alterado neste lote.

## Mudanças Recentes (2026-08-03)

### Transparência de Dados Históricos (2026-08-03)

UI de transparência temporal (dado histórico real vs referência), acompanhando a MV V17 do banco (ano âncora N → N-1 → N-2):

- **`DataTransparencyInfo.tsx`** (novo) — ícone (i) circulado com tooltip/popover explicativo:
  - Contrato **aditivo**: renderiza `null` quando `!tipo_dado` — consumidores antigos sem os novos campos continuam funcionando
  - Tipos de dado (`tipo_dado`): `REAL_ATUAL` → título "Dado Atual" + badge "Coleta Efetiva"; `HISTORICO_BASE` → "Ano de Origem: N" + badge "Histórico Real CONAB"; demais → "Dado de Referência"/"Referência"
  - Defasagem automática: `is_dado_legado` + `ano_referencia` < ano corrente → "Histórico de N ano(s) atrás"
  - NUNCA renderiza R$ (regra S3/R-ADD-03) — só ano, tipo, defasagem e proveniência
  - Tooltip claymorphism (`rounded-clay-sm`, `shadow-clay-card`/`shadow-clay-dark`), acessível via `role="button"`/`role="tooltip"` (hover + focus-within)
- **`types/domain.ts`** — `ProdutoVarejo` e `MesSazonalidade` ganham campos opcionais: `ano_referencia`, `tipo_dado`, `mensagem_transparencia`, `is_dado_legado`
- **`ProductCard.tsx`** — badges de tipo de dado substituem os sintéticos: `tipoDadoLabel()`/`tipoDadoVariant()` → "Coleta Efetiva" (variant `default`) / "Histórico Real '25" (variant `warning`) + `DataTransparencyInfo` + rodapé "Ano de apuração: N". Removidos badges 📊 Estimativa / 🪄 Estimado
- **`SazonalidadeNacional.tsx`** — células da grade exibem badge de ano âncora (`'26`/`'25`/`'24`, sem texto sintético) + ícone (i) `DataTransparencyInfo` quando `is_dado_legado`/`tipo_dado`; removida classificação de gaps estruturais vs coleta (`GAP_STYLES`); célula sem linha virou muted vazia; aviso de baixa cobertura (< 3 UFs) abaixo da célula
- **`SupermercadoView.tsx`** — Grade Sazonal agora **sempre exibe o ano corrente** (MV V17 preenche meses sem dado com dado real do ano âncora); removido badge "⚠️ Ano em curso — dados parciais"; subtítulo "Grade com dados de N-2–N (ano âncora exibido por célula)"; botão "Ver N-1 (histórico)"
- **`GameCard.tsx`** / **`GameButton.tsx`** / **`ui/card.tsx`** / **`ui/button.tsx`** / **`ui/badge.tsx`** / **`ui/dialog.tsx`** — reestilização claymorphism (ver seção abaixo); `ui/button.tsx` ganhou nova variant `clay`

**Testes novos/atualizados (Vitest + RTL):**

- **`DataTransparencyInfo.test.tsx`** (novo) — 4 testes: contrato aditivo (`null` → nada renderizado), "Dado Atual"+"Coleta Efetiva" para `REAL_ATUAL`, sem R$ no DOM (S3), exposição de `mensagem_transparencia`
- **`SazonalidadeNacional.test.tsx`** (novo) — 4 testes: badge de ano legado `'25` em célula histórica, ícone (i) presente, célula sem dados vazia (sem tooltip de gap), sem R$ na grade (S3)
- **`ProductCard.test.tsx`** (atualizado) — badges "Coleta Efetiva" (REAL_ATUAL) / histórico + ano (HISTORICO_BASE), ausência de badges sintéticos 📊/🪄, rodapé com ano de apuração
- **`smoke_e2e.mjs`** (novo) — smoke E2E headless (Playwright chromium) contra `http://127.0.0.1:5173` (`SMOKE_BASE_URL`): app renderiza, clica na aba Grade Sazonal, ausência de tooltips de gap estrutural/coleta, ícones (i)/badges de ano presentes, sem R$ no DOM, badges "Coleta Efetiva"/"Histórico Real", sem badges sintéticos 📊/🪄, sem erros de console. Exit 0 = PASS, 1 = FAIL

### Claymorphism — implementação (2026-08-03)

Estilo "argila" (almost flat + skeuomórfico) aplicado conforme `docs/RELATORIO_CLAYMORPHISM.md`:

- **Tokens** (`tailwind.config.js`): `boxShadow.clay-*` (clay-card, clay-btn, clay-press, clay-dark...) e `borderRadius.clay*` (28/20/32px) — sombra de 3 camadas: drop tintado verde + inset inferior escuro (curvatura) + inset superior claro (luz de topo).
- **Base shadcn**: `ui/card.tsx` (rounded-clay + shadow-clay-card + dark), `ui/button.tsx` (nova variant `clay` com press/lift), `ui/badge.tsx` (rounded-full), `ui/dialog.tsx` (rounded-clay + clay-card).
- **Cards do app**: `ProductCard` (shadow-clay-card/hover + dark), `GameCard` (rounded-2xl + clay + whileHover framer com sombra clay), `SkeletonCard` (rounded-clay), `DataTransparencyInfo` (tooltip rounded-clay-sm).
- **GameButton**: raio rounded-2xl + highlight de topo (gradiente branco skeuo) + lip inferior inset escuro (sombra moldada) — mantendo o padrão keycap.
- **Dark mode**: variantes `dark:shadow-clay-dark` re-derivadas (drop escuro profundo + brilho de topo ~6%).
- **Escopo seletivo**: tabelas/gráficos (TabelaView/GraficosView) e header glass NÃO alterados; regra de ouro nº 1 (sem R$) intacta.

### Instalação de Bibliotecas (frontend/package.json + frontend/package-lock.json)

Lote de dependências adicionadas via `npm install` (nenhum código alterado):

| Biblioteca                                                                          | Versão                 | Uso previsto                                                                                                                                      |
| ----------------------------------------------------------------------------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| react-router                                                                        | 7.18.2                 | Roteamento (v7 — pacote único; `react-router-dom` fundido nele)                                                                                   |
| @reduxjs/toolkit + react-redux                                                      | 2.12.0 / 9.3.0         | Estado global (Redux)                                                                                                                             |
| react-hook-form                                                                     | 7.84.0                 | Formulários                                                                                                                                       |
| zod                                                                                 | 4.4.3                  | Validação de schema (v4 — breaking changes vs v3)                                                                                                 |
| gsap                                                                                | 3.15.0                 | Animações avançadas                                                                                                                               |
| swr                                                                                 | 2.5.0                  | Data fetching (concorre com TanStack Query)                                                                                                       |
| date-fns                                                                            | 4.4.0                  | Manipulação de datas                                                                                                                              |
| @mui/material + @mui/icons-material + @emotion/*                                    | 9.2.0 / 11.14.x        | Design system Material UI                                                                                                                         |
| @rewind-ui/core + @tailwindcss/forms + @tailwindcss/typography + tailwind-scrollbar | 0.20.0 / 0.5.x / 4.0.2 | Componentes Tailwind (React 18-only — instalado com `--legacy-peer-deps`)                                                                         |
| @testing-library/dom (devDep)                                                       | 10.4.1                 | Peer dependency explícita do @testing-library/react — o `--legacy-peer-deps` havia removido a instalação automática dela, quebrando lint e testes |

Já presentes (não reinstaladas): axios, @tanstack/react-query (5.101.4), zustand, framer-motion, lucide-react e shadcn/ui (config `components.json` + `src/components/ui/`).

Observações:

- `npm audit` reporta 2 vulnerabilidades de alta severidade (pré-existentes; `npm audit fix` ainda não rodado).
- **Rewind UI**: pacote oficial é `@rewind-ui/core` (o `rewind-ui` no npm é abandonado desde 2023). Exige React 18 — instalado com `--legacy-peer-deps`; React 19.2.8 mantido no topo e deps internas aninhadas (framer-motion 10, date-fns 2). Ainda NÃO configurado no `tailwind.config.js` (faltam o content glob `./node_modules/@rewind-ui/core/dist/theme/styles/*.js` e os plugins `@tailwindcss/forms` + `tailwind-scrollbar` + `@tailwindcss/typography`).
- Coexistência de 3 design systems (Mantine, shadcn/Tailwind, MUI) e sobreposição de data fetching (TanStack + SWR) e estado global (Zustand + Redux) — ver regra 5 e seção Stack para a convenção.

## Mudanças Recentes (2026-07-30)

### Ajustes na SupermercadoView

- `src/pages/SupermercadoView.tsx` — Ajustes menores no layout da página principal
- Melhor alinhamento dos seletores (UF, mês, ano) e responsividade

## BRNationalIcon — Ícone BR Animado

- `BRNationalIcon.tsx` — substitui o dropdown de UF nos modos **Grade Sazonal** e **Mapa Regional**
- Exibe bandeira do Brasil (SVG) com pulse animation + 5 frutas orbitando (Framer Motion + CSS keyframes `fruit-orbit-{0-4}`)
- Modo **Cards** mantém o dropdown de UF normal (comportamento condicional em `SupermercadoView.tsx`)
- Ano: texto estático em todos os modos (não dropdown) — `selectedYear` exibido como label
- `BRNationalIcon.test.tsx` — 5 testes unitários (render, pulse, orbit count, fallback emoji, UF toggle)

## Mapa Rápido

- `src/App.tsx` — root, inicializa useTheme + useDataStream
- `src/main.tsx` — entry point Vite + PWA registration + QueryClientProvider
- `src/components/ProductCard.tsx` — card de produto (emoji + semáforo + badges de tipo de dado + DataTransparencyInfo + SpotlightCard)
- `src/components/DataTransparencyInfo.tsx` — ícone (i) de transparência temporal (ano âncora / tipo_dado / defasagem)
- `src/components/GameCard.tsx` — card animado com Framer Motion + confetti
- `src/components/GameButton.tsx` — botão com springs Framer Motion
- `src/components/LivingStatus.tsx` — indicador pulsante de status
- `src/components/TabelaView.tsx` — TanStack Table com colunas is_forecast, tendencia_futura
- `src/components/GraficosView.tsx` — Recharts (gráficos de linha/barras)
- `src/components/BrasilMap.tsx` — mapa do Brasil com 27 dots SVG (um por UF), interativo por região
- `src/components/RegiaoPanel.tsx` — painel lateral do mapa regional (SpotlightCard)
- `src/components/SazonalidadeNacional.tsx` — grid sazonal BR (12 meses x produtos) com badge de ano âncora + DataTransparencyInfo
- `src/components/CategoriesModal.tsx` — modal de categorias (shadcn Dialog)
- `src/components/SkeletonCard.tsx` — loading state (shadcn Skeleton)
- `src/components/ThemeToggle.tsx` — dark/light toggle
- `src/components/Beams.tsx` — React Bits: background animado Three.js (feixes de luz)
- `src/components/SpotlightCard.tsx` — React Bits: card com spotlight que segue o mouse
- `src/components/TiltedCard.tsx` — React Bits: card com 3D tilt ao hover
- `src/components/BlurText.tsx` — React Bits: texto com blur/fade animado
- `src/components/ui/` — componentes base shadcn (card, button, dialog, badge, skeleton, tabs, table, select)
- `src/lib/utils.ts` — função `cn()` (clsx + tailwind-merge)
- `src/hooks/useHortifruti.ts` — TanStack Query fetch
- `src/hooks/useRegioes.ts` — fetch `GET /api/v1/regioes`
- `src/hooks/useRegiaoResumo.ts` — fetch `/api/v1/sazonalidade?regiao=...`
- `src/hooks/useSazonalidadeComPreco.ts` — hook para `/sazonalidade/com-preco` (dados com preço)
- `src/hooks/useDataStream.ts` — SSE stream hook
- `src/hooks/useCategorias.ts` — categorias via API
- `src/hooks/useUfs.ts` — UFs disponíveis
- `src/hooks/useTheme.ts` — tema persistido (dark/light)
- `src/hooks/useConfetti.ts` — canvas-confetti hook
- `src/index.css` — TailwindCSS directives + CSS vars (light/dark)
- `src/pages/SupermercadoView.tsx` — página principal (tabs Cards/Mapa/Grade, seletores UF/mês/ano, Beams background)
- `src/services/api.ts` — instância axios (baseURL, timeout)

## Conexão com o Banco (via Backend)

O frontend NUNCA se conecta ao banco de dados diretamente. Toda comunicação passa pelo backend FastAPI em `localhost:8000`:

```
Frontend (Vite) ─── VITE_API_URL ───→ Backend FastAPI ─── asyncpg ───→ Supabase Remoto
     :5173              :8000                             (DATABASE_URL_API)
```

### Arquitetura Híbrida (referência)

- **Desenvolvimento diário**: frontend → backend → Supabase remoto (PRIMARY)
- **Backup/Standby**: PostgreSQL 18 local (`localhost:5432`) — transparente para o frontend
- **RLS**: ativo no banco mas não afeta o frontend — o backend usa `role_etl_writer` com bypass total
- Variável de ambiente: `VITE_API_URL=http://localhost:8000/api/v1` (em `frontend/.env`)
- `src/types/domain.ts` — tipos `ProdutoVarejo`, `RegiaoInfo`, `PoloInfo`, `StatusCor`, `Categoria`
- `src/types/index.ts` — barrel exports de tipos
- `src/store/useUserStore.ts` — Zustand store (preferências do usuário, persist IndexedDB)
- `src/vite-env.d.ts` — tipos Vite (import.meta.env)
- `src/test/ProductCard.test.tsx` — 12 testes unitários (Vitest + RTL, inclui badges de tipo de dado)
- `src/test/DataTransparencyInfo.test.tsx` — 4 testes de transparência temporal (contrato aditivo, badges, sem R$)
- `src/test/SazonalidadeNacional.test.tsx` — 4 testes da grade sazonal (badge ano âncora, ícone (i), sem gaps/R$)
- `src/test/smoke_e2e.mjs` — smoke E2E headless (Playwright) contra o dev server (transparência + sem R$)
- `vite.config.ts` — configuração Vite + PWA + proxy dev + vitest
- `tailwind.config.js` — Tailwind com cores sazonais + tailwindcss-animate
- `components.json` — configuração shadcn/ui + registry @react-bits
- `.prettierrc` — Prettier com prettier-plugin-tailwindcss
