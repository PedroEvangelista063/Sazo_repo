# OpenCode Prompt — Sazo Brasil Frontend Improvements

# Copie e cole este prompt diretamente no OpenCode

---

## CONTEXTO DO PROJETO

Você está trabalhando em `/home/pedroeduardo/projetos/quero_comprar_vg`, um app de sazonalidade de hortifrutigranjeiros.

**Stack frontend**: React 19 + Vite + TailwindCSS 3 + shadcn/ui + Framer Motion + Zustand 5 + TanStack Query v5

**MCPs disponíveis** (já configurados em `.opencode/opencode.json`):

- `filesystem` → leitura/escrita em `frontend/`
- `sequential-thinking` → planejamento ordenado de subtarefas
- `playwright` → validação visual pós-edição

**Regras invioláveis do projeto** (`.agents/AGENTS.md`):

- Nunca exibir R$ — apenas status visual (Verde/Amarelo/Vermelho)
- Mobile-first: 320px mínimo, touch targets ≥ 44px
- Zero MUI/Ant Design — só shadcn/ui + Tailwind + Framer Motion
- Dark/light mode obrigatório em todos os componentes
- Skeleton em vez de spinners bloqueantes
- Null safety com `?.` e `??` no React (campos nulos chegam do backend)

---

## INSTRUÇÕES DE ORQUESTRAÇÃO (gentle-ai subagents)

Você é o **ORQUESTRADOR**. Não execute as tarefas inline — delegue cada fase a um subagent especializado.

### Regra de Delegação

| Critério                             | Inline | Delegar      |
| ------------------------------------ | ------ | ------------ |
| Leitura de 1-3 arquivos para decidir | ✅     | —            |
| Leitura de 4+ arquivos               | —      | ✅ Explorer  |
| Escrita em 1 arquivo mecânico        | ✅     | —            |
| Escrita em 2+ arquivos com análise   | —      | ✅ Writer    |
| Validação visual (Playwright)        | —      | ✅ Validator |

### Workflow obrigatório

```
1. Para cada FASE abaixo:
   a. Use sequential-thinking MCP para decompor a tarefa
   b. Delegue leitura+escrita ao Writer subagent
   c. Delegue validação ao Validator subagent (Playwright)
   d. Registre resultado em memória (Engram MCP se disponível)

2. Após todas as fases:
   a. Execute `gentle-ai review start` no repo
   b. Rode lens `review-readability` (standard diff — mudanças de UI/CSS)
   c. Capture resultado com `gentle-ai review finalize`
```

---

## FASES DE IMPLEMENTAÇÃO

### FASE 1 — Nome do projeto "Sazo Brasil"

**Subagent: Writer**
**Arquivos a modificar** (use o MCP `filesystem` para leitura e edição):

#### 1.1 `frontend/index.html`

```diff
-  <title>Quero Comprar</title>
+  <title>Sazo Brasil — Sazonalidade de Hortifruti</title>

-  <meta name="description" content="Descubra a melhor época para comprar hortigranjeiros" />
+  <meta name="description" content="Sazo Brasil: descubra a melhor época para comprar hortifruti e economize na feira" />
```

#### 1.2 `frontend/src/components/layout/TopAppBar.tsx`

```diff
-    HortiSazonal
+    Sazo Brasil
```

#### 1.3 `frontend/src/components/layout/Footer.tsx`

```diff
-    HortiSazonal
+    Sazo Brasil
```

**Verificação**: `grep -r "HortiSazonal" frontend/src/ frontend/index.html` → deve retornar vazio.

---

### FASE 2 — Suavizar efeitos de zoom (Claymorphism correto)

**Subagent: Writer**

#### 2.1 `frontend/src/index.css`

Substituir o bloco `.clay-card` e `.clay-card:hover` completo:

