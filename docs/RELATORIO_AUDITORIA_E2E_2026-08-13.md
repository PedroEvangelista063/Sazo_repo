# 🔍 Relatório de Auditoria E2E — Confiabilidade e Qualidade

> **Data:** 13/08/2026
> **Objeto:** Pipeline completo — DB (PostgreSQL) → Materialized View → Backend (FastAPI) → Frontend (React 19)
> **Escopo:** Confiabilidade dos dados, sincronismo entre camadas e resiliência da UI (crash tolerance)

---

## Resumo Executivo

A auditoria end-to-end confirma que a arquitetura de dados do projeto é **sólida**: o contrato entre a Materialized View (`mart.vw_api_produtos_sazonalidade`, **V22**), o backend FastAPI e o frontend React está íntegro, com os campos de projeção (`is_forecast`, `forecast_method`, `confianca_baseline`) expostos corretamente na API e consumidos sem quebra de contrato.

Foram identificados **1 achado de arquitetura (A1)** — classificado como comportamento esperado do domínio de negócio, não como defeito — e **4 ações de resiliência de severidade média no Frontend (M1–M4)**, todas executadas nesta consolidação. O frontend passa a ter **Crash Tolerance (Zero Tela Branca)**.

---

## FASE 1 — Integridade Banco de Dados

### 1.1 Migrations de Fallback Histórico

| Migration | MV      | Status                       | Descrição                                                                               |
| --------- | ------- | ---------------------------- | --------------------------------------------------------------------------------------- |
| **78**    | **V22** | ✅ Aplicada (local + remoto) | **Deep Fallback Histórico** — cascata de 3 níveis para `status_cor` em meses sem dados  |
| 80        | V23     | ⚠️ Commitada, não aplicada   | Piso deslizante `ano >= Ano Atual − 3` no LATERAL `hh` do V22 (evita âncoras 2021/2022) |

### 1.2 Achado A1 — Defasagem de dados (53%)

| Atributo          | Valor                                                                                      |
| ----------------- | ------------------------------------------------------------------------------------------ |
| **Achado**        | **A1** — defasagem de cobertura de ~53% dos pontos de dados                                |
| **Causa raiz**    | Latência de publicação das CEASAs regionais (fontes públicas publicam com atraso de meses) |
| **Classificação** | ✅ **Comportamento esperado do domínio de negócio** — não é defeito de arquitetura         |
| **Tratamento**    | **Deep Fallback Histórico** (Migration 78 / V22)                                           |

**Análise:** a defasagem de 53% reflete a natureza do domínio: as CEASAs regionais divulgam seus preços com atraso natural, fazendo com que uma parcela expressiva do período corrente dependa de dados históricos de referência. O projeto lida com isso de forma estruturada — **não** com preenchimento arbitrário de meses futuros (Quality Gate da Fase 76 e regra de âncora `Ano Atual − 1`), mas com a cascata de fallback da Migration 78:

1. **1º nível** — `LEFT JOIN LATERAL hh`: status real mais recente do mesmo `(id_produto, id_localidade, mes)` em anos anteriores (`REAL_ATUAL` / `HISTORICO_BASE`);
2. **2º nível** — `b.status_cor_mode` de `mart.sazonalidade_baseline`;
3. **3º nível** — fallback final `'VERDE'` (nunca estado vazio).

A proveniência é preservada: `tipo_dado` continua `REAL_ATUAL` / `HISTORICO_BASE` / `FALLBACK_DIMENSAO`, e os metadados (`metadado_transparencia`, `mensagem_transparencia`, `ano_referencia`) informam ao usuário quando o valor é projeção histórica.

**Conclusão executiva:** a defasagem de 53% (A1) é um comportamento esperado do domínio de negócio (latência das CEASAs regionais) e está devidamente tratada pelo _Deep Fallback Histórico_ (Migration 78). Nenhuma ação corretiva de arquitetura é necessária; a transparência sobre a origem dos dados é garantida pelos metadados expostos na API e exibidos na UI.

---

## FASE 2 — Backend (FastAPI) vs Materialized View

### 2.1 Contrato de API — Verificado

| Campo                    | Contrato                                | Status                                                                          |
| ------------------------ | --------------------------------------- | ------------------------------------------------------------------------------- |
| `status_cor`             | `Literal["VERDE","AMARELO","VERMELHO"]` | ✅ Íntegro (CINZA tratado no frontend como fallback)                            |
| `is_forecast`            | `bool = False`                          | ✅ Íntegro                                                                      |
| `forecast_method`        | `str \| None`                           | ✅ Exposto (`SANDUICHE_MEDIA_24_25`, `beta_weighted_25_24`, `null` = dado real) |
| `confianca_baseline`     | `float \| None`                         | ✅ Íntegro                                                                      |
| `mensagem_transparencia` | `str \| None`                           | ✅ Íntegro (proveniência do fallback)                                           |

### 2.2 Sincronismo de Migrations

- ✅ 01–78 aplicadas e validadas em local + remoto (Aiven)
- ⚠️ **Pendência:** Migration 80 (V23) commitada mas **não aplicada** — piso de âncora `Ano Atual − 3` no LATERAL `hh` do V22
- ⚠️ Cache do backend não é limpo automaticamente após MV refresh (mitigação manual: `POST /admin/cache/clear`)

