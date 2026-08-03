# Relatório — Viabilidade de Claymorphism no Frontend

**Data:** 2026-08-03
**Escopo:** `frontend/` (app React PWA "Quero Comprar")
**Status:** ✅ VIÁVEL — esforço baixo-médio, risco baixo, sem mudança de API/estado

---

## 1. Resumo Executivo

**É possível implementar Claymorphism no projeto? Sim.** O frontend está saudável
(lint `tsc --noEmit` limpo, 25 testes / 4 suites passando) e a base técnica já contém
80% do necessário:

- O **`GameButton.tsx` já implementa o padrão "keycap"** (sombra dura de borda +
  lift no hover + afundar no active) — a essência do efeito 3D suave do clay.
- O projeto usa **Tailwind 3 com valores arbitrários** (`shadow-[...]`, `rounded-[...]`),
  o que permite aplicar o estilo sem instalar nada novo.
- **Framer Motion e GSAP** estão instalados para as transições de press/lift.

O esforço concentra-se em **trocar sombras e raios** de ~15-20 arquivos de
componentes, de forma seletiva (não em telas densas como tabelas/gráficos).

---

## 2. O que é Claymorphism (referência técnica)

Tendência de UI (2021+, popularizada por Michał Malewicz) que faz elementos
parecerem blocos de massinha/argila — evolução do neumorfismo com **cor saturada**
(resolve o problema de contraste do neumorfismo).

Três pilares técnicos:

| Pilar                  | Valor recomendado                                                                                                      |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| **Cor**                | Fundo pastel saturado (nunca branco puro); texto escuro dessaturado (contraste ≥ 4.5:1 WCAG AA)                        |
| **Border-radius**      | Cartões 24–32px; botões 16–24px                                                                                        |
| **Sombra (3 camadas)** | `0 35px 68px` drop tintado + `inset 0 -8px 16px` escura (curvatura inferior) + `inset 0 8px 16px` branca (luz de topo) |

Receita CSS canônica:

```css
.clay-card {
  background: #f3e8ff; /* pastel saturado */
  border-radius: 32px;
  box-shadow:
    0 35px 68px rgba(112, 100, 176, 0.3),
    /* drop tintado com a cor do elemento */ inset 0 -8px 16px
      rgba(95, 70, 140, 0.22),
    /* sombra inferior (curvatura) */ inset 0 8px 16px rgba(255, 255, 255, 0.65); /* luz de topo */
}
```

**Dark mode** exige re-derivar: drop escuro profundo, brilho de topo com branco em
opacidade baixa (~0.08–0.12), sombra inferior com preto translúcido.

---

## 3. Estado Atual do Frontend vs. Requisito Clay

| Aspecto        | Hoje no projeto                                 | Claymorphism pede             | Gap                                  |
| -------------- | ----------------------------------------------- | ----------------------------- | ------------------------------------ |
| Raios de card  | `rounded-xl` (12px)                             | 24–32px                       | **Médio** — trocar classe            |
| Raios de botão | `rounded-md`/`rounded-xl` (6–12px)              | 16–24px                       | **Médio**                            |
| Sombras        | `shadow-sm/md/lg/xl` (difusas, neutras)         | pilha de 3 sombras tintadas   | **Alto** — novo token                |
| Botões         | `GameButton` com sombra dura keycap ✅          | press com insets              | **Baixo** — só acrescentar highlight |
| Cores          | `sazonal-verde/amarelo/vermelho` (já saturadas) | pastéis saturados             | **Baixo** — paleta compatível        |
| Dark mode      | `dark:bg-gray-800` + CSS vars                   | superfícies escuras matizadas | **Médio**                            |
| Animações      | Framer Motion springs, GSAP                     | transições de sombra/press    | **Baixo** — já existe                |
| Telas densas   | TabelaView, GraficosView                        | evitar clay em dados densos   | **Decisão de escopo**                |

**Observações estruturais relevantes:**

1. `index.css` já centraliza tokens em CSS vars (`--bg-card`, `--border-subtle`, `--glass-*`) — ponto natural para adicionar `--shadow-clay-*` e `--radius-clay`.
2. `ui/tabs.tsx` e `ui/select.tsx` usam cores `oklch()` padrão do shadcn (inconsistentes com o resto do app, que usa `gray-*`/`sazonal-*`) — **inconsistência pré-existente**, não causada por esta proposta.
3. `SpotlightCard.tsx` usa `neutral-900` fixo (sem variante dark) — exigirá atenção para não virar "buraco" no tema clay.
4. Regra de ouro nº 1 do app (**nunca exibir R$/valores monetários**) não é afetada — clay é estético, a semântica de cores (verde=barato/amarelo=médio/vermelho=caro) permanece.

---

## 4. Viabilidade por Camada

### 4.1 Tokens de design (Fase 0) — ✅ trivial

No `tailwind.config.js`:

```js
theme: {
  extend: {
    boxShadow: {
      'clay-sm': '0 10px 20px rgba(21,83,45,0.25), inset 0 -4px 8px rgba(21,83,45,0.18), inset 0 4px 8px rgba(255,255,255,0.5)',
      'clay-md': '0 20px 40px rgba(21,83,45,0.28), inset 0 -6px 12px rgba(21,83,45,0.20), inset 0 6px 12px rgba(255,255,255,0.55)',
      'clay-lg': '0 35px 68px rgba(21,83,45,0.30), inset 0 -8px 16px rgba(21,83,45,0.22), inset 0 8px 16px rgba(255,255,255,0.65)',
      'clay-dark': '0 25px 50px rgba(0,0,0,0.55), inset 0 -8px 16px rgba(0,0,0,0.45), inset 0 8px 16px rgba(255,255,255,0.08)',
      'clay-press': '0 6px 12px rgba(21,83,45,0.3), inset 0 -2px 4px rgba(21,83,45,0.3), inset 0 2px 4px rgba(255,255,255,0.5)',
    },
    borderRadius: { clay: '1.75rem' },   /* 28px */
  }
}
```

