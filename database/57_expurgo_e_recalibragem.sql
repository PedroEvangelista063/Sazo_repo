-- =============================================================================
-- 57_expurgo_e_recalibragem.sql
-- -----------------------------------------------------------------------------
-- Objetivo: saneamento da grade sazonal + recalibragem estatística do semáforo.
--
-- Contexto (auditoria de acurácia das views):
--   * MAPE do modelo sazonal = 22,8% (mediana do erro 15%) e apenas ~50% dos
--     pares ficam dentro do limiar de ±15% que alimentava o semáforo.
--   * A grade 2026 continha 38.882 células FORECAST LEGADAS com
--     forecast_method IS NULL (preenchimento antigo, sem método documentado):
--        - 21.664 em 2026 (21.482 em meses passados <=7, 182 em meses futuros)
--        - 17.218 em 2025
--     Nenhuma delas tem dado real (is_forecast=FALSE) no mesmo par/mês
--     (legadas_sem_real = 100%) -> DELETE 100% seguro.
--
-- FASE 1 — EXPURGO: backup auditável + DELETE das células legadas sem método.
-- FASE 2 — RECALIBRAGEM ±25%: novo semáforo oficial
--            VERDE    se preco_atual <  preco_referencia * 0.75
--            VERMELHO se preco_atual >  preco_referencia * 1.25
--            AMARELO  caso contrário
--          recalcular retroativamente status_cor na tabela e tornar a nova
--          margem o padrão de todas as funções/procedures (procedure v6).
-- FASE 3 — REFRESH MATERIALIZED VIEW + limpeza de cache do FastAPI.
-- -----------------------------------------------------------------------------
-- PADRÃO: BEGIN/COMMIT, backup auditável, DELETE idempotente, NOTICE com
-- contagens, REFRESH MV após COMMIT, seção de verificação manual.
-- =============================================================================

BEGIN;

-- =============================================================================
-- FASE 1 — EXPURGO DE CÉLULAS LEGADAS (forecast_method IS NULL, is_forecast=TRUE)
-- =============================================================================

-- 1.1) Backup auditável (idempotente): preserva as linhas deletadas.
CREATE TABLE IF NOT EXISTS mart.sazonalidade_legado_backup_57 AS
SELECT *
FROM mart.sazonalidade_produto
WHERE forecast_method IS NULL
  AND is_forecast = TRUE;

-- 1.2) DELETE apenas das legadas SEM método E SEM dado real no mesmo par/mês.
--      Células reais (is_forecast = FALSE, forecast_method NULL) NÃO são tocadas.
DO $$
DECLARE
    v_deleted INTEGER;
BEGIN
    DELETE FROM mart.sazonalidade_produto s
    USING mart.sazonalidade_produto s2
    WHERE s.id_sazonalidade = s2.id_sazonalidade
      AND s.forecast_method IS NULL
      AND s.is_forecast = TRUE
      AND NOT EXISTS (
          SELECT 1 FROM mart.sazonalidade_produto r
          WHERE r.id_produto      = s.id_produto
            AND r.id_localidade   = s.id_localidade
            AND r.ano             = s.ano
            AND r.mes             = s.mes
            AND r.is_forecast     = FALSE
      );

    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RAISE NOTICE '[57] FASE 1 — Expurgo: % células legadas sem método deletadas.', v_deleted;
END $$;

-- =============================================================================
-- FASE 2 — RECALIBRAGEM DO SEMÁFORO PARA ±25%
-- =============================================================================

-- 2.1) Novo semáforo oficial ±25% (função canônica, substitui a regra ±15%).
CREATE OR REPLACE FUNCTION staging.fn_status_cor_regra_25(
    p_preco_atual     NUMERIC,
    p_preco_referencia NUMERIC
)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
        WHEN p_preco_atual IS NULL OR p_preco_atual <= 0 THEN NULL
        WHEN p_preco_atual <  COALESCE(p_preco_referencia, p_preco_atual) * 0.75 THEN 'VERDE'
        WHEN p_preco_atual >  COALESCE(p_preco_referencia, p_preco_atual) * 1.25 THEN 'VERMELHO'
        ELSE 'AMARELO'
    END;
$$;

