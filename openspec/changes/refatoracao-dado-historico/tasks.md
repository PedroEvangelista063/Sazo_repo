# Tasks: Refatoração Dado Histórico — Real Historical Data with Anchor-Year Transparency

## Review Workload Forecast

| Field                   | Value                                                                        |
| ----------------------- | ---------------------------------------------------------------------------- |
| Estimated changed lines | ~1,300–1,500 total (Slice 1: ~575–625; Slice 2: ~280–320; Slice 3: ~455–500) |
| 400-line budget risk    | High (Slice 1 and Slice 3 exceed 400)                                        |
| Chained PRs recommended | Yes                                                                          |
| Suggested split         | PR 1 (DB) → PR 2 (Backend) → PR 3 (Frontend), stacked to main                |
| Delivery strategy       | force-chained (authoritative, pre-resolved)                                  |
| Chain strategy          | stacked-to-main                                                              |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: High

**Chained-PR contract**: each slice = one PR with clear start/finish boundary, own verification (SQL assertions / pytest / vitest) and rollback path; commit in small work-unit commits per logical step; stacked to main in order DB → backend → frontend.

**Slice 1 (~575–625 lines, over budget)**: migration 63 alone is a single cohesive DDL+data+object change (~400–450 lines) that cannot be split into separate PRs without breaking `sp_executar_carga_completa` atomicity. Mitigation: **5 work-unit commits inside PR #1** (1a deactivation, 1b columns+backfill, 1c anchor view+MV+fn, 1d 000021+pipeline+deploy script, 1e RED/verification SQL), each independently reviewable; per-commit verification listed. **Slice 3 (~455–500, marginally over)**: majority is dead-code deletion (GAP_STYLES/tooltips) — low-risk deletions; mitigate with 4 work-unit commits (component → types → wiring → tests). No additional PR split (force-chained 3-slice structure is authoritative).

### Suggested Work Units

| Unit | Goal                                       | Likely PR | Focused test command                                                                                                | Runtime harness                                                                        | Rollback boundary                                                                                           |
| ---- | ------------------------------------------ | --------- | ------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| 1    | DB migration 63 + 000021 + pipeline guards | PR 1      | `psql -v ON_ERROR_STOP=1 -f database/63_dado_historico_real_transparencia.sql` on Supabase branch + RED guard greps | Supabase branch DB seeded with 62-run mart; then prod via `scripts/deploy_v13_prod.sh` | Revert 63/000021 commits; `database/64_rollback_dado_historico.sql` drops columns/view; MV restored from 36 |
| 2    | Backend schemas + V17 endpoints            | PR 2      | `pytest backend/tests -k "transparencia or sazonalidade"`                                                           | `GET /api/v1/sazonalidade?uf=SP` + `/br-sazonalidade?ano=2026` against V17-deployed DB | `git revert` (additive fields, old frontend unaffected)                                                     |
| 3    | Frontend transparency UI                   | PR 3      | `cd frontend && vitest run` + `tsc --noEmit`                                                                        | `npm run dev` grid/card manual check; Playwright SupermercadoView                      | `git revert`; optional fields default, old backend safe                                                     |

## Slice 1 — DB (PR #1): Migration + MV + Pipeline Deactivation

### Phase 1.1: RED Tests (guard-first, strict TDD)

- [x] 1.1.1
- [x] 1.1.2
- [x] 1.1.3

### Phase 1.2: Migration `database/63_dado_historico_real_transparencia.sql`

- [x] 1.2.1
- [x] 1.2.2
- [x] 1.2.3
- [x] 1.2.4
- [x] 1.2.5
- [x] 1.2.6
- [x] 1.2.7

### Phase 1.3: Supabase Track + Pipeline Guards

- [x] 1.3.1
- [x] 1.3.2
- [x] 1.3.3

### Phase 1.4: Verification (GREEN) + Rollback

- [x] 1.4.1
- [x] 1.4.2
- [x] 1.4.3

## Slice 2 — Backend (PR #2): Schemas + Endpoints

