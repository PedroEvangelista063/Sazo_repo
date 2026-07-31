-- ============================================================================
-- QUERO COMPRAR — Fase 51: Índice de Sazonalidade Relativa no Forecast 2026
-- PostgreSQL 16+
--
-- PROBLEMA (limite matemático):
--   O Sanduíche Sazonal (40/50) injeta preco_atual sintético usando média
--   histórica plana + tendência linear. Quando a tendência é 0 ou o mês não
--   tem variação interanual, preco_atual fica IDÊNTICO a preco_referencia,
--   travando a variação em 0% e forçando AMARELO "estrutural" em ~100% dos
--   forecasts sem tendência. A grade futura perde a volatilidade orgânica.
--
-- SOLUÇÃO — ÍNDICE DE SAZONALIDADE RELATIVO:
--   Em vez de uma média plana, usamos o desvio histórico do MÊS em relação à
--   média global do produto/localidade (2024-2025):
--
--     Fator Sazonal = (Média do Mês / Média Global) - 1
--
--   E aplicamos o MOMENTUM no preço projetado:
--
--     preco_atual     = Preço Base 2026 * (1 + Fator Sazonal do Mês)
--     preco_referencia = Preço Base 2026
--
--   Assim, se Outubro é historicamente mês de safra (preço baixo), o forecast
--   é empurrado para baixo (ex: -20%), cruzando a barreira dos 15% e ativando
--   o VERDE legitimamente. Se o mês é de entressafra (+20%), ativa VERMELHO.
--
--   Preço Base 2026 = média REAL do produto/localidade nos meses já
--   observados de 2026 (Jan-Jul); fallback = média global 2024-2025.
--   Fator Sazonal calculado por (produto, localidade, mês) com fallback por UF.
--   O semáforo (fn_status_cor_regra_15 da Fase 50, ±15%) é aplicado LOGO APÓS
--   a injeção do novo preço.
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: Funções auxiliares do Índice de Sazonalidade
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1.1 fn_preco_base_2026: média real de 2026 (is_forecast=FALSE) do par
--     (produto, localidade). Fallback: média global 2024-2025.
--     Retorna NULL se nada existir.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION staging.fn_preco_base_2026(
    p_id_produto      INTEGER,
    p_id_localidade   INTEGER
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT AVG(s.preco_atual)
         FROM mart.sazonalidade_produto s
         WHERE s.id_produto    = p_id_produto
           AND s.id_localidade = p_id_localidade
           AND s.ano           = 2026
           AND s.is_forecast   = FALSE
           AND s.preco_atual IS NOT NULL
           AND s.preco_atual   > 0),
        (SELECT AVG(f.preco_medio)
         FROM staging.fact_precos_mensais f
         WHERE f.id_produto    = p_id_produto
           AND f.id_localidade = p_id_localidade
           AND f.ano IN (2024, 2025)
           AND f.preco_medio IS NOT NULL
           AND f.preco_medio   > 0)
    )
$$;

COMMENT ON FUNCTION staging.fn_preco_base_2026 IS
    'Preço base para a projeção: média real 2026 do par (produto, localidade); '
    'fallback = média global 2024-2025. NULL se sem dados.';