COMMENT ON FUNCTION staging.fn_status_cor_regra_25(NUMERIC, NUMERIC) IS
'Semáforo oficial ±25%. VERDE se preco_atual < preco_referencia*0.75, VERMELHO se preco_atual > preco_referencia*1.25, senão AMARELO. Substitui a regra ±15% (Fase 57).';

GRANT EXECUTE ON FUNCTION staging.fn_status_cor_regra_25(NUMERIC, NUMERIC) TO role_etl_writer;

-- 2.2) Recalcular retroativamente status_cor de TODA a tabela com a regra ±25%.
--      Aplica-se a forecasts (is_forecast=TRUE) e a células reais (FALSE).
DO $$
DECLARE
    v_updated INTEGER;
BEGIN
    UPDATE mart.sazonalidade_produto s
    SET status_cor = COALESCE(
            staging.fn_status_cor_regra_25(s.preco_atual, s.preco_referencia),
            s.status_cor
        ),
        calculado_em = NOW()
    WHERE s.preco_atual IS NOT NULL
      AND s.preco_atual > 0;

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    RAISE NOTICE '[57] FASE 2 — Recalc ±25%%: status_cor recalculado em % linhas.', v_updated;
END $$;

-- =============================================================================
-- FASE 2 (cont.) — PROCEDURE v6: novo padrão ±25% em todos os Steps
-- -----------------------------------------------------------------------------
-- Recreate de staging.sp_project_sandwich_prices_2026() a partir da v5
-- (fator_kg, advisory lock, statement_timeout 300s) substituindo todas as
-- chamadas fn_status_cor_regra_15 -> fn_status_cor_regra_25.
-- =============================================================================

CREATE OR REPLACE PROCEDURE staging.sp_project_sandwich_prices_2026()
 LANGUAGE plpgsql
 SET statement_timeout TO '300000'