```css
.clay-card {
  border-radius: 2rem;
  background: theme("colors.surface-container");
  box-shadow:
    inset -4px -4px 8px rgba(255, 255, 255, 0.65),
    inset 4px 4px 8px rgba(0, 0, 0, 0.04),
    6px 6px 14px rgba(0, 0, 0, 0.04),
    -2px -2px 6px rgba(255, 255, 255, 0.5);
  transition:
    box-shadow 0.3s cubic-bezier(0.34, 1.56, 0.64, 1),
    transform 0.3s cubic-bezier(0.34, 1.56, 0.64, 1);
}

/* Hover passivo: apenas sombra muda, SEM scale */
.clay-card:hover {
  box-shadow:
    inset -3px -3px 6px rgba(255, 255, 255, 0.7),
    inset 3px 3px 6px rgba(0, 0, 0, 0.06),
    8px 8px 18px rgba(0, 0, 0, 0.06),
    -2px -2px 6px rgba(255, 255, 255, 0.6);
}

/* Press/active: sombra interna afunda */
.clay-card:active {
  box-shadow:
    inset 5px 5px 10px rgba(0, 0, 0, 0.08),
    inset -5px -5px 10px rgba(255, 255, 255, 0.6),
    2px 2px 4px rgba(0, 0, 0, 0.02);
  transform: translateY(1px);
}

/* Variante para cards CLICÁVEIS (ProductCard, botões de mês) */
.clay-card--interactive:hover {
  transform: translateY(-2px);
  box-shadow:
    inset -3px -3px 6px rgba(255, 255, 255, 0.7),
    inset 3px 3px 6px rgba(0, 0, 0, 0.06),
    10px 10px 20px rgba(0, 0, 0, 0.08),
    -3px -3px 8px rgba(255, 255, 255, 0.7);
}
```

#### 2.2 `frontend/src/components/ProductCard.tsx`

```diff
- whileHover={{ y: -4, scale: 1.02 }}
- whileTap={{ scale: 0.95 }}
+ whileHover={{ y: -2 }}
+ whileTap={{ y: 1 }}

- className={cn('clay-card group relative ...
+ className={cn('clay-card clay-card--interactive group relative ...
```

#### 2.3 `frontend/src/components/SazonalidadeNacional.tsx`

Remover `whileHover={{ scale: 1.08 }}` das células da grade e trocar `<motion.div>` por `<div>`.

---

### FASE 3 — Ícones de sazonalidade nos filtros do nav lateral

**Subagent: Writer**
**Arquivo**: `frontend/src/pages/SupermercadoView.tsx`

Substituir os 3 botões de filtro de status (material icons `done/remove/close`) por círculos semânticos de cor com dot branco central:

- **VERDE**: `bg-primary` + dot `bg-white/90`, `h-11 w-11` (44px touch), `aria-pressed`
- **AMARELO**: `bg-secondary-container` + dot `bg-white/90`
- **VERMELHO**: `bg-tertiary-container` + dot `bg-white/90`
- Estado ativo: `ring-2 ring-{cor}/40 brightness-110`
- Estado inativo: `opacity-70 hover:opacity-90`
- Remover todo `<span className="material-symbols-outlined">done/remove/close</span>`

---

### FASE 4 — Remover alerta ⚠️ das células da grade + rodapé

**Subagent: Writer**

#### 4.1 `frontend/src/components/SazonalidadeNacional.tsx`

Remover o bloco `{isLowCoverage && (<p className="...">⚠️ {item.total_ufs} UF...</p>)}`

#### 4.2 `frontend/src/components/layout/Footer.tsx`

Adicionar uma segunda linha ao rodapé com legenda de transparência:

```tsx
{
  /* Legenda de transparência — segunda linha do footer */
}
<div className="flex w-full flex-wrap items-center justify-center gap-x-4 gap-y-1 border-t border-outline-variant/30 bg-surface-container/40 px-lg py-1.5">
  <span className="flex items-center gap-1 text-[10px] text-on-surface-variant">
    <span
      className="inline-block h-2 w-2 rounded-full bg-primary"
      aria-hidden="true"
    />
    Melhor época
  </span>
  <span className="flex items-center gap-1 text-[10px] text-on-surface-variant">
    <span
      className="inline-block h-2 w-2 rounded-full bg-secondary-container"
      aria-hidden="true"
    />
    Preço normal
  </span>
  <span className="flex items-center gap-1 text-[10px] text-on-surface-variant">
    <span
      className="inline-block h-2 w-2 rounded-full bg-tertiary-container"
      aria-hidden="true"
    />
    Fora de época
  </span>
  <span className="text-[10px] text-on-surface-variant opacity-60">|</span>
  <span className="text-[10px] text-amber-600 dark:text-amber-400">
    ⚠️ &lt; 3 UFs = cobertura reduzida
  </span>
  <span className="text-[10px] text-on-surface-variant">
    ⓘ Histórico = último ano real CONAB
  </span>
</div>;
```

Ajustar padding-bottom do `<main>` em `SupermercadoView.tsx`:

```diff
- pb-xl
+ pb-[7rem]
```

---