-- ----------------------------------------------------------------------------
-- 1.2 fn_fator_sazonal_mensal: (Média do Mês / Média Global) - 1
--     Nível 1: por (produto, localidade, mês) 2024-2025.
--     Nível 2 (fallback): por (produto, UF, mês) 2024-2025.
--     Exige >= 6 meses distintos na série global (robustez).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION staging.fn_fator_sazonal_mensal(
    p_id_produto      INTEGER,
    p_id_localidade   INTEGER,
    p_mes             SMALLINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_mm         NUMERIC;   -- média do mês (produto, localidade)
    v_mg         NUMERIC;   -- média global (produto, localidade)
    v_md         NUMERIC;   -- mediana do par (sanitização de outliers)
    v_meses      INTEGER;
    v_uf         CHAR(2);
    v_uf_mm      NUMERIC;   -- média do mês (produto, UF)
    v_uf_mg      NUMERIC;   -- média global (produto, UF)
    v_uf_md      NUMERIC;   -- mediana do par (produto, UF)
    v_uf_meses   INTEGER;
BEGIN
    -- ── Nível 1: (produto, localidade) ──
    SELECT
        AVG(f.preco_medio) FILTER (WHERE f.mes = p_mes),
        AVG(f.preco_medio),
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.preco_medio),
        COUNT(DISTINCT f.mes)
    INTO v_mm, v_mg, v_md, v_meses
    FROM staging.fact_precos_mensais f
    WHERE f.id_produto    = p_id_produto
      AND f.id_localidade = p_id_localidade
      AND f.ano IN (2024, 2025)
      AND f.preco_medio IS NOT NULL
      AND f.preco_medio   > 0;

    -- Sanitização de outlier: a média do mês precisa estar entre 0,5x e 2,0x
    -- a mediana do par (protege de preços digitados errado no dado cru).
    IF v_mm IS NOT NULL AND v_mg IS NOT NULL AND v_mg > 0 AND v_md IS NOT NULL
       AND v_meses >= 6
       AND v_mm >= v_md * 0.5 AND v_mm <= v_md * 2.0 THEN
        RETURN ROUND((v_mm / v_mg) - 1, 4);
    END IF;

    -- ── Nível 2 (fallback): (produto, UF) ──
    SELECT l.uf INTO v_uf
    FROM staging.dim_localidade l
    WHERE l.id_localidade = p_id_localidade;

    IF v_uf IS NOT NULL THEN
        SELECT
            AVG(f.preco_medio) FILTER (WHERE f.mes = p_mes),
            AVG(f.preco_medio),
            PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.preco_medio),
            COUNT(DISTINCT f.mes)
        INTO v_uf_mm, v_uf_mg, v_uf_md, v_uf_meses
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
        WHERE f.id_produto = p_id_produto
          AND l.uf         = v_uf
          AND f.ano IN (2024, 2025)
          AND f.preco_medio IS NOT NULL
          AND f.preco_medio   > 0;

        IF v_uf_mm IS NOT NULL AND v_uf_mg IS NOT NULL AND v_uf_mg > 0 AND v_uf_md IS NOT NULL
           AND v_uf_meses >= 6
           AND v_uf_mm >= v_uf_md * 0.5 AND v_uf_mm <= v_uf_md * 2.0 THEN
            RETURN ROUND((v_uf_mm / v_uf_mg) - 1, 4);
        END IF;
    END IF;

    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION staging.fn_fator_sazonal_mensal IS
    'Índice de Sazonalidade Relativa: (Média do Mês / Média Global) - 1 '
    'para 2024-2025. Nível produto+localidade, fallback por UF. '
    'Requer série global com >= 6 meses distintos. Sanitiza outliers '
    '(média do mês fora da banda 0,5x-2,0x da mediana do par → NULL). '
    'NULL se sem dados.';

-- ============================================================================
-- SEÇÃO 2: FASE 2 — sp_project_sandwich_prices_2026 com Momentum Sazonal
-- ============================================================================
-- Step 2 (pre-fill futuro) passa a injetar:
--   preco_atual      = preco_base * (1 + fator_sazonal)
--   preco_referencia = preco_base
--   status_cor       = fn_status_cor_regra_15(preco_atual, preco_referencia)
-- Se o fator sazonal não existir, mantém a média plana (variação 0% → AMARELO),
-- preservando o comportamento conservador das Fases 40/50.
-- ============================================================================

