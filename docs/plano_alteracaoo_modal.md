# 🗺️ OpenCode Prompt — Mapa Regional como Pivot Principal

> **Stack**: React 19 + Vite + TailwindCSS 3 + shadcn/ui + Framer Motion + Zustand 5 + TanStack Query v5
> **Repo**: `frontend/src/`
> **Regras da casa**: Sem MUI/Ant/Mantine. Mobile-first (320px, touch ≥ 44px). Null-safety obrigatório (`?.`, `??`). Nunca exibir preços em R$. Dark/light mode. Skeleton em vez de spinners bloqueantes.

---

## CONTEXTO GERAL

O projeto `Sazo Brasil` exibe sazonalidade de alimentos hortifrúti por estado/região do Brasil.
Atualmente o fluxo de navegação é: **Cards → Mapa → Tabela** (abas horizontais).
O objetivo desta tarefa é **inverter essa hierarquia**: o **Mapa Regional passa a ser o pivot central** — ele é a tela de entrada e, a partir dele, o usuário navega para Cards (por UF) ou para a Tabela geral.

---

## ARQUIVOS PRINCIPAIS A MODIFICAR

| Arquivo                                             | Papel                                              |
| --------------------------------------------------- | -------------------------------------------------- |
| `frontend/src/pages/SupermercadoView.tsx`           | Página principal — orquestrador de estado e layout |
| `frontend/src/components/BrasilMap.tsx`             | SVG do mapa interativo                             |
| `frontend/src/components/layout/NavigationTabs.tsx` | Abas de navegação                                  |
| `frontend/src/components/layout/TopAppBar.tsx`      | Header com busca                                   |

---

## TAREFA 1 — Mapa Regional como pivot (view default)

Em `SupermercadoView.tsx`:

**1.1** Alterar o `viewMode` default de `'grade-sazonal'` para `'mapa'`:

```tsx
// ANTES
const [viewMode, setViewMode] = useState<ViewMode>("grade-sazonal");

// DEPOIS
const [viewMode, setViewMode] = useState<ViewMode>("mapa");
```

**1.2** Renomear o tipo `'grade-sazonal'` para `'tabela'` em todo o arquivo:

```tsx
type ViewMode = "tabela" | "cards" | "mapa";
```

Substituir TODAS as ocorrências de `'grade-sazonal'` por `'tabela'` nos condicionais, no `handleTabChange`, e no `NavigationTabs`.

**1.3** No `handleTabChange`, a regra de forçar `selectedUF = 'BR'` ao entrar na tabela continua — apenas troque a referência:

```tsx
if (tab === "tabela" && selectedUF !== "BR") {
  setSelectedUF("BR");
  setSelectedMonth(null);
}
```

---

## TAREFA 2 — Navegação a partir do mapa: UF → Cards; Bandeira → Tabela

### 2a. Badge flutuante: Clique em UF → Cards

No `BrasilMap.tsx`, adicionar duas novas props à interface `BrasilMapProps`:

```tsx
interface BrasilMapProps {
  // ... props existentes sem alteração ...
  onUfNavigate?: (uf: string) => void;
  onTableNavigate?: () => void;
}
```

Dentro do componente, após o fechamento da tag `</svg>` e antes dos controles existentes, adicionar o badge flutuante que aparece quando uma UF está selecionada:

```tsx
{
  /* Badge flutuante — aparece ao selecionar uma UF */
}
{
  selectedUF &&
    onUfNavigate &&
    (() => {
      const ufData = UFS.find((u) => u.uf === selectedUF);
      return (
        <motion.button
          key={selectedUF}
          initial={{ opacity: 0, y: 8, scale: 0.95 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          exit={{ opacity: 0, y: 4, scale: 0.95 }}
          transition={{ duration: 0.2 }}
          onClick={() => onUfNavigate(selectedUF)}
          style={{
            position: "absolute",
            bottom: 16,
            left: "50%",
            transform: "translateX(-50%)",
          }}
          className="z-10 flex items-center gap-2 rounded-full border border-outline-variant
                 bg-surface-container/90 px-4 py-2 text-sm font-semibold text-on-surface
                 shadow-clay-dark backdrop-blur-md hover:shadow-clay-pressed
                 active:scale-95 transition-all duration-150 whitespace-nowrap"
        >
          <span>📄</span>
          <span>Ver Cards de {ufData?.nome ?? selectedUF}</span>
          <svg
            className="h-3.5 w-3.5 text-primary"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth={2.5}
          >
            <path d="M5 12h14M12 5l7 7-7 7" />
          </svg>
        </motion.button>
      );
    })();
}
```