AS $procedure$
DECLARE
    v_inicio     TIMESTAMPTZ;
    v_fim        TIMESTAMPTZ;
    v_total      INTEGER;
    v_mes_atual  INTEGER;
    v_proxy      INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    v_mes_atual := EXTRACT(MONTH FROM NOW())::INTEGER;

    PERFORM pg_advisory_xact_lock(hashtext('sp_project_sandwich_prices_2026'));

    RAISE NOTICE '[sp_project_sandwich_prices_2026] Iniciando Sanduíche Sazonal v6 (±25%%) (mês atual: %)...', v_mes_atual;

    WITH precos_patch AS (
        SELECT
            s.id_sazonalidade,
            s.id_produto,
            s.id_localidade,
            s.ano, s.mes,
            h.preco_medio_historico,
            h.tendencia_pct,
            h.confianca,
            COALESCE(NULLIF(f.fator_kg, 0), 1) AS fator_kg
        FROM mart.sazonalidade_produto s
        JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
        LEFT JOIN mart.fator_kg_produto_uf f
            ON f.id_produto = s.id_produto
           AND f.uf         = l.uf
        CROSS JOIN LATERAL staging.fn_sandwich_historical_price(
            s.id_produto, s.id_localidade, s.mes
        ) h
        WHERE s.ano = 2026
          AND s.mes <= v_mes_atual
          AND s.preco_atual IS NULL
          AND s.is_forecast = TRUE
          AND h.preco_medio_historico IS NOT NULL
    )
    UPDATE mart.sazonalidade_produto s
    SET
        preco_atual        = ROUND(p.preco_medio_historico * (1 + p.tendencia_pct / 100) / p.fator_kg, 4),
        preco_referencia   = ROUND(p.preco_medio_historico / p.fator_kg, 4),
        status_cor         = COALESCE(
            staging.fn_status_cor_regra_25(
                ROUND(p.preco_medio_historico * (1 + p.tendencia_pct / 100) / p.fator_kg, 4),
                ROUND(p.preco_medio_historico / p.fator_kg, 4)
            ),
            s.status_cor
        ),
        baseline_confianca = GREATEST(s.baseline_confianca, p.confianca),
        forecast_method    = 'SANDUICHE_MEDIA_24_25',
        usou_fallback_12m  = COALESCE(s.usou_fallback_12m, FALSE),
        calculado_em       = NOW()
    FROM precos_patch p
    WHERE s.id_sazonalidade = p.id_sazonalidade;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 1 — Patch retroativo (Jan-%): % linhas.', v_mes_atual, v_total;

    WITH meses_futuros AS (
        SELECT generate_series(v_mes_atual + 1, 12) AS mes
    ),
    produtos_historicos AS (
        SELECT DISTINCT f.id_produto, f.id_localidade
        FROM staging.fact_precos_mensais f
        WHERE f.ano IN (2024, 2025)
          AND f.preco_medio IS NOT NULL
          AND f.preco_medio > 0
    ),
    grade_futura AS (
        SELECT p.id_produto, p.id_localidade, m.mes
        FROM produtos_historicos p
        CROSS JOIN meses_futuros m
    ),
    meses_sem_real AS (
        SELECT g.*
        FROM grade_futura g
        LEFT JOIN mart.sazonalidade_produto s
            ON s.id_produto    = g.id_produto
           AND s.id_localidade = g.id_localidade
           AND s.ano           = 2026
           AND s.mes           = g.mes
           AND s.is_forecast   = FALSE
        WHERE s.id_sazonalidade IS NULL
    ),
    projecao AS (
        SELECT
            msr.id_produto,
            msr.id_localidade,
            msr.mes,
            COALESCE(
                staging.fn_preco_base_2026(msr.id_produto, msr.id_localidade),
                h.preco_medio_historico
            ) AS preco_base,
            staging.fn_fator_sazonal_mensal(
                msr.id_produto, msr.id_localidade, msr.mes::SMALLINT
            ) AS fator_sazonal,
            GREATEST(h.confianca, COALESCE(b.confianca, 0)) AS confianca,
            COALESCE(NULLIF(f.fator_kg, 0), 1) AS fator_kg
        FROM meses_sem_real msr
        JOIN staging.dim_localidade l ON l.id_localidade = msr.id_localidade
        LEFT JOIN mart.fator_kg_produto_uf f
            ON f.id_produto = msr.id_produto
           AND f.uf         = l.uf
        CROSS JOIN LATERAL staging.fn_sandwich_historical_price(
            msr.id_produto, msr.id_localidade, msr.mes::SMALLINT
        ) h
        LEFT JOIN mart.sazonalidade_baseline_24_25 b
            ON b.id_produto    = msr.id_produto
           AND b.id_localidade = msr.id_localidade
           AND b.mes           = msr.mes
        WHERE h.preco_medio_historico IS NOT NULL
          AND h.preco_medio_historico > 0
    ),
    projecao_final AS (
        SELECT
            id_produto, id_localidade, mes, preco_base, fator_sazonal, confianca, fator_kg,
            ROUND(preco_base * (1 + COALESCE(fator_sazonal, 0)) / fator_kg, 4) AS preco_atual,
            ROUND(preco_base / fator_kg, 4) AS preco_referencia
        FROM projecao
        WHERE preco_base IS NOT NULL AND preco_base > 0
    )
    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade, ano, mes,
        preco_atual, preco_referencia,
        data_referencia_atual,
        status_cor, fonte, calculado_em,
        is_forecast, baseline_confianca, forecast_method,
        usou_fallback_12m
    )
    SELECT
        pf.id_produto,
        pf.id_localidade,
        2026,
        pf.mes,
        pf.preco_atual,
        pf.preco_referencia,
        2026::TEXT || '-' || LPAD(pf.mes::TEXT, 2, '0'),
        COALESCE(
            staging.fn_status_cor_regra_25(pf.preco_atual, pf.preco_referencia),
            'AMARELO'
        ) AS status_cor,
        'BASELINE_HISTORICO',
        NOW(),
        TRUE,
        GREATEST(pf.confianca, 0),
        CASE WHEN pf.fator_sazonal IS NOT NULL
             THEN 'SANDUICHE_FATOR_SAZONAL'
             ELSE 'SANDUICHE_MEDIA_24_25' END,
        FALSE
    FROM projecao_final pf
    ON CONFLICT (id_produto, id_localidade, ano, mes)
    DO UPDATE SET
        preco_atual        = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                  THEN mart.sazonalidade_produto.preco_atual
                                  ELSE EXCLUDED.preco_atual END,
        preco_referencia   = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                  THEN mart.sazonalidade_produto.preco_referencia
                                  ELSE EXCLUDED.preco_referencia END,
        status_cor         = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                  THEN mart.sazonalidade_produto.status_cor
                                  ELSE EXCLUDED.status_cor END,
        is_forecast        = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE THEN FALSE ELSE TRUE END,
        baseline_confianca = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                  THEN mart.sazonalidade_produto.baseline_confianca
                                  ELSE EXCLUDED.baseline_confianca END,
        forecast_method    = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                  THEN mart.sazonalidade_produto.forecast_method
                                  ELSE EXCLUDED.forecast_method END,
        usou_fallback_12m  = COALESCE(mart.sazonalidade_produto.usou_fallback_12m, FALSE),
        calculado_em       = NOW();

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 2 — Pre-fill futuro c/ Fator Sazonal: % linhas.', v_total;

    WITH recalc_futuro AS (
        SELECT
            s.id_sazonalidade,
            COALESCE(
                staging.fn_preco_base_2026(s.id_produto, s.id_localidade),
                s.preco_referencia
            ) AS preco_base,
            staging.fn_fator_sazonal_mensal(
                s.id_produto, s.id_localidade, s.mes::SMALLINT
            ) AS fator_sazonal,
            COALESCE(NULLIF(f.fator_kg, 0), 1) AS fator_kg
        FROM mart.sazonalidade_produto s
        JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
        LEFT JOIN mart.fator_kg_produto_uf f
            ON f.id_produto = s.id_produto
           AND f.uf         = l.uf
        WHERE s.ano = 2026
          AND s.mes BETWEEN v_mes_atual + 1 AND 12
          AND s.is_forecast = TRUE
          AND s.preco_atual IS NOT NULL
          AND s.preco_atual > 0
    ),
    recalc_final AS (
        SELECT
            r.id_sazonalidade,
            ROUND(r.preco_base * (1 + COALESCE(r.fator_sazonal, 0)) / r.fator_kg, 4) AS preco_atual,
            ROUND(r.preco_base / r.fator_kg, 4) AS preco_referencia,
            r.fator_sazonal
        FROM recalc_futuro r
        WHERE r.preco_base IS NOT NULL AND r.preco_base > 0
    )
    UPDATE mart.sazonalidade_produto s
    SET
        preco_atual        = r.preco_atual,
        preco_referencia   = r.preco_referencia,
        status_cor         = COALESCE(
            staging.fn_status_cor_regra_25(r.preco_atual, r.preco_referencia),
            'AMARELO'
        ),
        forecast_method    = CASE WHEN r.fator_sazonal IS NOT NULL
                                  THEN 'SANDUICHE_FATOR_SAZONAL'
                                  ELSE s.forecast_method END,
        calculado_em       = NOW()
    FROM recalc_final r
    WHERE s.id_sazonalidade = r.id_sazonalidade;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 2b — Momentum em forecasts existentes: % linhas.', v_total;

    CREATE TEMP TABLE IF NOT EXISTS tmp_orphans_proxy ON COMMIT DROP AS
    WITH orfaos AS (
        SELECT DISTINCT s.id_produto
        FROM mart.sazonalidade_produto s
        WHERE s.ano = 2026
          AND s.mes <= v_mes_atual
          AND s.is_forecast = FALSE
          AND NOT EXISTS (
              SELECT 1 FROM mart.sazonalidade_produto s2
              WHERE s2.id_produto = s.id_produto
                AND s2.ano = 2026
                AND s2.mes = v_mes_atual + 1
                AND s2.is_forecast = TRUE
                AND s2.forecast_method IN ('SANDUICHE_MEDIA_24_25', 'PROXY_HIERARQUICO', 'SANDUICHE_FATOR_SAZONAL')
          )
    ),
    orfaos_com_pai AS (
        SELECT
            o.id_produto AS id_filho,
            staging.fn_encontrar_produto_pai(o.id_produto, (v_mes_atual + 1)::SMALLINT) AS id_pai
        FROM orfaos o
    )
    SELECT * FROM orfaos_com_pai WHERE id_pai IS NOT NULL;

    GET DIAGNOSTICS v_proxy = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 3 — % produtos órfãos com pai.', v_proxy;

    IF v_proxy > 0 THEN
        WITH meses_futuros AS (
            SELECT generate_series(v_mes_atual + 1, 12) AS mes
        ),
        ratio_preco AS (
            SELECT
                o.id_filho, o.id_pai,
                sf.id_localidade, sf.mes,
                AVG(sf.preco_atual) / NULLIF(AVG(sp.preco_atual), 0) AS ratio
            FROM tmp_orphans_proxy o
            JOIN mart.sazonalidade_produto sf ON sf.id_produto = o.id_filho
                                               AND sf.ano = 2026 AND sf.is_forecast = FALSE
                                               AND sf.preco_atual IS NOT NULL AND sf.preco_atual > 0
            JOIN mart.sazonalidade_produto sp ON sp.id_produto = o.id_pai
                                               AND sp.id_localidade = sf.id_localidade
                                               AND sp.ano = 2026 AND sp.mes = sf.mes
                                               AND sp.is_forecast = FALSE
                                               AND sp.preco_atual IS NOT NULL AND sp.preco_atual > 0
            GROUP BY o.id_filho, o.id_pai, sf.id_localidade, sf.mes
        ),
        projecao_pai AS (
            SELECT
                o.id_filho, s.id_localidade, m.mes,
                s.preco_atual AS pai_preco_atual,
                s.preco_referencia AS pai_preco_referencia,
                s.status_cor AS pai_status_cor,
                s.baseline_confianca AS pai_confianca
            FROM tmp_orphans_proxy o
            JOIN mart.sazonalidade_produto s ON s.id_produto = o.id_pai
            CROSS JOIN meses_futuros m
            WHERE s.ano = 2026 AND s.mes = m.mes
              AND s.forecast_method IN ('SANDUICHE_MEDIA_24_25', 'PROXY_HIERARQUICO', 'SANDUICHE_FATOR_SAZONAL')
        ),
        proxy_final AS (
            SELECT
                pp.id_filho, pp.id_localidade, pp.mes,
                ROUND(pp.pai_preco_atual * COALESCE(
                    (SELECT AVG(r.ratio) FROM ratio_preco r
                     WHERE r.id_filho = pp.id_filho AND r.id_localidade = pp.id_localidade), 1.0
                ), 4) AS preco_projetado,
                ROUND(pp.pai_preco_referencia * COALESCE(
                    (SELECT AVG(r.ratio) FROM ratio_preco r
                     WHERE r.id_filho = pp.id_filho AND r.id_localidade = pp.id_localidade), 1.0
                ), 4) AS preco_referencia,
                pp.pai_status_cor, pp.pai_confianca
            FROM projecao_pai pp
        )
        INSERT INTO mart.sazonalidade_produto (
            id_produto, id_localidade, ano, mes,
            preco_atual, preco_referencia,
            data_referencia_atual,
            status_cor, fonte, calculado_em,
            is_forecast, baseline_confianca, forecast_method,
            usou_fallback_12m
        )
        SELECT
            pf.id_filho, pf.id_localidade, 2026, pf.mes,
            pf.preco_projetado, pf.preco_referencia,
            2026::TEXT || '-' || LPAD(pf.mes::TEXT, 2, '0'),
            COALESCE(
                staging.fn_status_cor_regra_25(pf.preco_projetado, pf.preco_referencia),
                'AMARELO'
            ) AS status_cor,
            'BASELINE_HISTORICO',
            NOW(),
            TRUE,
            pf.pai_confianca,
            'PROXY_HIERARQUICO',
            FALSE
        FROM proxy_final pf
        WHERE pf.preco_projetado IS NOT NULL AND pf.preco_projetado > 0
        ON CONFLICT (id_produto, id_localidade, ano, mes)
        DO UPDATE SET
            preco_atual        = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                      THEN mart.sazonalidade_produto.preco_atual
                                      ELSE EXCLUDED.preco_atual END,
            preco_referencia   = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                      THEN mart.sazonalidade_produto.preco_referencia
                                      ELSE EXCLUDED.preco_referencia END,
            status_cor         = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                      THEN mart.sazonalidade_produto.status_cor
                                      ELSE EXCLUDED.status_cor END,
            is_forecast        = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE THEN FALSE ELSE TRUE END,
            baseline_confianca = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                      THEN mart.sazonalidade_produto.baseline_confianca
                                      ELSE EXCLUDED.baseline_confianca END,
            forecast_method    = 'PROXY_HIERARQUICO',
            usou_fallback_12m  = COALESCE(mart.sazonalidade_produto.usou_fallback_12m, FALSE),
            calculado_em       = NOW();

        GET DIAGNOSTICS v_total = ROW_COUNT;
        RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 3 — Proxy: % linhas.', v_total;
    ELSE
        RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 3 — Nenhum órfão com pai.';
    END IF;

    DROP TABLE IF EXISTS tmp_orphans_proxy;

    WITH proxy_flat AS (
        SELECT s.id_sazonalidade, s.id_produto AS id_filho, s.id_localidade, s.mes,
               s.preco_referencia AS filho_ref
        FROM mart.sazonalidade_produto s
        WHERE s.ano = 2026
          AND s.mes BETWEEN v_mes_atual + 1 AND 12
          AND s.is_forecast = TRUE
          AND s.forecast_method = 'PROXY_HIERARQUICO'
          AND s.preco_atual IS NOT NULL AND s.preco_atual > 0
          AND s.preco_referencia IS NOT NULL AND s.preco_referencia > 0
          AND ABS(s.preco_atual - s.preco_referencia) < 0.0001
    ),
    filhos_distintos AS (
        SELECT DISTINCT s.id_produto AS id_filho, s.mes,
               SPLIT_PART(dp.nome_produto, ' ', 1) AS palavra
        FROM mart.sazonalidade_produto s
        JOIN staging.dim_produto dp ON dp.id_produto = s.id_produto
        WHERE s.ano = 2026
          AND s.mes BETWEEN v_mes_atual + 1 AND 12
          AND s.is_forecast = TRUE
          AND s.forecast_method = 'PROXY_HIERARQUICO'
          AND s.preco_atual IS NOT NULL AND s.preco_atual > 0
          AND s.preco_referencia IS NOT NULL AND s.preco_referencia > 0
          AND ABS(s.preco_atual - s.preco_referencia) < 0.0001
    ),
    pai_candidates AS (
        SELECT fd.id_filho, fd.mes, p.id_produto AS id_pai,
               EXISTS(
                   SELECT 1 FROM mart.sazonalidade_produto sp
                   WHERE sp.id_produto = p.id_produto
                     AND sp.mes = fd.mes AND sp.ano = 2026
                     AND sp.is_forecast = TRUE
                     AND sp.forecast_method = 'SANDUICHE_FATOR_SAZONAL'
                     AND sp.preco_atual IS NOT NULL AND sp.preco_atual > 0
               ) AS tem_fator,
               LENGTH(p.nome_produto) AS len_nome
        FROM filhos_distintos fd
        JOIN staging.dim_produto p
          ON p.nome_produto ILIKE fd.palavra || '%'
         AND p.id_produto <> fd.id_filho
        WHERE EXISTS (
            SELECT 1 FROM mart.sazonalidade_produto sp
            WHERE sp.id_produto = p.id_produto
              AND sp.mes = fd.mes AND sp.ano = 2026
              AND sp.is_forecast = TRUE
              AND sp.forecast_method IN ('SANDUICHE_MEDIA_24_25', 'SANDUICHE_FATOR_SAZONAL', 'PROXY_HIERARQUICO')
              AND sp.preco_atual IS NOT NULL AND sp.preco_atual > 0
        )
    ),
    melhor_pai AS (
        SELECT DISTINCT ON (pc.id_filho, pc.mes)
               pc.id_filho, pc.mes, pc.id_pai
        FROM pai_candidates pc
        ORDER BY pc.id_filho, pc.mes, pc.tem_fator DESC, pc.len_nome ASC
    ),
    projecao_pai AS (
        SELECT
            pf.id_sazonalidade, pf.id_filho, pf.id_localidade, pf.mes, pf.filho_ref,
            s.preco_atual AS pai_preco_atual,
            s.preco_referencia AS pai_preco_referencia
        FROM proxy_flat pf
        JOIN melhor_pai mp ON mp.id_filho = pf.id_filho AND mp.mes = pf.mes
        JOIN mart.sazonalidade_produto s
          ON s.id_produto = mp.id_pai
         AND s.id_localidade = pf.id_localidade
         AND s.ano = 2026 AND s.mes = pf.mes AND s.is_forecast = TRUE
        WHERE s.preco_atual IS NOT NULL AND s.preco_atual > 0
          AND s.preco_referencia IS NOT NULL AND s.preco_referencia > 0
    ),
    reproj AS (
        SELECT
            pp.id_sazonalidade,
            CASE
                WHEN pp.filho_ref IS NOT NULL AND pp.filho_ref > 0
                     AND pp.pai_preco_referencia IS NOT NULL
                     AND pp.pai_preco_referencia > 0
                THEN ROUND(pp.filho_ref * (pp.pai_preco_atual / pp.pai_preco_referencia), 4)
                ELSE pp.pai_preco_atual
            END AS preco_projetado,
            CASE
                WHEN pp.filho_ref IS NOT NULL AND pp.filho_ref > 0
                THEN pp.filho_ref
                ELSE pp.pai_preco_referencia
            END AS preco_referencia
        FROM projecao_pai pp
    )
    UPDATE mart.sazonalidade_produto s
    SET
        preco_atual        = r.preco_projetado,
        preco_referencia   = r.preco_referencia,
        status_cor         = COALESCE(
            staging.fn_status_cor_regra_25(r.preco_projetado, r.preco_referencia),
            'AMARELO'
        ),
        forecast_method    = 'PROXY_HIERARQUICO',
        calculado_em       = NOW()
    FROM reproj r
    WHERE s.id_sazonalidade = r.id_sazonalidade
      AND r.preco_projetado IS NOT NULL AND r.preco_projetado > 0
      AND r.preco_referencia IS NOT NULL AND r.preco_referencia > 0
      AND ABS(r.preco_projetado - r.preco_referencia) >= 0.0001;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 3b — Proxies reprojetados (variação do pai, escala do filho): % linhas.', v_total;

    WITH recalc_forecast AS (
        SELECT
            id_sazonalidade,
            CASE
                WHEN preco_atual IS NULL OR preco_atual <= 0 THEN 'AMARELO'
                ELSE COALESCE(
                    staging.fn_status_cor_regra_25(preco_atual, preco_referencia),
                    status_cor
                )
            END AS novo_status_cor
        FROM mart.sazonalidade_produto
        WHERE ano = 2026
          AND is_forecast = TRUE
    )
    UPDATE mart.sazonalidade_produto s
    SET status_cor   = r.novo_status_cor,
        calculado_em = NOW()
    FROM recalc_forecast r
    WHERE s.id_sazonalidade = r.id_sazonalidade
      AND r.novo_status_cor IS DISTINCT FROM s.status_cor;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 4 — Recalc ±25%%: % linhas.', v_total;

    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Concluído em % seg.',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$procedure$;