### Phase 2.1: RED Tests

- [x] 2.1.1 pytest RED: `FlowItem.ano_referencia` serializes from real anchor (2025), never default `2024`; `None` when no anchor (S-L1, S-L2, R-MOD-01). File: `backend/tests/test_transparencia_dado_historico.py` (new) — confirmado RED (falhou `assert 2024 is None`).
- [x] 2.1.2 pytest RED: `/api/v1/sazonalidade` item includes `ano_referencia`, `tipo_dado`, `is_dado_legado`, `mensagem_transparencia`; no `R$` anywhere in payload (S1, S2, S3; R-ADD-01/03).

### Phase 2.2: Schemas — `backend/app/schemas/responses.py`

- [x] 2.2.1 Add optional/defaulted fields `ano_referencia: int|None`, `tipo_dado: str|None`, `mensagem_transparencia: str|None`, `is_dado_legado: bool=False` to `SazonalidadeResponse`, `SazonalidadeComPrecoResponse`, `MesSazonalidade`, card schemas (R-ADD-01, S4).
- [x] 2.2.2 `FlowItem.ano_referencia: int = 2024` (L278) → `int | None = None` (R-MOD-01).

### Phase 2.3: Endpoints — `backend/app/api/v1/endpoints/produtos.py`

- [x] 2.3.1 Append `v.ano_referencia, v.tipo_dado, v.idade_dado_anos` to `BASE_COLS`, `_compute_periodo_full` SELECT e query do `/com-preco`; dedupe by `id_sazonalidade` unchanged.
- [x] 2.3.2 Builders `_build_response`, `_query_sazonalidade_por_mes`, `_build_br_response`, `_query_regional_snapshot`, `_query_regional_por_mes` map the 4 fields; `is_dado_legado = (ano_referencia is not None) and (ano_referencia < datetime.now(UTC).year)`.
- [x] 2.3.3 `_query_br_sazonalidade`: map `r["ano_referencia"]`, `r["tipo_dado"]` into `MesSazonalidade` from fn output.
- [x] 2.3.4 Add `_compor_mensagem_transparencia(tipo_dado, ano_referencia, idade=None)` pt-BR: REAL_ATUAL / HISTORICO_BASE (defasagem N ano(s)) / FALLBACK — no R$; `idade` derivada de `ANO_ATUAL - ano_referencia` quando ausente (fix review: fn_br_nacional_sazonalidade não projeta idade_dado_anos); null/zero rows still carry tipo_dado/ano/mensagem (R-ADD-04).
- [x] 2.3.5 Bump `br_sazonalidade` cache key `"v": 2` → `"v": 3`; purge via `POST /admin/cache/clear` + `pipeline/cache_purge.py` (R-ADD-05, S5) — purge já invocado no pipeline (ingestao_conab_inteligente.py:422, scraper/persistence.py:90, run_scraper_historico.py:259); passo de purge pós-deploy adicionado ao `deploy_v13_prod.sh` (seção 9, `bash -n` OK); teste offline: retorna False graciosamente com API off.

### Phase 2.4: Verification (GREEN)

- [x] 2.4.1 pytest green: `test_transparencia_dado_historico.py` 14 passed (13 RED→GREEN + 1 derivada de idade) + `test_resilience.py` 6 passed; `ruff check` + `ruff format` clean.
- [ ] 2.4.2 Integration against V17 DB: `GET /api/v1/sazonalidade?uf=SP` shows ≥1 REAL_ATUAL 2026 + ≥1 HISTORICO_BASE 2025 with `mensagem_transparencia`; `/br-sazonalidade?ano=2026` grid complete; no R$ leakage; purge then re-GET fresh (design §D step 8). **PENDENTE — banco remoto Supabase em hot standby (down) e sem credenciais do banco local disponíveis na sessão; validar quando o serviço voltar.** (Fase 4: purge mechanism testado offline; deploy script agora faz purge pós-CALL.)

## Slice 3 — Frontend (PR #3): Transparency UI

### Phase 3.1: RED Tests (vitest)

