-- ============================================================================
-- QUERO COMPRAR — Fase 50: Padronização do Semáforo ±15% nos Dados Projetados
-- PostgreSQL 16+
--
-- PROBLEMA (diagnosticado):
--   O Sanduíche Sazonal (40) e a Engine Preditiva (30) injetam preco_atual
--   sintético mas mantêm um status_cor HERDADO (moda da baseline 24-25/25-26),
--   que não reflete a regra matemática oficial do projeto (±15%):
--     - variações de 0% classificadas como VERDE/VERMELHO
--     - variações de +40% classificadas como VERDE (ex.: Repolho Roxo Nov/26)
--   A Fase 42 criou fn_calcular_status_cor_por_preco com threshold ±10% e
--   ainda prioriza b.status_cor_mode — regra divergente da oficial.
--
-- CORREÇÃO (regra oficial — PROJECT_RULES.md Fase 6):
--   status_cor deriva EXCLUSIVAMENTE de preco_atual vs preco_referencia:
--     preco_atual <  ref * 0.85  → 'VERDE'
--     preco_atual >  ref * 1.15  → 'VERMELHO'
--     senão (incl. preco_atual = ref) → 'AMARELO'
--   Âncora da referência: COALESCE(preco_referencia, preco_atual) — se não
--   houver referência, variação = 0 → AMARELO (regra Gamma).
--
-- FASES:
--   1. fn_status_cor_regra_15() — única fonte de verdade do semáforo.
--   2. Correção retroativa: UPDATE em TODAS as linhas computáveis com cor
--      inconsistente (is_forecast TRUE e real; metodo_calculo NULL incluído).
--   3. Correção na raiz: sp_project_sandwich_prices_2026 recalcula status_cor
--      matematicamente nos Steps 1/2/3 + varredura final em 2026 forecast.
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: Função canônica — Semáforo pela Regra ±15%
-- ============================================================================
-- Única fonte de verdade. Retorna NULL se o preço atual não existir/for <= 0
-- (o chamador decide o fallback, normalmente AMARELO).
-- ============================================================================

CREATE OR REPLACE FUNCTION staging.fn_status_cor_regra_15(
    p_preco_atual      NUMERIC,
    p_preco_referencia NUMERIC
)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
        WHEN p_preco_atual IS NULL OR p_preco_atual <= 0 THEN NULL
        WHEN p_preco_atual < COALESCE(p_preco_referencia, p_preco_atual) * 0.85 THEN 'VERDE'
        WHEN p_preco_atual > COALESCE(p_preco_referencia, p_preco_atual) * 1.15 THEN 'VERMELHO'
        ELSE 'AMARELO'
    END
$$;

COMMENT ON FUNCTION staging.fn_status_cor_regra_15 IS
    'Semáforo oficial ±15%: preco_atual < ref*0.85 → VERDE; > ref*1.15 → VERMELHO; '
    'senão AMARELO. ref = COALESCE(preco_referencia, preco_atual). '
    'Retorna NULL se preco_atual IS NULL ou <= 0. '
    'Substitui a regra ±10% da Fase 42 para dados projetados.';

-- ============================================================================
-- SEÇÃO 2: FASE 1 — Correção retroativa dos dados existentes
-- ============================================================================
-- Recalcula status_cor pela regra oficial em TODAS as linhas computáveis cuja
-- cor atual está inconsistente (cobre is_forecast TRUE e FALSE, metodo_calculo
-- NULL incluído). Linhas sem preço computável permanecem inalteradas.
-- ============================================================================

DO $$
DECLARE
    v_corrigidos INTEGER;
BEGIN
    WITH recalc AS (
        SELECT
            s.id_sazonalidade,
            CASE
                -- Projeção SEM preço → semáforo neutro (a regra ±15% exige preço)
                WHEN (s.preco_atual IS NULL OR s.preco_atual <= 0)
                     AND s.is_forecast = TRUE
                    THEN 'AMARELO'::TEXT
                ELSE COALESCE(
                    staging.fn_status_cor_regra_15(s.preco_atual, s.preco_referencia),
                    s.status_cor
                )
            END AS novo_status_cor
        FROM mart.sazonalidade_produto s
    )
    UPDATE mart.sazonalidade_produto s
    SET status_cor   = r.novo_status_cor,
        calculado_em = NOW()
    FROM recalc r
    WHERE s.id_sazonalidade = r.id_sazonalidade
      AND r.novo_status_cor IS DISTINCT FROM s.status_cor;

    GET DIAGNOSTICS v_corrigidos = ROW_COUNT;
    RAISE NOTICE '[50] Linhas com status_cor corrigido pela regra ±15%%: %', v_corrigidos;
END $$;

-- ============================================================================
-- SEÇÃO 3: FASE 2 — Correção na raiz (sp_project_sandwich_prices_2026)
-- ============================================================================
-- Steps 1/2/3 passam a derivar status_cor da regra ±15% sobre os preços
-- PROJETADOS (nunca mais moda da baseline). Step 4 varre 2026 forecast
-- garantindo consistência mesmo para linhas criadas pela Engine 30.
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
        -- FIX 50: semáforo recalculado pela regra ±15% sobre o preço projetado
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
        -- FIX 50: NÃO usa mais moda da baseline — regra ±15% sobre preço projetado
        COALESCE(
            staging.fn_status_cor_regra_15(
                ROUND(h.preco_medio_historico * (1 + h.tendencia_pct / 100), 4),
                ROUND(h.preco_medio_historico, 4)
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
            -- FIX 50: regra ±15% sobre o preço projetado do FILHO
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
    -- Garante consistência mesmo para linhas criadas pela Engine 30
    -- (que inserem status_cor da moda da baseline antes do preço existir).
    -- ====================================================================
    WITH recalc_forecast AS (
        SELECT
            id_sazonalidade,
            CASE
                -- Projeção SEM preço → semáforo neutro (a regra ±15% exige preço)
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
    'Sanduíche Sazonal — Projeta preços numéricos para 2026. '
    'FIX 50: status_cor derivado SEMPRE da regra ±15%% (fn_status_cor_regra_15) '
    'sobre os preços projetados — nunca mais moda da baseline. '
    'Step 4 varre 2026 forecast para consistência total. '
    'ON CONFLICT preserva dado real (is_forecast=FALSE).';

-- ============================================================================
-- SEÇÃO 4: Permissões
-- ============================================================================
GRANT EXECUTE ON FUNCTION staging.fn_status_cor_regra_15(NUMERIC, NUMERIC)
    TO role_etl_writer;
GRANT ALL ON PROCEDURE staging.sp_project_sandwich_prices_2026
    TO role_etl_writer;

COMMIT;
