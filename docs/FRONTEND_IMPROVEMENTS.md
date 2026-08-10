# Melhorias de Frontend — Sazo Brasil

Documento de referência da Fase 7 do refactor de frontend: sistema visual claymorphism, semântica de cor por status, ícones de filtro acessíveis, transparência de dados no rodapé e responsividade mobile-first.

Escopo baseado no código real em `frontend/` (React 19 + Vite + TailwindCSS 3 + shadcn/ui + Framer Motion).

---

## 1. Decisões de Design

O visual claymorphism simula um material "pressionável" a partir de sombras em camadas, sem depender de imagens ou gradientes complexos. As regras foram centralizadas em `frontend/src/index.css` (classe `.clay-card`) e nos tokens de `frontend/tailwind.config.js`.

- **Sombras em camadas** — cada card combina _inset_ highlights (claros, para simular luz incidente) com _drop shadows_ externos (para profundidade), ex. `inset -4px -4px 8px rgba(255,255,255,.65)` + `6px 6px 14px rgba(0,0,0,.04)`. O raio padrão do card é `border-radius: 2rem` (token `borderRadius.lg`).
- **Hover passivo apenas muda a sombra** — a transição `.clay-card:hover` recalcula _somente_ o `box-shadow` (highlight levemente mais forte e sombra externa mais difusa). Zero `transform`/`scale`.
- **Active afunda** — `.clay-card:active` inverte as sombras inset (realce para dentro) e aplica `translateY(1px)`, simulando o botão sendo "pressionado" no material.
- **Variante clicável `clay-card--interactive`** — para elementos que são de fato interativos (ex. `ProductCard`), o `:hover` ganha um suave `translateY(-2px)` — deslocamento, **não** escala — além do reforço da sombra. O comportamento de "afundar" ao pressionar continua vindo do `:active` base.
- **Transições cubic-bezier** — `box-shadow` e `transform` usam `0.3s cubic-bezier(0.34, 1.56, 0.64, 1)` (com overshoot leve), deixando o movimento orgânico.
- **Framer Motion só para translateY suave** — em `ProductCard.tsx`, `whileHover={{ y: -2 }}` / `whileTap={{ y: 1 }}` com `transition={{ duration: 0.2 }}` substituem o antigo `scale`. A grade de produtos (`SazonalidadeNacional.tsx`) e o `ProductCard` não usam mais escala de hover: animações de entrada usam `scale` apenas no _mount_ (entrada da view), nunca em interação.
- **Grade Sazonal (accordion)** — o wrapper usa `clay-card overflow-hidden border border-outline-variant/40`; o header sticky de cada categoria usa `bg-surface-container-lowest/95 backdrop-blur-sm`, com `hover:bg-surface-container/80` e `active:translate-y-[1px] active:shadow-clay-press` (mesma linguagem de "afundar"). Textos: `text-on-surface` (título) e `text-on-surface-variant` (descrição/badge).

**Onde a classe é aplicada:**

- `ProductCard.tsx` — `clay-card clay-card--interactive` no card do produto (interativo, selecionável).
- `SupermercadoView.tsx` — cards de estado (erro, "Nenhum dado disponível", aviso da grade nacional), card do mapa, botão de fechar modal e botões de mês do modal, todos usando a superfície clay com raio `rounded-lg` (2rem) ou `rounded-full`.
- `GradeSazonalAcordeao.tsx` — seção de cada macrocategoria (`clay-card overflow-hidden`) e header sticky de categoria.

**Princípio geral:** cor/sombra comunicam estado; movimento é deslocamento pequeno e rápido, nunca escala exagerada.

---

## 2. Tokens de cor

Os status semânticos de sazonalidade mapeiam diretamente para tokens do Material Design customizados em `frontend/tailwind.config.js`. A cor é o próprio dado: o usuário reconhece o status pela cor antes de ler qualquer texto.

| Status   | Significado   | Token Tailwind          | Valor hex | Onde aparece                                                                    |
| -------- | ------------- | ----------------------- | --------- | ------------------------------------------------------------------------------- |
| VERDE    | Melhor época  | `primary`               | `#006b2c` | Filtros (botão ativo), legenda do rodapé, `ProductCard` (`shadow-clay-green`)   |
| AMARELO  | Preço normal  | `secondary-container`   | `#fed01b` | Filtros (botão ativo), legenda do rodapé, `ProductCard` (`shadow-clay-pressed`) |
| VERMELHO | Péssima época | `tertiary-container`    | `#e02928` | Filtros (botão ativo), legenda do rodapé, `ProductCard` (`shadow-clay-pressed`) |
| CINZA    | Sem dados     | `surface-container-low` | `#eef4ff` | `ProductCard` (fallback CINZA)                                                  |

Observações:

