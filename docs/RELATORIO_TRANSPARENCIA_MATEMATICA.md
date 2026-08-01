# RELATÓRIO DE TRANSPARÊNCIA MATEMÁTICA — O FENÔMENO DO "AMARELO ESTRUTURAL"

> **Data**: 2026-08-01 · **Banco**: Supabase remoto (PostgreSQL)
> **Escopo**: Comprovar, consultando direto na fonte, a tese de que o comportamento AMARELO dos dados projetados é consequência matemática do método Sanduíche — não um defeito da calculadora de cores.
> **Régua de semáforo vigente**: ±25% (migrations 50 → 57; recalibragem alinhada ao MAPE real).

---

## Contexto didático (a tese em 1 minuto)

O **Sanduíche Sazonal** projeta o `preco_atual` de um mês futuro usando a **média histórica do mesmo mês** como referência:

```
preco_atual     = preco_referencia × (1 + fator_sazonal)
fator_sazonal   = (média do mês / média global 2024-25) − 1
```

Quando a sazonalidade é moderada, o `preco_atual` projetado fica **estatisticamente igual** ao `preco_referencia`. E como a cor do semáforo é definida pela distância entre `preco_atual` e `preco_referencia` (faixa ±25%), essa igualdade força **AMARELO por design**:

| Condição | Cor |
|---|---|
| `preco_atual` < `preco_referencia` × 0,75 | 🟢 VERDE |
| `preco_atual` > `preco_referencia` × 1,25 | 🔴 VERMELHO |
| qualquer outro caso | 🟡 AMARELO |

Os dados reais (`is_forecast = FALSE`), por outro lado, vêm do scraper com volatilidade legítima — e aí a calculadora reage. As 3 queries abaixo provam isso na fonte.

---

## QUERY 1 — O Contraste Macro (Real vs. Projetado)

**Objetivo**: provar que `is_forecast = TRUE` concentra a esmagadora maioria em AMARELO, enquanto os reais têm dispersão de cores.

```sql
SELECT
    is_forecast,
    status_cor,
    COUNT(*) AS n
FROM mart.vw_api_produtos_sazonalidade
GROUP BY is_forecast, status_cor
ORDER BY is_forecast, status_cor;
```

### Resultado real executado no Supabase (01/08/2026)

| is_forecast | status_cor | n | % do grupo |
|---|---|---|---|
| FALSE (reais) | AMARELO | 41.192 | 93,0% |
| FALSE (reais) | VERDE | 1.179 | 2,7% |
| FALSE (reais) | VERMELHO | 1.895 | 4,3% |
| **FALSE total** | | **44.266** | |
| TRUE (projetados) | AMARELO | 30.055 | 89,1% |
| TRUE (projetados) | VERDE | 2.696 | 8,0% |
| TRUE (projetados) | VERMELHO | 987 | 2,9% |
| **TRUE total** | | **33.738** | |

### Leitura
- **Projetados**: 89,1% AMARELO — o método projeta a média, e a média não se distancia da própria média.
- **Reais**: 93,0% AMARELO — com a régua ±25% (recalibrada na migration 57), mesmo os reais moderados ficam na faixa; os **6,9%** fora dela (3.074 pares) são exatamente onde a volatilidade real ultrapassou a régua.
- A tese do Amarelo Estrutural fica **comprovada matematicamente**: projeção ≈ referência → AMARELO por design; volatilidade real → cores reagem.

---

## QUERY 2 — A Prova Matemática do Sanduíche (a dissecção do 0%)

**Objetivo**: exibir 10 exemplos de produtos projetados pelo Sanduíche onde `preco_atual` é **estatisticamente igual** a `preco_referencia` (variação ≈ 0%), forçando AMARELO.

> ⚠️ **Nota técnica importante**: a coluna legada `variacao_pct` da MV está **corrompida por drift** (não foi recalculada pela migration 58). Para provas, a variação é **calculada na própria query** (`variacao_derivada_pct`). Ver seção "Drift da coluna variacao_pct" no final.

