# 🧾 Relatório de Auditoria de Conciliação — RAW vs. ETLs vs. Migrations

> **Data:** 31/07/2026
> **Escopo:** Divergências de **PREÇO** e **ANO** na linhagem do dado (Data Lineage):
> `RAW (arquivos locais) → staging.fact_precos_mensais → mart.sazonalidade_produto`
> **Ambiente auditado:** Supabase remoto (`kxsqrcccaaxplpktmutl`)

---

## Sumário Executivo

| Fase | Objeto | Verdicto |
|---|---|---|
| FASE 1 — Migrations | Tipagem/constraints de preço e ano | 🟡 **Sem truncamento de casas decimais**, mas **drift de schema** entre migrations e banco real |
| FASE 2 — RAW vs Staging | Parsing (separador decimal, ano) | 🟢 **Parsing OK** (vírgula→ponto, 0 erros em 53.811 preços), ⚠️ **8/50 amostras com divergência de preço** por base de cotação distinta |
| FASE 3 — Staging vs Mart | Regressão silenciosa | 🔴 **CRÍTICO:** 343 outliers > 500% (quebra de unidade de medida), 14.270 mart sem preço com fact com preço, 60.519 linhas sem `ano`/`mes` |

---

# FASE 1 — Auditoria Estrutural das Migrations

## 1.1 Mapa de colunas de preço e tempo (linhagem)

| Camada | Tabela/Coluna | Tipo no banco real | Origem (migration) |
|---|---|---|---|
| RAW | `raw.precos_uf.preco_medio` | `TEXT` (intencional) | `01_ddl_medalhao.sql` |
| RAW | `raw.precos_municipio.preco_medio` | `TEXT` | `01_ddl_medalhao.sql` |
| STAGING | `staging.fact_precos_mensais.preco_medio` | `NUMERIC(14,4) NOT NULL CHECK (>0)` | `01_ddl_medalhao.sql` |
| STAGING | `staging.fact_precos_mensais.ano/mes` | `SMALLINT` | `01_ddl_medalhao.sql` |
| STAGING | `staging.fact_precos_mensais.preco_curado` | `NUMERIC(14,4)` | `22_data_healing_schema.sql` |
| MART | `mart.sazonalidade_produto.preco_atual/preco_referencia` | `NUMERIC` (precisão arbitrária) | `05_recalibracao_baseline_2025.sql`, `013_reconciliacao_drift_fase4.sql` |
| MART | `mart.sazonalidade_produto.ano/mes` | `SMALLINT NULL` | `01` (recriada no 30+) |
| MART | `mart.sazonalidade_produto.preco_medio` (legado) | `NUMERIC(14,4)` | `01_ddl_medalhao.sql` (NÃO removida!) |

## 1.2 Diagnóstico de tipagem

✅ **Nenhuma mudança `NUMERIC/DECIMAL → FLOAT/DOUBLE/INT`** foi encontrada nas 52 migrations.
Todas as colunas de preço permanecem `NUMERIC(14,4)` ou `TEXT` — **não há truncamento silencioso de centavos por cast**.

⚠️ **Porém, dois problemas estruturais reais:**

### 🔴 1.2.1 — Tabela mart híbrida (Frankenstein de schemas)
O banco real mantém **simultaneamente** as colunas da fase 1 (`preco_medio`, `media_movel_12m`, `indice_sazonalidade`)
**e** as colunas da fase 5+ (`preco_atual`, `preco_referencia`, `data_referencia_atual`, `is_forecast`, `forecast_method`).
As migrations 05, 23 e 30 não droparam as colunas legadas. **Duas fontes de verdade de preço na mesma linha.**

### 🔴 1.2.2 — 60.519 linhas do mart sem `ano`/`mes`
SPs da era snapshot (05/17/18/19/22/23 — ex.: `sp_calcular_sazonalidade_preditiva` v8/v9) gravam
apenas `data_referencia_atual` e deixam `ano`/`mes` **NULL**. Hoje **30,5% do mart** (60.519 de 192.318)
é **invisível para qualquer filtro por ano/mês** e não participa das junções temporais da API.

### 🟡 1.2.3 — UNIQUE constraint divergente entre migrations
- Migration `23_time_series_mart.sql` alterou UNIQUE para `(id_produto, id_localidade, data_referencia_atual)`.
- O banco real tem `uq_sazonalidade UNIQUE (id_produto, id_localidade, ano, mes)` (revertido pelo 30+).
- Consequência: `ON CONFLICT (…, data_referencia_atual)` de SPs antigas **não conflita** com o UNIQUE atual,
  permitindo **duplicatas temporais** e reescrita silenciosa.

