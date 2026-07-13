# RELATÓRIO DE AUDITORIA — DROPDOWN "BR NACIONAL"

**Auditor:** Staff Data Engineer / Data QA  
**Data:** 2026-07-13  
**Escopo:** Pipeline CONAB → Frontend, agregação nacional, interpolação, vazamento B2B  
**Stack:** PostgreSQL 16 + Python/Polars + React/FastAPI

---

## 1. ELT vs ETL: Onde a mágica acontece?

### Resumo: HÍBRIDO — os dois mundos

```
ETL (Python/Polars) ──> staging ──> ELT (SQL/SP) ──> mart ──> API/Frontend
```

> **Analogia do restaurante:** O Python é o *cozinheiro* que lava, corta e separa os ingredientes (ETL na Garagem). O PostgreSQL é o *chef* que aplica as receitas e monta o prato final (ELT no Medalhão). Um não funciona sem o outro.

| Camada | Onde | Ferramenta | O que faz |
|--------|------|-----------|-----------|
| **Extract** | Python | `ingestao_conab_inteligente.py` | Baixa LISTA*.txt da CONAB, faz parser CSV (separador `;`, encoding Latin-1), converte vírgula decimal `2,27` → `2.27` |
| **Transform (primeira)** | Python | MotorCategorizacao (regex) | Classifica cada produto como `ALIMENTO_VAREJO`, `MAQUINARIO_FERRAMENTA`, `INSUMO_AGRICOLA`, etc. Separa B2C de B2B |
| **Load** | Python → PG | `execute_values` (COPY bulk) | UPSERT em `staging.fact_precos_mensais` — só chega `ALIMENTO_VAREJO` |
| **Transform (segunda)** | PostgreSQL | `staging.sp_calcular_sazonalidade_preditiva()` | Lê da `fact_precos_mensais`, aplica Alpha/Beta/Gamma, escreve em `mart.sazonalidade_produto` |
| **Apresentação** | PostgreSQL | `mart.vw_api_produtos_sazonalidade` (MV) | Filtra, JOIN, ordena — o que a API lê |

> **Pra um jovem de 15 anos:** Imagina que você tá fazendo um bolo. O Python é quem lava as frutas, separa os ingredientes e coloca tudo na bancada (ETL). O PostgreSQL é quem mistura na ordem certa, leva ao forno e decide o ponto exato (ELT). O bolo pronto é a `Materialized View` que o garçom (API) leva pra mesa (Frontend).

---

## 2. Data Lineage: A Vida do Dado

### Mapa passo a passo

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. CONAB/CEASA                                                │
│    └─► LISTA*.txt (CSV separado por ";", vírgula decimal)     │
│                                                                 │
│ 2. raw.coleta_bruta (Bronze)                                    │
│    └─► Cópia 1:1 do payload, JSONB, append-only                │
│                                                                 │
│ 3. Python (MotorCategorizacao)                                  │
│    └─► Regex classifica: ALIMENTO_VAREJO ou B2B                │
│    └─► Filtra: só ALIMENTO_VAREJO passa                        │
│                                                                 │
│ 4. staging.fact_precos_mensais (Silver)                         │
│    └─► Tabela fato: (produto, localidade, ano, mes) UNIQUE      │
│    └─► Colunas: preco_medio, preco_curado, is_interpolado      │
│                                                                 │
│ 5. data_healer.py (Layer A + B)                                 │
│    └─► Interpolação linear de gaps ≤ 2 meses                   │
│    └─► Marca is_interpolado = True                              │
│    └─► Calcula score_confianca (Layer B)                        │
│                                                                 │
│ 6. staging.sp_calcular_sazonalidade_preditiva() (SP V9)         │
│    └─► Alpha (baseline 2025 se confiável)                       │
│    └─► Beta (fallback 12m se ≥ 3 meses disponíveis)             │
│    └─► Gamma (cold start = AMARELO se sem histórico)            │
│    └─► Semaforo: VERDE < -15%, VERMELHO > +15%, AMARELO resto  │
│                                                                 │
│ 7. mart.vw_api_produtos_sazonalidade (MV V13)                   │
│    └─► 4 barreiras de filtro                                    │
│    └─► Expõe apenas o que o app B2C deve ver                    │
│                                                                 │
│ 8. FastAPI → produtos.py                                        │
│    └─► /api/v1/sazonalidade?uf=AC (dados da UF)                │
│    └─► /api/v1/sazonalidade?uf=BR (agregação nacional)          │
│                                                                 │
│ 9. React → SupermercadoView.tsx                                 │
│    └─► Dropdown "BR (Nacional)" → chama API com uf=BR           │
└─────────────────────────────────────────────────────────────────┘
```

> **Pra um jovem de 15 anos:** Pensa num pacote dos Correios. Sai da CONAB (loja), chega no nosso centro de distribuição (`raw.coleta_bruta`), é separado por tipo (Python categoriza), colocado nas prateleiras certas (`staging.fact_precos_mensais`). Se um mês não veio produto, a gente "adivinha" o preço com base nos meses vizinhos (`data_healer.py` — mas avisa que é chute). Depois o chefe decide se o preço tá bom, caro ou barato demais (SP do semáforo). Finalmente empacota tudo bonito na `Materialized View` e entrega pro app.

---

## 3. Como é feito o Cálculo do Semáforo?

### A Matemática por Trás da SP

O semáforo compara **preço_atual** com **preço_referência** (a âncora):

```
threshold = 15%

