# Proposal: Forecast Ponderado 2025

## Intent

Replace the flat 24-month baseline (2024+2025 averaged with equal weight) with a weighted approach that prioritizes recent data. As of July 2026, the current `gamma_forecast_baseline` method polls all months from 2024–2025 with zero weighting, but 2024 covers only 51 of ~180 products and 8 UFs have zero 2024 data — dragging the MODE with stale or absent signals and degrading forecast quality for Aug–Dec 2026.

The new `beta_weighted_25_24` method weights 2025+2026 data higher than 2024, producing a sharper MODE that reflects current price behavior without discarding 2024 entirely as a fallback for products with short 2025 coverage.

## Scope

| In scope | Out of scope |
|----------|-------------|
| New baseline table `mart.sazonalidade_baseline_25_26` | ProHort ETL modifications |
| SP modification: add `beta_weighted_25_24` method | ML model training or inference |
| Refresh of `mart.vw_api_produtos_sazonalidade` | Frontend changes |
| Rastreabilidade: `forecast_method` = `beta_weighted_25_24` | Any `flows.json` changes |
| Backward-compat: keep old `sazonalidade_baseline_24_25` untouched | |

## Approach

### Phase 1 — New baseline table `mart.sazonalidade_baseline_25_26`

Compute MODE of `status_cor` by `(produto, localidade, mes)` using only **real** rows (`is_forecast = FALSE`) from 2025 AND 2026 (Jan–Jul). This gives 19 months of denser coverage. The existing `confianca` column reflects confidence within this window only.

### Phase 2 — Weighted forecast method `beta_weighted_25_24`

Inside `sp_calcular_forecast_2026()`, a new CTE `baseline_ponderado` replaces the single `baseline_24_25` lookup:

- **Primary**: `sazonalidade_baseline_25_26` — the default source for MODE, confianca, and `forecast_method = 'beta_weighted_25_24'`.
- **Weighted fallback**: when `baseline_25_26` has no row for a given `(produto, localidade, mes)` OR its confidence < 30, fall back to `sazonalidade_baseline_24_25` and mark `forecast_method = 'beta_weighted_25_24'` as well (same method, different effective weight).
- **Confidence score**: computed as `COALESCE(bl_25_26.confianca, bl_24_25.confianca * 0.5, 0)` — giving 2024 half weight when used solo.
- **No baseline at all**: product falls out of the forecast grid (no projection).

### Phase 3 — Refresh MV

Existing UPSERT logic already handles substitution of real data over projections via `is_forecast = FALSE`. Only the MV refresh call within the SP is needed; no DDL changes.

## Risks

1. **Low 2025+2026 coverage for late-entering products**: some products may have only 2–3 months of 2025+2026 data. The 30% confidence floor prevents projections with insufficient signal — same guard as the `confianca >= 25` in the current code, but now applied to the primary baseline only.
2. **2024 fallback with half confidence**: products that exist only in 2024 will project with halved confidence. Acceptable tradeoff — better than losing them entirely, and the API already exposes `baseline_confianca` so the frontend can sort/filter.
3. **Migration cost**: one-time `DROP/CREATE TABLE` for the new baseline, no data loss. The old table remains untouched for audit.

## Next Step

Ready for **spec phase**: write delta spec with acceptance scenarios covering single-source, blended, and zero-coverage cases.