- [x] 3.1.1 vitest RED `DataTransparencyInfo.test.tsx` — confirmado RED (7 falhas antes da implementação).
- [x] 3.1.2 vitest RED `SazonalidadeNacional.test.tsx`.
- [x] 3.1.3 vitest RED `ProductCard.test.tsx` (substituídos os casos 📊/🪄 por transparência).

### Phase 3.2: Types + Component

- [x] 3.2.1 `frontend/src/types/domain.ts`: optional `ano_referencia?`, `tipo_dado?`, `mensagem_transparencia?`, `is_dado_legado?` em `ProdutoVarejo` e `MesSazonalidade`.
- [x] 3.2.2 `frontend/src/components/DataTransparencyInfo.tsx`: lucide `Info` (strokeWidth 1.5) com tooltip/popover no padrão CSS do projeto (Mantine Popover NÃO usado — Mantine não está wired no app: sem MantineProvider/main.tsx; decisão documentada no relatório); props `ano_referencia/tipo_dado/mensagem_transparencia/is_dado_legado/size`; title row + status Badge + explanation + defasagem; renders `null` quando `!tipo_dado`; nunca renderiza R$.

### Phase 3.3: UI Wiring

- [x] 3.3.1 `SazonalidadeNacional.tsx`: removidos `GAP_STYLES`/`classifyGap`/gray-cell branch/ícone 📈 + tooltips de forecast; `missing mesData` → célula muted; year badge `'25`/`'24` + `<DataTransparencyInfo/>` em células legadas (is_dado_legado || ano_referencia < ano atual).
- [x] 3.3.2 `SupermercadoView.tsx`: `selectedYear` sempre `new Date().getFullYear()`; badge "⚠️ Ano em curso..." → "Grade com dados de {N-2}–{N}"; "Ver {N-1} (cobertura completa)" → "(histórico)".
- [x] 3.3.3 `ProductCard.tsx`: removidos `📊 Estimativa`/`🪄 Estimado`; badge `tipo_dado` (default/warning/outline) com ano real ("Histórico Real '25"); footer `Ano de apuração: {ano_referencia ?? '—'}` + `<DataTransparencyInfo/>`.
- [x] 3.3.4 `useDataStream.ts`: confirmadas as 5 keys no `ETL_FINISHED` (`br-sazonalidade`, `hortifruti-meta`, `hortifruti-filter`, `sazonalidade-com-preco`, `regiao-resumo`) — já presentes, sem alteração.

### Phase 3.4: Verification (GREEN)

- [x] 3.4.1 vitest green: 4 files / 25 tests passed (DataTransparencyInfo 4, SazonalidadeNacional 4, ProductCard 12, BRNationalIcon 5); `tsc --noEmit` clean; `prettier --check` clean nos arquivos alterados. Playwright smoke: **não executado** (Chrome não disponível no ambiente); coberto por vitest + tsc.

## Dependencies & Apply Order

- **Strict order**: Slice 1 → Slice 2 → Slice 3 (each merges to main before the next; later slices depend on earlier V17 columns/fields).
- Within Slice 1: 1.1.x (RED) before 1.2.x production; 1.2.1 → 1.2.2 → 1.2.3 → 1.2.4 → 1.2.5 → 1.2.6 → 1.2.7 sequential; 1.3.1 after 1.2.1 (same body); 1.3.2/1.3.3 parallel once deactivated body defined; 1.4.x last.
- Within Slice 2: 2.1.x before 2.2/2.3; 2.2.1 → 2.2.2 → 2.3.1 → 2.3.2 → 2.3.3 → 2.3.4 → 2.3.5.
- Within Slice 3: 3.1.x before 3.2/3.3; 3.2.1 and 3.2.2 independent (component props self-contained); 3.3.4 can start as soon as Slice 2 ships (keys already covered).
- **Can proceed without waiting**: 3.2.2 (new component) may be scaffolded in parallel with Slice 2 once the schema field contract is fixed; 1.1.x RED scripts can be authored before migration 63 body (TDD).