- **CINZA** não tem botão de filtro (existem apenas 3 status ativos). No `ProductCard.tsx:65` o fallback usa `bg-surface-container-low text-on-surface-variant shadow-clay-dark border border-outline-variant/30` — cor neutra de superfície, sem conotação positiva/negativa. Na grade sazonal, a célula "Sem Cotação" usa cinza neutro do próprio tema (`bg-gray-100 dark:bg-gray-800/40`).
- **Sombra por status** — cada card colorido usa uma sombra clay própria: `shadow-clay-green` (tom do verde), `shadow-clay-pressed` (afundado, para amarelo/vermelho) e `shadow-clay-dark` (padrão).
- **Classe de status no ProductCard** — o mapa `statusColors` aponta para as classes utilitárias `.bg-status-*` / `.status-*` (definidas no `index.css`) que resolvem para `primary-container` / `secondary-container` / `tertiary-container`.

---

## 3. Ícones de filtro

Os filtros semânticos (VERDE / AMARELO / VERMELHO) em `SupermercadoView.tsx` são **círculos de cor**, não botões com ícones de material (como `done`/`remove`/`close`). Justificativa:

- **A cor é o próprio semântico** — não há necessidade de traduzir "melhor época" para um glifo; o círculo pintado com o token de status já comunica. Evita o salto cognitivo cor → ícone → significado.
- **Consistência com a legenda** — o mesmo círculo de cor aparece na segunda linha do rodapé (legenda "Melhor época / Preço normal / Fora de época"), criando uma única linguagem visual em todo o app.
- **Contraste** — cores full-opacity (`bg-primary`, `bg-secondary-container`, `bg-tertiary-container`) com um ponto interno `bg-white/90 shadow-inner` (um "olho" de material) garantem legibilidade em claro e escuro.
- **Acessibilidade** — cada botão declara `aria-label` ("Filtrar: Melhor Época", etc.) e `aria-pressed` com o estado selecionado, além do atributo `title`. O ponto interno tem `aria-hidden`.
- **Touch target** — os botões usam `h-11 w-11` = **44 × 44px**, o mínimo recomendado para toque (WCAG 2.5.5). O seletor de categorias adjacente usa `h-10 w-10` (40px), um desvio aceito por ser opção secundária.
- **Estado selecionado** — além do `ring-2` na cor do status (`ring-primary/40` etc.), o botão ativo ganha `brightness-110` e a sombra correspondente (`shadow-clay-green` / `shadow-clay-pressed`), destacando-o por contraste, anel e profundidade. O estado não selecionado usa opacidade reduzida (`bg-primary/70` etc.) com `hover` escurecendo.
- **Transições** — `transition-all duration-300` suaviza a troca entre estados (opacidade, anel, brilho e sombra) quando o usuário alterna o filtro, mantendo a linguagem clay do app.

---

## 4. Transparência de dados

A transparência sobre a origem e a cobertura dos dados foi **removida do corpo da grade** e consolidada no rodapé docked (`Footer.tsx`):

- **Alerta ⚠️ < 3 UFs removido da grade** — antes exibido inline por célula/linha, o aviso de cobertura reduzida saiu de `SazonalidadeNacional.tsx`. As células da grade voltaram a ser `<div>` simples, sem poluição visual nem repetição do alerta.
- **Legenda de cores no rodapé** — a segunda linha do `Footer` traz a legenda com os círculos de cor (Melhor época / Preço normal / Fora de época), seguida do alerta `⚠️ < 3 UFs = cobertura reduzida` e da nota `ⓘ Histórico = último ano real CONAB`. A primeira linha mantém o badge "Painel Transparência Ativo", o status de cache e os links "Transparência" / "Metodologia".
- **Footer docked** — o rodapé é `fixed bottom-0 z-40 ... backdrop-blur-md`, sempre visível, dividido em duas linhas: marca/status e legenda + notas de transparência.
- **Padding do main** — o conteúdo principal em `SupermercadoView.tsx` usa `pb-[7rem]` para reservar espaço vertical e **não sobrepor o footer docked** ao rolar até o fim da página.
- **Transparência por célula preservada** — a nota de cobertura/legado saiu da grade, mas o tooltip granular `DataTransparencyInfo` (que exibe `tipo_dado`, `ano_referencia` e `mensagem_transparencia` por célula legada) permanece em `SazonalidadeNacional.tsx` para o detalhe fino no hover/leitor de tela.
- **Sem preenchimento futuro com fallback** — mantém-se a regra do projeto: nenhuma projeção preenche meses futuros com dados de fallback; o ano de referência legado é sempre o último ano real da CONAB (indicado na nota ⓘ).

---

## 5. Responsividade

**Breakpoints adotados** (mobile-first):

| Breakpoint          | Valor       | Estratégia                                                          |
| ------------------- | ----------- | ------------------------------------------------------------------- |
| Base (mobile-first) | ≥ 320px     | Layout de uma coluna, grid de produtos em 2 colunas                 |
| `sm`                | ≥ 768px     | Selector UF em largura automática; nav lateral vira coluna vertical |
| `lg`                | ≥ 1024px    | Grid de produtos em 4 colunas; mapa + painel lado a lado            |
| Container           | `max-w-7xl` | Largura máxima do `main` centralizado                               |

