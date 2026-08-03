# Proposal: Refatoração Dado Histórico — Stop Synthetic Forecasts, Show Real Historical Data with Transparency

## Intent

Product/audit directive: the current seasonal experience is built on **synthetic projections** — the Sazonal Sandwich procedure (`staging.sp_project_sandwich_prices_2026`, V7 lineage in `57_expurgo_e_recalibragem.sql`) and the V13 forecast engine (`staging.sp_calcular_forecast_2026_v13`, `database/62_engine_forecast_2024_2025_v13.sql`). These extrapolate prices with multipliers from `staging.fact_precos_mensais` rows marked `fonte='FLUXO_PROXY'` and projected rows, degrading credibility.

This change replaces projections with **REAL historical data** plus **temporal transparency**: when no real data exists for the current year, show the last real collected price (N-1 / N-2) **without synthetic multipliers**, explicitly informing the user of the **Anchor Year** and **provenance** through a transparency UI (circled `(i)` icon → tooltip/popover).

### Authoritative product decisions (do not reopen)

1. **"Dado real"** = rows WITHOUT `fonte='FLUXO_PROXY'` in `staging.fact_precos_mensais` / mart provenance. FLUXO_PROXY rows are EXCLUDED from display. Proxy is used only as MINIMUM fallback for a `(produto, localidade, mes)` tuple with no real history, explicitly marked in transparency metadata.
2. **Dynamic anchor year**: `ANO_ATUAL = EXTRACT(YEAR FROM CURRENT_DATE)`, priority N → N-1 → N-2 (in 2026: 2026 → 2025 → 2024). NOT hardcoded constants.
3. **B2C R$ price ban KEPT** (`backend/app/schemas/responses.py:7-11`): B2C payloads carry NO monetary R$ values. Seasonal grid shows semáforo + badges + `(i)` tooltip (year/type/defasagem). R$ restricted to internal/admin panel.
4. **Scope**: recreate ONLY `mart.vw_api_produtos_sazonalidade` (V17). `vw_mapa_regional_completo` is DEFERRED (no consumers) — non-goal/future phase.
5. **Cleanup**: remove sandwich + V13 calls from `sp_executar_carga_completa` (`database/62_engine_forecast_2024_2025_v13.sql:816-832` and guarded calls), KEEP synthetic scripts in repo (deactivated, audit trail). Pipeline simplifies to extract → clean → store real slice → `REFRESH MATERIALIZED VIEW`.

## Scope

| In scope                                                                                        | Out of scope                                                   |
| ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| Migration `database/63_*.sql`: new transparency columns + MV V17 recreation + pipeline cleanup  | `vw_mapa_regional_completo` (deferred, no consumers)           |
| Backend: optional transparency fields in API schemas + endpoints (sazonalidade, regioes, cards) | B2C display of R$ prices (kept banned)                         |
| Frontend: `DataTransparencyInfo` component, gray-cell removal, year badges, `(i)` tooltip       | Deleting synthetic SPs (kept deactivated as audit trail)       |
| Cache invalidation keys update + cache purge                                                    | New forecasting / ML training                                  |
| Deactivate synthetic generation (sandwich/V13) in pipeline                                      | Physical deletion of FLUXO_PROXY rows (display semantics only) |

## Key Requirements

- **Anchor-year fallback** (per produto/localidade/mes): N real → N-1 real → N-2 real → dimension fallback, each with provenance metadata. `tipo_dado` ∈ `'REAL_ATUAL' | 'HISTORICO_BASE' | 'FALLBACK_DIMENSAO'`.
- **Mandatory metadata columns**: `ano_referencia` (INTEGER), `tipo_dado` (TEXT), `metadado_transparencia` (JSONB), `idade_dado_anos` (`ANO_ATUAL - ano_referencia`).
- **MV V17 columns**: `preco_exibido`, `preco_referencia`, `variacao_pct`, `status_cor`, `ano_referencia`, `tipo_dado`, `idade_dado_anos`.
- **Semáforo ±25%**: compared between `preco_exibido` and the REAL equivalent reference of the same produto/localidade.
- Respect BOTH existing mart UNIQUEs `(id_produto,id_localidade,ano,mes)` and `(id_produto,id_localidade,data_referencia_atual)` + CHECK `data_ref=ano-mes` (`57`).

