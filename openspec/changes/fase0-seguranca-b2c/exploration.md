# Exploration: Fase 0 — B2C Security Fixes (fase0-seguranca-b2c)

Source: backend audit (Engram #431, topic `auditoria/backend-fastapi-2026-08`).
Scope: 3 critical findings — C1 (admin auth fail-open), C3 (R$ prices at B2C edge), A1 (Redis password in log).

---

## Current State

### C1 — Auth fail-open on administrative routes — CONFIRMED (exact lines unchanged)

- `backend/app/api/v1/endpoints/admin.py:24-29` — `_verify_api_key`:
  `if settings.internal_api_key and x_api_key != settings.internal_api_key: raise HTTPException(403)`
  → blocks **only if** the key is configured; otherwise the route is wide open. Comparison with `!=` (not constant-time).
- `backend/app/api/v1/endpoints/internal.py:11-14` — `verify_api_key`: **identical logic, duplicated**.
- `backend/app/core/config.py:66` — `internal_api_key: str = ""` (empty default → fail-open by default).
- Protected routes (all public today if the key is unset):
  - `POST /api/v1/admin/trigger-pipeline` (admin.py:112-114) — triggers the full ETL scrape+materialization.
  - `POST /api/v1/admin/cache/clear` (admin.py:151-153).
  - `GET` + `POST /api/v1/_internal/cache-clear` (internal.py:17-30).
  - `POST /api/v1/_internal/etl-done` (internal.py:33) — publishes `ETL_FINISHED`, which `main.py:170-187` (`_cache_invalidator`) uses to **clear the whole cache** → unauthenticated cache-flush DoS vector (mitigated only by rate limit 60-120 req/min).
- Current deployment: `backend/.env`, `.env.staging`, `.env.production` all have `INTERNAL_API_KEY` set (len 21) → live envs are protected **today**, but the pattern is a latent fail-open (fresh Render deploy without the dashboard value — `render.yaml:34` is `sync: false` — or any env without the var → routes public). `.env.example` documents `INTERNAL_API_KEY=""`.
- No `backend/tests/` coverage for admin/internal auth. The pentest suite `tests/pentest/test_02_autenticacao.py` covers it (tests 2.1-2.5 assert 403 and pass only while the key is set; test 2.8 is an `xfail` explicitly documenting **V1-CRÍTICA** and prescribing the fail-closed fix with `503` when the key is empty). `tests/pentest/relatorio_pentest.md` records it.
- No `hmac`/`secrets.compare_digest` usage anywhere yet; `backend/app/core/security.py` does not exist (fix plan creates it).

Fail-closed semantics per environment: `app_env` is only `staging|production` (`config.py:35`; `dev` normalizes to staging). There is no unauthenticated dev mode to preserve → fail-closed everywhere is safe:

- key unset → **503** ("Admin routes not configured") in both staging and production;
- key set but wrong/missing header → **403**.

### C3 — R$ prices at the B2C edge — CONFIRMED (exact lines) + NEW: zero live consumers

- `backend/app/api/v1/endpoints/produtos.py:990` — `@router.get("/com-preco", response_model=SazonalidadeComPrecoListResponse)` on `APIRouter(prefix="/sazonalidade")` (line 23), mounted publicly via `main.py:244`. SQL selects `preco_referencia, preco_atual, variacao_pct, preco_estimado, preco_mes_anterior` (lines 1054-1060) + lateral join `pm.preco_atual AS preco_mes_anterior`.
- `backend/app/schemas/responses.py:154-193` — `SazonalidadeComPrecoResponse` with 4 monetary fields; docstring (155-156) says "para endpoints analíticos (tabela/gráficos). NUNCA deve ser usado no endpoint B2C /sazonalidade". File header docstring (lines 7-11) forbids R$ in API responses.
- Frontend R$ rendering confirmed exactly as audited:
  - `frontend/src/components/GraficosView.tsx` — lines 154 (tooltip `R$ ${...}`), 208 (YAxis tickFormatter), 297 (BarChart YAxis tickFormatter), 371 (StatCard currency).
  - `frontend/src/components/TabelaView.tsx` — lines 118-143 (columns `Ref. (R$)`, `Atual (R$)`, `Mês Ant. (R$)`, `Var. %`).
- **NEW DISCOVERY**: `GraficosView` and `TabelaView` are **orphaned/dead code**. `App.tsx` renders only `SupermercadoView`; nothing imports the two components (verified by grep across `frontend/src`). The only consumer of `/sazonalidade/com-preco` is `frontend/src/hooks/useSazonalidadeComPreco.ts`, used exclusively by those two dead components. They are not in the Vite production bundle. The live PWA (`SupermercadoView.tsx`) consumes: `/sazonalidade`, `/sazonalidade/br-sazonalidade`, `/categorias`, `/regioes`, `/ufs`, `/fluxos`, `/fluxos/boletins`, SSE `/stream/updates` — **never `/com-preco`**.
- Related monetary leak: `backend/app/api/v1/endpoints/fluxos.py:24,61` exposes `preco_referencial` (string, e.g. `"R$ 3,50"`) from `staging.vw_abastecimento_logistico` in the B2C payload (`FlowItem`, responses.py:296; `domain.ts:110`). The live PWA fetches `/fluxos` but does not render `preco_referencial` (BrasilMap does not use it) — prices still cross the edge in transit.
- Guard tests already exist: `backend/tests/test_transparencia_dado_historico.py` — `test_payload_b2c_sem_r_dolar` (S3: no R$ in `SazonalidadeResponse`), `test_flowitem_preco_referencial_eh_excecao_administrativa` (explicitly treats `FlowItem.preco_referencial` as an administrative exception), `test_sazonalidade_com_preco_response_campos_transparencia` (schema still exercised). Frontend guards: `ProductCard.test.tsx:112-113`, `DataTransparencyInfo.test.tsx:19-43`, `SazonalidadeNacional.test.tsx:96-118` assert no R$ in the DOM.

### A1 — Redis password leaked in startup log — CONFIRMED (exact line)

- `backend/app/core/cache.py:149`:
  `logger.info("Cache: RedisCache em %s", redis_url.replace(redis_url.split("@")[-1] if "@" in redis_url else redis_url, "***"))`
  Masks the **host** (everything after the last `@`) and preserves `user:password@`. Example: `redis://default:secret@host:6379/0` → logged as `redis://default:secret@***`.
  Fix: `urllib.parse.urlsplit` + mask only the password (config.py already imports `urlsplit` — same pattern).
- `backend/app/core/config.py:37` — `database_url: str = "postgresql://role_api_reader:senha@localhost:5432/quero_comprar"`: literal default password `senha` in source. Actual env files are gitignored (`backend/.env*`), only `.env.example` tracked — no repo-wide secret leak beyond this default. Default only matters when `database_url_primary`/`database_url` are unset.
- No other credential-exposing log statements found (scan of `core/*.py`, `db/*.py`, `start.sh`, `main.py`).

### Testing capabilities (confirmed)

- Backend: `python -m pytest backend/tests`. `backend/pytest.ini`: `asyncio_mode=auto`, `timeout=5` (thread), `-p no:cacheprovider`, `-v --tb=short`. Existing tests: `test_ambiente_config.py` (pure Settings — no DB), `test_fluxos_boletins.py` (mocks `fetch`/`fetchrow` — no DB), `test_resilience.py` (mocks/pure), `test_transparencia_dado_historico.py` (pure schema). `conftest.py` defines `db_pool` (real asyncpg pool) and `client` (httpx → `http://localhost:8000`) fixtures, but **no current test in `backend/tests/` uses either** → **backend/tests does not require a live PostgreSQL** (only the `asyncpg` package installed, which it is).
- Frontend: `npx vitest run` in `frontend/` (vitest configured in `vite.config.ts`, `test.setupFiles: ./src/test/setup.ts`); 17 test files.
- Pentest suite lives in `tests/pentest/` (root `tests/` dir) — **outside** the configured `test_command_backend` path. Its auth tests use an ASGITransport app without lifespan (no live server); `api_pool` fixture needs a DB but skips when unavailable.

---

## Affected Areas

- `backend/app/api/v1/endpoints/admin.py` — `_verify_api_key` (24-29), route deps (114, 153) → replace with shared verifier.
- `backend/app/api/v1/endpoints/internal.py` — `verify_api_key` (11-14), route deps (18, 26, 33) → replace with shared verifier.
- `backend/app/core/config.py` — `internal_api_key` default (66); `database_url` default password (37).
- `backend/app/core/security.py` — **new file**: shared `require_internal_api_key` dependency using `secrets.compare_digest` + fail-closed 503.
- `backend/app/api/v1/endpoints/produtos.py` — `/com-preco` (990-1134): strip monetary fields and/or move to protected group.
- `backend/app/schemas/responses.py` — `SazonalidadeComPrecoResponse` (154-193): remove `preco_referencia/preco_atual/variacao_pct/preco_mes_anterior` or keep internal-only; `FlowItem.preco_referencial` (296) if compliance extended to `/fluxos`.
- `backend/app/api/v1/endpoints/fluxos.py` — `preco_referencial` (24, 61) — decision needed (B2C contract leak).
- `backend/app/core/cache.py` — line 149 log masking.
- `frontend/src/components/GraficosView.tsx` (154, 208, 297, 371), `frontend/src/components/TabelaView.tsx` (118-143), `frontend/src/hooks/useSazonalidadeComPreco.ts` — dead code consuming price fields; delete or convert to index/status.
- `frontend/src/hooks/useDataStream.ts:21` — remove `['sazonalidade-com-preco']` from `QUERIES_TO_INVALIDATE` if the hook is deleted.
- `backend/tests/` — add auth fail-closed tests (no DB needed, ASGITransport or direct calls).
- `tests/pentest/test_02_autenticacao.py:68-86` — convert xfail (2.8) into a real 503 assertion once C1 lands.
- `frontend/src/types/domain.ts` — `preco_referencial` (110) if `/fluxos` contract changes.

---

## Approaches

### C1 — shared fail-closed verifier

1. **Shared verifier + fail-closed + constant-time** (recommended)
   - New `backend/app/core/security.py`: `require_internal_api_key(x_api_key: str | None = Header(None))` → `503` if `not settings.internal_api_key`; `403` via `secrets.compare_digest` otherwise.
   - Replace duplicated `_verify_api_key`/`verify_api_key` in both routers.
   - Pros: single implementation; constant-time; fail-closed by default in all envs; matches pentest prescription (503) and audit plan; easy to unit test.
   - Cons: cron webhooks / operators calling `/_internal/*` get 503 until a key is configured (correct behavior).
   - Effort: Low.

2. **Keep per-router verifiers, just add fail-closed + compare_digest**
   - Pros: smaller diff.
   - Cons: duplicated logic remains; drift risk; test surface doubled.
   - Effort: Low.

### C3 — prices at the B2C edge

1. **Strip monetary fields + move `/com-preco` under auth** (recommended — hybrid A+B)
   - Backend: remove `preco_referencia`, `preco_atual`, `preco_mes_anterior`, `variacao_pct` from the public `SazonalidadeComPrecoResponse` (replace with normalized index, e.g. relative-to-reference index 0-100 or keep only `status_cor`), AND protect the route with the new shared verifier (its docstring already says it is analytical, never B2C). Since there are **zero live consumers**, deleting the public route (or mounting it only under the key) has no frontend impact.
   - Frontend: delete orphaned `GraficosView`, `TabelaView`, `useSazonalidadeComPreco` and the `['sazonalidade-com-preco']` invalidation entry — they are not bundled; deletion is zero-risk. If product wants the analytical views back, revive later behind auth + index-based rendering.
   - Pros: fully complies with responses.py:7-11 and PROJECT_RULES ("nunca exibir preços R$"); defense in depth; zero live-frontend impact; removes cache-flush-by-proxy surface on the same router.
   - Cons: requires touching schema + route + deleting dead FE code (a "cleanup" beyond pure security); the `FlowItem.preco_referencial` question remains open.
   - Effort: Medium.

2. **Move `/com-preco` to an admin group only (no schema change)**
   - Pros: minimal change; keeps raw prices available to operators; reuses C1 verifier.
   - Cons: prices remain in the API _contract_ (violates responses.py:7-11 if interpreted strictly); the public `/fluxos` `preco_referencial` leak remains; endpoint stays as latent risk if ever re-mounted.
   - Effort: Low.

3. **Normalized index only (keep endpoint public)**
   - Pros: preserves a public analytical capability without R$.
   - Cons: `variacao_pct`/derived stats still leak price-adjacent info; still violates the spirit of "apenas status visual"; no consumers justify keeping it public.
   - Effort: Low-Medium.

Recommendation: **Approach 1 (hybrid)** — strip monetary fields from the B2C response and gate `/com-preco` behind the C1 verifier (or remove the public route entirely), plus delete the orphaned frontend price-rendering code. Also decide on `FlowItem.preco_referencial`: recommend stripping it from the B2C `/fluxos` contract too (the existing "administrative exception" test intent should be revisited) — or explicitly document it as accepted product scope in the proposal.

### A1 — password in logs/default

1. **urlsplit password masking** (recommended)
   - `cache.py:149`: parse with `urlsplit`, rebuild URL with `password → "***"` (keep host). Or log only `hostname` + port.
   - Plus: change `config.py:37` default to a passwordless/placeholder value (e.g. `postgresql://role_api_reader@localhost:5432/quero_comprar` or empty) so no literal secret sits in source; keep `.env*` as the single secret source.
   - Pros: kills the leak; simple; pattern already used in config.py.
   - Cons: none material.
   - Effort: Low.

---

## Recommendation

Proceed to **propose** with all three fixes as planned:

- C1: new `core/security.py` shared verifier (`secrets.compare_digest` + 503 fail-closed) used by admin.py and internal.py; update pentest 2.8 from xfail to real assertion; add `backend/tests` unit tests (no DB).
- C3: strip monetary fields from the B2C schema **and** gate `/com-preco` under the C1 verifier; delete the orphaned GraficosView/TabelaView/useSazonalidadeComPreco (or convert to index-based if product wants charts back); take an explicit decision on `FlowItem.preco_referencial` in `/fluxos`.
- A1: mask only the password in `cache.py:149` via `urlsplit`; remove the literal `senha` default from `config.py:37`.
- Testing note for the proposal: `backend/tests` needs no live PostgreSQL; the pentest auth suite requires `INTERNAL_API_KEY` set to pass — after C1 it must be extended to assert 503 when unset (needs a monkeypatched `get_settings` cache-bust or env manipulation).

## Risks

- C1 fail-closed may 503 legitimate cron/operator calls if `INTERNAL_API_KEY` is missing in some env (currently set in all three env files — verify the cron-job.org webhook key still matches after the change; memory #309 documents that webhook).
- C3: deleting `/com-preco` or the orphaned components is a product-visible decision (charts/tables were once planned) — confirm with the user in the proposal. Stripping `FlowItem.preco_referencial` from `/fluxos` contradicts an existing test's documented intent (administrative exception) — update test + intent together.
- C1 comparison with `compare_digest` requires both sides `str` (Header returns `str | None` — handle None before calling).
- `get_settings()` is `lru_cache`d — fail-closed tests must clear/monkeypatch settings or construct `Settings` directly.
- Frontend deletion touches `useDataStream.ts` invalidation list — keep it in sync.

## Ready for Proposal

**Yes** — all three findings verified at exact current lines; no code changed. The orchestrator should tell the user: (1) all 3 findings confirmed as-is; (2) GraficosView/TabelaView are orphaned (zero live consumers of `/com-preco`), which makes C3's fix cheap and frontend-safe; (3) recommend the hybrid fix for C3 (strip + guard) and deleting the dead FE code; (4) ask about `FlowItem.preco_referencial` scope and whether the analytical charts should be revived later behind auth.