### 2b. Botão Bandeira 🇧🇷 → Tabela

No mesmo wrapper do mapa em `BrasilMap.tsx`, adicionar no canto inferior-direito:

```tsx
{
  onTableNavigate && (
    <button
      onClick={onTableNavigate}
      className="absolute bottom-4 right-4 z-10 flex flex-col items-center gap-1
               rounded-2xl border border-outline-variant bg-surface-container/90 p-3
               shadow-clay-dark backdrop-blur-md hover:shadow-clay-pressed
               active:scale-95 transition-all duration-150 group"
      title="Ver Tabela Nacional"
    >
      <span className="text-2xl">🇧🇷</span>
      <span
        className="text-[10px] font-semibold text-on-surface-variant
                     group-hover:text-primary transition-colors"
      >
        Tabela
      </span>
      <svg
        className="h-3 w-3 text-primary"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth={2.5}
      >
        <path d="M5 12h14M12 5l7 7-7 7" />
      </svg>
    </button>
  );
}
```

O wrapper `<div>` do BrasilMap já tem `className={cn('relative mx-auto w-full...', className)}` — os botões `absolute` já ficam posicionados corretamente dentro dele.

### 2c. Passar os handlers em SupermercadoView.tsx

```tsx
<BrasilMap
  selectedRegion={selectedRegion}
  onRegionClick={(id) => {
    hapticLight();
    setSelectedRegion(selectedRegion === id ? null : id);
  }}
  selectedUF={selectedMapUF}
  onUfClick={handleUfClick}
  fluxos={fluxos}
  onUfNavigate={handlePoloClick}
  onTableNavigate={() => {
    hapticLight();
    setViewMode("tabela");
    setSelectedUF("BR");
  }}
/>
```

---

## TAREFA 3 — Remover filtro de modo noturno

**Em `TopAppBar.tsx`**: remover completamente:

- A prop `onThemeToggle?: () => void` da interface `TopAppBarProps`
- O parâmetro `onThemeToggle` do componente
- O bloco JSX do botão `dark_mode` inteiro

**Em `SupermercadoView.tsx`**:

- Remover o import `useTheme`
- Remover `const { toggleTheme } = useTheme()`
- Remover a prop `onThemeToggle={toggleTheme}` do `<TopAppBar />`

---

## TAREFA 4 — Mapa expansível e responsivo para mobile

**Em `BrasilMap.tsx`**, trocar o max-width fixo do wrapper:

```tsx
// ANTES:
<div className={cn('relative mx-auto w-full max-w-[420px]', className)}>

// DEPOIS:
<div className={cn(
  'relative mx-auto w-full',
  'max-w-[320px] sm:max-w-[420px] md:max-w-[560px] lg:max-w-[680px] xl:max-w-[800px]',
  className
)}>
```

**Em `SupermercadoView.tsx`**, no bloco da view `mapa`, alterar o container e o layout:

```tsx
// ANTES:
<motion.div className="flex flex-col gap-lg lg:flex-row">
  <div className="clay-card relative flex min-h-[400px] flex-1 items-center justify-center overflow-hidden p-lg">

// DEPOIS:
<motion.div className="flex flex-col gap-lg">
  <div className="clay-card relative flex w-full flex-col items-center justify-center overflow-hidden p-2 sm:p-lg">
```

O `RegiaoPanel` fica empilhado abaixo do mapa em todas as telas.

---

## TAREFA 5 — Remover bolinha colorida e contagem dos chips de status

