# Design: Refatoração Dado Histórico — Real Historical Data with Anchor-Year Transparency

## Overview

Replace synthetic projections (Sazonal Sandwich `staging.sp_project_sandwich_prices_2026`, V13 `staging.sp_calcular_forecast_2026_v13`) with REAL historical data. `mart.sazonalidade_produto` gains transparency columns; a helper view resolves the anchor-year fallback (N → N-1 → N-2 → dimension) per `(produto, localidade, mes)`; MV V17 (`mart.vw_api_produtos_sazonalidade`) is recreated (36-pattern) projecting real display values; `sp_executar_carga_completa` stops invoking the synthetic engines and owns the MV refresh. Backend exposes additive transparency fields; frontend removes gray cells, adds year badges and a `(i)` transparency popover. B2C R$ ban kept (`responses.py:7-11`).

Scope guard: recreate ONLY MV V17 (+ its helper view + `fn_br_nacional_sazonalidade` + orchestrator). `vw_mapa_regional_completo` stays deferred.

## Technical Approach

1. **DB (`database/63_dado_historico_real_transparencia.sql`)**: deactivate steps 5-6 of `sp_executar_carga_completa` (62:816-832); add 5 nullable columns; single-pass backfill UPDATE; create helper view `mart.vw_anchor_sazonalidade` (LATERAL, no CROSS JOIN); recreate MV V17 (DROP+CREATE+7 indexes+grants, 36:150-214 pattern) with 3 branches (real rows / anchored display rows / fallback rows); add explicit `REFRESH MATERIALIZED VIEW CONCURRENTLY`; recreate `fn_br_nacional_sazonalidade` (+`ano_referencia`,`tipo_dado` outputs).
2. **Supabase track**: minimal `supabase/migrations/000021_desativar_engines_sinteticas.sql` overriding ONLY the orchestrator (deactivated body) so CLI-track deploys cannot re-activate V13; `database/` declared source of truth for mart DDL/MV/anchor/fn (drift documented).
3. **Backend**: optional transparency fields on `SazonalidadeResponse`/`SazonalidadeComPrecoResponse`/`MesSazonalidade`; remove hardcoded `FlowItem.ano_referencia = 2024` (responses.py:278); populate from V17 columns via asyncpg raw SQL; provenance message composed in Python (no R$).
4. **Frontend**: new `DataTransparencyInfo.tsx`; gray-cell removal in `SazonalidadeNacional.tsx`; year badges; `SupermercadoView`/`ProductCard` badges → real/histórico; invalidation already covered by `useDataStream.ts` keys.
5. **Deploy**: migration 63 → 000021 → pipeline → backend → frontend → cache purge (`cache_purge.py` / `POST /admin/cache/clear`).

## Architecture Decisions

| #   | Decision                                    | Options considered                                                                                        | Choice                                                                                                                                                                                                                                                                                                              | Rationale                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| --- | ------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | Anchor fallback materialization             | (a) helper SQL VIEW with LATERAL over real rows; (b) helper TABLE refreshed by pipeline                   | **(a) `mart.vw_anchor_sazonalidade` view**                                                                                                                                                                                                                                                                          | Avoids the 4.85M CROSS JOIN OOM pattern (62:31-38/200-226) entirely: LATERAL per DISTINCT `(produto, localidade, mes)` tuple, index-backed (`uq_sazonalidade`, `idx_sazonalidade_data_ref`), no cartesian product. No pipeline coupling, no refresh ordering, no extra storage. Cost paid once per MV refresh; API never recomputes in memory.                                                                                               |
| D2  | Supabase track policy                       | (a) full mirror 000021 + port 000020 into `database/`; (b) `database/` source of truth + document drift   | **(b) source of truth + minimal 000021 orchestrator override**                                                                                                                                                                                                                                                      | 000019 (CLI track) contains its own `sp_executar_carga_completa` copy calling V13+sandwich (000019:821/834) and is re-applied by `deploy_v13_prod.sh` on every deploy — a full-drift policy (b) without a guard would silently re-activate synthetic generation. A minimal 000021 that overrides only the orchestrator closes that vector with least effort/risk; 000020 is already superseded by `database/57` sandwich v7 (no port value). |
| D3  | MV row set                                  | one row per `(prod,loc,ano,mes)` real-only; anchored rows at `ano=ANO_ATUAL`; collapsed one-row-per-month | **3-branch MV**: (A) real rows stamped with anchor fields (historical browsing), (B) anchored display rows at `ano=ANO_ATUAL` for tuples whose anchor year < N (fills current-year grid — kills gray cells without changing `fn` semantics), (C) `FALLBACK_DIMENSAO` rows for tuples with no real history in N..N-2 | Keeps `/sazonalidade?ano=&mes=` historical browsing intact; `fn_br_nacional_sazonalidade(ano)` keeps its `v.ano = p_ano` filter so only +2 output columns are needed; branch B emits at most one row per month tuple (condition `ano_referencia < ANO_ATUAL` prevents double counting with branch A current-year rows); synthetic/FLUXO_PROXY mart rows never enter the MV (display semantics only — no deletion).                           |
| D4  | `status_cor` semáforo                       | reuse mart `status_cor` (engine-written); recompute in MV                                                 | **Recompute in MV**: `fn_status_cor_regra_25` logic inlined (±25%: VERDE if `preco_exibido < ref*0.75`, VERMELHO if `> ref*1.25`, else AMARELO; `n_meses_referencia < 6` → AMARELO) against the REAL reference                                                                                                      | Spec S9: semáforo must never compare against a synthetic value. Inline CASE (identical to `57:88` formula) avoids a dependency on the ad-hoc live-DB function.                                                                                                                                                                                                                                                                               |
| D5  | `preco_exibido` / `preco_referencia` source | mart `preco_atual`/`preco_referencia`; anchor-computed                                                    | **Anchor-computed** in the view: `preco_exibido` = newest real price of the anchor row (no multiplier); `preco_referencia` = AVG of real prices over the 12 months preceding the anchor month (same product/localidade)                                                                                             | `sp_calcular_sazonalidade` writes `preco_referencia = preco_medio` (58:192), so the mart reference is useless for ±25% (would be identically equal). The trailing-12m real AVG matches the existing indice semantics (58:145-188) while guaranteeing a real-only basis.                                                                                                                                                                      |
| D6  | Future mart rows metadata                   | re-write `sp_calcular_sazonalidade` to stamp new columns; leave NULL                                      | **Leave NULL; MV is authoritative** for display `tipo_dado`/`ano_referencia`/`preco_exibido` (computed from anchor view); mart stamps are a one-time backfill provenance snapshot                                                                                                                                   | Recreating the real-data engine (58) is high-risk and out of scope. New real rows enter the mart with NULL stamps but still resolve correctly at the MV level.                                                                                                                                                                                                                                                                               |
| D7  | Deactivation mechanism                      | remove CALL lines; comment block; config flag                                                             | **No-op guards**: step 5 → commented `CALL` + `RAISE NOTICE`; step 6 → keep EXISTS guard but no-op branch + notice; new step 7 = explicit `REFRESH MATERIALIZED VIEW CONCURRENTLY`                                                                                                                                  | Procedures stay defined (audit trail per authoritative decision 5); the call text remains as comments; no config flag exists today (verified: guard is `EXISTS` on procedure presence) — a no-op branch guarantees forecasts never regenerate regardless of procedure presence. The synthetic SPs previously owned the MV refresh; the orchestrator must take it over.                                                                       |

