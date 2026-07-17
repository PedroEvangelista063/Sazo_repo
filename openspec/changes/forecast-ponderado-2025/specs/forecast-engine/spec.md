# Delta Spec: Forecast Ponderado 2025 — Weighted Baseline

**Change**: `forecast-ponderado-2025`
**Capability**: Forecast Engine
**Type**: MODIFIED — method substitution within existing SP
**Base Spec**: N/A (first formal spec for this capability)
**Status**: DRAFT

---

## Overview

Replace the flat 24-month baseline (2024+2025 weighted equally) with a two-tier weighted approach: primary baseline `sazonalidade_baseline_25_26` (2025+2026 real data only, 19 months) and fallback baseline `sazonalidade_baseline_24_25` with halved confidence. All projected rows use `forecast_method = 'beta_weighted_25_24'`.

---

## ADDED Requirements

### R-ADD-01: Baseline 25-26 table
`mart.sazonalidade_baseline_25_26` SHALL be created with the identical schema as `mart.sazonalidade_baseline_24_25` (`id_produto`, `id_localidade`, `mes`, `status_cor_mode`, `confianca`, `fonte`, `atualizado_em`). The MODE SHALL be computed over real rows (`is_forecast = FALSE`) from years 2025 AND 2026 only. `confianca` SHALL reflect coverage within this 19-month window.

### R-ADD-02: Weighted fallback logic
When `baseline_25_26` has no row for a given `(produto, localidade, mes)` OR its `confianca < 30`, the SP MUST fall back to `sazonalidade_baseline_24_25` with `confianca * 0.5`. The effective confidence SHOULD be `COALESCE(primary.confianca, fallback.confianca * 0.5, 0)`.

### R-ADD-03: Silent exclusion for zero-baseline products
Products with no row in EITHER baseline table MUST be excluded from the forecast grid entirely. They SHALL NOT appear in `projecao_faltantes`.

---

## MODIFIED Requirements

### R-MOD-01: SP forecast method
`staging.sp_calcular_forecast_2026()` SHALL replace the single `baseline_24_25` CTE with a `baseline_ponderado` CTE implementing R-ADD-02. The `produtos_com_baseline` derivation MUST now check the weighted view instead of a single table.

### R-MOD-02: forecast_method check constraint
The `CHECK` constraint on `mart.sazonalidade_produto.forecast_method` SHALL include `'beta_weighted_25_24'` in the allowed values list.

### R-MOD-03: Confiança minimum floor
The current `WHERE confianca >= 25` guard SHALL be replaced by the logic in R-ADD-02. No explicit numeric floor on the final effective confidence is required — if fallback also yields zero, the product is excluded per R-ADD-03.

### R-MOD-04: UPSERT unchanged
The UPSERT logic (`real sempre vence projeção`) MUST remain identical. The MV refresh (`REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade`) SHALL remain as the final step.

---

## Scenarios

### S1: Product with complete 2025+2026 data (19 months)
**Given** produto P has real data in all 19 months of 2025+2026 for (localidade, mes)
**When** `sp_calcular_forecast_2026()` runs
**Then** all projected months use `status_cor_mode` from `baseline_25_26` exclusively, `forecast_method = 'beta_weighted_25_24'`, `baseline_confianca >= 30`

### S2: Partial 2025+2026, full 2024 coverage
**Given** produto Q has 6 months in 2025+2026 and 24 months in 2024 for (localidade, mes)
**When** forecast runs
**Then** months WITH 25-26 baseline use primary; months WITHOUT use fallback `baseline_24_25` with `confianca * 0.5`; all projected rows carry `forecast_method = 'beta_weighted_25_24'`

### S3: Product exists only in 2024 baseline
**Given** produto R has zero 2025+2026 real data, but exists in `baseline_24_25`
**When** forecast runs
**Then** every projected month uses fallback with `baseline_confianca = baseline_24_25.confianca * 0.5`, `forecast_method = 'beta_weighted_25_24'`

### S4: Product with zero baseline coverage
**Given** produto S has no row in either baseline table
**When** forecast runs
**Then** S is absent from `projecao_faltantes` — no projection is generated for any month

### S5: Real data replaces existing projection (UPSERT)
**Given** produto T has a projected row `(is_forecast = TRUE)` for 2026-08
**When** scraper inserts a real row `(is_forecast = FALSE)` for the same `(produto, localidade, 2026-08)`
**Then** UPSERT sets `is_forecast = FALSE`, `forecast_method = NULL`, real column values override projections

### S6: Primary confidence below 30%
**Given** produto U has `confianca = 18` in `baseline_25_26` for a given `(localidade, mes)` but `confianca = 80` in `baseline_24_25`
**When** forecast runs
**Then** the fallback value is used with `baseline_confianca = 40` (80 * 0.5), `forecast_method = 'beta_weighted_25_24'`

---

## Traceability

| Req | Scenarios | Proposal Ref |
|-----|-----------|-------------|
| R-ADD-01 | S1, S2 | Phase 1 |
| R-ADD-02 | S2, S3, S6 | Phase 2 §"Weighted fallback" |
| R-ADD-03 | S4 | Phase 2 §"No baseline at all" |
| R-MOD-01 | S1–S6 | Phase 2 |
| R-MOD-02 | S1, S2, S3, S6 | Phase 2 §"forecast_method" |
| R-MOD-03 | S6 | Phase 2 §30% floor |
| R-MOD-04 | S5 | Phase 3 |
