# Relatório de Auditoria DBA & QA — Integridade, Paridade e Compatibilidade E2E

**Data:** 2026-08-18
**Escopo:** PostgreSQL Local (primário) × Aiven (remoto) → FastAPI → Frontend React
**Objeto auditado:** `mart.vw_api_produtos_sazonalidade` (MV V23) e views de suporte (`vw_ancora_preco_referencia`, `vw_anchor_sazonalidade`, `vw_categorias`, `vw_municipios`, `vw_mapa_regional_completo`, `vw_abastecimento_regional_completo`, `staging.vw_abastecimento_logistico`), endpoints `/sazonalidade*`, `/categorias`, `/municipios`, `/ufs`, `/fluxos` e superfícies de status no frontend.

---

## 1. Resumo Executivo

### Nível de Risco: **ALTO** 🔴

| Dimensão                               | Status                   | Comentário                                                                                                           |
| -------------------------------------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| Paridade de Schema (Local × Aiven)     | ✅ **PARIDADE PERFEITA** | MV e todas as views com MD5 byte-idêntico; PG 18.6 local × PG 18.4 Aiven                                             |
| Paridade de Dados (Local × Aiven)      | ✅ **PARIDADE PERFEITA** | Contagens idênticas em todas as tabelas/views (177.485 linhas MV)                                                    |
| Quality Gate de Transparência (âncora) | ❌ **VIOLAÇÃO**          | Projeções de meses futuros 2026 (ago–dez) usam âncora **2023** (Ano Atual − 3); regra exige **Ano Atual − 1 (2025)** |
| Contrato "Sem dados ⇒ CINZA"           | ❌ **VIOLAÇÃO**          | MV emite 0 linhas CINZA; 18.487 linhas `FALLBACK_DIMENSAO` (sem dado real) são servidas como **VERDE/AMARELO**       |
| Camada API (Pydantic v2)               | ⚠️ **RISCO**             | `status_cor` é `Literal["VERDE","AMARELO","VERMELHO"]` — CINZA não é aceito; se a MV emitisse CINZA → HTTP 500       |
| Frontend (cores/status)                | ❌ **VIOLAÇÃO**          | `ProductCard` mapeia status nulo/desconhecido para **AMARELO** deliberadamente; `StatusCor` não contém CINZA         |

### Resumo da Incompatibilidade

1. **Não há divergência Local vs Remoto**: as duas bases estão perfeitamente sincronizadas (mesmas migrations 77/80/81 aplicadas, mesmas definições, mesmos dados). O risco de "drift" entre ambientes é **zero** hoje.
2. **A infidelidade está no contrato de dados em si**: a decisão de negócio da migration 80 (`80_mv_fallback_janela_2023.sql`) fixa o piso da âncora de projeção em `Ano Atual − 3` (2023), **acima** do limite rígido do `AGENTS.md` (`Ano Atual − 1`). Isso repõe o padrão exatamente proibido: _"repetir 2023 para 2025/2026"_.
3. **A camada de exibição é cega ao cinza**: o backend não aceita CINZA (Pydantic) e o frontend não conhece CINZA (tipo `StatusCor`); a única superfície que renderiza cinza corretamente é `SazonalidadeNacional` (por ausência de célula, não por valor).

---

## 2. Divergências de Dados e Fallback Indevido

### 2.1 Paridade Local × Remoto — VERIFICADO ✅

**Definições (MD5 de `pg_get_viewdef`):**

| Objeto                                    | MD5 Local                          | MD5 Aiven | Paridade                        |
| ----------------------------------------- | ---------------------------------- | --------- | ------------------------------- |
| `mart.vw_api_produtos_sazonalidade`       | idêntico                           | idêntico  | ✅ byte-idêntico (13.912 bytes) |
| `mart.vw_categorias`                      | `a4bc86b60311968ca0b7fe7c724fbb99` | idêntico  | ✅                              |
| `mart.vw_municipios`                      | `600860bd3060bfb5907007526f1238a5` | idêntico  | ✅                              |
| `mart.vw_mapa_regional_completo`          | `6bcddd213c854c2bd0d0d3d146936c36` | idêntico  | ✅                              |
| `mart.vw_abastecimento_regional_completo` | `803a0711863bdab5a926304f712ab0bd` | idêntico  | ✅                              |
| `mart.vw_anchor_sazonalidade`             | `8e2e9cdc02e1a0738c0e9a3aa3a404a1` | idêntico  | ✅                              |
| `mart.vw_ancora_preco_referencia`         | `2d554c8e5931a1df56d60669c78f7e10` | idêntico  | ✅                              |
| `staging.vw_abastecimento_logistico`      | `8e500488e554959d7a8c75c2acbe818f` | idêntico  | ✅                              |