## Data Flow

```
CONAB scraper/landing
   │  (extract)
   ▼
staging.fact_precos_mensais  (fonte='FLUXO_PROXY' rows flagged, NOT deleted)
   │  sp_calcular_sazonalidade(NULL,NULL)  ← real slice only (was: + V13 + sandwich)
   ▼
mart.sazonalidade_produto  (per (prod,loc,ano,mes); +5 new columns backfilled once)
   │
   ├── mart.vw_anchor_sazonalidade   (LATERAL: N→N-1→N-2 real, per (prod,loc,mes);
   │                                  preco_exibido, preco_referencia(12m real AVG),
   │                                  status_cor ±25%, metadado JSONB)
   ▼
mart.vw_api_produtos_sazonalidade  (V17, 3 branches) ── REFRESH CONCURRENTLY
   │                                                     (orchestrator step 7 / migration / deploy)
   ▼
asyncpg raw SQL (produtos.py) → SazonalidadeResponse(+transparency) → React Query
   │                                                    cache purge POST /admin/cache/clear
   ▼
SazonalidadeNacional / ProductCard / SupermercadoView  (badges, (i) tooltip — no R$)
```

## A. Database — `database/63_dado_historico_real_transparencia.sql`

### A.1 Pipeline deactivation (`sp_executar_carga_completa`)

File `database/62_engine_forecast_2024_2025_v13.sql:816-832`. The orchestrator is recreated in 63 with the same header/grants (62:764-838, 840-844). No config flag guards these calls today — the sandwich branch is guarded only by `EXISTS` on procedure presence (62:823-832), and V13 is called unconditionally (62:816). Deactivation:

```sql
-- BEFORE (62:815-832)
    -- 5. Forecast 2026 — Engine V13
    CALL staging.sp_calcular_forecast_2026_v13();
    RAISE NOTICE '[sp_executar_carga_completa] Forecast 2026 V13 (status_cor) OK';
    -- 6. Sanduíche Sazonal (guard EXISTS)
    SELECT EXISTS (...) INTO v_existe;
    IF v_existe THEN
        CALL staging.sp_project_sandwich_prices_2026();
        RAISE NOTICE '[sp_executar_carga_completa] Sanduíche Sazonal (preço numérico) OK';
    ELSE
        RAISE NOTICE '[sp_executar_carga_completa] Sanduíche Sazonal SKIP (proc ausente neste ambiente)';
    END IF;

-- AFTER (63)
    -- 5. Forecast V13 — DESATIVADO (refatoracao-dado-historico). Dado exibido passa a
    --    ser o histórico real com ano âncora. Proc permanece definida (audit trail), nunca invocada.
    -- CALL staging.sp_calcular_forecast_2026_v13();   -- desativado (audit trail)
    RAISE NOTICE '[sp_executar_carga_completa] Forecast V13 DESATIVADO — dado histórico real é a fonte de exibição';

    -- 6. Sanduíche Sazonal — DESATIVADO. Guard EXISTS mantido apenas para o aviso;
    --    o branch de execução é no-op. Proc permanece definida (audit trail).
    SELECT EXISTS (...) INTO v_existe;
    IF v_existe THEN
        RAISE NOTICE '[sp_executar_carga_completa] Sanduíche Sazonal DESATIVADO (proc presente, não invocada)';
    ELSE
        RAISE NOTICE '[sp_executar_carga_completa] Sanduíche Sazonal SKIP (proc ausente neste ambiente)';
    END IF;

    -- 7. (NOVO) Refresh explícito da MV — antes executado pelas engines sintéticas.
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
    RAISE NOTICE '[sp_executar_carga_completa] MV vw_api_produtos_sazonalidade atualizada';
```

