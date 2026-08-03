# Delta Spec: Dados Históricos Reais — Anchor-Year Fallback with Provenance

**Change**: `refatoracao-dado-historico`
**Capability**: `dados-historicos-reais`
**Type**: NEW — first formal spec (Base Spec: N/A, per repo convention)
**Status**: DRAFT

---

## Overview

Replace synthetic projections (Sazonal Sandwich `sp_project_sandwich_prices_2026`, V13 `sp_calcular_forecast_2026_v13`) with REAL historical data: `mart.sazonalidade_produto` gains transparency columns, MV V17 (`mart.vw_api_produtos_sazonalidade`) is recreated projecting real values with anchor-year provenance, and `sp_executar_carga_completa` stops invoking the synthetic engines. "Dado real" = rows without `fonte='FLUXO_PROXY'`; proxy rows are display-excluded and used only as a minimum, provenance-marked fallback.

---

## ADDED Requirements

### R-ADD-01: Transparency columns on mart.sazonalidade_produto

Migration `database/63_*.sql` SHALL add to `mart.sazonalidade_produto`: `ano_referencia` (INTEGER), `tipo_dado` (TEXT, constrained to `'REAL_ATUAL' | 'HISTORICO_BASE' | 'FALLBACK_DIMENSAO'`), `metadado_transparencia` (JSONB), `idade_dado_anos` (INTEGER = `ANO_ATUAL - ano_referencia`). `ANO_ATUAL` SHALL be computed as `EXTRACT(YEAR FROM CURRENT_DATE)` — never hardcoded.

### R-ADD-02: preco_exibido / preco_referencia semantics

`preco_exibido` SHALL hold the last real collected price for the anchor month of the `(id_produto, id_localidade, mes)` tuple, with NO synthetic multiplier applied. `preco_referencia` SHALL hold the REAL equivalent reference price for the same product/localidade used as the comparison basis.

### R-ADD-03: Anchor-year fallback chain

For each `(id_produto, id_localidade, mes)`, the system SHALL select the newest real row with priority N → N-1 → N-2 (in year 2026: 2026 → 2025 → 2024). If no real row exists in N, N-1, or N-2, the tuple SHALL fall back to the dimension-derived value with `tipo_dado = 'FALLBACK_DIMENSAO'`.

### R-ADD-04: FLUXO_PROXY exclusion

Rows with `fonte = 'FLUXO_PROXY'` SHALL NOT be selected as `REAL_ATUAL` or `HISTORICO_BASE`. Proxy SHALL be used ONLY as `FALLBACK_DIMENSAO`, and ONLY when no real historical row exists for the tuple; `metadado_transparencia` SHALL mark proxy provenance in that case.

### R-ADD-05: MV V17 transparency projection

`mart.vw_api_produtos_sazonalidade` SHALL be recreated projecting: `preco_exibido`, `preco_referencia`, `variacao_pct`, `status_cor`, `ano_referencia`, `tipo_dado`, `idade_dado_anos`. The semáforo `status_cor` SHALL compare `preco_exibido` against the REAL equivalent reference (same product/localidade) using the existing ±25% rule — never against a synthetic value.

### R-ADD-06: Synthetic engine deactivation in pipeline

`sp_executar_carga_completa` (in `database/62_engine_forecast_2024_2025_v13.sql`, calls at L816 V13 and L828 sandwich) SHALL no longer invoke the sandwich or V13 procedures. The synthetic scripts SHALL remain in the repository deactivated (audit trail); the pipeline SHALL simplify to extract → clean → store real slice → `REFRESH MATERIALIZED VIEW`.

### R-ADD-07: Constraint preservation

The migration SHALL preserve both existing mart UNIQUE constraints `(id_produto, id_localidade, ano, mes)` and `(id_produto, id_localidade, data_referencia_atual)`, and the CHECK constraint `data_referencia_atual` format `YYYY-MM` (migration 57).

---

## Scenarios

### S1: Current-year real data

- GIVEN produto P has a real 2026 row for (localidade, mes)
- WHEN the mart is loaded and MV V17 refreshed
- THEN the tuple gets `tipo_dado='REAL_ATUAL'`, `ano_referencia=2026`, `idade_dado_anos=0`

### S2: Only prior-year (N-1) real data

- GIVEN produto Q has real rows only for 2025 (no 2026 data)
- WHEN the mart is loaded
- THEN the tuple gets `tipo_dado='HISTORICO_BASE'`, `ano_referencia=2025`, `idade_dado_anos=1`, and `preco_exibido` equals the real 2025 price (no multiplier)

### S3: Only N-2 real data

- GIVEN produto R has real rows only for 2024
- WHEN the mart is loaded
- THEN the tuple gets `tipo_dado='HISTORICO_BASE'`, `ano_referencia=2024`, `idade_dado_anos=2`

### S4: No real history at all

- GIVEN produto S has no real row in N, N-1, or N-2 for the tuple
- WHEN the mart is loaded
- THEN the tuple gets `tipo_dado='FALLBACK_DIMENSAO'` and `metadado_transparencia` records the fallback reason and proxy provenance if a proxy row was used

### S5: Year-boundary behavior (January of current year)

- GIVEN today is 2026-01-10 and only 2025 real data exists for the tuple
- WHEN the mart is loaded
- THEN the system does NOT wait for 2026 data; it anchors to 2025 (`HISTORICO_BASE`, `ano_referencia=2025`, `idade_dado_anos=1`)

### S6: Dynamic anchor recomputation across years

- GIVEN the system runs in calendar year 2027 with real data for 2026 and 2027
- WHEN the mart is loaded
- THEN the anchor chain resolves as 2027 → 2026 → 2025 with `ANO_ATUAL=2027`, requiring no code change (no hardcoded constants)

### S7: Proxy never primary

- GIVEN a tuple has both a real 2025 row and a `FLUXO_PROXY` 2026 row
- WHEN the mart is loaded
- THEN `tipo_dado='HISTORICO_BASE'` anchors to 2025 (`ano_referencia=2025`); the proxy row is NOT selected and does NOT appear in the MV

### S8: Forecasts do not regenerate on next load

- GIVEN `sp_executar_carga_completa` previously regenerated synthetic rows each load
- WHEN the pipeline runs after migration `database/63_*.sql`
- THEN sandwich and V13 are not called; no `is_forecast` rows or synthetic multipliers are (re)generated

### S9: Semáforo compared against real reference

- GIVEN a tuple with `preco_exibido` from 2025 and a real `preco_referencia` for the same product/localidade
- WHEN `status_cor` is computed
- THEN the ±25% rule compares `preco_exibido` against that REAL reference; a synthetic or proxy value is never the comparison basis

### S10: Constraints survive migration

- GIVEN the dual UNIQUEs and the `YYYY-MM` CHECK exist before migration
- WHEN `database/63_*.sql` is applied
- THEN both UNIQUE constraints and the CHECK remain enforceable and no duplicate tuples are admitted

---

## Traceability

| Req      | Scenarios  | Proposal Ref                                 |
| -------- | ---------- | -------------------------------------------- |
| R-ADD-01 | S1–S4, S6  | Key Requirements §mandatory metadata columns |
| R-ADD-02 | S2, S3, S9 | Key Requirements §preco_exibido semantics    |
| R-ADD-03 | S1–S6      | Key Requirements §anchor-year fallback       |
| R-ADD-04 | S4, S7     | Authoritative decision 1                     |
| R-ADD-05 | S9         | Key Requirements §MV V17 columns             |
| R-ADD-06 | S8         | Authoritative decision 5                     |
| R-ADD-07 | S10        | Key Requirements §respect constraints        |