CREATE OR REPLACE PROCEDURE staging.sp_project_sandwich_prices_2026()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio     TIMESTAMPTZ;
    v_fim        TIMESTAMPTZ;
    v_total      INTEGER;
    v_mes_atual  INTEGER;
    v_proxy      INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    v_mes_atual := EXTRACT(MONTH FROM NOW())::INTEGER;

    RAISE NOTICE '[sp_project_sandwich_prices_2026] Iniciando Sanduíche Sazonal v2 (mês atual: %)...', v_mes_atual;

    -- ====================================================================
    -- STEP 1: PATCH RETROATIVO (Jan a mês atual)
    -- ====================================================================
    WITH precos_patch AS (
        SELECT
            s.id_sazonalidade,
            s.id_produto,
            s.id_localidade,
            s.ano, s.mes,
            h.preco_medio_historico,
            h.tendencia_pct,
            h.confianca
        FROM mart.sazonalidade_produto s
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
        preco_atual        = ROUND(p.preco_medio_historico * (1 + p.tendencia_pct / 100), 4),
        preco_referencia   = ROUND(p.preco_medio_historico, 4),
        status_cor         = COALESCE(
            staging.fn_status_cor_regra_15(
                ROUND(p.preco_medio_historico * (1 + p.tendencia_pct / 100), 4),
                ROUND(p.preco_medio_historico, 4)
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

    -- ====================================================================
    -- STEP 2: PRE-FILL FUTURO (mês atual+1 até Dezembro) — FATOR SAZONAL
    -- ====================================================================
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
            -- FIX 51: base = média real 2026; fallback média 2024-25
            COALESCE(
                staging.fn_preco_base_2026(msr.id_produto, msr.id_localidade),
                h.preco_medio_historico
            ) AS preco_base,
            -- FIX 51: momentum sazonal (pode ser NULL → variação 0%)
            staging.fn_fator_sazonal_mensal(
                msr.id_produto, msr.id_localidade, msr.mes::SMALLINT
            ) AS fator_sazonal,
            GREATEST(h.confianca, COALESCE(b.confianca, 0)) AS confianca
        FROM meses_sem_real msr
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
            id_produto, id_localidade, mes, preco_base, fator_sazonal, confianca,
            ROUND(preco_base * (1 + COALESCE(fator_sazonal, 0)), 4) AS preco_atual,
            ROUND(preco_base, 4) AS preco_referencia
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
        -- FIX 51: semáforo ±15% aplicado LOGO APÓS a injeção do novo preço
        COALESCE(
            staging.fn_status_cor_regra_15(pf.preco_atual, pf.preco_referencia),
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

    -- ====================================================================
    -- STEP 2b: VARRE os forecasts futuros JÁ EXISTENTES (criados pela
    -- Engine 30 / versões anteriores) e aplica o momentum sazonal neles.
    -- Aplica SOMENTE em linhas is_forecast=TRUE (nunca sobrescreve real).
    -- ====================================================================
    WITH recalc_futuro AS (
        SELECT
            s.id_sazonalidade,
            COALESCE(
                staging.fn_preco_base_2026(s.id_produto, s.id_localidade),
                s.preco_referencia
            ) AS preco_base,
            staging.fn_fator_sazonal_mensal(
                s.id_produto, s.id_localidade, s.mes::SMALLINT
            ) AS fator_sazonal
        FROM mart.sazonalidade_produto s
        WHERE s.ano = 2026
          AND s.mes BETWEEN v_mes_atual + 1 AND 12
          AND s.is_forecast = TRUE
          AND s.preco_atual IS NOT NULL
          AND s.preco_atual > 0
    ),
    recalc_final AS (
        SELECT
            r.id_sazonalidade,
            ROUND(r.preco_base * (1 + COALESCE(r.fator_sazonal, 0)), 4) AS preco_atual,
            ROUND(r.preco_base, 4) AS preco_referencia,
            r.fator_sazonal
        FROM recalc_futuro r
        WHERE r.preco_base IS NOT NULL AND r.preco_base > 0
    )
    UPDATE mart.sazonalidade_produto s
    SET
        preco_atual        = r.preco_atual,
        preco_referencia   = r.preco_referencia,
        status_cor         = COALESCE(
            staging.fn_status_cor_regra_15(r.preco_atual, r.preco_referencia),
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

    -- ====================================================================
    -- STEP 3: PROXY HIERÁRQUICO — Produto Pai para Órfãos
    -- ====================================================================
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
                staging.fn_status_cor_regra_15(pf.preco_projetado, pf.preco_referencia),
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

    -- ====================================================================
    -- STEP 4 (FIX 50): VARREDURA FINAL — recalcula ±15% em 2026 forecast
    -- ====================================================================
    WITH recalc_forecast AS (
        SELECT
            id_sazonalidade,
            CASE
                WHEN preco_atual IS NULL OR preco_atual <= 0 THEN 'AMARELO'
                ELSE COALESCE(
                    staging.fn_status_cor_regra_15(preco_atual, preco_referencia),
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
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 4 — Recalc ±15%%: % linhas.', v_total;

    -- ====================================================================
    -- Refresh da MV
    -- ====================================================================
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Concluído em % seg.',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

COMMENT ON PROCEDURE staging.sp_project_sandwich_prices_2026 IS
    'Sanduíche Sazonal v2 — Fase 51. Injetar preço com Índice de Sazonalidade '
    'Relativa: preco_atual = base * (1 + fator_sazonal); fator = (média do mês '
    '/ média global 2024-2025) - 1. Base = média real 2026, fallback média global. '
    'status_cor derivado da regra ±15% (fn_status_cor_regra_15) logo após a '
    'injeção. ON CONFLICT preserva dado real (is_forecast=FALSE).';

-- ============================================================================
-- SEÇÃO 3: Permissões
-- ============================================================================
GRANT EXECUTE ON FUNCTION staging.fn_preco_base_2026(INTEGER, INTEGER)
    TO role_etl_writer;
GRANT EXECUTE ON FUNCTION staging.fn_fator_sazonal_mensal(INTEGER, INTEGER, SMALLINT)
    TO role_etl_writer;
GRANT ALL ON PROCEDURE staging.sp_project_sandwich_prices_2026
    TO role_etl_writer;

COMMIT;