---

# FASE 2 — Conciliação RAW vs. Staging (O Teste do Parsing)

## 2.1 Execução

Script criado: **`utilities/audit_raw_vs_db.py`** (lê os 40 arquivos RAW locais, amostra 50 registros,
compara texto exato do preço e ano com `staging.fact_precos_mensais`).

```
105.304 registros raw carregados (40 arquivos: LISTA*.json + LISTA*.txt)
Separador decimal: 53.811 vírgula | 0 ponto | 0 ambos | 0 não-parseáveis
```

## 2.2 Resultado da amostra (50 registros, semente=42)

| Resultado | Qtd |
|---|---|
| ✅ Preço + Ano idênticos | 11 |
| ❌ Divergência de PREÇO | 8 |
| ❌ Divergência de ANO/MÊS | **0** |
| ⚠️ B2C ausente no banco | 1 |
| ➖ Não encontrado (B2B/outros) | 30 |

## 2.3 Diagnóstico

### ✅ Separador decimal — SEM problema
Todos os 53.811 preços usam vírgula decimal (padrão BR). `_sanitizar_preco` (`ingestao_conab.py:335`)
e `_parse_price_column` (`transform.py:44`) convertem `"2,27" → 2.27` corretamente. **Nenhum centavo perdido no parsing.**

### ✅ Ano/Mês — SEM problema
0 divergências de ano/mês na amostra. O `ano` vem de coluna explícita do arquivo CONAB e condiz com o banco.

### 🔴 Divergências de PREÇO — Causa raiz: bases de cotação distintas
Os arquivos RAW auditados são **cotações CONAB "PREÇO PAGO PELO PRODUTOR"** (`dsc_nivel_comercializacao`),
enquanto a `fact` foi povoada com fonte **`SCRAPER`** (CEASA/atacado). São **duas bases de preço diferentes**
sendo comparadas — o que é, em si, um achado de conciliação:

| Arquivo | Produto | UF | Período | Preço RAW (texto) | Preço no banco | Dif |
|---|---|---|---|---|---|---|
| LISTA15 | FEIJAO - COMUM CORES TIPO 1 | SC | 2025/06 | `8,93` | `2,43` | +6,50 (3,7×) |
| LISTA1 | BATATA | DF | 2026/03 | `5,37` | `3,7333` | +1,64 |
| LISTA1 | BANANA - PRATA | CE | 2026/05 | `1,41` | `0,54` | +0,87 |
| LISTA13 | CAFE - CONILLON TIPO 7 | ES | 2025/12 | `20,8` | `21,14` | −0,34 |
| LISTA1 | ARROZ - LONGO FINO TIPO 1 BE | CE | 2025/08 | `4,15` | `5,10` | −0,95 |
| LISTA1 | ACUCAR - CRISTAL | AC | 2025/10 | `4,11` | `3,44` | +0,67 |
| LISTA20 | TRIGO - PÃO, PH 78, TIPO 1 | RS | 2026/01 | `1,01` | `0,91` | +0,10 |

> 💡 **Interpretação:** para produtos com **1 fonte** (ex.: BANANA-NANICA PE = `12,71` = `12,71` ✅), o parsing é fiel.
> As divergências ocorrem onde **duas fontes coexistem na mesma chave `(produto, uf, ano, mes)`**
> — o `ON CONFLICT (id_produto, id_localidade, ano, mes)` da `ingestao_conab_inteligente` sobrescreve
> o preço da fonte anterior, misturando bases de cotação na mesma célula.

---

# FASE 3 — Conciliação Staging vs. Mart (A Regressão Silenciosa)

## 3.1 Volumes

```
fact_precos_mensais :  45.965   (1.291 interpolados)
mart.sazonalidade_produto : 192.318  (107.135 is_forecast = 55,7% SINTÉTICOS)
```

O mart tem **4,2× mais linhas que a fact** — inflado por projeções (Sanduíche/Proxy/Forecast).

## 3.2 Anomalias temporais

| Checagem | Resultado |
|---|---|
| Mart real (is_forecast=FALSE, com ano/mes) sem lastro na fact | ✅ **0** |
| Fact sem linha correspondente no mart | ✅ **0** |
| Mart com `ano`/`mes` NULL (legado) | 🔴 **60.519** (30,5%) — todos com `data_referencia_atual` 2024-01..2026-12 |