VERDE   → preço_atual <  âncora × 0.85   (barato / safra)
AMARELO → preço_atual entre ±15% da âncora (normal)
VERMELHO → preço_atual >  âncora × 1.15  (caro / entressafra)
```

### Como a âncora é definida? (Cadeia de Fallback)

```
Alpha ──> Beta ──> Gamma
```

| Camada | Método | Condição | Fonte |
|--------|--------|----------|-------|
| **Alpha** | `alpha_sazonal` | `confiavel_2025 = TRUE` (≥ 6 meses com dados em 2025) | Média do baseline 2025 (curado/interpolado) |
| **Beta** | `beta_media_disponivel` | ≥ 3 meses nos últimos 12 períodos | Média dos últimos 12 meses |
| **Gamma** | `gamma_cold_start` | Sem histórico suficiente | `preco_referencia = preco_atual` → variação 0% → **AMARELO** |

> **Pra um jovem de 15 anos:** É como perguntar "esse preço do tomate tá justo?"  
> - **Alpha:** A gente olha quanto custou o tomate em cada mês de 2025. Se tiver pelo menos 6 meses de dados, usa a média de 2025 como referência.  
> - **Beta:** Se 2025 não é confiável (menos de 6 meses), a gente olha os últimos 12 meses. Se tiver pelo menos 3 meses, usa a média deles.  
> - **Gamma:** Se o produto é novato (zero histórico), a gente não tem como comparar — assume AMARELO (neutro) até acumular dados.

### Variação Percentual (quanto % mais caro/barato)

```sql
((preco_atual / preco_referencia) - 1) × 100
```

Exemplo: preço atual = R$ 5,00, referência = R$ 4,00  
→ ((5/4) - 1) × 100 = **+25%** → **VERMELHO** (> +15%)

---

## 4. A Caça aos Fantasmas — Riscos do "BR Nacional"

### 4.1 Interpolação: O Sistema "Inventa" Preços?

**SIM, mas com limites e transparência.**

O `data_healer.py` (Layer A) faz:

1. **Gera grid temporal completo** — para cada (produto, localidade), cria todos os meses entre `ano_min` e `ano_max`
2. **Interpola linearmente** gaps de **1-2 meses consecutivos** usando Polars `.interpolate(method="linear")` + `fill_null(forward, limit=2)`
3. **NÃO interpola** gaps > 2 meses — deixa `preco_curado = NULL`
4. **Marca `is_interpolado = True`** em todo valor que foi inventado

**Cadeia de propagação do `is_interpolado` → `preco_estimado`:**

```
fact_precos_mensais.is_interpolado
  → SP V8.1: f.is_interpolado AS preco_estimado
  → MV V12+: s.preco_estimado
  → FastAPI: SazonalidadeResponse.preco_estimado
  → Frontend: ProdutoVarejo.preco_estimado (booleano no tipo)
```

**🚩 ACHADO CRÍTICO:** O frontend **recebe** o campo `preco_estimado` mas **NUNCA o exibe**. Em `ProductCard.tsx`, `CategoriesModal.tsx`, `SupermercadoView.tsx` — zero referências a `preco_estimado`. O dado está na tipagem mas o usuário não vê aviso de "preço estimado por IA".

### 4.2 Agregação Nacional — Riscos Multiplicados

Quando o usuário seleciona "BR (Nacional)" no dropdown, o backend roda `_query_br_por_mes()` em `produtos.py:353`:

```sql
SELECT
    AVG(v.preco_referencia)   AS preco_referencia,  -- média de TODOS os estados
    AVG(v.preco_atual)        AS preco_atual,        -- média de TODOS os estados
    BOOL_OR(v.preco_estimado) AS preco_estimado,     -- TRUE se ALGUM estado foi interpolado
    BOOL_OR(v.usou_fallback_12m) AS usou_fallback_12m,
    MODE() WITHIN GROUP (ORDER BY v.status_cor) AS status_cor,  -- moda (mais frequente)
    BOOL_OR(v.is_forecast)    AS is_forecast