Satisfies spec S8 (forecasts do not regenerate on next load) and R-ADD-06.

**Guards for the other synthetic entry points** (verified against source):

| Entry point                                | Current call                                                                                                                                       | Design                                                                                                                                                                                                                                                                                                                                                                                            |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pipeline/run_bulk_historical_fill.py:788` | `CALL staging.sp_calcular_sazonalidade_preditiva()` — the OLD predictive engine (V9/V8.1 from 18/19/22/22b/23) that writes `is_forecast=TRUE` rows | Replace with `CALL staging.sp_calcular_sazonalidade(NULL, NULL)` (real-only, 58:125) followed by `REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;` + a before/after `count(*) WHERE is_forecast=TRUE` guard log.                                                                                                                                                        |
| `scripts/deploy_v13_prod.sh:154-159`       | `CALL staging.sp_executar_carga_completa()` after applying 000019/000020                                                                           | Insert new deploy step applying `database/63` + `supabase/migrations/000021` BEFORE the pipeline CALL (so the orchestrator is deactivated before it runs); keep `-v ON_ERROR_STOP=1` + `die` guards; add post-CALL guard: `SELECT count(*) FROM mart.sazonalidade_produto WHERE is_forecast=TRUE` must not grow. 000019's orchestrator copy (000019:767+) is neutralized by 000021 overriding it. |

### A.2 New columns on `mart.sazonalidade_produto`

`preco_referencia` already exists (05:58); `preco_atual`, `variacao_mom_pct`, `media_movel_12m`, `data_referencia_atual`, `usou_fallback_12m`, `is_forecast`, `forecast_method`, `baseline_confianca` all exist. Only 5 columns are added:

```sql
ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS ano_referencia         INTEGER,
    ADD COLUMN IF NOT EXISTS tipo_dado              TEXT,
    ADD COLUMN IF NOT EXISTS metadado_transparencia JSONB,
    ADD COLUMN IF NOT EXISTS idade_dado_anos        INTEGER,
    ADD COLUMN IF NOT EXISTS preco_exibido          NUMERIC(14,4);

COMMENT ON COLUMN mart.sazonalidade_produto.ano_referencia IS
    'Ano âncora do dado exibido (última cotação REAL). NULL p/ FALLBACK_DIMENSAO.';
COMMENT ON COLUMN mart.sazonalidade_produto.tipo_dado IS
    'REAL_ATUAL | HISTORICO_BASE | FALLBACK_DIMENSAO (snapshot de proveniência da linha; MV é a fonte de exibição).';
COMMENT ON COLUMN mart.sazonalidade_produto.metadado_transparencia IS
    'JSONB: fonte_dado, data_referencia, procedencia (coleta_real_conab|sintetico_proxy|sintetico_engine), calculado_em.';
COMMENT ON COLUMN mart.sazonalidade_produto.idade_dado_anos IS
    'ANO_ATUAL - ano_referencia (0 = ano corrente).';
COMMENT ON COLUMN mart.sazonalidade_produto.preco_exibido IS
    'Preço real exibido (sem multiplicador sintético). NULL p/ linhas não exibíveis.';

-- CHECK pós-backfill (R-ADD-01): valores restritos, NULL permitido
ALTER TABLE mart.sazonalidade_produto
    ADD CONSTRAINT chk_sazonalidade_tipo_dado
    CHECK (tipo_dado IS NULL OR tipo_dado IN ('REAL_ATUAL','HISTORICO_BASE','FALLBACK_DIMENSAO'));
```

No DEFAULT — columns are NULL until the one-time backfill (D6). Both UNIQUEs (`uq_sazonalidade` on `(id_produto,id_localidade,ano,mes)` and `uq_sazonalidade_data_ref` on `(id_produto,id_localidade,data_referencia_atual)`) and the CHECK `chk_data_ref_ano_mes` (57) are untouched — additive-only, satisfies spec S10/R-ADD-07.

### A.3 Backfill UPDATE (single pass, no CROSS JOIN)

Per-row, no joins (spec R-ADD-01 mapping; FLUXO_PROXY rows flagged, NOT deleted):

```sql
UPDATE mart.sazonalidade_produto AS s
SET ano_referencia = EXTRACT(YEAR FROM s.data_referencia_atual)::INTEGER,
    idade_dado_anos = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
                      - EXTRACT(YEAR FROM s.data_referencia_atual)::INTEGER,
    tipo_dado = CASE
        WHEN COALESCE(s.fonte,'') = 'FLUXO_PROXY' OR s.is_forecast THEN 'FALLBACK_DIMENSAO'
        WHEN EXTRACT(YEAR FROM s.data_referencia_atual)::INTEGER
             = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER THEN 'REAL_ATUAL'
        ELSE 'HISTORICO_BASE'
    END,
    metadado_transparencia = jsonb_build_object(
        'fonte_dado',      COALESCE(s.fonte,'desconhecida'),
        'data_referencia', s.data_referencia_atual,
        'procedencia', CASE
            WHEN COALESCE(s.fonte,'') = 'FLUXO_PROXY' THEN 'sintetico_proxy'
            WHEN s.is_forecast THEN 'sintetico_engine'
            ELSE 'coleta_real_conab'
        END,
        'calculado_em',    s.calculado_em
    ),
    preco_exibido = CASE
        WHEN COALESCE(s.fonte,'') <> 'FLUXO_PROXY' AND NOT s.is_forecast THEN s.preco_atual
        ELSE NULL
    END