**Em `SupermercadoView.tsx`**, atualizar a constante removendo emojis:

```tsx
const STATUS_CHIPS: Record<string, string> = {
  VERDE: "Barato",
  AMARELO: "Normal",
  VERMELHO: "Caro",
};
```

E no JSX do botão de chip, remover `({contadores[status]})`:

```tsx
// ANTES:
{STATUS_CHIPS[status]} ({contadores[status]})

// DEPOIS:
{STATUS_CHIPS[status]}
```

---

## TAREFA 6 — Remover bloco UF/Ano e mover selects para linha das abas

**Em `SupermercadoView.tsx`**:

**REMOVER** este bloco inteiro do `clay-card` superior:

```tsx
<div className="flex items-center justify-between">
  <span className="font-label-sm text-on-surface-variant">📍 {ufLabel}</span>
  <span className="font-headline-md text-primary">{selectedYear}</span>
</div>
```

**SUBSTITUIR** a estrutura do `clay-card` superior para ter abas + selects na mesma linha:

```tsx
<div className="flex flex-col gap-4 rounded-3xl bg-clay-surface p-3 pb-4 shadow-clay-rest dark:bg-surface-container-low dark:shadow-clay-dark">
  <div className="flex flex-wrap items-center gap-2">
    <NavigationTabs activeTab={viewMode} onTabChange={handleTabChange} />

    {/* Select UF inline com as abas */}
    <select
      value={selectedUF}
      onChange={handleUfChange}
      aria-label="Selecionar UF"
      className="h-12 shrink-0 rounded-full bg-clay-surface px-3 text-sm font-semibold text-on-surface shadow-clay-rest outline-none transition-colors focus:ring-2 focus:ring-primary/50 dark:bg-surface-container dark:shadow-clay-dark"
    >
      {ufOptions.map((opt) => (
        <option key={opt.value} value={opt.value}>
          {opt.label}
        </option>
      ))}
    </select>

    {/* Select Mês inline com as abas */}
    <select
      value={selectedMonth ?? ""}
      onChange={handleMonthChange}
      aria-label="Selecionar mês"
      className="h-12 shrink-0 rounded-full bg-clay-surface px-3 text-sm font-semibold text-on-surface shadow-clay-rest outline-none transition-colors focus:ring-2 focus:ring-primary/50 dark:bg-surface-container dark:shadow-clay-dark"
    >
      <option value="">📅 Mês: Todos</option>
      {MESES_NOME.map((nome, idx) => (
        <option key={nome} value={idx + 1}>
          📅 Mês: {nome}
        </option>
      ))}
    </select>
  </div>
</div>
```

**REMOVER** os dois `<select>` da área de filtros horizontais (`hide-scrollbar flex items-center gap-2`), pois foram movidos para cima. Essa área fica apenas com chips de status e botão Categorias.

---

## TAREFA 7 — Busca inteligente com Floating Glassmorphism Modal

### Criar `frontend/src/components/SearchResultsModal.tsx`