## API Contract

New fields on `ProdutoSazonalResponse` (and product-card schemas): `ano_referencia`, `tipo_dado`, `mensagem_transparencia`, `is_dado_legado` — **optional/defaulted** to avoid breaking consumers (SazonalidadeNacional, TabelaView, GraficosView). `MapaRegionalResponse` deferred (non-goal). No R$ fields added to B2C.

## Approach

1. **DB (`database/63_*.sql`)**: remove sandwich (L825-828) + V13 (L816) calls from `sp_executar_carga_completa`; add `ano_referencia`, `tipo_dado`, `metadado_transparencia`, `idade_dado_anos`; recreate MV V17 following the `36_fix_dedup_dim_localidade.sql` pattern (DROP + CREATE + 7 indexes + grants).
2. **Backend**: read transparency columns via asyncpg raw SQL (no ORM); expose optional fields.
3. **Frontend**: `DataTransparencyInfo.tsx` (lucide-react `Info` icon 0.460 / Mantine Tooltip/Popover ^9.4.1); replace gray cells with real-data fill; year badges (`'25`/`'24`); card footer with apuração year; map/polo tooltips where applicable.
4. **Cache**: invalidate `['br-sazonalidade', ano]`, `['hortifruti-meta', uf]`, `['hortifruti-filter', uf, ano, mes]`, `['sazonalidade-com-preco', ...]`, `['regiao-resumo', regiaoId, ano]`; purge via `POST /admin/cache/clear` (`X-API-Key: internal_api_key`).

## Capabilities

> `openspec/specs/` has no main specs yet — every delta below is a FIRST formal spec (Base Spec: N/A, per repo convention).

### New Capabilities

- `dados-historicos-reais`: anchor-year fallback rules, real-vs-proxy semantics, MV V17 transparency columns, `tipo_dado`/`metadado_transparencia` contract.
- `transparencia-dados-ui`: `DataTransparencyInfo` component, gray-cell removal, year badges, `(i)` tooltip content, card footer.

### Modified Capabilities

- `sazonalidade-api`: optional `ano_referencia`/`tipo_dado`/`mensagem_transparencia`/`is_dado_legado` fields on B2C responses (first formal spec; behavior-additive only).

## Affected Areas

| Area                                                     | Impact   | Description                                                                |
| -------------------------------------------------------- | -------- | -------------------------------------------------------------------------- |
| `database/63_*.sql` (new)                                | New      | Columns + MV V17 recreation + pipeline step removal                        |
| `database/62_engine_forecast_2024_2025_v13.sql`          | Modified | Calls removed at L816-832 (file kept, audit trail)                         |
| `supabase/migrations/000021_*` (new, track TBD)          | New      | Mirror of 63 / drift resolution (open decision)                            |
| `backend/app/schemas/responses.py`                       | Modified | Optional transparency fields (L38-101, 144-173, 215-223, 278)              |
| `backend/app/api/v1/endpoints/produtos.py`               | Modified | Raw-SQL reads of new MV columns (L195-238, 360-386, 783-810)               |
| `frontend/src/components/SazonalidadeNacional.tsx`       | Modified | Gray cells (L22-33) → real fill; tooltips (L129-134, 159-213) → (i)        |
| `frontend/src/components/DataTransparencyInfo.tsx` (new) | New      | Tooltip/popover with year/type/defasagem                                   |
| `frontend/src/pages/SupermercadoView.tsx`                | Modified | Year default (L76-80), badge (L482-507), year-1 link (L508-515)            |
| `frontend/src/components/ProductCard.tsx`                | Modified | Replace 📊 Estimativa/🪄 Estimado badges (L103-129)                        |
| `frontend/src/hooks/useHortifruti.ts`                    | Modified | Cache keys/invalidation                                                    |
| `scripts/deploy_v13_prod.sh`                             | Modified | L154-159 pipeline call still valid post-cleanup; verify no V13 assumptions |
| `scripts/run_bulk_historical_fill.py`                    | Modified | L788 must NOT reintroduce V13 rows                                         |

