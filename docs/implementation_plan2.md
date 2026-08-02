# Plano de Implementação Sênior — Modelo Preditivo 2024-2025 & Preenchimento 100% da Grade Sazonal

## Contexto e Objetivos

O objetivo deste plano é **eliminar 100% dos espaços cinzas (gaps)** da Grade Sazonal (2025 e 2026) através de uma nova engine de forecast probabilístico baseada na **âncora de 2024**, ajustada pela **margem de variação de 2025**, garantindo a **sobrescrita dinâmica** assim que o scraper coletar dados reais do ano corrente (2026).

---

## 🎯 Arquitetura do Modelo Preditivo (2024 âncora + 2025 ajuste)

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│ 1. DADOS REAIS DO ANO VIGENTE (2026)                                                        │
│    Se o scraper já coletou dados reais (ex: Jan–Jul/2026) → MANTÉM INTACTO (is_forecast=FALSE)  │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
                                              │ (Se mês não possui dado real)
                                              ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│ 2. ENGINE PREDITIVA (FORECAST MULTINÍVEL 2024 + 2025)                                       │
│                                                                                             │
│  • Nível 1 (Âncora 2024 + Ajuste 2025):                                                     │
│    Baseline = Status 2024 (peso 60%) + Variação/Margem 2025 (peso 40%).                     │
│                                                                                             │
│  • Nível 2 (Produtos Novos de 2025):                                                        │
│    Para produtos sem dados em 2024 (ex: criados em Jun/25) → Usa Baseline 2025.             │
│                                                                                             │
│  • Nível 3 (Fallback de Categoria / LOCF):                                                  │
│    Para produtos sem dados em 2024/2025 → Moda da Categoria/UF ou LOCF do mês anterior.     │
│                                                                                             │
│  Resultado: 100% dos 12 meses preenchidos para TODOS os produtos (ZERO espaços cinzas).    │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
                                              │ (Pós-coleta do scraper)
                                              ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│ 3. SOBRESCRITA DINÂMICA (ON CONFLICT DO UPDATE)                                             │
│    Assim que o scraper coleta o dado real de um novo mês → Sobrescreve o forecast           │
│    (is_forecast passa a FALSE e a MV é atualizada automaticamente).                         │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## User Review Required

> [!IMPORTANT]
> **Ponderação Preditiva Proposta**:
> Para os meses futuros/faltantes, o modelo calculará o status de cor ponderando **60% do peso para o comportamento de 2024** (ano com 98.1% de consistência em todos os 12 meses) e **40% de peso para o ajuste de tendência de 2025**.
> Caso haja divergência direta de status entre 2024 e 2025 (ex: Verde em 2024 e Vermelho em 2025), o modelo aplicará o status da tendência de 2025 como margem de risco (marcando **Amarelo** para indicar volatilidade).

---

## Open Questions

> [!NOTE]
>
> 1. Para produtos novos que não existiam em 2024 nem em 2025 (produtos raras/novas variedades de 2026), concorda em usar a moda sazonal da **categoria (ex: Hortaliças/Frutas)** na mesma UF como fallback final? (Isso garante visualização limpa de 100% das células).

---

## Proposed Changes

### Banco de Dados (PostgreSQL / Supabase Migrations)

---

#### [NEW] [000019_engine_forecast_2024_2025_v13.sql](file:///home/pedroeduardo/projetos/quero_comprar_vg/supabase/migrations/000019_engine_forecast_2024_2025_v13.sql)

Cria a nova Procedure de Forecast Preditivo `staging.sp_calcular_forecast_2026_v13()` e recalcula os baselines históricos:

1. **Reconstrução da `mart.sazonalidade_baseline_24_25`**:
   - Agrega o histórico de **2024** por produto/localidade/mês para definir o perfil base de alta/média/baixa estação.

2. **Criação da `mart.sazonalidade_baseline_ponderada`**:
   - Faz o `FULL JOIN` entre a âncora 2024 e a margem de ajuste 2025:
   - Se produto tem 2024 + 2025: aplica matriz de decisão ($0.6 \cdot S_{2024} + 0.4 \cdot S_{2025}$).
   - Se produto só tem 2025: usa 2025.
   - Se produto só tem 2024: usa 2024.