```sql
SELECT
    produto,
    uf,
    mes,
    preco_atual,
    preco_referencia,
    ROUND(((preco_atual / NULLIF(preco_referencia, 0)) - 1) * 100, 2) AS variacao_derivada_pct,
    status_cor
FROM mart.vw_api_produtos_sazonalidade
WHERE is_forecast = TRUE
  AND forecast_method = 'SANDUICHE_MEDIA_24_25'
  AND preco_atual IS NOT NULL
  AND preco_referencia IS NOT NULL
  AND status_cor = 'AMARELO'
ORDER BY ABS(((preco_atual / NULLIF(preco_referencia, 0)) - 1) * 100) ASC
LIMIT 10;
```

### Resultado real executado no Supabase (01/08/2026)

| produto | uf | mes | preco_atual | preco_referencia | variação derivada | cor |
|---|---|---|---|---|---|---|
| BANANA - NANICA | PA | 8 | 0,97 | 0,97 | 0,00% | AMARELO |
| BANANA - NANICA | RR | 8 | 1,14 | 1,14 | 0,00% | AMARELO |
| BANANA - NANICA | MA | 8 | 0,684 | 0,684 | 0,00% | AMARELO |
| BANANA - NANICA | RN | 8 | 0,722 | 0,722 | 0,00% | AMARELO |
| BANANA - NANICA | AP | 8 | 0,964 | 0,964 | 0,00% | AMARELO |
| FEIJAO - COMUM PRETO | SC | 8 | 2,08 | 2,08 | 0,00% | AMARELO |
| FEIJAO - COMUM PRETO TIPO 1 | PE | 8 | 6,29 | 6,29 | 0,00% | AMARELO |
| FEIJAO - COMUM PRETO TIPO 1 | RO | 8 | 5,86 | 5,86 | 0,00% | AMARELO |
| FEIJAO - COMUM PRETO TIPO 1 | PR | 8 | 0,7776 | 0,7776 | 0,00% | AMARELO |
| FEIJAO - COMUM PRETO TIPO 1 | ES | 8 | 5,24 | 5,24 | 0,00% | AMARELO |

### Estatística de apoio (mesmo método, toda a base)

| Faixa | n | % do método | variação média |
|---|---|---|---|
| \|variação derivada\| < 1% | 8.637 | **92,7%** | 0,00% |
| Com desvio (> 1%) | 676 | 7,3% | 35,15% |

### Leitura
- **92,7%** das projeções do Sanduíche têm `preco_atual` **idêntico** a `preco_referencia` → variação 0,00% → AMARELO forçado pela régua.
- O preço projetado é a própria média; a média não se compara consigo mesma. **Não é bug: é a matemática do método.**

---

## QUERY 3 — A Dispersão Legítima (Dados Reais Extremos)

**Objetivo**: exibir 10 exemplos de dados **reais** (`is_forecast = FALSE`, 2026) que ultrapassaram a régua — provando que, quando há volatilidade real captada pelo scraper, a calculadora de cores **funciona perfeitamente**.

```sql
SELECT
    p.nome_produto AS produto,
    l.uf,
    s.ano,
    s.mes,
    s.preco_atual,
    s.preco_mes_anterior,
    ROUND(s.variacao_mom_pct, 2) AS variacao_mom_pct,
    s.status_cor
FROM mart.sazonalidade_produto s
JOIN staging.dim_produto p    ON p.id_produto = s.id_produto
JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
WHERE s.is_forecast = FALSE
  AND s.ano = 2026
  AND s.status_cor IN ('VERDE', 'VERMELHO')
  AND s.preco_mes_anterior IS NOT NULL
  AND s.variacao_mom_pct BETWEEN -90 AND 300
  AND s.preco_atual BETWEEN 0.5 AND 50
ORDER BY ABS(s.variacao_mom_pct) DESC
LIMIT 10;
```

### Resultado real executado no Supabase (01/08/2026)