**Contagens (Local = Aiven):**

| Tabela/View                                                             | Linhas  |
| ----------------------------------------------------------------------- | ------- |
| `staging.fact_precos_mensais`                                           | 245.362 |
| `mart.sazonalidade_produto`                                             | 346.961 |
| `staging.dim_produto`                                                   | 863     |
| `staging.dim_localidade`                                                | 623     |
| `mart.sazonalidade_baseline`                                            | 20.088  |
| `mart.vw_api_produtos_sazonalidade`                                     | 177.485 |
| `mart.vw_anchor_sazonalidade` / `vw_ancora_preco_referencia`            | 95.374  |
| `mart.vw_categorias`                                                    | 11      |
| `mart.vw_municipios`                                                    | 595     |
| `mart.vw_mapa_regional_completo` / `vw_abastecimento_regional_completo` | 5.589   |

**Distribuição de status/tipo na MV (Local = Aiven):**

| Dimensão          | Valor                 | Linhas     |
| ----------------- | --------------------- | ---------- |
| status_cor        | VERDE                 | 39.413     |
| status_cor        | AMARELO               | 109.172    |
| status_cor        | VERMELHO              | 28.900     |
| status_cor        | **CINZA**             | **0**      |
| tipo_dado         | REAL_ATUAL            | 52.673     |
| tipo_dado         | HISTORICO_BASE        | 106.325    |
| tipo_dado         | **FALLBACK_DIMENSAO** | **18.487** |
| ano_referencia    | **NULL**              | 18.062     |
| is_forecast       | true                  | 0          |
| usou_fallback_12m | true                  | 2.355      |

> **Conclusão de paridade**: as duas bases são clones funcionais. Nenhuma divergência de schema, tipo, fuso ou ordenação foi encontrada. `timestamp`/`timestamptz` não afetam a ordenação da MV (o sort é por `ano, mes, is_forecast, status_cor, produto`).

### 2.2 Fallback Indevido — VIOLAÇÃO CONFIRMADA ❌

**Distribuição de `ano_referencia` nas linhas `FALLBACK_DIMENSAO` de 2026 (Local = Aiven):**

| Mês 2026 | min_ancora | max_ancora | Linhas    | Diagnóstico                                 |
| -------- | ---------- | ---------- | --------- | ------------------------------------------- |
| jan      | NULL       | NULL       | 1.205     | Baseline de dimensão (sem âncora histórica) |
| fev      | NULL       | NULL       | 1.194     | Baseline de dimensão                        |
| mar      | NULL       | NULL       | 1.177     | Baseline de dimensão                        |
| abr      | NULL       | NULL       | 1.185     | Baseline de dimensão                        |
| mai      | NULL       | NULL       | 1.188     | Baseline de dimensão                        |
| jun      | NULL       | NULL       | 722       | Baseline — queda de volume (~40%)           |
| jul      | NULL       | NULL       | 769       | Baseline — queda de volume                  |
| **ago**  | **2023**   | **2023**   | **1.992** | ⚠️ Deep Fallback com âncora 2023            |
| **set**  | **2023**   | **2023**   | **2.232** | ⚠️ Deep Fallback com âncora 2023            |
| **out**  | **2023**   | **2023**   | **2.260** | ⚠️ Deep Fallback com âncora 2023            |
| **nov**  | **2023**   | **2023**   | **2.253** | ⚠️ Deep Fallback com âncora 2023            |
| **dez**  | **2023**   | **2023**   | **2.310** | ⚠️ Deep Fallback com âncora 2023            |