-- =============================================================================
-- FASE 3 — REFRESH DA MATERIALIZED VIEW + ENCERRAMENTO
-- =============================================================================

COMMIT;

-- O REFRESH roda FORA da transação (padrão das migrations 54-56).
REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- =============================================================================
-- VERIFICAÇÃO MANUAL
-- -----------------------------------------------------------------------------
-- 1) Legadas expurgadas (esperado: 0):
--    SELECT COUNT(*) FROM mart.sazonalidade_produto
--    WHERE forecast_method IS NULL AND is_forecast = TRUE;
--
-- 2) Backup preservado:
--    SELECT COUNT(*) FROM mart.sazonalidade_legado_backup_57;
--
-- 3) Nova distribuição de cores (Nacional), 2026 forecast:
--    SELECT status_cor, COUNT(*) FROM mart.sazonalidade_produto
--    WHERE ano = 2026 AND is_forecast = TRUE GROUP BY status_cor;
--
-- 4) Nova distribuição por UF:
--    SELECT l.uf, s.status_cor, COUNT(*) AS n
--    FROM mart.sazonalidade_produto s
--    JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
--    WHERE s.ano = 2026 AND s.is_forecast = TRUE
--    GROUP BY l.uf, s.status_cor ORDER BY l.uf, s.status_cor;
--
-- 5) MV refrescada:
--    SELECT MAX(calculado_em) FROM mart.vw_api_produtos_sazonalidade;
--
-- 6) Função ±25% ativa:
--    SELECT staging.fn_status_cor_regra_25(10, 8)  -- VERMELHO (10 > 8*1.25=10? não, 10 = 10 -> AMARELO)
--    SELECT staging.fn_status_cor_regra_25(9, 8)   -- AMARELO
--    SELECT staging.fn_status_cor_regra_25(5, 8)   -- VERDE   (5 < 8*0.75=6)
-- =============================================================================
