# PLANO: Grade Sazonal — Ícone BR Nacional + Animação de Frutas

**Data**: 2026-07-16
**Status**: APROVADO (Aguardando implementação)
**Escopo**: Frontend (React/TypeScript) + Backend (FastAPI)

---

## 1. Objetivo

Na aba **"Grade Sazonal"**, o dropdown de UF deve exibir **apenas o ícone BR Nacional com efeitos de frutas em movimento**, em vez da lista tradicional de UFs. O usuário acessa dados de 2026 respeitando as regras de fallback do banco e backend.

---

## 2. Análise do Estado Atual

### Frontend
- **`SupermercadoView.tsx`** (Linha 42): `selectedUF` inicia como `'SP'`
- **`SupermercadoView.tsx`** (Linha 58-61): `ufOptions` monta a lista de UFs do hook `useUfs()`
- **`SupermercadoView.tsx`** (Linha 282-291): Dropdown `<select>` renderiza todas as UFs
- **`SupermercadoView.tsx`** (Linha 382-398): Condição para Grade Sazonal: `selectedUF === 'BR' && selectedMonth == null && brSazonalidade`
- **`SazonalidadeNacional.tsx`**: Componente que renderiza a grade 12 meses x produtos
- **`useHortifruti.ts`** (Linha 30): `isBRFull = isBR && !hasFilter` → fetch `/sazonalidade/br-sazonalidade`

### Backend
- **`produtos.py`** (Linha 92-111): `_query_sazonalidade()` detecta `uf='BR'` e chama `_query_br_snapshot()` ou `_query_br_por_mes()`
- **`produtos.py`** (Linha 746-767): Endpoint `GET /api/v1/sazonalidade/br-sazonalidade` → `fn_br_nacional_sazonalidade()`
- **`ufs.py`** (Linha 18): Endpoint `GET /api/v1/ufs` lista UFs disponíveis (inclui "BR" como primeiro item)

### Database
- **`31_remove_year_filter_mv.sql`**: MV V15 expõe dados de 2024, 2025 e 2026
- **`database/summary.md`** (Linha 16): Janela temporal: `2024-01 a 2026-12`
- **`database/summary.md`** (Linha 93-95): Forecast é fallback condicional — dado real nunca é sobrescrito

---

## 3. Regras de Fallback (Já Implementadas)

### Backend
1. **`usou_fallback_12m`**: TRUE quando âncora veio de fallback 12m (produto sem 2025)
2. **`preco_estimado`**: TRUE quando preço foi estimado por interpolação (gap de coleta)
3. **`is_forecast`**: TRUE quando dado é projeção (não real)
4. **`baseline_confianca`**: % de meses com dado real no baseline (0-100)
5. **Regra de ouro**: dado real (scraper) sempre vence projeção (`ON CONFLICT DO UPDATE` com `is_forecast = FALSE`)

### Frontend
1. **`ProdutoVarejo`** (domain.ts): Campos `usou_fallback_12m`, `preco_estimado`, `is_forecast`, `confianca_baseline`
2. **`ProductCard.tsx`**: Badge `📊 Estimativa` quando `is_forecast=true`
3. **`SazonalidadeNacional.tsx`** (Linha 99-101): Emoji `📈` quando `is_forecast=true`

---

## 4. Plano de Implementação

### Fase 1: Criar componente `BRNationalIcon.tsx` (FRONTEND)

**Local**: `frontend/src/components/BRNationalIcon.tsx`

**Responsabilidade**: Renderizar ícone animado representando BR Nacional com frutas em movimento.

**Especificações**:
- Container com borda circular (44x44px mínimo para touch target mobile)
- Emoji de fruta central (ex: `🇧🇷` + combo de frutas)
- Animação Framer Motion:
  - Pulse/scale no ícone central
  - Partículas de frutas flutuando ao redor (emoji menores: 🍎🍌🍅🍊🍇)
  - CSS `@keyframes` para movimento orbital
- Cores: gradiente verde-amarelo (tema BR)
- Hover: intensificar animação
- Click: expandir para mostrar opção de seleção

**Dependências**:
- `framer-motion` (já instalado)
- `lucide-react` (já instalado)

### Fase 2: Adaptar dropdown de UF na Grade Sazonal (FRONTEND)

**Arquivo**: `frontend/src/pages/SupermercadoView.tsx`

**Mudanças**:
1. **Linha 282-291**: Substituir `<select>` por componente condicional
   - Quando `viewMode === 'grade-sazonal'`: renderizar `BRNationalIcon` em vez do dropdown
   - Quando `viewMode !== 'grade-sazonal'`: manter dropdown tradicional

2. **Nova lógica**:
```tsx
const isGradeSazonal = viewMode === 'grade-sazonal'

// Dentro do render:
{isGradeSazonal ? (
  <BRNationalIcon
    onClick={() => setSelectedUF('BR')}
    isActive={selectedUF === 'BR'}
  />
) : (
  <select
    value={selectedUF}
    onChange={(e) => { setSelectedUF(e.target.value); setSelectedMonth(null); setSelectedStatus(null) }}
    className="h-9 rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 px-2 text-sm outline-none focus:ring-2 focus:ring-sazonal-verde-600 w-24 shadow-sm"
    aria-label="Selecionar UF"
  >
    {ufOptions.map((opt) => (
      <option key={opt.value} value={opt.value}>{opt.label}</option>
    ))}
  </select>
)}
```

3. **Auto-seleção**: Quando `viewMode` muda para `'grade-sazonal'`, forçar `selectedUF = 'BR'` automaticamente (Linha 48)

### Fase 3: Efeitos de frutas em movimento (FRONTEND)

**Local**: `frontend/src/components/BRNationalIcon.tsx` + `frontend/src/index.css`

