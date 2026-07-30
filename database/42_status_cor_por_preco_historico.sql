-- ============================================================================
-- QUERO COMPRAR — Fase 42: Status Cor por Preço Histórico
-- PostgreSQL 16+
--
-- OBJETIVO:
--   Substituir o fallback fixo 'AMARELO' por um semáforo calculado a partir
--   dos preços reais de 2024-2025. Antes, quando um produto não tinha
--   registro na tabela sazonalidade_baseline_24_25, o sistema usava
--   'AMARELO' como padrão — resultando em 87% da grade amarela.
--
--   Agora, calculamos o status_cor comparando o preço do mês alvo contra
--   a média anual do (produto, localidade):
--     < 90% da média anual → 🟢 VERDE (safra/melhor época)
--     ±10% da média anual  → 🟡 AMARELO (preço normal)
--     > 110% da média anual→ 🔴 VERMELHO (entressafra)
--
--   Threshold de 10% calibrado com base em 31.884 registros reais:
--     21% VERDE | 62% AMARELO | 17% VERMELHO
--
-- MUDANÇAS:
--   1. Cria fn_calcular_status_cor_por_preco()
--   2. Atualiza Step 2 da procedure: COALESCE(b.status_cor_mode, fn(...), 'AMARELO')
--   3. Atualiza Step 3 da procedure: COALESCE(fn(filho), pai_status_cor, 'AMARELO')
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: Função — Calcular status_cor a partir de preços históricos
-- ============================================================================
-- Compara o preço médio de um mês específico contra a média anual do
-- (produto, localidade). Retorna VERDE/AMARELO/VERMELHO ou NULL se não
-- houver dados suficientes.
--
-- Threshold de 10% (calibrado empiricamente):
--   - VERDE:   preço do mês < 90% da média anual
--   - VERMELHO: preço do mês > 110% da média anual
--   - AMARELO: dentro da faixa ±10%

CREATE OR REPLACE FUNCTION staging.fn_calcular_status_cor_por_preco(
    p_id_produto    INTEGER,
    p_id_localidade INTEGER,
    p_mes           SMALLINT
)
RETURNS TEXT  -- 'VERDE', 'AMARELO', 'VERMELHO', ou NULL
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_preco_mes     NUMERIC(14,4);
    v_media_anual   NUMERIC(14,4);
    v_threshold     CONSTANT NUMERIC(4,2) := 0.10;  -- 10%
BEGIN
    -- Preço médio do mês específico (2024-2025)
    SELECT AVG(f.preco_medio) INTO v_preco_mes
    FROM staging.fact_precos_mensais f
    WHERE f.id_produto    = p_id_produto
      AND f.id_localidade = p_id_localidade
      AND f.mes           = p_mes
      AND f.ano IN (2024, 2025)
      AND f.preco_medio IS NOT NULL
      AND f.preco_medio > 0;

    IF v_preco_mes IS NULL THEN
        RETURN NULL;  -- sem dados para este mês
    END IF;

    -- Média anual do (produto, localidade) em 2024-2025
    SELECT AVG(f.preco_medio) INTO v_media_anual
    FROM staging.fact_precos_mensais f
    WHERE f.id_produto    = p_id_produto
      AND f.id_localidade = p_id_localidade
      AND f.ano IN (2024, 2025)
      AND f.preco_medio IS NOT NULL
      AND f.preco_medio > 0;

    IF v_media_anual IS NULL OR v_media_anual = 0 THEN
        RETURN NULL;
    END IF;

    -- Classificação por threshold
    IF v_preco_mes < v_media_anual * (1.0 - v_threshold) THEN
        RETURN 'VERDE';     -- abaixo da média → safra/melhor época
    ELSIF v_preco_mes > v_media_anual * (1.0 + v_threshold) THEN
        RETURN 'VERMELHO';  -- acima da média → entressafra
    ELSE
        RETURN 'AMARELO';   -- dentro da faixa normal
    END IF;
END;
$$;

COMMENT ON FUNCTION staging.fn_calcular_status_cor_por_preco IS
    'Calcula status_cor (VERDE/AMARELO/VERMELHO) comparando o preço do mês '
    'contra a média anual do (produto, localidade) em 2024-2025. '
    'Threshold: ±10%. Retorna NULL se não houver dados suficientes.';

-- ============================================================================
-- SEÇÃO 2: Atualizar sp_project_sandwich_prices_2026
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

    RAISE NOTICE '[sp_project_sandwich_prices_2026] Iniciando Sanduíche Sazonal (mês atual: %)...', v_mes_atual;

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
        baseline_confianca = GREATEST(s.baseline_confianca, p.confianca),
        forecast_method    = 'SANDUICHE_MEDIA_24_25',
        usou_fallback_12m  = COALESCE(s.usou_fallback_12m, FALSE),
        calculado_em       = NOW()
    FROM precos_patch p
    WHERE s.id_sazonalidade = p.id_sazonalidade;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 1 — Patch retroativo (Jan-%): % linhas.', v_mes_atual, v_total;

    -- ====================================================================
    -- STEP 2: PRE-FILL FUTURO (mês atual+1 até Dezembro)
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
        msr.id_produto,
        msr.id_localidade,
        2026,
        msr.mes,
        ROUND(h.preco_medio_historico * (1 + h.tendencia_pct / 100), 4),
        ROUND(h.preco_medio_historico, 4),
        2026::TEXT || '-' || LPAD(msr.mes::TEXT, 2, '0'),
        -- FIX 42: Não usa mais 'AMARELO' fixo — calcula dos preços históricos
        COALESCE(
            b.status_cor_mode,
            staging.fn_calcular_status_cor_por_preco(
                msr.id_produto, msr.id_localidade, msr.mes
            ),
            'AMARELO'
        ) AS status_cor,
        'BASELINE_HISTORICO',
        NOW(),
        TRUE,
        GREATEST(h.confianca, COALESCE(b.confianca, 0)),
        'SANDUICHE_MEDIA_24_25',
        FALSE
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
                                  ELSE 'SANDUICHE_MEDIA_24_25' END,
        usou_fallback_12m  = COALESCE(mart.sazonalidade_produto.usou_fallback_12m, FALSE),
        calculado_em       = NOW();

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 2 — Pre-fill futuro: % linhas.', v_total;

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
                AND s2.forecast_method IN ('SANDUICHE_MEDIA_24_25', 'PROXY_HIERARQUICO')
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
              AND s.forecast_method IN ('SANDUICHE_MEDIA_24_25', 'PROXY_HIERARQUICO')
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
            -- FIX 42: Tenta calcular do filho, depois do pai, depois AMARELO
            COALESCE(
                staging.fn_calcular_status_cor_por_preco(
                    pf.id_filho, pf.id_localidade, pf.mes
                ),
                pf.pai_status_cor,
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
    -- Refresh da MV
    -- ====================================================================
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Concluído em % seg.',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

-- ============================================================================
-- SEÇÃO 3: Permissões
-- ============================================================================
GRANT EXECUTE ON FUNCTION staging.fn_calcular_status_cor_por_preco TO role_etl_writer;
GRANT ALL ON PROCEDURE staging.sp_project_sandwich_prices_2026 TO role_etl_writer;

COMMIT;