FROM mart.vw_api_produtos_sazonalidade v
GROUP BY v.produto, v.classificao_produto, v.categoria, b.confianca
```

**Riscos identificados:**

| Risco | Gravidade | Detalhes |
|-------|-----------|----------|
| **Média de médias** | ALTA | `AVG(v.preco_atual)` tira a média de algo que já é uma média por UF. Se SP tem 20 fontes e AC tem 1, ambas pesam igual. O BR não pondera por população ou volume de produção |
| **BOOL_OR mascara confiança** | MÉDIA | Se 1 estado dos 27 tem `preco_estimado = True`, o BR inteiro fica marcado como estimado. Correto em transparência, mas pode assustar o usuário |
| **MODE(status_cor) é frágil** | ALTA | Se 10 UFs estão VERMELHO, 9 AMARELO, 8 VERDE → moda é VERMELHO. Mas se 10-9-8 (empate técnico), o MODE() do PostgreSQL pega o primeiro valor na ordenação interna — **não deterministico** |
| **JOIN baseline usa br_id fixo** | MÉDIA | `sazonalidade_baseline` é joinada com `b.id_localidade = {br_id}` — precisa existir uma entrada específica para a localidade BR. Se não existir, `confianca_baseline` vem NULL |

### 4.3 Gaps Diretos — Produtos com Dados Insuficientes

**Layer B** (confiança do baseline 2025) calcula:

```
score_confianca = (meses_reais + meses_interpolados) / 12
confiavel_2025 = (score_confianca >= 0.50)
```

Se **confiavel_2025 = FALSE** (menos de 6 meses de dados em 2025), o sistema cai para **Beta** (fallback 12m). Se o fallback também falhar (< 3 meses nos últimos 12 períodos), cai para **Gamma** (cold start → AMARELO).

**🚩 ACHADO:** O Gamma (cold start) sempre retorna AMARELO com variação 0%. O produto aparece no dropdown BR Nacional sem nenhuma base real de comparação. O usuário vê um "Preço Normal" que é, na verdade, um palpite vazio.

### 4.4 Vazamento B2B — A Contaminação por Trator e Diesel

#### Análise das Barreiras

A MV V13 tem **4 barreiras simultâneas**:

```
1. status_cor IN ('VERDE', 'AMARELO', 'VERMELHO')     ── Trindade Estrita
2. categoria_b2c = 'ALIMENTO_VAREJO'                    ── Gate principal B2C
3. classificao_produto NOT IN (INSUMO, MAQUINARIO, ...) ── Exclusão B2B
4. nome_categoria NOT IN ('FLORES', 'OUTROS')           ── Exclusão de categorias
```

**Risco ATUAL: BAIXO** — as 4 barreiras funcionam em conjunto.

**Risco HISTÓRICO:** Entre as versões MV V5 e V7 (arquivos `15_schema_agro_regional.sql` a `19_fix_supressao_preditiva.sql`), o filtro `ALIMENTO_VAREJO` estava **AUSENTE**. Durante esse período, Óleo Diesel, Tratores, Lubrificantes e outros itens B2B **vazaram para o frontend B2C**.

**🚩 FRAGILIDADE NA REGEX:** O `MotorCategorizacao` em `ingestao_conab_inteligente.py:136` inclui `OLEO` na lista de `ALIMENTO_VAREJO`. O hotfix `20_hotfix_filtro_varejo.sql` corrigiu manualmente **12 IDs específicos** de produtos (óleo diesel, lubrificante, mineral). Mas **qualquer novo produto** que comece com "OLEO" e não seja explicitamente bloqueado por `classificao_produto` pode vazar para a MV. A correção é frágil e manual.

### 4.5 BUG CRÍTICO: SP Errada no Pipeline Final

**Arquivo:** `26_forecast_baseline.sql:148`

```sql
CALL staging.sp_calcular_sazonalidade(v_ultimo_ano, v_ultimo_mes);
--       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
--       CHAMADA ERRADA! É a V1 LEGACY (rolling window 12m)!
--       Deveria ser: CALL staging.sp_calcular_sazonalidade_preditiva()
```

O `sp_executar_carga_completa()` (V2 da migração 26) chama a **stored procedure original da Fase 1**, que usa o algoritmo de rolling window 12m da arquitetura antiga, **em vez da SP V9 atual** (Alpha/Beta/Gamma com data healing). Isso significa que:

- O cálculo de sazonalidade é feito com o modelo **antigo** (sem interpolação, sem baseline 2025)
- O `preco_estimado` pode não ser propagado corretamente
- Produtos que dependem de data healing podem ter âncora errada

---

## 5. Plano de Ação — 3 Passos Técnicos

### Passo 1: Corrigir o Bug da SP no Pipeline Final

**O que:** Substituir a chamada `sp_calcular_sazonalidade()` por `sp_calcular_sazonalidade_preditiva()` em `26_forecast_baseline.sql:148`.

**Onde:** `database/26_forecast_baseline.sql` — função `sp_executar_carga_completa()`

**Código:**
```sql
-- ERRADO (linha 148):
CALL staging.sp_calcular_sazonalidade(v_ultimo_ano, v_ultimo_mes);
-- CORRETO:
CALL staging.sp_calcular_sazonalidade_preditiva();
```

**Por que:** Sem essa correção, o pipeline orquestrado roda o motor LEGACY V1, ignorando 8 versões de melhoria (data healing, baseline 2025 interpolado, preco_estimado, filtro ALIMENTO_VAREJO nas CTEs).

### Passo 2: Exibir `preco_estimado` no Frontend

**O que:** O campo `preco_estimado` chega no frontend como booleano mas nunca é renderizado. O usuário não sabe que está vendo um preço "inventado" por interpolação.

**Onde:** `frontend/src/components/ProductCard.tsx`

**Como:** Adicionar um badge "Preço Estimado" (amarelo, interrogação) ao lado do nome do produto quando `preco_estimado === true`. Também adicionar tooltip explicativo: "Este preço foi calculado com base nos meses anteriores (dado oficial não disponível para este período)."

No nível BR Nacional, o `BOOL_OR` já propaga corretamente — se qualquer UF teve interpolação, o BR inteiro aparece como estimado. Basta o frontend consumir essa flag.

### Passo 3: Ponderar a Média Nacional por Número de Fontes (ou População)

**O que:** A agregação BR atual usa `AVG()` simples sobre as médias de cada UF. Isso distorce a realidade: SP com 20 fontes pesa o mesmo que AC com 1 fonte.

**Onde:** `backend/app/api/v1/endpoints/produtos.py` — função `_query_br_por_mes()`

**Como (abordagens em ordem de preferência):**

1. **SQL ponderado (mínima mudança):** Usar `SUM(preco_atual * peso_fonte) / SUM(peso_fonte)` onde `peso_fonte` = número de registros distintos de localidade daquela UF no período. Dá mais peso a estados com mais coleta.

2. **Nova MV nacional:** Criar `mart.vw_br_sazonalidade` que já faz a agregação ponderada com os pesos corretos, evitando que o backend faça matemática em SQL ad-hoc.

3. **Flag de "cobertura mínima":** Adicionar um filtro `HAVING COUNT(DISTINCT v.uf) >= 5` para que a agregação BR só apareça se houver pelo menos 5 estados representados no mês. Se não, o produto não aparece no dropdown BR Nacional — menos dados, menos enganação.

**Recomendação:** Implementar a opção 1 (ponderada) junto com a 3 (mínimo de UFs). A opção 2 é desejável mas requer migração.

---

## Apêndice: Checklist de Verificação

| Item | Status | Arquivo |
|------|--------|---------|
| `is_interpolado` existe na `fact_precos_mensais` | ✅ | `database/22_data_healing_schema.sql:36` |
| `preco_estimado` propagado na SP V8.1 | ✅ | `database/22b_data_healing_hotfix.sql:52` |
| `preco_estimado` na MV V12+ | ✅ | `database/25_fix_mv_missing_columns.sql:40` |
| `preco_estimado` no schema Pydantic | ✅ | `backend/app/schemas/responses.py:64` |
| `preco_estimado` no type frontend | ✅ | `frontend/src/types/domain.ts:13` |
| `preco_estimado` renderizado no frontend | ❌ | `frontend/src/components/ProductCard.tsx` |
| Filtro `ALIMENTO_VAREJO` na MV atual | ✅ | `database/26_forecast_baseline.sql:95` |
| Filtro `classificao_produto` B2B na MV | ✅ | `database/26_forecast_baseline.sql:96-97` |
| Hotfix óleos não-comestíveis (20) | ✅ | `database/20_hotfix_filtro_varejo.sql:28-43` |
| SP correta no pipeline (V9, não V1) | ❌ | `database/26_forecast_baseline.sql:148` |
| Regex de OLEO capturando ALIMENTO_VAREJO | ⚠️ Fragil | `pipeline/ingestao_conab_inteligente.py:142` |
| BR Nacional sem ponderação | ⚠️ | `backend/app/api/v1/endpoints/produtos.py:377-378` |
| MODE(status_cor) determinístico no BR | ⚠️ | `backend/app/api/v1/endpoints/produtos.py:381` |