**Checklist aplicado no código:**

- [x] **Touch targets ≥ 44px** — botões de filtro semântico com `h-11 w-11`.
- [x] **`safe-area-inset-bottom` para notch** — em `index.css`: `@supports (padding-bottom: env(safe-area-inset-bottom))` aplica padding extra em `footer.docked`, respeitando a área de gestos de iPhones (viewport usa `viewport-fit=cover`).
- [x] **Scroll-snap horizontal na nav lateral em <768px** — media query `max-width: 767px`: `nav.hide-scrollbar.sticky` recebe `scroll-snap-type: x mandatory` e os botões `scroll-snap-align: center` (com `flex-shrink: 0`); a nav em si usa `overflow-x-auto` e `hide-scrollbar`. Em `md` a nav vira coluna vertical (`md:flex-col md:overflow-y-auto md:rounded-full`).
- [x] **Selector UF** — `w-full` no mobile e `sm:w-auto` no desktop (`SupermercadoView.tsx`), dentro de um container flex que quebra linha quando necessário.
- [x] **`overflow-x: hidden` no body** — evita scroll horizontal acidental em qualquer viewport (`index.css`).
- [x] **`scroll-behavior: smooth`** — rolagem suave para âncoras e scroll-snap (`index.css`).
- [x] **Mobile-first** — grids e utilidades são definidos para a base e ampliados com `sm:`/`lg:`; `main` usa `pt-sm` no mobile e `md:flex-row` no desktop; margens móveis via token `px-margin-mobile` (20px).

**Detalhes de implementação verificados:**

- **Grid de produtos** — `grid-cols-2` na base (320px) → `sm:grid-cols-3` (≥768px) → `lg:grid-cols-4` (≥1024px).
- **Nav lateral sticky** — `sticky top-16` no mobile (logo abaixo do TopAppBar) e `md:top-24` no desktop; a coluna de filtros fica vertical (`md:w-16 md:rounded-full`) em telas largas.
- **Header sticky do accordion** — `sticky top-14` dentro de cada grupo, grudando abaixo do header do app durante a rolagem; preserva o `sticky left-0` da coluna "Produto" da tabela via `overflow-clip` no container de conteúdo.
- **Safe-area horizontal** — além do `viewport-fit=cover` no `index.html`, o footer docked compensa apenas o `padding-bottom` (área de gestos); os `px-margin-mobile` cobrem as margens laterais de segurança em telas com cantos arredondados.

---

## 6. Próximos passos

Aperfeiçoamentos planejados, ainda não implementados:

1. **Skeleton na tabela** — a grade sazonal e o accordion ainda não têm estados de carregamento esqueleto dedicados; a tela usa apenas `SkeletonCard` no modo cards. Adicionar linhas/colunas placeholder no padrão dos skeletons existentes (sem spinner bloqueante).
2. **Tooltip mobile (long-press)** — os `aria-label` por célula existem, mas não há tooltip acessível por toque longo no mobile para revelar o texto "Produto — Mês: status". Avaliar long-press ou tap em modal informativo.
3. **A11y — foco visível** — reforçar o `:focus-visible` consistente em botões/cards interativos (especialmente o `ProductCard` e os filtros circulares), garantindo um outline perceptível em navegação por teclado em claro e escuro.

---

### Referência de arquivos

| Arquivo                                            | Papel                                                                                                                                             |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `frontend/src/index.css`                           | Classes `.clay-card`, `:hover`/`:active`, `clay-card--interactive`, tabs de status, safe-area do footer, scroll-snap mobile, `overflow-x: hidden` |
| `frontend/tailwind.config.js`                      | Tokens de cor (M3), `boxShadow` clay-dark/green/pressed, `borderRadius.lg` (2rem), `spacing`                                                      |
| `frontend/src/components/ProductCard.tsx`          | Card clay interativo, círculo de status por token, CINZA fallback, `whileHover`/`whileTap` de translateY                                          |
| `frontend/src/pages/SupermercadoView.tsx`          | Filtros circulares semânticos (aria-pressed), selector UF responsivo, `main` com `pb-[7rem]`                                                      |
| `frontend/src/components/layout/Footer.tsx`        | Footer docked de duas linhas: status + legenda/transparência                                                                                      |
| `frontend/src/components/GradeSazonalAcordeao.tsx` | Accordion com wrapper clay, header sticky e `active` de afundar                                                                                   |
| `frontend/src/components/SazonalidadeNacional.tsx` | Grade de células simples (sem alerta inline, sem hover scale)                                                                                     |
| `frontend/index.html`                              | Título "Sazo Brasil — Sazonalidade de Hortifruti" e description do PWA                                                                            |