```tsx
"use client";

import { motion, AnimatePresence } from "framer-motion";
import { useMemo, useEffect } from "react";
import type { ProdutoVarejo } from "@/types/domain";

const UF_EMOJI: Record<string, string> = {
  AC: "🌿",
  AL: "🌊",
  AP: "🌴",
  AM: "🌿",
  BA: "☀️",
  CE: "🌵",
  DF: "🏛️",
  ES: "🌊",
  GO: "🌾",
  MA: "🌴",
  MT: "🌄",
  MS: "🌿",
  MG: "⛰️",
  PA: "🌳",
  PB: "🌵",
  PR: "🌲",
  PE: "🌊",
  PI: "🌾",
  RJ: "🏖️",
  RN: "🌵",
  RS: "🌾",
  RO: "🌿",
  RR: "🌴",
  SC: "🏔️",
  SP: "🏙️",
  SE: "🌊",
  TO: "🌾",
  BR: "🇧🇷",
};

const MESES_ABREV = [
  "Jan",
  "Fev",
  "Mar",
  "Abr",
  "Mai",
  "Jun",
  "Jul",
  "Ago",
  "Set",
  "Out",
  "Nov",
  "Dez",
];

interface SearchResult {
  produto: ProdutoVarejo;
  score: number;
}

interface SearchResultsModalProps {
  query: string;
  produtos: ProdutoVarejo[];
  onSelectResult: (uf: string, nomeProduto: string) => void;
  onClose: () => void;
  visible: boolean;
}

function norm(s: string): string {
  return s
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .trim();
}

function getBigrams(s: string): Set<string> {
  const bg = new Set<string>();
  for (let i = 0; i < s.length - 1; i++) bg.add(s.slice(i, i + 2));
  return bg;
}

function bigramSimilarity(a: string, b: string): number {
  if (a.length < 2 || b.length < 2) return 0;
  const bgA = getBigrams(a);
  const bgB = getBigrams(b);
  let intersection = 0;
  for (const bg of bgA) if (bgB.has(bg)) intersection++;
  return (2 * intersection) / (bgA.size + bgB.size);
}

function buscarProdutos(
  query: string,
  produtos: ProdutoVarejo[],
): SearchResult[] {
  if (!query || query.trim().length < 2) return [];
  const q = norm(query);
  const resultMap = new Map<string, SearchResult>();

  for (const p of produtos) {
    const nomeNorm = norm(p.nome_produto);
    let score = 0;
    if (nomeNorm === q) score = 4;
    else if (nomeNorm.startsWith(q)) score = 3;
    else if (nomeNorm.includes(q)) score = 2;
    else {
      const sim = bigramSimilarity(q, nomeNorm);
      if (sim > 0.4) score = sim;
    }
    if (score > 0) {
      const key = `${p.nome_produto}__${p.uf}__${p.mes_referencia ?? "null"}`;
      const existing = resultMap.get(key);
      if (!existing || score > existing.score) {
        resultMap.set(key, { produto: p, score });
      }
    }
  }
  return Array.from(resultMap.values())
    .sort(
      (a, b) =>
        b.score - a.score ||
        a.produto.nome_produto.localeCompare(b.produto.nome_produto),
    )
    .slice(0, 12);
}

export function SearchResultsModal({
  query,
  produtos,
  onSelectResult,
  onClose,
  visible,
}: SearchResultsModalProps) {
  const results = useMemo(
    () => buscarProdutos(query, produtos),
    [query, produtos],
  );

  const grouped = useMemo(() => {
    const map = new Map<string, SearchResult[]>();
    for (const r of results) {
      const key = r.produto.nome_produto;
      if (!map.has(key)) map.set(key, []);
      map.get(key)!.push(r);
    }
    return Array.from(map.entries()).slice(0, 5);
  }, [results]);

  // Fechar com Escape
  useEffect(() => {
    if (!visible) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, [visible, onClose]);

  const hasResults = results.length > 0;
  const noResults = query.trim().length >= 2 && !hasResults;

  return (
    <AnimatePresence>
      {visible && query.trim().length >= 2 && (
        <>
          <motion.div
            key="search-backdrop"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.15 }}
            className="fixed inset-0 z-[60] bg-on-background/10 backdrop-blur-[2px]"
            onClick={onClose}
          />
          <motion.div
            key="search-modal"
            initial={{ opacity: 0, y: -12, scale: 0.97 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: -8, scale: 0.97 }}
            transition={{ duration: 0.2, ease: [0.4, 0, 0.2, 1] }}
            className="fixed left-1/2 top-[7.25rem] z-[70] w-full max-w-md -translate-x-1/2 flex flex-col gap-3 rounded-3xl border border-outline-variant/60 bg-surface-container-lowest/80 p-4 shadow-[0_8px_32px_rgba(0,0,0,0.18),0_2px_8px_rgba(0,0,0,0.12)] backdrop-blur-xl"
          >
            <div className="flex items-center justify-between px-1">
              <span className="text-sm font-semibold text-on-surface-variant">
                🔍 Resultados para{" "}
                <span className="text-primary">"{query}"</span>
              </span>
              {hasResults && (
                <span className="text-xs text-outline">
                  {results.length} resultado{results.length !== 1 ? "s" : ""}
                </span>
              )}
            </div>

            {noResults && (
              <div className="flex flex-col items-center gap-2 py-4 text-center text-on-surface-variant">
                <span className="text-2xl">🌿</span>
                <p className="text-sm">
                  Nenhum alimento encontrado para <strong>"{query}"</strong>
                </p>
                <p className="text-xs text-outline">
                  Tente: "maca", "cebola", "tomate"
                </p>
              </div>
            )}

            <div
              className="flex flex-col gap-3 overflow-y-auto"
              style={{ maxHeight: "60vh" }}
            >
              {grouped.map(([nomeProduto, items]) => (
                <motion.div
                  key={nomeProduto}
                  initial={{ opacity: 0, x: -8 }}
                  animate={{ opacity: 1, x: 0 }}
                  transition={{ duration: 0.18 }}
                  className="rounded-2xl border border-outline-variant/40 bg-clay-surface/70 p-3 shadow-[2px_2px_8px_rgba(0,0,0,0.08),-1px_-1px_4px_rgba(255,255,255,0.6)] dark:bg-surface-container/70 dark:shadow-[2px_2px_8px_rgba(0,0,0,0.3)]"
                >
                  <p className="mb-2 text-sm font-semibold text-on-surface">
                    {nomeProduto}
                  </p>
                  <div className="flex flex-wrap gap-2">
                    {items.map((r) => {
                      const { uf, mes_referencia } = r.produto;
                      const mesIdx =
                        typeof mes_referencia === "number"
                          ? mes_referencia - 1
                          : null;
                      const mesAbrev =
                        mesIdx !== null ? (MESES_ABREV[mesIdx] ?? "") : "";
                      const emoji = UF_EMOJI[uf] ?? "📍";
                      return (
                        <button
                          key={`${uf}-${mes_referencia ?? "null"}`}
                          onClick={() => onSelectResult(uf, nomeProduto)}
                          className="flex min-w-[4rem] flex-col items-center gap-0.5 rounded-2xl border border-outline-variant/50 bg-surface-container p-2.5 shadow-[2px_2px_6px_rgba(0,0,0,0.1),-1px_-1px_3px_rgba(255,255,255,0.7)] transition-all duration-150 hover:shadow-[3px_3px_10px_rgba(0,0,0,0.15),-2px_-2px_6px_rgba(255,255,255,0.8)] active:scale-95 active:shadow-[inset_2px_2px_5px_rgba(0,0,0,0.12)] dark:bg-surface-container-high dark:shadow-[2px_2px_6px_rgba(0,0,0,0.35)]"
                        >
                          <span className="text-xl leading-none">{emoji}</span>
                          <span className="text-[11px] font-bold text-on-surface">
                            {uf}
                          </span>
                          {mesAbrev && (
                            <span className="text-[9px] font-medium text-on-surface-variant">
                              {mesAbrev}
                            </span>
                          )}
                        </button>
                      );
                    })}
                  </div>
                </motion.div>
              ))}
            </div>

            {hasResults && (
              <p className="px-1 text-center text-xs text-outline">
                Toque em um estado para ver os cards
              </p>
            )}
          </motion.div>
        </>
      )}
    </AnimatePresence>
  );
}
```

