# summary.md — /frontend (Aplicativo B2C)

## Propósito
App React PWA (offline-first, mobile-first). Interface de cores (verde/amarelo/vermelho) para preços de hortifrúti — NUNCA exibe valores monetários. Fallbacks visuais com emojis.

## Stack
- React 19, Vite + PWA plugin (vite-plugin-pwa), TailwindCSS 3 + tailwindcss-animate
- **shadcn/ui**: Card, Button, Dialog, Badge, Skeleton
- **TanStack Table** (TabelaView), **Recharts** (GraficosView)
- **Framer Motion** (animações: hover/tap springs, loading, pulse glow, shake, tab transitions)
- Radix UI primitives (Dialog, Slot, Select, Tabs, Tooltip)
- Zustand 5 (persist), TanStack Query v5, class-variance-authority, clsx, tailwind-merge
- Lucide React (ícones), canvas-confetti (efeitos de celebração)
- **Testes**: Vitest + React Testing Library

## Regras de Ouro
1. **Sem Dinheiro na Tela**: NUNCA exibir `R$`, `$`, ou valores numéricos de preço. Apenas cores (Verde = barato, Amarelo = médio, Vermelho = caro) derivadas da API.
2. **Offline-first**: PWA com service worker. TanStack Query com `staleTime` alto e cache persistente via Zustand.
3. **Mobile-first**: design responsivo partindo de 320px. Touch targets >= 44px.
4. **Fallback Visual**: emoji unicode via `PRODUTO_EMOJI` map — nunca quebrar layout.
5. **Tailwind + shadcn/ui**: zero Mantine/MUI/Ant Design. Tudo com Tailwind utility classes + componentes shadcn.
6. **Sem Loading Spinners Genéricos**: usar SkeletonCards com animação de pulsar via Tailwind animate-pulse.
7. **Streaming**: `useDataStream` hook para receber dados em SSE (Server-Sent Events) do backend.
8. **Tema**: suporte a dark/light mode via classe `.dark` no `<html>`, controlado por `useTheme` hook.
9. **Transparência no Forecast**: dados estimados (is_forecast=true) exibem badge `📊 Estimativa` com tooltip CSS da % de confiança do baseline histórico. Dados reais (is_forecast=false) NÃO ganham indicador visual.

## Forecast — Badge de Transparência
- `ProdutoVarejo` type em `domain.ts` inclui `is_forecast: boolean` e `confianca_baseline: number | null`
- `ProductCard.tsx` renderiza `<Badge variant="outline">📊 Estimativa</Badge>` com tooltip via CSS `group-hover`
- Badge posicionado ao lado do semáforo, não abaixo do card
- Nenhuma alteração em fetch/staleTime — apenas renderização condicional

## View Modes (3 modos na SupermercadoView)
A SupermercadoView oferece 3 modos de visualização com tabs Framer Motion:
- **Cards** (padrão) — grid de `ProductCard`/`GameCard` com semáforo
- **Tabela** — `TabelaView` com TanStack Table (colunas: produto, UF, município, status, forecast, tendência)
- **Gráficos** — `GraficosView` com Recharts (gráficos de linha/barras por produto)

## Juicy UI — Game-Inspired Components
- `GameButton.tsx` — Framer Motion button com hover/tap springs, loading spinner, pulse glow, shake on error
- `GameCard.tsx` — Card animado com entrada Framer Motion, badge forecast, hover scale, confetti on VERDE
- `LivingStatus.tsx` — Indicador de status com animação pulsante e transições suaves
- `useConfetti.ts` — Hook canvas-confetti para efeitos de celebração

## Mapa Rápido
- `src/App.tsx` — root, inicializa useTheme + useDataStream
- `src/main.tsx` — entry point Vite + PWA registration + QueryClientProvider
- `src/components/ProductCard.tsx` — card de produto (emoji + semáforo + badge forecast com tooltip)
- `src/components/GameCard.tsx` — card animado com Framer Motion + confetti
- `src/components/GameButton.tsx` — botão com springs Framer Motion
- `src/components/LivingStatus.tsx` — indicador pulsante de status
- `src/components/TabelaView.tsx` — TanStack Table com colunas is_forecast, tendencia_futura
- `src/components/GraficosView.tsx` — Recharts (gráficos de linha/barras)
- `src/components/CategoriesModal.tsx` — modal de categorias (shadcn Dialog)
- `src/components/SkeletonCard.tsx` — loading state (shadcn Skeleton)
- `src/components/ThemeToggle.tsx` — dark/light toggle
- `src/components/ui/` — componentes base shadcn (card, button, dialog, badge, skeleton)
- `src/lib/utils.ts` — função `cn()` (clsx + tailwind-merge)
- `src/hooks/useHortifruti.ts` — TanStack Query fetch
- `src/hooks/useSazonalidadeComPreco.ts` — hook para `/sazonalidade/com-preco` (dados com preço)
- `src/hooks/useDataStream.ts` — SSE stream hook
- `src/hooks/useCategorias.ts` — categorias via API
- `src/hooks/useUfs.ts` — UFs disponíveis
- `src/hooks/useTheme.ts` — tema persistido (dark/light)
- `src/hooks/useConfetti.ts` — canvas-confetti hook
- `src/index.css` — TailwindCSS directives + CSS vars (light/dark)
- `src/pages/SupermercadoView.tsx` — página principal (tabs Cards/Tabela/Gráficos, seletores UF/mês)
- `src/services/api.ts` — instância axios (baseURL, timeout)
- `src/types/domain.ts` — tipos `ProdutoVarejo` (is_forecast, confianca_baseline, tendencia_futura), `StatusCor`, `Categoria`
- `src/types/index.ts` — barrel exports de tipos
- `src/store/useUserStore.ts` — Zustand store (preferências do usuário, persist IndexedDB)
- `src/vite-env.d.ts` — tipos Vite (import.meta.env)
- `src/test/ProductCard.test.tsx` — 10 testes unitários (Vitest + RTL)
- `vite.config.ts` — configuração Vite + PWA + proxy dev + vitest
- `tailwind.config.js` — Tailwind com cores sazonais + tailwindcss-animate
- `components.json` — configuração shadcn/ui
- `.prettierrc` — Prettier com prettier-plugin-tailwindcss