WHERE ano_referencia IS NULL;
```

`ANO_ATUAL = EXTRACT(YEAR FROM CURRENT_DATE)` everywhere — dynamic (spec S6; 2027 requires no code change). Verify counts after: `tipo_dado` distribution + 0 NULL `ano_referencia` on real rows.

### A.4 Anchor fallback projection — helper VIEW (D1)

```sql
CREATE OR REPLACE VIEW mart.vw_anchor_sazonalidade AS
WITH real AS (
    SELECT id_sazonalidade, id_produto, id_localidade, ano, mes,
           data_referencia_atual, preco_atual, fonte, calculado_em
    FROM mart.sazonalidade_produto
    WHERE COALESCE(fonte,'') <> 'FLUXO_PROXY' AND NOT is_forecast
      AND preco_atual IS NOT NULL AND preco_atual > 0
),
tuples AS (SELECT DISTINCT id_produto, id_localidade, mes FROM real),
anchored AS (
    SELECT t.id_produto, t.id_localidade, t.mes,
           a.id_sazonalidade, a.ano AS ano_referencia, a.preco_atual AS preco_exibido,
           a.data_referencia_atual, a.calculado_em AS data_ultima_coleta, a.fonte,
           EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - a.ano AS idade_dado_anos,
           CASE WHEN a.ano = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
                THEN 'REAL_ATUAL' ELSE 'HISTORICO_BASE' END AS tipo_dado,
           r.preco_ref_real AS preco_referencia, r.n_meses AS n_meses_referencia
    FROM tuples t
    LEFT JOIN LATERAL (   -- anchor: newest real row in N..N-2 for the month tuple
        SELECT r.id_sazonalidade, r.ano, r.preco_atual, r.data_referencia_atual,
               r.calculado_em, r.fonte
        FROM real r
        WHERE r.id_produto = t.id_produto
          AND r.id_localidade = t.id_localidade
          AND r.mes = t.mes
          AND r.ano BETWEEN EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 2
                        AND EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
        ORDER BY r.ano DESC, r.mes DESC
        LIMIT 1
    ) a ON TRUE
    LEFT JOIN LATERAL (   -- REAL reference: 12 months preceding anchor month (same prod/loc)
        SELECT AVG(r2.preco_atual)::NUMERIC(14,4) AS preco_ref_real, COUNT(*) AS n_meses
        FROM real r2
        WHERE r2.id_produto = t.id_produto
          AND r2.id_localidade = t.id_localidade
          AND (r2.ano * 12 + r2.mes) BETWEEN (a.ano * 12 + t.mes - 12)
                                        AND (a.ano * 12 + t.mes - 1)
    ) r ON TRUE
)
SELECT *,
       CASE
           WHEN n_meses_referencia IS NULL OR n_meses_referencia < 6 THEN 'AMARELO'
           WHEN preco_exibido IS NULL THEN NULL
           WHEN preco_exibido < preco_referencia * 0.75 THEN 'VERDE'
           WHEN preco_exibido > preco_referencia * 1.25 THEN 'VERMELHO'
           ELSE 'AMARELO'
       END AS status_cor,
       jsonb_build_object(
           'fonte_dado',        fonte,
           'data_ultima_coleta', data_ultima_coleta,
           'procedencia',       'coleta_real_conab',
           'ano_referencia',    ano_referencia
       ) AS metadado_transparencia
FROM anchored
WHERE preco_exibido IS NOT NULL;   -- tuples with a real anchor only (fallback handled in the MV)