3. **Garantia de 100% de Cobertura (Fallback por Categoria + LOCF)**:
   - Insere fallback de categoria/mês para qualquer combinação `(produto, mes)` ainda sem baseline histórico.

4. **Lógica de Inserção e Sobrescrita Dinâmica**:
   - Insere na `mart.sazonalidade_produto` para todos os meses sem dado real em 2026.
   - Define `is_forecast = TRUE` e `forecast_method = 'ANCHOR_2024_MARGIN_2025'`.
   - Cláusula `ON CONFLICT (id_produto, id_localidade, data_referencia_atual)`:
     ```sql
     DO UPDATE SET
       status_cor = EXCLUDED.status_cor,
       is_forecast = CASE
           WHEN EXCLUDED.is_forecast = FALSE THEN FALSE  -- Sobrescreve com dado real do scraper
           WHEN mart.sazonalidade_produto.is_forecast = FALSE THEN FALSE -- Preserva dado real já existente
           ELSE TRUE -- Mantém forecast atualizado
       END,
       fonte = EXCLUDED.fonte,
       calculado_em = NOW();
     ```

5. **Atualização da SP Principal `staging.sp_executar_carga_completa()`**:
   - Atualiza a chamada interna para invocar a nova procedure `sp_calcular_forecast_2026_v13()`.

---

### Pipeline ETL / Python

---

#### [MODIFY] [persistence.py](file:///home/pedroeduardo/projetos/quero_comprar_vg/pipeline/scraper/persistence.py)

- Garantir que `executar_ciclo_medalhao()` invoque a `sp_executar_carga_completa()` após a ingestão de novos payloads do scraper, realizando o ciclo automático de sobrescrita.

---

### Frontend (React / TypeScript)

---

#### [MODIFY] [SazonalidadeNacional.tsx](file:///home/pedroeduardo/projetos/quero_comprar_vg/frontend/src/components/SazonalidadeNacional.tsx)

- Exibir indicação visual sutil (ex: um pequeno ponto ou borda estilizada) quando o mês for preenchido via forecast preditivo `2024+2025`, incluindo tooltip explicativo:
  - Dado Real: `"Coletado em 15/07/2026 via CEASA/CONAB"`
  - Forecast: `"Previsão baseada no histórico 2024 com ajuste de tendência 2025"`

---

## Verification Plan

### Automated Tests

```bash
# 1. Compilação TypeScript do Frontend
npx tsc --noEmit --project frontend/tsconfig.json

# 2. Testes de integração do Pipeline Backend
python3 -m pytest backend/tests/ -v
```

### Script de Validação SQL da Grade Pós-Fix

```python
python3 -c "
import asyncio, asyncpg, dotenv, os
dotenv.load_dotenv('backend/.env')

async def val():
    conn = await asyncpg.connect(os.getenv('DATABASE_URL_ETL'))

    # 1. Executa o pipeline de carga e forecast v13
    await conn.execute('CALL staging.sp_executar_carga_completa()')

    # 2. Checa a grade sazonal nacional de 2026
    rows = await conn.fetch('SELECT * FROM mart.fn_br_nacional_sazonalidade(2026, NULL, 1)')

    prod_map = {}
    for r in rows:
        prod_map.setdefault(r['produto'], set()).add(r['mes'])

    completos = sum(1 for m in prod_map.values() if len(m) == 12)
    incompletos = sum(1 for m in prod_map.values() if len(m) < 12)

    print('=== VALIDAÇÃO DA GRADE SAZONAL 2026 (PÓS-FORECAST V13) ===')
    print(f'Total de produtos na grade: {len(prod_map)}')
    print(f'Produtos 100% preenchidos (12/12 meses): {completos} ({completos/len(prod_map)*100:.1f}%)')
    print(f'Produtos com espaços cinzas/gaps: {incompletos}')

    await conn.close()

asyncio.run(val())
"
```

### Critérios de Aceite Sênior

1. **0 Espaços Cinzas**: 100% dos produtos exibem 12 meses preenchidos na Grade Sazonal 2026.
2. **Preservação de Dados Reais**: Jan–Jul/2026 mantém dados reais do scraper (`is_forecast=FALSE`).
3. **Sobrescrita Automática**: Ao simular carga de um novo mês real, o forecast daquele mês vira dado real instantaneamente.