### FASE 5 — Claymorphism consistente na GradeSazonal

**Subagent: Writer**
**Arquivo**: `frontend/src/components/GradeSazonalAcordeao.tsx`

```diff
# section wrapper:
- "rounded-clay border border-gray-200 bg-white/80 shadow-clay-card backdrop-blur-sm dark:border-gray-700 dark:bg-gray-800/80 dark:shadow-clay-dark"
+ "clay-card overflow-hidden border border-outline-variant/40"

# button sticky header:
- 'bg-white/95 shadow-clay-btn backdrop-blur-sm ...'
- 'dark:bg-gray-800/95 dark:shadow-clay-dark ...'
+ 'bg-surface-container-lowest/95 backdrop-blur-sm ...'
+ 'border-b border-outline-variant/20 hover:bg-surface-container/80'

# texto produto:
- "text-gray-900 dark:text-gray-100"
+ "text-on-surface"

- "text-gray-400 dark:text-gray-500"
+ "text-on-surface-variant"
```

---

### FASE 6 — Responsividade aprimorada

**Subagent: Writer**

#### 6.1 `frontend/src/index.css` — adicionar ao final:

```css
/* Safe area para dispositivos com notch */
@supports (padding-bottom: env(safe-area-inset-bottom)) {
  footer.docked {
    padding-bottom: calc(env(safe-area-inset-bottom) + 0.375rem);
  }
}

html {
  scroll-behavior: smooth;
}
body {
  overflow-x: hidden;
}

@media (max-width: 767px) {
  nav.hide-scrollbar.sticky {
    scroll-snap-type: x mandatory;
  }
  nav.hide-scrollbar.sticky > button {
    scroll-snap-align: center;
    flex-shrink: 0;
  }
}
```

#### 6.2 `frontend/src/pages/SupermercadoView.tsx`

Selector de UF: adicionar `w-full sm:w-auto` para ser full-width em mobile.

---

### FASE 7 — Documento FRONTEND_IMPROVEMENTS.md

**Subagent: Writer**
**Arquivo NOVO**: `docs/FRONTEND_IMPROVEMENTS.md`

Criar documento com:

1. Decisões de design do claymorphism (sombras, hover, transições)
2. Tabela de tokens de cor por status de sazonalidade
3. Justificativa dos ícones de filtro (círculo semântico vs material icon)
4. Posicionamento dos alertas de transparência no rodapé
5. Breakpoints e checklist de responsividade
6. Próximos passos de UX (skeleton, tooltip mobile, PWA, a11y)

---

## VALIDAÇÃO PÓS-IMPLEMENTAÇÃO

**Subagent: Validator** (Playwright MCP)

Tarefas de validação em http://localhost:5173 (dev server):

1. Verificar `<title>Sazo Brasil — Sazonalidade de Hortifruti</title>`
2. Verificar `<h1>Sazo Brasil</h1>` no header
3. Verificar 3 círculos coloridos no nav lateral (sem `material-symbols-outlined`)
4. Hover em ProductCard → `translateY` sem scale visível
5. Abrir Grade Sazonal → verificar ausência de `⚠️` nas células
6. Verificar rodapé com legenda de cores de sazonalidade
7. Viewport 375px → selector UF full-width, nav horizontal funcional
8. Dark mode toggle → verificar tokens corretos (sem bg-white/bg-gray hardcoded)

---

## REVIEW COM GENTLE-AI

```bash
gentle-ai review status --cwd /home/pedroeduardo/projetos/quero_comprar_vg --contract gentle-ai.review-integration/v1 --next-transition
gentle-ai review start --cwd /home/pedroeduardo/projetos/quero_comprar_vg
gentle-ai review finalize --cwd /home/pedroeduardo/projetos/quero_comprar_vg
```

**Lens**: `review-readability` (standard diff — UI/CSS/naming sem lógica de negócio)

---

## MEMÓRIA (Engram MCP)

Após concluir, salvar via Engram MCP:

- **title**: "Refatoração frontend Sazo Brasil — claymorphism + responsividade"
- **type**: architecture
- **topic_key**: "frontend/design-system"
- **What**: Renomeação, hover suavizado, ícones círculo, alertas no rodapé, claymorphism uniforme
- **Where**: SupermercadoView, SazonalidadeNacional, GradeSazonalAcordeao, Footer, TopAppBar, index.css, index.html, docs/FRONTEND_IMPROVEMENTS.md
- **Learned**: `clay-card--interactive` como variante separada evita translateY em hover passivo