GRANT SELECT ON mart.vw_anchor_sazonalidade TO role_api_reader;
```

- **OOM-safe**: no `CROSS JOIN`; the LATERAL anchor lookup filters to ≤3 candidate years over the existing index `uq_sazonalidade(id_produto,id_localidade,ano,mes)` / `idx_sazonalidade_data_ref`; the reference subquery scans at most 12 indexed rows. Tuple set ≈ products × localidades × 12 (tens of thousands, not 4.85M).
- **Proxy exclusion** (R-ADD-04/S7): `real` CTE excludes `FLUXO_PROXY`; a proxy 2026 row never becomes anchor → tuple anchors to 2025 `HISTORICO_BASE`. Proxy appears only via the MV's fallback branch C, provenance-marked.
- Satisfies R-ADD-02/03/05 + S1-S6, S9 (semáforo vs real reference, never synthetic).

### A.5 MV V17 recreation (36-pattern: DROP + CREATE + 7 indexes + grants)

Full `CREATE MATERIALIZED VIEW` per 36:150-198 shape (dims joins, `ALIMENTO_VAREJO` + classificao/categoria filters, `ORDER BY`), with three UNION ALL branches. Projection adds `preco_exibido`, `ano_referencia`, `tipo_dado`, `idade_dado_anos`, `metadado_transparencia`; keeps every existing column (`preco_referencia`, `preco_atual`, `variacao_pct` = `s.variacao_mom_pct`, `status_cor`, `fonte`, `calculado_em`, `is_forecast`, `baseline_confianca`, `forecast_method`, `data_referencia_atual`, `usou_fallback_12m`, `preco_estimado`, `tendencia_futura`, `metodo_calculo`).

- **Branch A — real rows (historical browsing)**: `FROM mart.sazonalidade_produto s JOIN dims LEFT JOIN mart.vw_anchor_sazonalidade a ON (prod,loc,mes)`; `WHERE COALESCE(s.fonte,'') <> 'FLUXO_PROXY' AND NOT s.is_forecast AND <B2C filters> AND (COALESCE(a.status_cor,s.status_cor) IS NOT NULL OR COALESCE(a.tipo_dado,s.tipo_dado)='FALLBACK_DIMENSAO')`; projected display = `COALESCE(a.preco_exibido, s.preco_atual)`, `COALESCE(a.preco_referencia, s.preco_referencia)`, `COALESCE(a.status_cor, s.status_cor)`, `COALESCE(a.ano_referencia, s.ano_referencia)`, `COALESCE(a.tipo_dado, s.tipo_dado)`, `COALESCE(a.idade_dado_anos, s.idade_dado_anos)`, `COALESCE(a.metadado_transparencia, s.metadado_transparencia)`; `s.ano, s.mes` (own year — supports `?ano=` browsing).
- **Branch B — anchored display rows**: source = `mart.vw_anchor_sazonalidade a JOIN mart.sazonalidade_produto s ON s.id_sazonalidade = a.id_sazonalidade JOIN dims`; `WHERE a.ano_referencia < EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER AND a.status_cor IS NOT NULL AND <B2C filters>`; project `ano = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER` (display year), `mes = a.mes`, `id_sazonalidade = -a.id_sazonalidade`, display fields from `a.*`, `is_forecast = FALSE`. One row per month tuple with past-year real history → current-year grid complete (kills gray cells) without touching `fn` semantics; no double count (branch B only when anchor year < N).
- **Branch C — fallback rows**: `DISTINCT ON (id_produto, id_localidade, mes)` over the whole mart WHERE `NOT EXISTS (SELECT 1 FROM mart.vw_anchor_sazonalidade a2 WHERE a2.id_produto=f.id_produto AND a2.id_localidade=f.id_localidade AND a2.mes=f.mes)` (prefer non-proxy row when both exist), JOIN dims, `<B2C filters>`; project `ano = ANO_ATUAL`, `id_sazonalidade = -(f.id_sazonalidade) - 1000000000`, `tipo_dado='FALLBACK_DIMENSAO'`, `preco_exibido = NULLIF(f.preco_atual,0)` (proxy value, provenance-marked), `preco_referencia = NULL`, `status_cor = NULL`, `metadado_transparencia = jsonb_build_object('fonte_dado',f.fonte,'procedencia', CASE WHEN f.fonte='FLUXO_PROXY' THEN 'sem_historico_real_uso_proxy' ELSE 'sem_historico_real' END, 'data_referencia', f.data_referencia_atual)`, `is_forecast = FALSE`.

Synthetic/FLUXO_PROXY mart rows never appear in the MV (display semantics only — rows kept in the mart as audit trail; spec S8/R-ADD-04).

**id_sazonalidade collision guard** (B uses `-id`, C uses `-(id)-1e9`): include a pre-create `DO $$ ... RAISE EXCEPTION IF MAX(id_sazonalidade) >= 1000000000 ... $$;` — current mart ≈130k rows, safe.

Indexes + grants (36:202-214 pattern, adapted):

```sql
CREATE UNIQUE INDEX idx_vw_sazonalidade_unico       ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);  -- REQUIRED for CONCURRENTLY
CREATE INDEX idx_vw_sazonalidade_filtro             ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);
CREATE INDEX idx_vw_sazonalidade_categoria          ON mart.vw_api_produtos_sazonalidade (categoria);
CREATE INDEX idx_vw_sazonalidade_produto            ON mart.vw_api_produtos_sazonalidade (id_produto);
CREATE INDEX idx_vw_sazonalidade_ano_mes            ON mart.vw_api_produtos_sazonalidade (ano, mes) WHERE (ano IS NOT NULL AND mes IS NOT NULL);
CREATE INDEX idx_vw_sazonalidade_tipo_dado          ON mart.vw_api_produtos_sazonalidade (tipo_dado) WHERE (tipo_dado IS NOT NULL);   -- replaces is_forecast idx
CREATE INDEX idx_vw_sazonalidade_ano_referencia     ON mart.vw_api_produtos_sazonalidade (ano_referencia DESC) WHERE (ano_referencia IS NOT NULL);  -- is_dado_legado scans
GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;
```

### A.6 Refresh strategy

`REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;` (requires the UNIQUE index above; API keeps serving the old snapshot during refresh — zero downtime). Invoked: (1) end of migration 63 (initial fill), (2) `sp_executar_carga_completa` step 7 (every pipeline run), (3) post-deploy. Followed by server cache purge (`cache_purge.py` → `POST /api/v1/admin/cache/clear`, `X-API-Key`).

### A.7 `fn_br_nacional_sazonalidade` recreation

`database/62:860-922` DROP-both-overloads + CREATE pattern. Add output columns `ano_referencia INTEGER`, `tipo_dado TEXT`; level-1 group adds `MODE() WITHIN GROUP (ORDER BY v.ano_referencia) AS uf_ano_ref` and `MODE() WITHIN GROUP (ORDER BY v.tipo_dado) AS uf_tipo_dado`; level-2 same modes. Grant `EXECUTE ... TO role_api_reader`. No source change (branch B rows at `ano=ANO_ATUAL` make the current-year grid complete; historical years keep working).

### A.8 Supabase track (D2)

- **`database/` = source of truth** for mart DDL, backfill, anchor view, MV V17, `fn_br_nacional_sazonalidade`, orchestrator.
- **`supabase/migrations/000021_desativar_engines_sinteticas.sql`** (NEW): `CREATE OR REPLACE PROCEDURE staging.sp_executar_carga_completa()` with the identical deactivated body of A.1 — the only CLI-track object that must be overridden, because `000019` (CLI) carries an orchestrator copy calling V13+sandwich and `deploy_v13_prod.sh` re-applies 000019/000020 on every deploy. Header comment documents the drift policy (mart `fonte` CHECK drift, mart columns applied via `database/`, `000020` not ported — superseded by `database/57`).
- `deploy_v13_prod.sh`: insert step applying `database/63` + `000021` between the current 000020 step (L147-149) and the pipeline CALL (L154-159); add post-CALL guard (A.1); adjust the "grade 2026" validation (L165-172) to expect `cinzas = 0`.

## B. Backend (FastAPI)

### B.1 `backend/app/schemas/responses.py`

Add optional/defaulted fields (additive contract — S4 backward compat):

```python
# SazonalidadeResponse (after forecast_method, L90-93) and SazonalidadeComPrecoResponse (after L167-170)
    ano_referencia: int | None = Field(None, description="Ano âncora do dado exibido (última cotação real). None p/ FALLBACK_DIMENSAO.")
    tipo_dado: str | None = Field(None, description="REAL_ATUAL | HISTORICO_BASE | FALLBACK_DIMENSAO")
    mensagem_transparencia: str | None = Field(None, description="Texto de proveniência (sem R$).")
    is_dado_legado: bool = Field(False, description="True quando ano_referencia < ano corrente.")