**Animações**:
1. **Framer Motion** (componente):
   - `animate={{ scale: [1, 1.05, 1] }}` com `repeat: Infinity`
   - `animate={{ rotate: [0, 360] }}` para partículas orbitais
   - `transition={{ duration: 3, repeat: Infinity, ease: "easeInOut" }}`

2. **CSS** (`index.css`):
```css
@keyframes fruit-float {
  0%, 100% { transform: translateY(0) rotate(0deg); opacity: 0.7; }
  50% { transform: translateY(-8px) rotate(15deg); opacity: 1; }
}

@keyframes fruit-orbit {
  0% { transform: rotate(0deg) translateX(20px) rotate(0deg); }
  100% { transform: rotate(360deg) translateX(20px) rotate(-360deg); }
}

.fruit-orbit-1 { animation: fruit-orbit 8s linear infinite; }
.fruit-orbit-2 { animation: fruit-orbit 10s linear infinite reverse; }
.fruit-orbit-3 { animation: fruit-orbit 12s linear infinite; }
```

3. **Partículas**: 3-5 emojis de frutas menores orbitando o ícone central

### Fase 4: Garantir dados de 2026 com fallback (JÁ IMPLEMENTADO)

**Backend**: Nenhuma mudança necessária
- MV V15 (`31_remove_year_filter_mv.sql`) já expõe dados de 2024-2026
- `fn_br_nacional_sazonalidade()` aceita parâmetro `ano` (Linha 102, migration 31)
- Forecast é fallback condicional (Linha 93-95, database/summary.md)

**Frontend**: Nenhuma mudança necessária
- `useHortifruti.ts` (Linha 38): `params: { ano, por_pagina: 1000 }` já passa ano
- `SupermercadoView.tsx` (Linha 43): `selectedYear` inicia com `new Date().getFullYear()` (2026)
- `SazonalidadeNacional.tsx` (Linha 99-101): Já renderiza badge de forecast

### Fase 5: Testes (FRONTEND)

**Arquivo**: `frontend/src/test/BRNationalIcon.test.tsx`

**Casos de teste**:
1. Renderiza ícone BR Nacional quando `viewMode === 'grade-sazonal'`
2. Não renderiza ícone quando `viewMode !== 'grade-sazonal'`
3. Animações são aplicadas (verificar classes CSS)
4. Click no ícone seta `selectedUF` para 'BR'
5. Dropdown tradicional aparece em outros modos

---

## 5. Arquivos a Modificar

| Arquivo | Tipo | Mudança |
|---------|------|---------|
| `frontend/src/components/BRNationalIcon.tsx` | **NOVO** | Componente ícone animado |
| `frontend/src/pages/SupermercadoView.tsx` | EDITAR | Lógica condicional do dropdown |
| `frontend/src/index.css` | EDITAR | Keyframes para animação de frutas |
| `frontend/src/test/BRNationalIcon.test.tsx` | **NOVO** | Testes unitários |

---

## 6. Arquivos NÃO Modificados (Já OK)

| Arquivo | Razão |
|---------|-------|
| `backend/app/api/v1/endpoints/produtos.py` | Já suporta `uf=BR` e `ano=2026` |
| `backend/app/api/v1/endpoints/ufs.py` | Lista UFs corretamente |
| `frontend/src/hooks/useHortifruti.ts` | Já busca `/br-sazonalidade` com ano |
| `frontend/src/components/SazonalidadeNacional.tsx` | Já renderiza grade corretamente |
| `database/migrations/*.sql` | MV V15 já expõe 2024-2026 |

---

## 7. Riscos e Mitigações

| Risco | Impacto | Mitigação |
|-------|---------|-----------|
| Quebra do dropdown em outros modos | Alto | Usar `viewMode` como condição, não remover lógica existente |
| Performance com animações | Baixo | Usar CSS puro para partículas, Framer Motion apenas para ícone central |
| Dados de 2026 indisponíveis | Médio | Backend já tem fallback para forecast (Moda do baseline 24-25) |
| Crash do FastAPI | Baixo | Nenhuma mudança no backend |
| Incompatibilidade com mobile | Médio | Touch target >= 44px, responsivo 320px+ |

---

## 8. Dependências

- `framer-motion` (já instalado)
- `lucide-react` (já instalado)
- `tailwindcss` (já instalado)
- Nenhuma dependência nova necessária

---

## 9. Ordem de Implementação

1. **BRNationalIcon.tsx** — Criar componente isolado (testável independentemente)
2. **index.css** — Adicionar keyframes de animação
3. **SupermercadoView.tsx** — Integrar componente no dropdown condicional
4. **BRNationalIcon.test.tsx** — Escrever testes
5. **Teste manual** — Verificar em browser (mobile + desktop)

---

## 10. Notas Técnicas

### Sobre o fallback de 2026
- O banco usa `sp_calcular_forecast_2026()` para projetar meses sem dado real
- Dados reais (scraper) sempre vencem projeções (`ON CONFLICT DO UPDATE` com `is_forecast = FALSE`)
- `baseline_confianca` indica % de meses com dado real no baseline 2024-2025
- Threshold mínimo: confiança >= 25%

### Sobre a animação
- Partículas usam `position: absolute` relativo ao container
- Ícone central usa `framer-motion` para spring scale
- Partículas usam CSS puro para orbit (mais performático que JS)
- Dark mode: cores ajustam via classes Tailwind `dark:`

### Sobre o comportamento do dropdown
- Em modo "Grade Sazonal": dropdown é substituído por ícone BR Nacional
- Clique no ícone força `selectedUF = 'BR'`
- Ao mudar para outro modo (Cards/Mapa): dropdown tradicional retorna
- `selectedUF` permanece 'BR' ao trocar de aba (manter contexto)
