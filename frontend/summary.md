# summary.md — /frontend (Aplicativo B2C)

## Propósito
App React PWA (offline-first, mobile-first). Interface de cores (verde/amarelo/vermelho) para preços de hortifrúti — NUNCA exibe valores monetários. Fallbacks visuais com emojis.

## Stack
- React 19, Vite + PWA plugin (vite-plugin-pwa), TailwindCSS 3 + tailwindcss-animate
- **shadcn/ui**: Card, Button, Dialog, Badge, Skeleton, Tabs
- **TanStack Table** (TabelaView), **Recharts** (GraficosView)
- **Framer Motion** / **Motion** (animações: hover/tap springs, loading, pulse glow, shake, tab transitions)
- **React Bits**: Beams (Three.js background), SpotlightCard (mouse spotlight), TiltedCard (3D tilt), BlurText (blur reveal)
- **Three.js** + **@react-three/fiber** + **@react-three/drei** (motor 3D do Beams)
- Radix UI primitives (Dialog, Slot, Select, Tabs, Tooltip)
- Zustand 5 (persist), TanStack Query v5, class-variance-authority, clsx, tailwind-merge
- Lucide React (ícones), canvas-confetti (efeitos de celebração)
- dotted-map (instalado para referência, não usado em produção — mapa custom com 27 dots manuais)
- **Testes**: Vitest + React Testing Library

## Regras de Ouro
1. **Sem Dinheiro na Tela**: NUNCA exibir `R$`, `$`, ou valores numéricos de preço. Apenas cores (Verde = barato, Amarelo = médio, Vermelho = caro) derivadas da API.
2. **Offline-first**: PWA com service worker. TanStack Query com `staleTime` alto e cache persistente via Zustand.
3. **Mobile-first**: design responsivo partindo de 320px. Touch targets >= 44px.
4. **Fallback Visual**: emoji unicode via `PRODUTO_EMOJI` map — nunca quebrar layout.
5. **Tailwind + shadcn/ui**: zero Mantine/MUI/Ant Design. Tudo com Tailwind utility classes + componentes shadcn. React Bits como biblioteca de efeitos animados.
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
  - Dados de fluxo vêm de `config/flows.json` (104 fluxos reais CEASA/CONAB, todas as 27 UFs como origem e destino)
- Clicar num polo navega para a UF correspondente na aba Cards

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
- `src/components/ProductCard.tsx` — card de produto (emoji + semáforo + badge forecast + SpotlightCard)
- `src/components/GameCard.tsx` — card animado com Framer Motion + confetti
- `src/components/GameButton.tsx` — botão com springs Framer Motion
- `src/components/LivingStatus.tsx` — indicador pulsante de status
- `src/components/TabelaView.tsx` — TanStack Table com colunas is_forecast, tendencia_futura
- `src/components/GraficosView.tsx` — Recharts (gráficos de linha/barras)
- `src/components/BrasilMap.tsx` — mapa do Brasil com 27 dots SVG (um por UF), interativo por região
- `src/components/RegiaoPanel.tsx` — painel lateral do mapa regional (SpotlightCard)
- `src/components/SazonalidadeNacional.tsx` — grid sazonal BR (12 meses x produtos)
- `src/components/CategoriesModal.tsx` — modal de categorias (shadcn Dialog)
- `src/components/SkeletonCard.tsx` — loading state (shadcn Skeleton)
- `src/components/ThemeToggle.tsx` — dark/light toggle
- `src/components/Beams.tsx` — React Bits: background animado Three.js (feixes de luz)
- `src/components/SpotlightCard.tsx` — React Bits: card com spotlight que segue o mouse
- `src/components/TiltedCard.tsx` — React Bits: card com 3D tilt ao hover
- `src/components/BlurText.tsx` — React Bits: texto com blur/fade animado
- `src/components/ui/` — componentes base shadcn (card, button, dialog, badge, skeleton, tabs)
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
- `src/test/ProductCard.test.tsx` — 10 testes unitários (Vitest + RTL)
- `vite.config.ts` — configuração Vite + PWA + proxy dev + vitest
- `tailwind.config.js` — Tailwind com cores sazonais + tailwindcss-animate
- `components.json` — configuração shadcn/ui + registry @react-bits
- `.prettierrc` — Prettier com prettier-plugin-tailwindcss