# MesSazonalidade (L215-223): same 4 fields, optional/defaulted.

# FlowItem L278 — R-MOD-01:
    ano_referencia: int | None = None   # was: ano_referencia: int = 2024
```

### B.2 `backend/app/api/v1/endpoints/produtos.py`

- `BASE_COLS` (L195-202) and `_compute_periodo_full` SELECT (L360-386): append `v.ano_referencia, v.tipo_dado, v.idade_dado_anos` (id_sazonalidade dedupe unchanged).
- Builders `_build_response` (L389+) and `_query_sazonalidade_por_mes` (L278-303): populate the 4 fields; `is_dado_legado = (ano_referencia is not None) and (ano_referencia < datetime.now().year)`; `mensagem_transparencia = _compor_mensagem_transparencia(...)`.
- `_query_br_sazonalidade` (L887-909): map `r["ano_referencia"]`, `r["tipo_dado"]` into `MesSazonalidade` (fn output).
- Endpoints read V17 via asyncpg raw SQL directly — no in-memory forecast math (R-ADD-02/S6). `/sazonalidade`, `/regioes`, cards all source from V17 (`fn` for br-sazonalidade).
- Cache version bump: `br_sazonalidade` cache key `"v": 2` → `"v": 3` (L936) — belt-and-suspenders on top of the purge.

`mensagem_transparencia` composition (pt-BR, no R$ — S3):

```python
def _compor_mensagem_transparencia(tipo_dado, ano_referencia, idade) -> str | None:
    if not tipo_dado:
        return None
    if tipo_dado == "REAL_ATUAL":
        return f"Coleta efetiva — cotação real da CONAB no ano de referência {ano_referencia}."
    if tipo_dado == "HISTORICO_BASE":
        suf = "s" if (idade or 0) > 1 else ""
        return (f"Dado histórico real — última cotação real da CONAB em {ano_referencia} "
                f"(defasagem de {idade} ano{suf}). Não é estimativa sintética.")
    return "Sem histórico real para este período — valor de referência da dimensão (fallback)."
```

Null/zero signaling (R-ADD-04): when `preco_exibido`/`preco_referencia` are NULL, payload still carries `tipo_dado` + `ano_referencia` + `mensagem_transparencia` — never silent null.

## C. Frontend (React)

### C.1 `frontend/src/components/DataTransparencyInfo.tsx` (NEW)

```tsx
interface DataTransparencyInfoProps {
  ano_referencia?: number | null;
  tipo_dado?: string | null;
  mensagem_transparencia?: string | null;
  is_dado_legado?: boolean;
  size?: number; // icon px, default 14
}
```

Renders `null` when `!tipo_dado`. A trigger span with lucide-react `Info` icon (strokeWidth 1.5) wrapped in a Mantine `Popover` (^9.4.1): title row (`"Ano de Origem: 2025"` | `"Dado Atual: 2026"` | `"Dado de Referência"`), status Badge (`"Histórico Real CONAB"` for `HISTORICO_BASE` / `"Coleta Efetiva"` for `REAL_ATUAL` / `"Referência"` for `FALLBACK_DIMENSAO`), explanation (`"Este valor reflete a última cotação real registrada para este produto no mês correspondente. Não é uma estimativa sintética."`), defasagem (`"Histórico de 1 ano atrás"` / `"2 anos atrás"` when `is_dado_legado`), plus `mensagem_transparencia` when provided. **Never renders R$** (R-ADD-05/S6). Mounts: SazonalidadeNacional legacy cells, ProductCard footer, map/polo tooltips where applicable (map deferred).

### C.2 `SazonalidadeNacional.tsx`

- Delete `GAP_STYLES` (L22-33), `classifyGap` (L75-77), the gray-cell branch (L120-137) and the CSS hover tooltips (L129-134, L159-213) with the `📈` forecast icon (L155-157) and forecast-method tooltip branches (L178-211). Missing `mesData` → minimal empty muted cell (defensive only; new data model fills every current-year month).
- Cell: semáforo block + year badge `'25`/`'24` when `mesData.ano_referencia < new Date().getFullYear()` + `<DataTransparencyInfo ... />` on legacy cells (S1/S2/S3). Keep low-coverage warning.

### C.3 `SupermercadoView.tsx`

- L76-80: default `selectedYear` → always `new Date().getFullYear()` (anchored grid is complete by construction; drop the "before June → N-1" heuristic).
- L482-507: replace "⚠️ Ano em curso — dados parciais até {month}/{year}" with a year mix indicator (e.g., "Grade com dados de {min}–{max}") — grid completeness now comes from anchors.
- L508-515: "Ver {selectedYear-1} (cobertura completa)" → "Ver {selectedYear-1} (histórico)" (browses real historical grid via branch A rows).

### C.4 `ProductCard.tsx`

- L103-129: remove `📊 Estimativa` and `🪄 Estimado` badge blocks; render one badge from `product.tipo_dado`: `REAL_ATUAL` → green-outline "Coleta Efetiva"; `HISTORICO_BASE` → amber-outline `Histórico Real '25` (short year); `FALLBACK_DIMENSAO` → gray-outline "Referência" (S4).
- Footer: `Ano de apuração: {product.ano_referencia ?? '—'}` + `<DataTransparencyInfo />`.