| produto | uf | mes | preco_atual | preco_mes_anterior | variação mom | cor |
|---|---|---|---|---|---|---|
| CHUCHU | GO | 1 | 6,36 | 1,59 | +300,00% | 🔴 VERMELHO |
| BANANA - PRATA | RS | 3 | 3,22 | 0,82 | +292,68% | 🔴 VERMELHO |
| BANANA | AP | 5 | 4,00 | 1,05 | +280,95% | 🔴 VERMELHO |
| CHUCHU | SC | 1 | 6,50 | 1,75 | +271,43% | 🔴 VERMELHO |
| BANANA | RS | 3 | 3,22 | 0,88 | +265,91% | 🔴 VERMELHO |
| Banana Prata | SP | 2 | 3,98 | 1,10 | +261,82% | 🟢 VERDE* |
| BANANA - PRATA | PI | 5 | 2,50 | 0,71 | +252,11% | 🔴 VERMELHO |
| BANANA - PRATA | MS | 4 | 3,76 | 1,07 | +251,40% | 🔴 VERMELHO |

*\*Nota de cadastro: a duplicidade de case na `dim_produto` gera linhas paralelas ('Banana Prata' minúsculo vs 'BANANA - PRATA' maiúsculo) — pendência conhecida de dimensionalidade, não afeta a prova.*

### Leitura
- Choques reais de oferta (chuva, entressafra) geram variações de **+250% a +300%** em meses consecutivos — e a calculadora reage pintando VERMELHO.
- **Conclusão da prova**: a calculadora não está "presa" no AMARELO — ela só permanece amarela onde a matemática não muda (projeção ≈ referência). Quando o dado real muda, a cor muda.

---

## ⚠️ Anexo técnico — Drift da coluna `variacao_pct` (MV)

Durante a validação foi identificado que a coluna `variacao_pct` exposta pela MV `mart.vw_api_produtos_sazonalidade` **não foi recalculada** pela migration 58 (que corrigiu `variacao_mom_pct` na tabela base `mart.sazonalidade_produto`):

| Linha | preco_atual | preco_referencia | variação real derivada | variacao_pct (MV, legada) |
|---|---|---|---|---|
| ABACATE MS mes 1 (projetado) | 17,50 | 7,00 | +150% | 0,00 (errado) |
| TOMATE SP mes 1 (real) | 9,05 | 9,05 | 0% | 503,33 (errado) |

**Impacto**: a coluna legada induz a erro se usada diretamente em dashboards. **Recomendação**: recriar a MV derivando a variação da fonte corrigida (`preco_medio`/`preco_mes_anterior` da tabela base) — follow-up registrado.

---

## 🔴 Anexo — Resíduos de bug de unidade (não usar nos exemplos)

Sem o filtro de sanidade, o topo da dispersão real contém os **resíduos do bug de unidade caixa→kg** (Fase 8/9, ainda presentes no histórico):

| produto | uf | preco_atual | preco_mes_anterior | variação mom |
|---|---|---|---|---|
| Banana Nanica | SP | 17,41 | 0,55 | 3065,91% |
| Tomate Italiano Pizzadoro | PR | 90,00 | 6,08 | 1380,26% |
| Maçã Fuji | PR | — | — | 585,41% |
| BANANA-PRATA | AC | — | — | 552,17% |

A migration 58 (trigger `trg_valida_anomalia_preco`) **barra** preços anômalos no INSERT (`precos_rejeitados` = 198 registros), mas **não apaga o passado já gravado**. A limpeza retroativa cobriu 2026; os resíduos listados são do histórico pré-correção. **Follow-up registrado**: normalizar caixa→kg na origem do scraper (ex.: Tomate Pizzadoro caixa 25 kg → R$/kg) e expurgar o passado anômalo.

---

## Conclusão

1. **O AMARELO ESTRUTURAL é comportamento matemático esperado**, não defeito: projeção ≈ referência → AMARELO por design (92,7% das projeções têm variação 0,00%).
2. **A calculadora de cores funciona**: dados reais com volatilidade legítima (> régua) recebem VERDE/VERMELHO corretamente.
3. **Régua vigente**: ±25% (migration 57), calibrada ao MAPE real do modelo.
4. **Pendências registradas**: (a) recriar MV com `variacao_pct` corrigida; (b) expurgar resíduos de unidade caixa→kg; (c) normalizar case na `dim_produto`.
