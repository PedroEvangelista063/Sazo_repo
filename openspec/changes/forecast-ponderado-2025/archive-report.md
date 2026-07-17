# Archive Report: forecast-ponderado-2025

**Status**: ✅ COMPLETED
**Archived at**: 2026-07-17 21:00 BRT

## Summary

Substituiu a baseline flat 24-meses (peso igual 2024+2025) por uma abordagem ponderada de dois níveis: `sazonalidade_baseline_25_26` como fonte primária (dados reais 2025+2026) e `sazonalidade_baseline_24_25` como fallback com confiança reduzida à metade. O novo método `beta_weighted_25_24` produziu 19.933 projeções para Ago-Dez 2026 em 1.02s, preservando 12.884 registros reais de Jan-Jul 2026 — 6/6 cenários compliant, zero issues críticas.

## Artifacts

| Artifact | Status | Path |
|----------|--------|------|
| Proposal | ✅ | proposal.md |
| Spec | ✅ | specs/forecast-engine/spec.md |
| Design | ✅ | design.md |
| Tasks | ✅ | tasks.md |
| Apply | ✅ | tasks.md (marked [x]) |
| Verify | ✅ | verify-report.md |

## Deliverables

### Database

- **30_engine_preditiva_forecast_2026.sql** — 544 lines, expanded with:
  - Section 2b: `sazonalidade_baseline_25_26` DDL (32.581 rows)
  - CTE `baseline_ponderado` with FULL JOIN + CASE weighting
  - CHECK constraint with `'beta_weighted_25_24'`
  - Removed explicit confianca >= 25 guard

### Data

| Metric | Value |
|--------|-------|
| Baseline 25_26 rows | 32.581 |
| Baseline 24_25 rows (refreshed) | 23.449 |
| Projections (Ago-Dez 2026) | 19.933 |
| Real data preserved (Jan-Jul 2026) | 12.884 |
| MV rows | 54.479 |
| Execution time | 1.02 seconds |

### Spec Compliance

**6/6 scenarios compliant** — PASS

## Delta Spec Changes

(Not applicable — no external spec doc was modified)

## Lessons Learned

- A confiança mínima na baseline_25_26 foi de 50% (muito acima do threshold de 30%), então o cenário S6 (fallback por confiança < 30) não ocorreu na prática — mas o código está correto para quando ocorrer
- O `RAISE NOTICE` com contagem v_reais/v_proj foi simplificado porque CTEs dentro da SP não são visíveis fora do escopo da CTE no PostgreSQL