- **11.047 linhas** (ago–dez/2026) carregam `ano_referencia = 2023` — **defasagem de 3 anos**, acima do limite `Ano Atual − 1 = 2025` do `AGENTS.md`.
- **7.440 linhas** (jan–jul/2026) têm `ano_referencia = NULL` — são "baseline de dimensão" sem qualquer âncora real.
- **Total: 18.487 linhas de FALLBACK_DIMENSAO** — todas exibidas com cores de dado real (ver §3).

**Causa raiz (código):**

- Migration `80_mv_fallback_janela_2023.sql:366-383` — piso no `LEFT JOIN LATERAL hh`:
  ```sql
  AND h.ano >= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 3   -- hoje 2023
  ```
- Cascata de status em `80:119-125`:
  ```sql
  CASE WHEN v.tipo_dado = 'FALLBACK_DIMENSAO'
            AND v.ano = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
            AND v.mes >= EXTRACT(MONTH FROM CURRENT_DATE)::INTEGER
            AND v.ano_referencia IS NULL
       THEN COALESCE(hh.hist_status_cor, b.status_cor_mode, 'VERDE')  -- ❌ default VERDE
       ELSE v.status_cor
  END AS status_cor
  ```
- O default `'VERDE'` na cascata é a **mais grave violação de transparência**: quando não há histórico real nem baseline, o status vira **VERDE** (dado "bom") em vez de CINZA (sem dado).

**Observação adicional — volume jun/jul/2026:** a queda de ~40% nas linhas FALLBACK_DIMENSAO (722/769 vs ~1.200) indica que parte dos produtos deixa de ser projetada nesses meses — comportamento não documentado, merece investigação.

---

## 3. Gaps de Exibição Visual (Verde/Amarelo vs Cinza/Vermelho)

### 3.1 Matriz de cores — contrato vs implementação

| Status       | Contrato (AGENTS.md)                     | Implementação real                                                        | Conforme?                                           |
| ------------ | ---------------------------------------- | ------------------------------------------------------------------------- | --------------------------------------------------- |
| **Verde**    | Dado real, atualizado, dentro da margem  | Dado real **ou projeção sem base** (default `'VERDE'` na cascata)         | ❌ **Mascarado** — 10.593 linhas FALLBACK são VERDE |
| **Amarelo**  | Dado real com desvio/alerta metodológico | Dado real ou projeção com histórico amarelo                               | ⚠️ Parcial — 7.894 linhas FALLBACK são AMARELO      |
| **Vermelho** | Dado real confirmando queda/anomalia     | Somente dado real (28.900 linhas)                                         | ✅                                                  |
| **Cinza**    | Ausência de dado real / fora da âncora   | **Nunca emitido** (0 linhas na MV; não existe no backend nem no frontend) | ❌ **Contrato quebrado**                            |

### 3.2 Falhas ponto a ponto

**Banco (MV V23):**

1. ❌ A MV emite **0** `status_cor = 'CINZA'` e **0** `status_cor = NULL` — o `WHERE f.status_cor IN ('VERDE','AMARELO','VERMELHO')` (`80:349`) filtra o cinza estrutural. A exclusão de linha é o mecanismo de cinza "por ausência", mas **não cobre os meses projetados** (ago–dez) que são _preenchidos_ com fallback em vez de ficarem ausentes.
2. ❌ O default `'VERDE'` da cascata Deep Fallback transforma "sem histórico real + sem baseline" em **dado bom** — exatamente o "falso positivo" que o Quality Gate proíbe.