### C.5 Types & cache invalidation

- `frontend/src/types/domain.ts`: add optional `ano_referencia?: number | null`, `tipo_dado?: string | null`, `mensagem_transparencia?: string | null`, `is_dado_legado?: boolean` to `ProdutoVarejo` (L3-22) and `MesSazonalidade` (L48-55).
- `useHortifruti.ts` keys unchanged (`['br-sazonalidade', ano]`, `['hortifruti-meta', uf]`, `['hortifruti-filter', uf, ano, mes]`). **No hook change required for invalidation**: `useDataStream.ts` (L17-25) already invalidates all 5 spec keys (`br-sazonalidade`, `hortifruti-meta`, `hortifruti-filter`, `sazonalidade-com-preco`, `regiao-resumo`) on the `ETL_FINISHED` SSE event — the pipeline emits it after the MV refresh + cache purge. Clients refetch within staleTime (5 min).

## D. Deploy & Rollback

### Order of operations

1. **Branch validation** (Supabase branch DB): apply `database/63`; verify MV V17 row counts, `tipo_dado` distribution, no new `is_forecast` rows, constraints intact.
2. **Prod DB**: apply `database/63_dado_historico_real_transparencia.sql` (A.1-A.7). This recreates MV V17 (drop+create, brief unavailability of the MV), refreshes it, recreates the orchestrator deactivated.
3. **Supabase track**: apply `supabase/migrations/000021_desativar_engines_sinteticas.sql` (orchestrator override).
4. **Pipeline**: `CALL staging.sp_executar_carga_completa();` — now stores real slice + refreshes MV; **no synthetic regeneration** (S8). Guard: `SELECT count(*) FROM mart.sazonalidade_produto WHERE is_forecast = TRUE` unchanged vs. before.
5. **Backend deploy** (schemas + endpoints) — additive, safe against old frontend.
6. **Frontend deploy** (components/types) — additive, safe against old backend (fields optional).
7. **Cache purge**: `pipeline/cache_purge.py` (POST `/api/v1/admin/cache/clear`, `X-API-Key`) + br_sazonalidade cache version bump already deployed.
8. **Verify** (success criteria): `/api/v1/sazonalidade?uf=SP` shows ≥1 `REAL_ATUAL` 2026 item + ≥1 `HISTORICO_BASE` 2025 item with `mensagem_transparencia`; grid fully filled; no R$ in B2C payload.

### Rollback

1. **Re-enable synthetic** (if flag kept — no flag exists, so): restore `sp_executar_carga_completa` from git (62:764-838) and re-CALL pipeline — procedures remain defined, so this is a CREATE OR REPLACE + CALL.
2. **MV V17**: recreate from `database/36_fix_dedup_dim_localidade.sql` definition; `database/64_rollback_dado_historico.sql` drops the 5 added columns + `chk_sazonalidade_tipo_dado` + anchor view + 000021.
3. **Backend/frontend**: `git revert` (additive fields; old frontend ignores new fields — no data contract breakage).
4. Purge cache again; verify `/api/v1/sazonalidade?uf=SP`.

## File Changes

| File                                                          | Action | Description                                                                                               |
| ------------------------------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------- |
| `database/63_dado_historico_real_transparencia.sql`           | Create | Columns, backfill, anchor view, MV V17 (3 branches), fn, deactivated orchestrator, refresh                |
| `database/64_rollback_dado_historico.sql`                     | Create | Rollback: drop columns/CHECK/view, restore MV from 36, restore orchestrator                               |
| `supabase/migrations/000021_desativar_engines_sinteticas.sql` | Create | CLI-track orchestrator override (deactivated body) + drift-policy header                                  |
| `database/62_engine_forecast_2024_2025_v13.sql`               | Modify | (reference only — orchestrator recreated in 63; file kept as audit trail)                                 |
| `scripts/deploy_v13_prod.sh`                                  | Modify | Insert 63+000021 step before pipeline CALL; post-CALL synthetic guard; validation expects 0 gray          |
| `pipeline/run_bulk_historical_fill.py`                        | Modify | L788: `sp_calcular_sazonalidade_preditiva()` → `sp_calcular_sazonalidade(NULL,NULL)` + MV refresh + guard |
| `backend/app/schemas/responses.py`                            | Modify | 4 optional fields ×3 schemas; `FlowItem.ano_referencia: int\|None`                                        |
| `backend/app/api/v1/endpoints/produtos.py`                    | Modify | V17 columns in queries; builder mapping; `_compor_mensagem_transparencia`; cache key v3                   |
| `frontend/src/components/DataTransparencyInfo.tsx`            | Create | (i) popover component                                                                                     |
| `frontend/src/components/SazonalidadeNacional.tsx`            | Modify | Gray-cell removal, year badges, (i) integration                                                           |
| `frontend/src/components/ProductCard.tsx`                     | Modify | tipo_dado badges + apuração footer                                                                        |
| `frontend/src/pages/SupermercadoView.tsx`                     | Modify | Year default, badge semantics, year-1 link                                                                |
| `frontend/src/types/domain.ts`                                | Modify | Optional transparency fields                                                                              |

