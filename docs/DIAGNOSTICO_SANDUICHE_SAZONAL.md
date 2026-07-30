# 🥪 Diagnóstico: Sanduíche Sazonal — Projeção Numérica de Preços para 2026

> **Data:** 30/07/2026
> **Contexto:** Pre-fill de preços numéricos para meses futuros (Ago-Dez 2026) baseado em média histórica 2024/2025, com sobrescrita automática quando dados reais chegarem.

---

## FASE 1: Validação de Arquitetura

### 1.1 Schema Atual — `mart.sazonalidade_produto`

**Unique Key:** `CONSTRAINT uq_sazonalidade UNIQUE (id_produto, id_localidade, ano, mes)`

✅ **Chave lógica correta.** O `UNIQUE` usa `(id_produto, id_localidade, ano, mes)` — exatamente a chave que o sanduíche precisa. O `id_sazonalidade` auto-increment é apenas chave primária; o negócio é resolvido pela combinação lógica.

### 1.2 Flags Existentes

| Coluna | Tipo | Uso Atual |
|---|---|---|
| `is_forecast` | `BOOLEAN DEFAULT FALSE` | `TRUE` = projeção (baseline), `FALSE` = dado real do scraper |
| `baseline_confianca` | `NUMERIC(5,2) DEFAULT 0` | % de confiança (0-100) baseada em quantos meses do baseline têm dados |
| `forecast_method` | `TEXT` | Método de geração: `NULL` = dado real, `beta_weighted_25_24` = projeção |

✅ **Já temos flag de sobrescrita.** `is_forecast` é a coluna que distingue dado real vs projetado.

❌ **Não há `is_sintetico` separado** — mas não é necessário, pois o `is_forecast + forecast_method` já cobre o caso.

### 1.3 UPSERT Atual (30_engine_preditiva_forecast_2026.sql)

```sql
ON CONFLICT (id_produto, id_localidade, ano, mes)
DO UPDATE SET
    is_forecast = CASE
        WHEN EXCLUDED.is_forecast = FALSE THEN FALSE              -- dado real SEMPRE vence
        WHEN mart.sazonalidade_produto.is_forecast = TRUE
             AND EXCLUDED.is_forecast = TRUE THEN TRUE             -- mantém projeção
        ELSE mart.sazonalidade_produto.is_forecast                -- preserva o que estava
    END,
    ...
```

✅ **Regra de Ouro já implementada:** `DISTINCT ON + ORDER BY is_forecast ASC` garante que dado real (is_forecast=FALSE) vença a projeção no mesmo `(produto, localidade, ano, mes)`.

### 1.4 Diagnóstico Final

| Requisito | Status | Observação |
|---|---|---|
| Chave lógica correta `(produto, local, ano, mes)` | ✅ OK | `uq_sazonalidade` usa exatamente esta chave |
| Injeção de meses futuros sem quebrar constraints | ✅ OK | `ON CONFLICT ... DO UPDATE` cobre todos os casos |
| Flag para distinguir real vs projetado | ✅ OK | `is_forecast BOOLEAN` |
| Sobrescrita automática quando real chegar | ✅ OK | `ORDER BY is_forecast ASC` no DISTINCT ON |
| **Projeção de PREÇO NUMÉRICO (não só status_cor)** | ❌ **FALHA** | Engine atual (30) só projeta `status_cor`. `preco_atual` fica `NULL` nos meses futuros |
| **Patch de gaps em meses passados (Jan-Jul)** | ⚠️ **PARCIAL** | LOCF (39) cobre preço, mas engine preditiva (30) só cobre status_cor |
| **Método rastreável para projeção de preço** | ❌ **FALTA** | `forecast_method` não tem valor específico para média histórica de preço |

---

## FASE 2: Solução Proposta

### 2.1 Nova Migration — `database/40_sanduiche_sazonal_preco_projetado.sql`

**O que faz:**
1. Adiciona novo `forecast_method`: `'SANDUICHE_MEDIA_24_25'`
2. Atualiza `sp_calcular_forecast_2026` para projetar também **preço numérico**:
   - Usa média do mesmo mês em 2024-2025 como preço projetado
   - Ajusta por tendência do ano atual (inflação/deflação)
3. Faz **patch retroativo** em Jan-Jul 2026: onde `status_cor` existe mas `preco_atual` é `NULL`, preenche com média histórica
4. Mantém `is_forecast = TRUE` para todas as projeções
5. Mantém `DISTINCT ON + ORDER BY is_forecast ASC` — dado real sempre vence

### 2.2 Fluxo do Sanduíche