### Integrar em `SupermercadoView.tsx`

```tsx
// 1. Import
import { SearchResultsModal } from '@/components/SearchResultsModal'

// 2. Estado do modal de busca
const [searchModalOpen, setSearchModalOpen] = useState(false)

// 3. Handler de resultado de busca
const handleSearchResultSelect = useCallback((uf: string, nomeProduto: string) => {
  hapticSuccess()
  setSearch('')
  setSearchModalOpen(false)
  setSelectedUF(uf)
  setSelectedProducts([nomeProduto])
  setSelectedMonth(null)
  setSelectedStatus(null)
  setViewMode('cards')
}, [])

// 4. No TopAppBar, atualizar os handlers:
<TopAppBar
  search={search}
  onSearchChange={(val) => {
    setSearch(val)
    setSearchModalOpen(val.trim().length >= 2)
  }}
  onClearSearch={() => {
    handleClearSearch()
    setSearchModalOpen(false)
  }}
  onCalendarClick={() => setIsMonthModalOpen(true)}
/>

// 5. Renderizar o modal após <TopAppBar /> e antes de <OfflineBanner />:
<SearchResultsModal
  query={search}
  produtos={allProducts}
  onSelectResult={handleSearchResultSelect}
  onClose={() => setSearchModalOpen(false)}
  visible={searchModalOpen}
/>
```