> Paleta usada no exemplo: verde-sazonal do projeto (`#16a34a`/`#14532d`). As sombras
> **são tintadas com a cor do elemento** — para amarelo/vermelho, derivar do próprio token.

### 4.2 Componentes base shadcn (Fase 1) — ✅ fácil

| Arquivo         | Mudança                                                                                                                                                     |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ui/card.tsx`   | `rounded-xl` → `rounded-clay` (28px); `shadow-sm` → `shadow-clay-sm`; borda suavizada                                                                       |
| `ui/button.tsx` | nova variant `clay`: `rounded-2xl shadow-clay-sm hover:shadow-clay-md active:shadow-clay-press active:translate-y-[2px] active:scale-[0.98] transition-all` |
| `ui/badge.tsx`  | `rounded-md` → `rounded-full` + `shadow-clay-sm` (opcional)                                                                                                 |
| `ui/dialog.tsx` | `rounded-lg shadow-lg` → `rounded-clay shadow-clay-lg`                                                                                                      |

### 4.3 Componentes do app (Fase 2) — ⚠️ médio

- `ProductCard.tsx`: `rounded-xl shadow-sm hover:shadow-lg` → `rounded-clay shadow-clay-md hover:shadow-clay-lg` (manter `ring` de seleção).
- `GameCard.tsx`: idem, já tem hover lift — combinar com clay.
- `SkeletonCard.tsx`: manter skeleton (animate-pulse), só alinhar raio/fundo.
- `GameButton.tsx`: **acrescentar** o highlight de topo skeuo (`bg-[linear-gradient(...)]` + `inset` branco) sobre o padrão keycap existente — o menor esforço de todos.
- Header/filtros chips em `SupermercadoView.tsx`: `rounded-full shadow-sm` já próximos — basta trocar para `shadow-clay-sm`.
- `DataTransparencyInfo.tsx`: tooltip/badge pode ganhar clay sutil.

### 4.4 Dark mode (Fase 3) — ⚠️ médio

Re-derivar com `dark:shadow-clay-dark` + superfícies `dark:bg-[#1e293b]`/matizadas
(evitar `gray-900` puro). O app já tem `.dark` via `useTheme` — basta adicionar as
variantes `dark:` nas sombras.

### 4.5 Animações (Fase 4) — ✅ baixo

- Framer Motion: `whileTap={{ y: 3, scale: 0.98 }}` + spring (padrão já usado).
- GSAP: opcional — hover magnético/elastic para botões hero.

### 4.6 Acessibilidade (obrigatória, não negociável)

- Manter contraste de texto ≥ 4.5:1 (texto escuro sobre pastéis claros).
- Manter `focus-visible` rings (já presentes nos componentes shadcn).
- Não usar clay em tabelas/gráficos densos (TabelaView, GraficosView) — espaço útil.

---

## 5. Riscos e Mitigações

| Risco                                                     | Severidade | Mitigação                                                                                           |
| --------------------------------------------------------- | ---------- | --------------------------------------------------------------------------------------------------- |
| 3 design systems (Mantine/shadcn/MUI) + Rewind competindo | Média      | Centralizar clay em **tokens no tailwind.config.js** + CSS vars; não reescrever componentes por lib |
| Sombra tintada pode "sujar" em dark mode                  | Média      | Usar token `clay-dark` com opacidades calibradas                                                    |
| Contraste de texto em pastéis                             | Média      | Checklist WCAG AA antes de merge                                                                    |
| oklch() em tabs/select (pré-existente)                    | Baixa      | Opcional: normalizar para gray/sazonal no mesmo esforço                                             |
| Overlay visual (glass/backdrop-blur) vs clay              | Baixa      | Manter `--glass-*` para header; clay para superfícies de conteúdo                                   |

**Impacto em arquivos:** ~15–20 componentes `.tsx` + `index.css` + `tailwind.config.js`.
**Zero impacto** em API, estado (Zustand/Redux), fetching (TanStack/SWR) e tipos.

---

## 6. Plano de Implementação Recomendado

| Fase | Escopo                                                         | Estimativa |
| ---- | -------------------------------------------------------------- | ---------- |
| 0    | Tokens (tailwind.config.js + CSS vars)                         | 30 min     |
| 1    | Base shadcn (card, button, badge, dialog)                      | 1 h        |
| 2    | Cards do app (ProductCard, GameCard, SkeletonCard, GameButton) | 1–2 h      |
| 3    | Dark mode re-derivado                                          | 1 h        |
| 4    | Animações (press/lift) Framer Motion + GSAP                    | 1 h        |
| 5    | Validação: `npm run lint` + `npm test` + revisão visual + a11y | 1 h        |

**Total estimado: ~1 dia de trabalho.**

---

## 7. Conclusão

**Recomendação: APROVADO com escopo seletivo.**

1. Aplicar clay nos **componentes de superfície e ação** (cards, botões, badges, dialogs, filtros).
2. **Não aplicar** em tabelas/gráficos densos (TabelaView, GraficosView).
3. Manter a semântica de cores sazonais intacta (regra de ouro nº 1).
4. Centralizar em tokens para garantir consistência entre os 3 design systems.

O resultado seria um visual "massinha" coeso e lúdico — aderente ao atual estilo
game-inspired ("Juicy UI") do app, com custo baixo e risco controlado.
