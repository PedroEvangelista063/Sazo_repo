# Avaliação Técnica Senior: Filtro Regional + Mapa Clicável

> **Autor**: Análise baseada em engram + código-fonte
> **Data**: 2026-07-16
> **Contexto**: Avaliação dos planos `PLANO_REGIONAL_MAPA.md` e `PLANO_REGIONAL_DETALHES_TECNICOS.md` à luz do estado real do projeto (cache engram, arquitetura existente, gaps conhecidos)

---

## Resumo Executivo

Os planos são **bem estruturados e seguem a filosofia correta** (aditivo, sem refatoração). Aproveitam a MV existente, não criam tabelas novas, e o split em 4 fases é sensato. O orçamento de 9-14h parece realista para um dev sênior.

No entanto, **3 pontos críticos precisam de correção no plano** antes de implementar — dois deles vão quebrar em produção se não forem tratados.

---

## ✅ O Que Está Certo

### 1. Filosofia aditiva sem refatoração
O plano acerta ao manter o fluxo antigo (UF dropdown) intacto. `regiao` como query param opcional no endpoint `/sazonalidade` é a abordagem correta — não quebra clients existentes.

### 2. Arquitetura stateless regions.json
CEASAs como dados estáticos em JSON com TTL 24h é **a decisão correta**. CEASAs mudam em escala de anos, não dias. Evitar tabela de banco para isso elimina migration, cache warming, e join desnecessário. Um botão admin de refresh manual é overengineering — se precisar editar, faz commit.

### 3. Reuso da MV existente
Usar `vw_api_produtos_sazonalidade` sem novas tabelas é eficiente. O índice `idx_vw_sazonalidade_filtro` em `(uf, municipio, status_cor)` deve cobrir as queries regionais (`WHERE uf IN (...)`). Vale verificar se o planner faz index scan ou seq scan — mas é baixo risco.

### 4. SVG sem lib externa
5KB de SVG puro vs 32KB gzipped de react-simple-maps é **ganho líquido direto**. Especialmente relevante para PWA mobile onde cada KB conta no Lighthouse.

### 5. Split em fases
Fase 1 (config/schemas) isolada antes do frontend é a ordem pedagógica correta. Parallelizar Fase 2 e 3 após Fase 1 é factível sem conflito.

### 6. Hooks separados (useRegioes, useRegiaoResumo)
Cada hook com staleTime diferente (24h para regiões estáticas, 5min para resumo) é o pattern correto com TanStack Query.

---

## ❌ O Que Precisa de Correção

### 🔴 CRÍTICO #1 — SP sem dados em Jan-Jun/2026 distorce Sudeste inteiro

**Problema**: A auditoria R4 do SDD anterior identificou **1.245 combinações sem dado em SP** no período jan-jun/2026 (vs ~0 gaps em 2025). O plano usa `HAVING COUNT(DISTINCT uf) >= 2` para a moda regional do Sudeste — mas se SP não tem dados para um mês, a moda é calculada só com RJ + MG + ES, que são economias muito diferentes de SP.

**Impacto**: Um produto em alta em MG (`VERDE`) mas sem preço em SP (`INSUFICIENTE`) vai aparecer como `VERDE` no Sudeste inteiro — enganando o usuário que olha para CEAGESP como referência.

**Correção necessária**:

```sql
-- Versão corrigida: ponderar por representatividade
-- Exige no mínimo 75% das UFs da região com dados
-- Para Sudeste: 3 de 4 UFs
HAVING COUNT(DISTINCT uf) >= (
    SELECT CASE
        WHEN array_length(ufs, 1) <= 2 THEN 2
        ELSE CEIL(array_length(ufs, 1) * 0.75)::int
    END
)
```

Sugiro adicionalmente:
- No `RegiaoPanel.tsx`, exibir **quebra visual** quando a UF principal da região está com `INSUFICIENTE`
- Exemplo: "SP com dados parciais — resultados podem subestimar a cobertura"
- Alternativa: exibir nota de cobertura no formato "Sudeste: 3/4 UFs com dados"

### 🔴 CRÍTICO #2 — `_passo_contingencia` vai conflitar com filtro regional

**Problema**: O verify do SDD anterior identificou que `_passo_contingencia` no `orchestrator.py` chama `extract()` **uma vez por UF** (8 chamadas), mas cada chamada já coleta todas as 8 UFs. O mesmo payload é salvo 8x com `ON CONFLICT DO UPDATE`.