```
CAMADA 1 (2024):       Jan Fev Mar Abr Mai Jun Jul Ago Set Out Nov Dez
                        🟢  🟡  🔴  🟢  🟡  🟢  🟡  🟢  🔴  🟡  🟢  🟡
CAMADA 2 (2025):       Jan Fev Mar Abr Mai Jun Jul Ago Set Out Nov Dez
                        🟡  🟢  🟡  🔴  🟢  🟡  🟢  🟡  🔴  🟢  🟡  🟢
                        ↓   ↓   ↓   ↓   ↓   ↓   ↓   ↓   ↓   ↓   ↓   ↓
MÉDIA HISTÓRICA:       R$3.20 R$3.10 R$3.50 R$3.80 ... (preço médio por mês)

CAMADA 3 (2026 REAL):  Jan Fev Mar Abr Mai Jun Jul [Ago] [Set] [Out] [Nov] [Dez]
                        🟢  🟡  🔴  🟢  🟡  🟢  🟡  [🟡 ] [🟢 ] [🔴 ] [🟡 ] [🟢 ]
                        R$3.50 R$3.80 ...                         
                                                    ↓   ↓   ↓   ↓   ↓   ↓
CAMADA 4 (SANDUÍCHE):                                   R$3.40 R$3.25 R$3.60 R$3.90 R$3.45 R$3.30
                                                    🟡   🟢   🔴   🟡   🟢   🟡
                                                    is_forecast = TRUE
                                                    
      ↓ QUANDO SCRAPER CHEGAR ↓
      
CAMADA 4 (DADO REAL):                                   R$3.55 R$3.18 R$3.72 R$4.02 R$3.40 R$3.28
                                                    🟢   🟢   🟡   🟡   🟢   🟢
                                                    is_forecast = FALSE ← sobrescreveu!
```

### 2.3 Regras de Negócio

1. **Patch (Jan-Jul):** Onde `preco_atual IS NULL` mas `status_cor` existe → preencher com média do mesmo mês em 2024-2025
2. **Pre-fill (Ago-Dez):** Inserir `(produto, localidade, ano=2026, mes)` com `preco_atual` = média histórica do mesmo mês
3. **Sobrescrita:** Quando scraper trouxer dado real de Ago/2026 → `ON CONFLICT (id_produto, id_localidade, ano, mes)` → `is_forecast = FALSE`, `preco_atual` = valor real
4. **Tendência:** O preço projetado deve considerar a inflação do ano atual (percentual de variação entre preços reais de Jan-Jul 2026 vs mesmo período 2025)

---

## FASE 3: Flag de Sobrescrita

### 3.1 Status Atual

✅ `is_forecast BOOLEAN DEFAULT FALSE` já faz o papel de flag de sobrescrita:

- `FALSE` = dado **real** (veio do scraper, nunca será sobrescrito por projeção)
- `TRUE` = dado **projetado** (pode ser sobrescrito quando real chegar)

### 3.2 Comportamento do UPSERT

O `DISTINCT ON (id_produto, id_localidade, ano, mes) ... ORDER BY is_forecast ASC` garante que:

```
CENÁRIO:              UPSERT encontra conflito?
- Real + Projeção     → SIM → DISTINCT ON fica com a linha de is_forecast=FALSE (real)
- Projeção + Projeção → SIM → DISTINCT ON mantém (não há real para substituir)
- Real + Real         → SIM → DISTINCT ON fica com qualquer uma (ambas são FALSE)
- Só Projeção         → NÃO → insere normalmente
```

### 3.3 Não é Necessário DDL Adicional

A coluna `is_forecast` já existe e já está indexada:
```sql
CREATE INDEX IF NOT EXISTS idx_sazonalidade_forecast
    ON mart.sazonalidade_produto (is_forecast)
    WHERE is_forecast = TRUE;
```

---

## Resumo da Validação

| Item | Veredito |
|---|---|
| A arquitetura atual SUPORTA o sanduíche? | ✅ **SIM.** Chave lógica, flags, e UPSERT já estão prontos |
| Precisa de novas colunas? | ❌ **Não.** `is_forecast`, `baseline_confianca`, `forecast_method` já existem |
| Precisa de nova constraint? | ❌ **Não.** `uq_sazonalidade (id_produto, id_localidade, ano, mes)` é a chave correta |
| O que FALTA? | **Preço numérico projetado.** Engine atual só projeta `status_cor`, não `preco_atual` |
| O que fazer? | Migration **40** — estender `sp_calcular_forecast_2026` para projetar também `preco_atual` via média histórica |