**API (FastAPI + Pydantic v2):** 3. ❌ `SazonalidadeResponse.status_cor: Literal["VERDE","AMARELO","VERMELHO"]` (`responses.py:71`) — se a MV emitisse `CINZA`, a resposta viraria **HTTP 500** (Pydantic ValidationError). O contrato de CINZA não pode ser cumprido sem alterar o schema. 4. ✅ Campos de transparência (`ano_referencia`, `tipo_dado`, `mensagem_transparencia`) são `int|None`/`str|None` — nulls fluem sem erro. **Este lado está correto.** 5. ⚠️ `mensagem_transparencia` é composta em Python (`_compor_mensagem_transparencia`, `produtos.py:37-83`): para `FALLBACK_DIMENSAO` prefere o metadado do DB, senão deriva de `ano_referencia`, senão "baseline de dimensao". Como a MV já injeta `PROJECAO_HISTORICA`/`DEEP_FALLBACK` no metadado, a mensagem chega — mas **disfarçada de projeção legítima** quando a âncora é 2023. 6. ⚠️ Cache: TTL 1h (sazonalidade) / 24h (histórico mensal); chaves embutem o `mtime` da MV (auto-invalidação correta). Sem Redis → cache in-memory (per-processo). Risco baixo de dado obsoleto, mas com múltiplos workers o cache não é compartilhado — comportamento não determinístico entre instâncias.

**Frontend (React):** 7. ❌ **`ProductCard.tsx:102`** — decisão de cor:

```tsx
const badge = STATUS_BADGES[product.status_cor] ?? STATUS_BADGES.AMARELO;
```

Nulo/desconhecido → **AMARELO** ("Estável — Preço Normal"). Comentário 49-55 declara: _"NUNCA há estado vazio nem cor cinza"_. **Violação deliberada, codificada no teste** `ProductCard.test.tsx:52-63`. 8. ❌ **`frontend/src/types/domain.ts:1`** — `StatusCor = 'VERDE' | 'AMARELO' | 'VERMELHO'` — CINZA não existe no tipo. 9. ❌ **`SupermercadoView.tsx`** — chips/contadores só 3 cores (80-96, 189-202, 376-395); itens sem cor são **silenciosamente descartados** do filtro/contagem. 10. ❌ **`RegiaoPanel.tsx`** — `STATUS_CONFIG` sem Cinza (32-42); contadores filtram `p.status_cor === status` e ignoram o resto (102-119). 11. ✅ **`SazonalidadeNacional.tsx:94-130`** — única superfície correta: `!mesData` → célula muted/cinza; `STATUS_STYLES[status_cor] ?? fallback cinza 'Sem Cotação'`. 12. ⚠️ Código morto com lógica _certa_ mas não usada: `GameCard.tsx` (fallback cinza "Dados Insuficientes"), `TabelaView.tsx:38-42` (único registro CINZA do codebase + `null→CINZA`).

### 3.3 Exemplo concreto de dado infiel

```
Produto X, mês out/2026, sem qualquer dado real em 2026:
  tipo_dado              = 'FALLBACK_DIMENSAO'
  ano_referencia         = 2023          (defasagem 3 anos, viola âncora Ano Atual−1)
  mensagem_transparencia = 'Projecao sazonal baseada no historico de 2023'
  status_cor             = 'VERDE' | 'AMARELO'  (nunca CINZA)

→ Usuário vê: 🟢 "Época Boa — Barato" (ou 🟡 "Estável")
→ Realidade: NENHUM dado real em 2025/2026; projeção baseada em 2023.
```

---

## 4. Plano de Ação e Correção

### 4.1 Correção SQL — View `mart.vw_api_produtos_sazonalidade` (nova migration 83)

A MV é recriada por migração. Correção em **dois pontos**:

```sql
-- ============================================================================
-- 83_correcao_ancora_e_cinza_quality_gate.sql  (DDL-only, CREATE WITH DATA)
-- Aplica o Quality Gate do AGENTS.md:
--   1) âncora de projeção rígida: Ano Atual - 1 (nunca -3)
--   2) ausência de dado real recente => status_cor 'CINZA' (nunca default VERDE)
-- ============================================================================

-- PONTO 1: piso da âncora no LEFT JOIN LATERAL hh (era -3; agora -1)
-- ANTES:  AND h.ano >= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 3
-- DEPOIS:
--   AND h.ano >= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 1

-- PONTO 2: cascata de status projetado (default VERDE => CINZA)
-- ANTES:  THEN COALESCE(hh.hist_status_cor, b.status_cor_mode, 'VERDE')
-- DEPOIS:
CASE WHEN v.tipo_dado = 'FALLBACK_DIMENSAO'
          AND v.ano = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
          AND v.mes >= EXTRACT(MONTH FROM CURRENT_DATE)::INTEGER
          AND v.ano_referencia IS NULL
     THEN COALESCE(hh.hist_status_cor, b.status_cor_mode, 'CINZA')
     ELSE v.status_cor
END AS status_cor
```