Se o filtro regional utilizar o endpoint `/sazonalidade?regiao=NORTE`, ele vai filtrar por `uf IN ('PA','AM','AP','RR','RO','AC','TO')`. Mas se alguma dessas UFs foi coletada via PrecosiagrowebEngine (que cobre AC, AM, AP, RO, RR), os dados podem ter **duplicidade de fonte_id** — o SortingEngine vai priorizar CONAB sobre outras fontes, mas o comportamento não é determinístico.

**Correção**: Fixar o `_passo_contingencia` para single dispatch por competência **antes** de implementar o filtro regional. Do contrário, queries regionais para Norte podem pegar dados com peso errado.

### 🟡 MÉDIO #3 — Ocultar ano quebra o contexto do BR Nacional

**Problema**: O plano diz "ocultar ano no modo regional" e usar "sempre o ano mais recente". Mas a MV `vw_api_produtos_sazonalidade` tem dados de 2024, 2025 e 2026. O ano mais recente (2026) tem **1.245 gaps em SP** — se o sistema escolher 2026 automaticamente, o mapa regional do Sudeste vai mostrar muito menos dados que se o usuário selecionar 2025 manualmente.

**Correção**:

1. **Não ocultar o ano completamente**. Em vez disso, ter um **ano padrão** (o mais recente com > 80% de cobertura)
2. Exibir um **indicador sutil** no canto do painel: "Dados de 2026 · 78% de cobertura"
3. Se cobertura < 80%, sugerir trocar para o ano anterior via tooltip ou CTA leve

O plano acerta em simplificar a UI, mas esconde um problema de qualidade de dado que o usuário precisa saber para tomar decisão de compra.

---

## ⚠️ Riscos Que o Plano Subestima

### Risco 1 — Consultas regionais no mobile sem paginação

O endpoint `/regioes/{id}/produtos` pode retornar centenas de produtos para o Sudeste (4 UFs × ~30 produtos = ~120 linhas). No mobile, renderizar 120 cards + moda regional pode causar layout shift.

**Sugestão**: Usar `@tanstack/react-query` com `keepPreviousData` + paginação incremental. A Mantine já tem `Pagination` component. Se o volume esperado for < 200 produtos, paginação server-side com 50 por página é suficiente.

### Risco 2 — Navegação Região → Polo quebra o fluxo de cache

O usuário faz: `Mapa → SUDESTE → CEAGESP → Grade sazonal`. Nesse ponto, o `SupermercadoView` precisa trocar de "modo regional" para "modo UF" (`setSelectedUF('SP')`, `setViewMode('cards')`). Se a grade sazonal está em `useHortifruti('SP', ...)`, e o usuário volta para o mapa, o query cache do TanStack Query pode servir stale data.

**Sugestão**: No hook `useHortifruti`, quando `regiao` é passado, usar `queryKey: ['sazonalidade', { regiao, mes, categoria }]` — **não** reaproveitar a mesma queryKey do filtro UF. Assim os caches não colidem.

### Risco 3 — Fallback regional sem dados

O plano menciona `HAVING COUNT(DISTINCT uf) >= 2` mas não define o que acontece visualmente quando uma região inteira (ex: Norte) tem dados insuficientes para um mês. A grade regional vai mostrar "sem dados" silenciosamente — o usuário não sabe se é bug ou falta de cobertura.

**Sugestão**: No `RegiaoPanel`, adicionar um **mini semáforo de cobertura**: "Norte: 3/7 UFs com dados em Junho". Se cobertura < 50%, exibir warning visual.

### Risco 4 — SVG paths simplificados sem teste visual

O plano usa paths SVG simplificados (não geográficos). Em viewports extremos (320px mobile, 4K desktop), os polígonos podem distorcer ou ficar desproporcionais. O `viewBox="0 0 600 450"` é fixo — testar em 3 breakpoints é obrigatório.

**Sugestão**: Adicionar teste visual com Playwright para o `BrasilMap` em 320px, 768px e 1440px.

---

## ✅ Matriz de Confiança

### Alta confiança — "Pode ir"