## Interfaces / Contracts

- **MV V17 contract (new columns)**: `preco_exibido NUMERIC`, `preco_referencia NUMERIC`, `variacao_pct NUMERIC`, `status_cor TEXT`, `ano_referencia INTEGER`, `tipo_dado TEXT ∈ {REAL_ATUAL,HISTORICO_BASE,FALLBACK_DIMENSAO}`, `idade_dado_anos INTEGER`, `metadado_transparencia JSONB`. All other V17 columns unchanged (backward compatible).
- **API (additive)**: `ano_referencia: int | None`, `tipo_dado: str | None`, `mensagem_transparencia: str | None`, `is_dado_legado: bool = False` on `SazonalidadeResponse`, `SazonalidadeComPrecoResponse`, `MesSazonalidade`; `FlowItem.ano_referencia: int | None = None`.
- **Component**: `DataTransparencyInfoProps` per C.1.

## Testing Strategy

| Layer             | What to Test                                                                                                                                                                                                                                                                    | Approach                                                                                                                                                                                                             |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| DB (migration)    | Columns added, constraints preserved (2 UNIQUEs + CHECK YYYY-MM), backfill mapping (real 2026→REAL_ATUAL/0, real 2025→HISTORICO_BASE/1, proxy→FALLBACK_DIMENSAO flagged), anchor chain N→N-1→N-2 per (prod,loc,mes), proxy never anchor, MV 3 branches, no synthetic rows in MV | Run 63 on Supabase branch; SQL assertions mirroring specs S1-S10 (e.g., `ano_referencia`/`tipo_dado` per scenario product; `count(*) WHERE is_forecast=TRUE` before/after pipeline; constraints via `pg_constraint`) |
| DB (pipeline)     | Orchestrator deactivated (no V13/sandwich calls), MV refresh runs, bulk-fill no synthetic regen                                                                                                                                                                                 | `SELECT prosrc FROM pg_proc` grep for `sp_calcular_forecast_2026_v13` in orchestrator; run pipeline; count guard                                                                                                     |
| Integration (API) | Payload has mixed REAL_ATUAL/HISTORICO_BASE; `is_dado_legado`; `mensagem_transparencia` text w/o R$; null/zero signaling; br-sazonalidade grid complete; cache purge refreshes                                                                                                  | `GET /api/v1/sazonalidade?uf=SP`, `/br-sazonalidade?ano=2026`; assert fields + no `R$`/`preco` leakage; purge then re-GET                                                                                            |
| Frontend          | No gray cells; year badges; (i) popover content; card badges; no R$ in DOM                                                                                                                                                                                                      | Component tests (vitest/RTL) per UI specs S1-S6; DOM scan for `R$`                                                                                                                                                   |
| E2E               | Success criterion (c): grid fully filled, tooltip works                                                                                                                                                                                                                         | Playwright on SupermercadoView BR grid                                                                                                                                                                               |

## Threat Matrix

| Boundary                 | Applicability                                                                      | Design response | Planned RED tests |
| ------------------------ | ---------------------------------------------------------------------------------- | --------------- | ----------------- |
| Documentation-like paths | N/A — no executable markdown/README involved                                       | —               | —                 |
| Git repository selection | N/A — this change adds no git invocation (no `git -C`, no relative-path VCS calls) | —               | —                 |
| Commit state             | N/A — no commit automation added                                                   | —               | —                 |
| Push state               | N/A — no push automation added                                                     | —               | —                 |
| PR commands              | N/A — no PR automation added                                                       | —               | —                 |

Process integration note (shell): `scripts/deploy_v13_prod.sh` executes `psql` with existing `-v ON_ERROR_STOP=1` + `die` guards; the design adds a post-pipeline guard query (`is_forecast` count must not grow) with failure → `die` (abort deploy). `pipeline/run_bulk_historical_fill.py` executes SQL via asyncpg (no shell); the replaced call is guarded by before/after counts logged. These guards propagate to tasks as RED tests (deploy dry-run on branch: assert guard fails when V13 call present).

## Migration / Rollout

Covered in Section D (order of operations + rollback). Migration 63 is a single cohesive DDL+data+object change; estimated size exceeds the 400-line review budget → **tasks must plan chained/stacked PRs** (DB slice → backend slice → frontend slice), each with independent verification and rollback.

## Open Questions

- None blocking. Two decisions taken here worth confirming at review: (1) default `selectedYear` to always current in SupermercadoView (anchored grid is complete) — changes the pre-June N-1 heuristic; (2) `variacao_pct` keeps its existing MoM semantics (`s.variacao_mom_pct`) rather than being redefined as anchor-vs-reference variation — spec R-ADD-05 lists it as projected, not redefined.