---

## FASE 3 — Frontend: Achados de Resiliência (Severidade Média)

| ID     | Severidade | Achado                                                                                                | Arquivo(s)                           | Ação                                                           |
| ------ | ---------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------ | -------------------------------------------------------------- |
| **M1** | 🟡 Média   | **Sem Error Boundary** — um erro de render não capturado derruba a árvore React inteira (tela branca) | `main.tsx`                           | Criar `<ErrorBoundary>` com UI claymorphism + botão recarregar |
| **M2** | 🟡 Média   | **Crash latente com `status_cor` nulo** — `status.toLowerCase()` e `STATUS_CONFIG[status]` sem guard  | `TabelaView.tsx`, `LivingStatus.tsx` | Null safety com `?.` / `??`                                    |
| **M3** | 🟡 Média   | **`onToggle` inline derrota memoização** do `ProductCard` (novo closure por render)                   | `SupermercadoView.tsx`               | `useCallback` no `handleToggle`                                |
| **M4** | 🟡 Média   | **TanStack Query sem política global explícita** de retry/stale/focus                                 | `main.tsx`                           | `retry: 2`, `staleTime: 300000`, `refetchOnWindowFocus: false` |

### 3.1 Detalhamento dos Achados

**M1 — Ausência de Error Boundary**

- Grep por `ErrorBoundary|componentDidCatch|getDerivedFromStateError` no repositório: **zero resultados**.
- Um erro de render não capturado (ex.: campo nulo em uma célula) derruba a árvore inteira → tela branca.
- **Ação:** criar `frontend/src/components/ErrorBoundary.tsx` (class component com `componentDidCatch` / `getDerivedStateFromError`), UI elegante em claymorphism com a mensagem _"Ops! Ocorreu um erro ao carregar os dados. Tente novamente."_ e botão para recarregar a página; envolver o app inteiro no `main.tsx`.

**M2 — Crash latente com `status_cor` nulo**

- `TabelaView.tsx:153` — `status.toLowerCase()` lança `TypeError` se `status_cor` vier `null`/`undefined` (cenário CINZA documentado: meses sem dados chegam com campos nulos).
- `LivingStatus.tsx:57` — `STATUS_CONFIG[status]` sem fallback: `cfg` fica `undefined` → crash em `cfg.bg` (componente atualmente órfão, mas é crash latente).
- **Ação:** aplicar Nullish Coalescing (`??`) e Optional Chaining (`?.`) nos dois pontos, garantindo que `status_cor` nunca quebre; fallback seguro para estado neutro (CINZA).

**M3 — `onToggle` inline derrota memoização**

- `ProductCard` é `memo`izado (`ProductCard.tsx:158`), mas `SupermercadoView.tsx:521–527` passa `onToggle` como arrow function inline criada a cada render → novo closure por card a cada render → `React.memo` nunca previne re-render.
- **Ação:** extrair `handleToggle` com `useCallback` (dependência estável), passando a referência memoizada para os `ProductCard`.

**M4 — TanStack Query sem política global explícita**

- `main.tsx` configura `QueryClient` com `staleTime: 5min`, `retry: 2`, mas `refetchOnWindowFocus: true` (default) não é ideal para mobile-first/offline-first.
- **Ação:** injetar explicitamente `retry: 2`, `staleTime: 300000`, `refetchOnWindowFocus: false`.

---

## ✅ Resumo Final

| Requisito                                        | Status                                                                                            |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| Arquitetura de dados sólida (DB → MV → API → UI) | ✅ Confirmado                                                                                     |
| A1 — Defasagem 53%                               | ✅ Comportamento esperado (latência CEASAs) — tratado pelo Deep Fallback Histórico (Migration 78) |
| M1 — Error Boundary                              | ✅ Implementado (Crash Tolerance)                                                                 |
| M2 — Null safety `status_cor`                    | ✅ Implementado (`?.` / `??`)                                                                     |
| M3 — `useCallback` no `handleToggle`             | ✅ Implementado                                                                                   |
| M4 — QueryClient com política global             | ✅ Implementado (`retry: 2`, `staleTime: 300000`, `refetchOnWindowFocus: false`)                  |
| Frontend Crash Tolerance (Zero Tela Branca)      | ✅ **Confirmado**                                                                                 |

---

### Referência de arquivos

| Arquivo                                     | Papel                                                        |
| ------------------------------------------- | ------------------------------------------------------------ |
| `database/78_deep_fallback_historico.sql`   | Migration 78 (V22) — cascata de fallback histórico           |
| `database/80_mv_fallback_janela_2023.sql`   | Migration 80 (V23) — piso deslizante (pendente de aplicação) |
| `frontend/src/main.tsx`                     | Renderização do app + configuração do QueryClient            |
| `frontend/src/components/ErrorBoundary.tsx` | **Novo** — boundary de erro global                           |
| `frontend/src/components/TabelaView.tsx`    | Null safety em `status_cor`                                  |
| `frontend/src/components/LivingStatus.tsx`  | Null safety em `STATUS_CONFIG[status]`                       |
| `frontend/src/pages/SupermercadoView.tsx`   | `handleToggle` memoizado com `useCallback`                   |
| `frontend/src/components/ProductCard.tsx`   | Card memoizado (beneficiado pelo M3)                         |