| Item | Confiança | Razão |
|------|-----------|-------|
| SVG esquemático com 5 polígonos | **Alta** | 5KB, Framer Motion já no bundle, viewBox garante responsivo |
| `regions.json` como fonte de verdade estática | **Alta** | Zero dependência externa, TTL 24h, sem cache invalidation |
| Endpoint `/regioes` lendo JSON | **Alta** | Mesmo padrão usado no `config.py` — FastAPI lê JSON estático |
| `WHERE uf IN (...)` indexado | **Alta** | Índice composto já existe em `(uf, municipio, status_cor)` |
| Aditivo sem quebra de fluxo antigo | **Alta** | `regiao` como query param opcional, viewMode novo isolado |
| Mantine Card + Badge para polos | **Alta** | Já são dependências, padrão consistente com o resto do app |
| Cache de regions.json com staleTime 24h | **Alta** | Mesmo padrão de staleTime longo para dados estáticos já usado no frontend |

### Confiança média — "Precisa de validação"

| Item | Confiança | Risco |
|------|-----------|-------|
| Cache separado entre modo regional e UF | **Média** | Se queryKey colidir entre `useHortifruti(uf)` e `useHortifruti(regiao)`, dados podem misturar |
| Performance mobile com grade regional | **Média** | Paginação server-side resolve, mas sem virtual scroll pode travar em 120+ cards |
| SVG paths em viewport extremo | **Média** | Testar em 320px, 768px, 1440px antes de considerar resolvido |

### Confiança baixa — "Corrigir antes"

| Item | Confiança | Risco |
|------|-----------|-------|
| Ocultar ano sem feedback de cobertura | **Baixa** | Usuário não sabe que está vendo 2026 com 78% de cobertura — decisão errada de compra |
| Fallback silencioso sem dados | **Baixa** | Regiões com cobertura parcial precisam de indicador visual obrigatório |
| Moda regional com dados parciais de SP | **Baixa** | Sudeste inteiro pode ficar com sinal distorcido por 6 meses |
| `_passo_contingencia` sem fix | **Baixa** | Risco de duplicidade de fonte_id em queries regionais do Norte |

---

## Orçamento Revisado

| Fase | Horas (original) | Horas (revisado) | Diferença | Razão |
|------|:-:|:-:|:-:|-------|
| Fase 0: Fix `_passo_contingencia` | — | 1-2h | +2h | **Pré-requisito** — sem isso, queries regionais do Norte podem ter dados duplicados |
| Fase 1: regions.json + schemas + GET /regioes | 1-2h | 1-2h | = | Sem mudanças |
| Fase 2: Endpoints regionais | 2-3h | 3-4h | +1h | Adicionar validação de cobertura mínima (75% das UFs) |
| Fase 3: Frontend mapa + painel | 4-6h | 4-6h | = | Sem mudanças |
| Fase 4: Integração + cache | 2-3h | 2-3h | = | Sem mudanças, mas atenção ao Risco 2 (cache colision) |
| **Total** | **9-14h** | **11-17h** | **+2-3h** | |

---

## Conclusão

**Implementar o plano com 3 correções obrigatórias:**

1. **🔴 Pré-requisito**: Fixar `_passo_contingencia` (single dispatch por competência) antes de tocar em qualquer endpoint regional
2. **🔴 Query regional**: Adicionar validação de cobertura mínima na moda — >= 75% das UFs ou marca como `INSUFICIENTE`
3. **🟡 UX**: Não ocultar o ano — mostrar com indicador de cobertura ("2026 · 78% cobertura") no canto do painel

### Ordem de implementação recomendada (SDD)

```
Fase 0: Fix _passo_contingencia (1-2h)           ← PRÉ-REQUISITO
Fase 1: regions.json + schemas + GET /regioes (1-2h)
Fase 2: Endpoints regionais com validation (3-4h)
Fase 3: BrasilMap + RegiaoPanel + hooks (4-6h)
Fase 4: Integração SupermercadoView (2-3h)
       └── Cache separation: queryKey regional ≠ queryKey UF
       └── Cobertura indicator no header do painel
```

### Decisões pendentes que o plano acertadamente levantou

Do `PLANO_REGIONAL_DETALHES_TECNICOS.md` seção 7, as 5 perguntas ao usuário são pertinentes. Recomendo respondê-las **antes** de iniciar a Fase 3 (frontend):

1. **Mapa real vs esquemático** → Esquemático (5KB, sem lib externa) ✅ plano já decidiu certo
2. **Ano oculto?** → Não ocultar, mostrar com indicador de cobertura (correção #3 acima)
3. **Click no mapa → direto para grade?** → Via painel de polos (plano acerta — dá contexto ao usuário)
4. **Fallback regional sem dados?** → Marcar como `INSUFICIENTE` com tooltip explicativo
5. **CEASAs sem dados (RN, MS)?** → Omitir do mapa, mas listar em "Outras CEASAs da região" com status "sem dados"