---

## TAREFA 8 — Reordenar abas: Mapa primeiro

**Em `NavigationTabs.tsx`**, reordenar e renomear:

```tsx
const tabs = [
  { id: "mapa", label: "🗺️ Mapa" },
  { id: "cards", label: "📄 Cards" },
  { id: "tabela", label: "📊 Tabela" },
];
```

---

## CHECKLIST DE VERIFICAÇÃO

Após todas as alterações, verificar:

- [ ] `npm run dev` sem erros TypeScript
- [ ] View default ao abrir é o mapa (`viewMode = 'mapa'`)
- [ ] Clicar em UF no mapa mostra badge "Ver Cards de {Estado}"
- [ ] Badge navega para view Cards filtrada pela UF correta
- [ ] Botão 🇧🇷 no canto do mapa navega para view Tabela
- [ ] Botão `dark_mode` **não existe** no TopAppBar
- [ ] Chips de status sem emoji de bolinha e sem contagem numérica
- [ ] Select de UF e Mês estão na mesma linha das abas de navegação
- [ ] Bloco `flex items-center justify-between` com UF label e ano foi removido
- [ ] Selects não aparecem duplicados na área de filtros horizontais
- [ ] Campo de busca abre modal glassmorphism ao digitar ≥ 2 caracteres
- [ ] Busca fuzzy: "maca" → encontra "Maçã"; "cebo" → encontra "Cebola"
- [ ] Clicar num estado no modal navega para Cards com produto filtrado
- [ ] Tecla Escape fecha o modal de busca
- [ ] Mapa se adapta em 320px (mobile), tablet e desktop
- [ ] `null` safety em `mes_referencia` (campo pode ser `null` no backend para meses sem dado — o frontend **não exibe status cinza**, apenas omite o mês no círculo do modal de busca)
- [ ] Nenhum preço em R$ exibido em lugar algum

---

## NOTAS PARA O AGENTE

1. `allProducts` (sem filtro de status/mes) deve ser passado ao `SearchResultsModal`, não `produtos`. **Atenção**: o frontend deste projeto **não exibe status CINZA** em nenhuma view — produtos sem dado recente são simplesmente omitidos da exibição visual. O campo `mes_referencia` pode chegar como `null` do backend; trate-o defensivamente com `?.` e `??`, mas nunca renderize uma cor ou badge cinza.
2. O tipo `ViewMode` muda de `'grade-sazonal'` para `'tabela'` — buscar e substituir em TODO o arquivo `SupermercadoView.tsx`.
3. O `BrasilMap` wrapper já tem `position: relative` via `cn('relative ...')` — os botões `absolute` internos já se posicionam corretamente.
4. `temGradeCompleta` continua sendo aplicado na view tabela — não remover esse filtro.
5. `CategoriesModal` e `GradeSazonalAcordeao` não devem ser alterados.

---

## HIERARQUIA APÓS A IMPLEMENTAÇÃO

```
Mapa Regional (view padrão/pivot)
    │
    ├── Clique em UF → badge "Ver Cards de {Estado}"
    │       └── View Cards (filtrada por UF)
    │
    └── Botão 🇧🇷 → View Tabela (grade sazonal nacional)

TopAppBar (busca global)
    │
    └── Digitar ≥ 2 chars → Modal Glassmorphism
            └── Clicar em estado → View Cards (UF + produto filtrado)
```