## Impact Analysis

- **Consumers**: SazonalidadeNacional, TabelaView, GraficosView (R$ internal), SupermercadoView, ProductCard, BrasilMap/RegiaoPanel (map deferred — no impact now).
- **Migration numbering**: `database/` next is **63** (62 taken); parallel `supabase/migrations/` next is **000021**; existing `000020_fix_sanduiche_preserva_forecast_v13.sql` exists ONLY in the CLI track — **open decision for design**: sync tracks vs `database/` as source of truth.
- **Deploy**: `deploy_v13_prod.sh:154-159` still calls `sp_executar_carga_completa()` — valid post-cleanup; `run_bulk_historical_fill.py:788` must not reintroduce V13 rows.
- **B2C constraints**: no R$ leakage in new transparency fields; tooltip shows year/type/defasagem only.

## Risks

| Risk                                                                             | Likelihood | Mitigation                                                                         |
| -------------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------------------------- |
| MV V17 recalc OOM (CROSS JOIN 4.85M rows, 62 L31-38/200-226)                     | Med        | Follow 36-pattern recreation; validate on Supabase branch before prod              |
| Drift between `database/` and `supabase/migrations/` tracks (000020 only in CLI) | High       | Open decision in design: sync 000021 mirror or declare `database/` source of truth |
| Existing dual mart UNIQUEs + CHECK broken by new migration                       | Med        | Explicitly preserve both UNIQUEs and CHECK `data_ref=ano-mes`                      |
| B2C R$ leak via new fields                                                       | Low        | Optional fields carry no monetary values; schema review gate                       |
| Stale cache after MV rebuild                                                     | Med        | Purge all listed keys via `POST /admin/cache/clear` post-deploy                    |
| `run_bulk_historical_fill.py`/deploy scripts reintroducing synthetic rows        | Med        | Remove/guard V13 + sandwich calls in same change; verify grep clean                |
| Frontend consumers break on missing new fields                                   | Low        | Fields optional/defaulted; additive-only contract                                  |

## Rollback Plan

1. Restore synthetic calls in `sp_executar_carga_completa` from git history (L816-832 re-add) and re-run pipeline (SPs remain in repo, deactivated only).
2. Revert MV V17 DDL: recreate from `36_fix_dedup_dim_localidade.sql` definition; drop new columns via `database/64_rollback.sql`.
3. Frontend: revert component changes (git revert); no data contract breakage because new fields are additive/optional.
4. Purge cache keys again; verify with `/api/v1/sazonalidade?uf=SP`.

## Dependencies

- PostgreSQL 16 (Supabase) — MV recreation + migration approval on prod.
- Mantine `^9.4.1` Tooltip/Popover, lucide-react `0.460` (frontend).
- React Query cache purge endpoint `POST /admin/cache/clear` (exists).
- **Open decision (design)**: supabase track sync policy (`database/` vs `supabase/migrations/` as source of truth).

## Success Criteria

- [ ] **(a)** DDL of V17 in `database/63_*.sql` showing transparency columns (`ano_referencia`, `tipo_dado`, `metadado_transparencia`, `idade_dado_anos`, `preco_exibido`, `preco_referencia`, `variacao_pct`, `status_cor`).
- [ ] **(b)** API JSON payload example `/api/v1/sazonalidade?uf=SP` with one 2026 product (`tipo_dado='REAL_ATUAL'`) + one historical 2025/2024 product (`tipo_dado='HISTORICO_BASE'`) including transparency metadata.
- [ ] **(c)** UI: seasonal grid fully filled (no gray cells), historical real price shown, `(i)` tooltip functional (year/type/defasagem, no R$ in B2C).

## Next Step

Ready for **spec phase**: write delta specs for `dados-historicos-reais`, `transparencia-dados-ui`, `sazonalidade-api` with Given/When/Then scenarios (anchor-year fallback chain, proxy exclusion, dynamic anchor across year boundary, B2C no-price invariant).