## 3.3 Anomalias de preço (outliers)

### 🔴 3.3.1 — 343 linhas mart com preço > 500% do preço da fact (mesma chave)
**Causa raiz: quebra de unidade de medida** — a média histórica do Sanduíche Sazonal (migration 40)
mistura unidades de comercialização (caixa/dezena/maço vs kg):

| Produto | UF | Período | `mart.preco_atual` | `fact.preco_medio` | Fator | Variação |
|---|---|---|---|---|---|---|
| **Ovo Branco** | TO | 2026/06 | `141,1095` | `5,93` | **23,8×** | +2.280% |
| Batata Doce Amarela | SP | 2026/07 | `40,0195` | `2,335` | 17,1× | +1.614% |
| Batata Doce Amarela | RS | 2025/08 | `15,1841` | `0,92` | 16,5× | +1.550% |
| Tomate Italiano - Pizzadoro | PR | 2025/11 | `25,5167` | `1,58` | 16,2× | +1.515% |
| Pepino Caipira | TO | 2026/06 | `77,8289` | `5,50` | 14,2× | +1.315% |
| ALFACE | DF | 2025/11 | `16,9730` | `1,22` | 13,9× | +1.291% |
| Alface Crespa | DF | 2026/06 | `22,4130` | `1,67` | 13,4× | +1.242% |
| Cebola Roxa | RJ | 2026/06 | `40,6660` | `4,00` | 10,2× | +917% |

**Exemplo-fantasma (Ovo Branco TO 2026/06):**
- `fact` → `preco_medio = 5,93`, `fonte = NULL (SCRAPER)`, `preco_curado = NULL`
- `mart` → `preco_atual = 141,1095` **e** `preco_medio (legado) = 5,93` na **mesma linha**!
- Ou seja: a coluna legada está certa; a coluna nova (`preco_atual`) foi sobrescrita pela
  `fn_sandwich_historical_price` com a média histórica em **outra unidade** (R$/caixa de 30 ovos vs R$/kg).

### 🔴 3.3.2 — 14.270 linhas mart sem preço onde a fact TEM preço
`mart.preco_atual` NULL/≤0 mas `fact.preco_medio > 0` na mesma chave. O Sanduíche só patcha
`is_forecast=TRUE`; dados reais (is_forecast=FALSE) que perderam preço não são recuperados.
Desses, **20.675** também não têm `preco_medio` legado — células sem nenhum valor de preço.

### 🟡 3.3.3 — Preço congelado no mart (LOCF)
Ex.: `CARNE OVINA - CARCAÇA SE`: `preco_atual = 29,41` repetido em 2025/07,08,10,11,12 enquanto
a fact varia 28,24→30,11 — **LOCF propagando o último valor conhecido**, gerando séries "achatadas".

---

# 🎯 Conclusões e Recomendações

| # | Achado | Gravidade | Recomendação |
|---|---|---|---|
| 1 | **Unidade de medida misturada** no Sanduíche Sazonal (`preco_atual` 10-24× o real) | 🔴 CRÍTICA | Normalizar para **R$/kg** via `fator_kg` (migration 15) antes de calcular `fn_sandwich_historical_price` |
| 2 | **60.519 linhas mart sem `ano`/`mes`** | 🔴 ALTA | Backfill `ano/mes = SPLIT_PART(data_referencia_atual)` em migration de correção |
| 3 | **14.270 mart sem preço com fact com preço** | 🔴 ALTA | Rerun do Sanduíche patch para `is_forecast=FALSE` também, usando `COALESCE(preco_curado, preco_medio)` |
| 4 | **Mistura de fontes na mesma chave fact** (produtor vs scraper) | 🟡 MÉDIA | Adicionar `fonte` na chave de negócio ou priorizar fonte única (SCRAPER) |
| 5 | Schema híbrido do mart (colunas legadas + novas) | 🟡 MÉDIA | Migration de limpeza: dropar `preco_medio`/`media_movel_12m`/`indice_sazonalidade` legadas |
| 6 | Parsing de preço e ano | ✅ OK | Sem ação (vírgula→ponto correto; ano fiel ao arquivo) |

## Artefatos produzidos
- `utilities/audit_raw_vs_db.py` — auditoria FASE 2 (RAW vs Staging), reproduzível: `python utilities/audit_raw_vs_db.py [--amostra N] [--semente S]`
- Queries FASE 3 (neste relatório) — executadas via psycopg2 contra o Supabase remoto
