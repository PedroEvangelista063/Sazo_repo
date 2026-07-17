# Design: Forecast Ponderado 2025

## Overview

Replace the flat single-table baseline (`sazonalidade_baseline_24_25`) with a two-tier weighted approach inside the existing SP. A new baseline table covering 2025+2026 real data serves as primary; the old 2024-2025 table acts as fallback with halved confidence. No schema changes to `mart.sazonalidade_produto` beyond the CHECK constraint.

## Architecture

### Phase 1: New baseline table `mart.sazonalidade_baseline_25_26`

```sql
DROP TABLE IF EXISTS mart.sazonalidade_baseline_25_26;

CREATE TABLE mart.sazonalidade_baseline_25_26 AS
WITH dados_reais AS (
    SELECT
        s.id_produto,
        s.id_localidade,
        CAST(SPLIT_PART(s.data_referencia_atual, '-', 2) AS INTEGER) AS mes,
        s.status_cor,
        COUNT(*) AS freq
    FROM mart.sazonalidade_produto s
    WHERE CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER) IN (2025, 2026)
      AND s.is_forecast = FALSE
    GROUP BY s.id_produto, s.id_localidade, mes, s.status_cor
),
moda_por_mes AS (
    SELECT DISTINCT ON (id_produto, id_localidade, mes)
        id_produto,
        id_localidade,
        mes,
        status_cor AS status_cor_mode,
        freq,
        SUM(freq) OVER (PARTITION BY id_produto, id_localidade, mes) AS total_meses
    FROM dados_reais
    ORDER BY id_produto, id_localidade, mes, freq DESC
)
SELECT
    id_produto,
    id_localidade,
    mes,
    status_cor_mode,
    ROUND((freq::NUMERIC / total_meses) * 100, 2) AS confianca,
    'BASELINE_25_26' AS fonte,
    NOW() AS atualizado_em
FROM moda_por_mes;
```

Identical schema to `baseline_24_25`. MODE computed over years 2025 AND 2026 (real only). Overwrite on each SP run — ephemeral derived data.

### Phase 2: Weighted CTE `baseline_ponderado` inside SP

Replace CTE 1 in `sp_calcular_forecast_2026()`:

```sql
WITH baseline_ponderado AS (
    SELECT
        COALESCE(bl_25_26.id_produto, bl_24_25.id_produto) AS id_produto,
        COALESCE(bl_25_26.id_localidade, bl_24_25.id_localidade) AS id_localidade,
        COALESCE(bl_25_26.mes, bl_24_25.mes) AS mes,
        COALESCE(bl_25_26.status_cor_mode, bl_24_25.status_cor_mode) AS status_cor_mode,
        CASE
            WHEN bl_25_26.status_cor_mode IS NOT NULL AND bl_25_26.confianca >= 30
                THEN bl_25_26.confianca
            WHEN bl_24_25.status_cor_mode IS NOT NULL
                THEN bl_24_25.confianca * 0.5
            ELSE 0
        END AS confianca,
        'beta_weighted_25_24' AS forecast_method
    FROM mart.sazonalidade_baseline_25_26 bl_25_26
    FULL JOIN mart.sazonalidade_baseline_24_25 bl_24_25
        ON bl_25_26.id_produto = bl_24_25.id_produto
       AND bl_25_26.id_localidade = bl_24_25.id_localidade
       AND bl_25_26.mes = bl_24_25.mes
)
```

- FULL JOIN to capture rows present in either table.
- Primary wins when present AND confianca >= 30.
- Fallback applies when primary absent or below threshold, with halved confidence.
- `produtos_com_baseline` derives from this CTE instead of a single table.

The old explicit `WHERE confianca >= 25` guard is removed — the CASE in `baseline_ponderado` replaces it. Products with zero rows in both tables are naturally excluded (FULL JOIN produces nothing for them).

### Phase 3: ALTER CHECK constraint

```sql
ALTER TABLE mart.sazonalidade_produto
    DROP CONSTRAINT IF EXISTS sazonalidade_produto_forecast_method_check;

ALTER TABLE mart.sazonalidade_produto
    ADD CONSTRAINT sazonalidade_produto_forecast_method_check
    CHECK (forecast_method IS NULL
           OR forecast_method IN (
               'gamma_forecast_baseline',
               'alpha_baseline_25_26',
               'beta_media_disponivel',
               'beta_weighted_25_24'
           ));
```

Add `'beta_weighted_25_24'` to the allowed values list.

## Data Flow

1. `sp_calcular_forecast_2026()` runs baseline DDL: drops/recreates `sazonalidade_baseline_25_26` from 2025+2026 real data
2. CTE `baseline_ponderado` merges both baseline tables via FULL JOIN with weighted confidence
3. `produtos_com_baseline` selects DISTINCT (produto, localidade) from `baseline_ponderado`
4. `projecao_faltantes` joins missing months against `baseline_ponderado` — no explicit confianca filter (weighting is embedded in the CTE)
5. UPSERT inserts/updates `mart.sazonalidade_produto` with `forecast_method = 'beta_weighted_25_24'` for all projected rows
6. REFRESH MATERIALIZED VIEW CONCURRENTLY as final step

Real data (`is_forecast = FALSE`) still wins on UPSERT conflict per existing logic — unchanged.

## Migration Steps

1. Run DDL: `CREATE TABLE mart.sazonalidade_baseline_25_26 AS ...`
2. Run ALTER TABLE to add `'beta_weighted_25_24'` to CHECK constraint
3. `CREATE OR REPLACE PROCEDURE staging.sp_calcular_forecast_2026()` with new CTE
4. `CALL staging.sp_calcular_forecast_2026()` to recalculate
5. Verify: `SELECT DISTINCT forecast_method FROM mart.sazonalidade_produto WHERE is_forecast = TRUE` should include `beta_weighted_25_24`
6. Verify scenario S6: check a product with confianca < 30 in 25-26 but > 0 in 24-25 fallback

## Rollback

1. Revert the SP to the previous version (from git)
2. Drop the new baseline table: `DROP TABLE IF EXISTS mart.sazonalidade_baseline_25_26`
3. Revert CHECK constraint to original values
4. Re-run `CALL staging.sp_calcular_forecast_2026()`
5. All rows revert to `gamma_forecast_baseline` method

Both baseline tables coexist during rollback — no data loss.

## Files Changed

| File | Change |
|------|--------|
| `database/30_engine_preditiva_forecast_2026.sql` | Add DDL for `sazonalidade_baseline_25_26` + modify SP with `baseline_ponderado` CTE + alter CHECK constraint |