**Consequência esperada:** as ~11.047 linhas ago–dez/2026 com âncora 2023 passam a ter `ano_referencia = NULL` (sem âncora válida) e as linhas sem baseline passam a `status_cor = 'CINZA'` — o que exige as correções coordenadas abaixo para não gerar 500.

> ⚠️ **Aplicação coordenada obrigatória**: alterar a MV para emitir CINZA **sem** corrigir Pydantic + Frontend causa HTTP 500 na API. Sequência: (1) schema Pydantic → (2) frontend → (3) migration 83.

### 4.2 Correção Backend — Pydantic v2 (`backend/app/schemas/responses.py`)

Adicionar `CINZA` ao Literal nos 3 pontos:

```python
# linha 71 (SazonalidadeResponse)
status_cor: Literal["VERDE", "AMARELO", "VERMELHO", "CINZA"]  # required

# linha 172 (SazonalidadeComPrecoResponse)
status_cor: Literal["VERDE", "AMARELO", "VERMELHO", "CINZA"]

# linha 239 (MesSazonalidade)
status_cor: Literal["VERDE", "AMARELO", "VERMELHO", "CINZA"]
```

Opcional (defensivo): em `produtos.py`, mapear `status_cor` de `FALLBACK_DIMENSAO` com `ano_referencia IS NULL` e `mensagem_transparencia` indicando projeção → manter `CINZA` verbatim (já é o comportamento; apenas garantir testes).

### 4.3 Correção Frontend

1. **`types/domain.ts:1`**:
   ```ts
   export type StatusCor = "VERDE" | "AMARELO" | "VERMELHO" | "CINZA";
   ```
2. **`ProductCard.tsx:102`** — remover o fallback AMARELO e mapear CINZA:
   ```tsx
   const badge = STATUS_BADGES[product.status_cor] ?? STATUS_BADGES.CINZA;
   // STATUS_BADGES.CINZA = { label: '⚪ Sem Dados Recentes', badgeClass: 'bg-status-gray ...', ... }
   ```
   Atualizar o teste `ProductCard.test.tsx:52-63` (desconhecido → CINZA, não AMARELO).
3. **`SupermercadoView.tsx`** — incluir `CINZA` em `STATUS_CHIPS`, contadores e iteração de chips.
4. **`RegiaoPanel.tsx`** — incluir `CINZA` em `STATUS_CONFIG` e contadores.
5. **`SazonalidadeNacional.tsx`** — manter; já trata cinza por fallback (`??`).
6. **Null Safety**: manter `?.`/`??` em todo o path; adicionar `??` em `RegiaoPanel.tsx:174` (`flow.cor_indicadora`).

### 4.4 SQL de Validação de Paridade (rodar nos DOIS bancos)

