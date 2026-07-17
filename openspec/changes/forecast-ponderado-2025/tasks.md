# Tasks: Forecast Ponderado 2025

## Task 1: Add baseline_25_26 DDL after existing baseline_24_25 section  [x]
- **File**: `database/30_engine_preditiva_forecast_2026.sql`
- **Location**: Section 2, immediately before line 65 (`DROP TABLE IF EXISTS mart.sazonalidade_baseline_24_25;`)
- **Change**: Insert DDL block identical to `baseline_24_25` but targeting `mart.sazonalidade_baseline_25_26`, filtering years 2025-2026 instead of 2024-2025
- **Details**:
  - `fonte` column value = `'BASELINE_25_26'`
  - Add matching COMMENT and CREATE INDEX blocks
  - Identical columns: `id_produto`, `id_localidade`, `mes`, `status_cor_mode`, `confianca`, `fonte`, `atualizado_em`
- **Spec ref**: R-ADD-01
- **Verification**: Run `SELECT COUNT(*) FROM mart.sazonalidade_baseline_25_26` after executing the script — returns rows > 0
- **Acceptance**: Table exists with MODE computed from 2025+2026 real data only (`is_forecast = FALSE`)
## Task 2: Replace CTE `baseline_24_25` with `baseline_ponderado` inside SP  [x]

- **File**: `database/30_engine_preditiva_forecast_2026.sql`
- **Location**: SP body Section 3, CTE 1 (lines 128-136) and all downstream references
- **Change**: Three coordinated edits:
  1. **CTE replacement**: Replace `baseline_24_25` CTE with `baseline_ponderado` — FULL JOIN `sazonalidade_baseline_25_26` and `sazonalidade_baseline_24_25`, CASE-based confidence weighting (primary >= 30 wins, fallback * 0.5, else 0)
  2. **produtos_com_baseline**: Change FROM to reference `baseline_ponderado` instead of `baseline_24_25`
  3. **projecao_faltantes**: Change JOIN to reference `baseline_ponderado` instead of `baseline_24_25`; remove `WHERE b.confianca >= 25`; change `metodo_calculo` and `forecast_method` from `'gamma_forecast_baseline'` to `'beta_weighted_25_24'`
- **Spec ref**: R-ADD-02, R-ADD-03, R-MOD-01, R-MOD-03
- **Verification**: Inspect SP source — `baseline_ponderado` CTE exists, no reference to bare `baseline_24_25` CTE, no `confianca >= 25` filter
- **Acceptance**:
  - S1: Products with complete 2025+2026 data use primary confidence (>= 30)
  - S2: Products with partial coverage use primary where available, fallback * 0.5 for gaps
  - S3: Products only in 2024 baseline use fallback * 0.5
  - S4: Products in neither baseline are excluded from forecast grid
  - S6: Products with confianca < 30 in 25-26 but > 0 in 24-25 use fallback * 0.5

## Task 3: Add `beta_weighted_25_24` to CHECK constraint  [x]
- **File**: `database/30_engine_preditiva_forecast_2026.sql`
- **Location**: Section 1, lines 47-49
- **Change**: Replace the existing ALTER TABLE ADD CONSTRAINT block (lines 46-49) with DROP + recreate, adding `'beta_weighted_25_24'` to the allowed IN list
- **Current values**: `'gamma_forecast_baseline'`, `'alpha_baseline_25_26'`, `'beta_media_disponivel'`
- **New values**: add `'beta_weighted_25_24'`
- **Spec ref**: R-MOD-02
- **Verification**: Run `INSERT INTO mart.sazonalidade_produto (...) VALUES (... 'beta_weighted_25_24')` — succeeds without constraint violation (then rollback)
- **Acceptance**: CHECK constraint allows the new method value

## Task 4: Run CALL and verify end-to-end  [x]
- **Command**: Execute the full script file, then `CALL staging.sp_calcular_forecast_2026()`
- **Verification queries**:
  1. `SELECT DISTINCT forecast_method FROM mart.sazonalidade_produto WHERE is_forecast = TRUE` — must include `'beta_weighted_25_24'`
  2. `SELECT COUNT(*) FROM mart.sazonalidade_produto WHERE data_referencia_atual LIKE '2026-%' AND is_forecast = TRUE` — rows exist with new method
  3. Spot-check a product with confianca < 30 in baseline_25_26 but > 0 in baseline_24_25: verify it used fallback (`baseline_confianca = baseline_24_25.confianca * 0.5`)
  4. Confirm Jan-Jul 2026 real data (`is_forecast = FALSE`) is unchanged — counts match previous run
  5. Confirm MV refresh succeeded: `SELECT COUNT(*) FROM mart.vw_api_produtos_sazonalidade` returns rows
- **Spec ref**: R-MOD-04 (UPSERT unchanged + MV refresh)
- **Acceptance**: All queries pass; real data preserved; new projection method visible

## Review Workload Forecast
- **Total changed lines**: ~80-100 (all in one existing file)
- **400-line budget risk**: Low
- **Chained PRs recommended**: No
- **Decision needed before apply**: No