```sql
-- P1: Paridade de definição da MV (md5 deve ser idêntico nos 2 bancos)
SELECT md5(pg_get_viewdef('mart.vw_api_produtos_sazonalidade'::regclass, true)) AS mv_md5;

-- P2: Paridade de contagem geral
SELECT count(*) AS total,
       count(*) FILTER (WHERE status_cor='VERDE')   AS verde,
       count(*) FILTER (WHERE status_cor='AMARELO') AS amarelo,
       count(*) FILTER (WHERE status_cor='VERMELHO') AS vermelho,
       count(*) FILTER (WHERE status_cor='CINZA')   AS cinza,
       count(*) FILTER (WHERE tipo_dado='FALLBACK_DIMENSAO') AS fallback,
       count(*) FILTER (WHERE ano_referencia IS NULL) AS ano_ref_null
FROM mart.vw_api_produtos_sazonalidade;

-- P3: Detecta violação de âncora (deve retornar 0 após correção)
--     Defasagem > Ano Atual - 1 = âncora inválida
SELECT count(*) AS violacoes_ancora
FROM mart.vw_api_produtos_sazonalidade
WHERE tipo_dado = 'FALLBACK_DIMENSAO'
  AND ano = EXTRACT(YEAR FROM CURRENT_DATE)::integer
  AND COALESCE(ano_referencia, 0) < EXTRACT(YEAR FROM CURRENT_DATE)::integer - 1;

-- P4: Detecta default VERDE indevido (projeção sem histórico e sem baseline)
--     Deve retornar 0 após correção (vira CINZA)
SELECT count(*) AS projecao_sem_base_verde
FROM mart.vw_api_produtos_sazonalidade
WHERE tipo_dado = 'FALLBACK_DIMENSAO'
  AND ano = EXTRACT(YEAR FROM CURRENT_DATE)::integer
  AND mes >= EXTRACT(MONTH FROM CURRENT_DATE)::integer
  AND ano_referencia IS NULL
  AND status_cor = 'VERDE'
  AND metadado_transparencia->>'procedencia' = 'sem_historico_real';

-- P5: Distribuição por mês da âncora (visual)
SELECT ano, mes,
       min(ano_referencia) AS min_ancora, max(ano_referencia) AS max_ancora,
       count(*) AS linhas
FROM mart.vw_api_produtos_sazonalidade
WHERE tipo_dado = 'FALLBACK_DIMENSAO'
  AND ano = EXTRACT(YEAR FROM CURRENT_DATE)::integer
GROUP BY ano, mes ORDER BY mes;

-- P6: Paridade estrutural completa (diferença simétrica entre bancos)
--     Rode o mesmo script nos 2 bancos e compare a saída (union de P2+P3+P4).
```

### 4.5 Prioridade e ordem de execução

| #   | Ação                                              | Prioridade | Risco se não fizer                                         |
| --- | ------------------------------------------------- | ---------- | ---------------------------------------------------------- |
| 1   | Frontend: adicionar CINZA ao tipo + componentes   | Alta       | Usuário vê falso positivo 🟢/🟡 sem dado real              |
| 2   | Backend: Pydantic aceitar CINZA                   | Alta       | MV corrigida causaria HTTP 500                             |
| 3   | Migration 83: âncora −1 + default CINZA           | Alta       | Contrato de transparência permanece violado                |
| 4   | Testes (P3/P4) como gate de CI                    | Média      | Regressão silenciosa                                       |
| 5   | Investigar queda de volume jun/jul/2026           | Média      | Projeções inconsistentes entre meses                       |
| 6   | Avaliar Redis p/ cache compartilhado multi-worker | Baixa      | Cache in-memory não determinístico em múltiplas instâncias |

---

## Anexo A — Fontes de evidência

- `database/80_mv_fallback_janela_2023.sql` (piso −3, cascata VERDE)
- `database/78_deep_fallback_historico.sql`, `database/79_br_sazonalidade_inclui_projecao.sql`
- `database/63_dado_historico_real_transparencia.sql`, `database/65_limiares_cores_dinamicos_zscore.sql`, `database/68_recalibracao_estatistica_br.sql`
- `database/74_quality_gate_12_meses.sql`, `database/76_quality_gate_completude_serie.sql`, `database/66_hotfix_br_quality_gate.sql`
- `backend/app/schemas/responses.py` (71, 172, 239), `backend/app/api/v1/endpoints/produtos.py` (37-83, 345-346, 592-630), `backend/app/core/cache.py`, `backend/app/core/config.py` (49, 64), `backend/app/core/session.py`
- `frontend/src/components/ProductCard.tsx` (49-105), `frontend/src/types/domain.ts` (1), `frontend/src/pages/SupermercadoView.tsx`, `frontend/src/components/SazonalidadeNacional.tsx`, `frontend/src/components/RegiaoPanel.tsx`
- `docs/SUMMARY.md`, `docs/runbook_migration_80_local.md`, `docs/ARQUITETURA_AMBIENTES_CI_CD.md`
- Queries executadas via MCP em 2026-08-18 nos bancos `quero_comprar` (local) e `defaultdb` (Aiven)
