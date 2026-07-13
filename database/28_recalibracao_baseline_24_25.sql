-- ============================================================================
-- QUERO COMPRAR — Fase 28: Recalibração do Baseline (Bi-Anual 24-25)
-- PostgreSQL 16+
--
-- DIRETRIZ ARQUITETURAL:
--   Deprecação da "Interpolação Fantasma". Baseline baseado
--   EXCLUSIVAMENTE em preços reais (is_interpolado = FALSE).
--
-- CORRECOES:
--   1. sp_executar_carga_completa(): chama V11 em vez da V10.
--   2. Baseline Primário: AVG(preco) de 2024+2025, apenas dados reais
--      (is_interpolado = FALSE). Remove filtro assassino categoria_b2c.
--   3. Fallback de Segurança: AVG(preco) de 2026 para produtos novos.
--   4. Limpa forecast rows stale (is_forecast = true).
-- ============================================================================

BEGIN;

-- ============================================================================
-- SECAO 1: Migração de Dados — Limpa forecast rows stale
-- ============================================================================

DELETE FROM mart.sazonalidade_produto WHERE is_forecast = true;

-- ============================================================================
-- SECAO 2: Nova Procedure V11 — Baseline Bi-Anual
-- ============================================================================

CREATE OR REPLACE PROCEDURE staging.sp_calcular_sazonalidade_v11()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio  TIMESTAMPTZ;
    v_fim     TIMESTAMPTZ;
    v_total   INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_calcular_sazonalidade_v11] Iniciando V11 (Baseline 24-25)...';

    WITH baseline_24_25 AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            AVG(COALESCE(f.preco_curado, f.preco_medio)) AS media_baseline,
            COUNT(*) AS qtd_meses
        FROM staging.fact_precos_mensais f
        WHERE f.ano IN (2024, 2025)
          AND f.is_interpolado = FALSE
          AND COALESCE(f.preco_curado, f.preco_medio) > 0
        GROUP BY f.id_produto, f.id_localidade
        HAVING COUNT(*) >= 1
    ),
    fallback_2026 AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            AVG(COALESCE(f.preco_curado, f.preco_medio)) AS media_2026,
            COUNT(*) AS qtd_meses_2026
        FROM staging.fact_precos_mensais f
        WHERE f.ano = 2026
          AND f.is_interpolado = FALSE
          AND COALESCE(f.preco_curado, f.preco_medio) > 0
        GROUP BY f.id_produto, f.id_localidade
        HAVING COUNT(*) >= 1
    ),
    base_referencia AS (
        SELECT
            COALESCE(b.id_produto, fb.id_produto) AS id_produto,
            COALESCE(b.id_localidade, fb.id_localidade) AS id_localidade,
            CASE
                WHEN b.media_baseline IS NOT NULL THEN b.media_baseline
                WHEN fb.media_2026 IS NOT NULL THEN fb.media_2026
            END AS preco_referencia_calc,
            CASE
                WHEN b.media_baseline IS NOT NULL THEN 'alpha_baseline_24_25'
                WHEN fb.media_2026 IS NOT NULL THEN 'beta_fallback_2026'
            END AS metodo_calculo,
            CASE WHEN b.media_baseline IS NULL AND fb.media_2026 IS NOT NULL THEN TRUE ELSE FALSE END AS usou_fallback_12m
        FROM baseline_24_25 b
        FULL JOIN fallback_2026 fb
            ON fb.id_produto = b.id_produto
           AND fb.id_localidade = b.id_localidade
    ),
    todos_meses AS (
        SELECT DISTINCT
            f.id_produto,
            f.id_localidade,
            COALESCE(f.preco_curado, f.preco_medio) AS preco_atual,
            f.is_interpolado AS preco_estimado,
            f.ano,
            f.mes,
            f.ano::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0') AS data_referencia_atual
        FROM staging.fact_precos_mensais f
        WHERE f.ano >= 2024
          AND COALESCE(f.preco_curado, f.preco_medio) > 0
    ),
    serie_temporal AS (
        SELECT
            m.*,
            LAG(m.preco_atual) OVER (
                PARTITION BY m.id_produto, m.id_localidade
                ORDER BY m.ano, m.mes
            ) AS preco_mes_anterior
        FROM todos_meses m
    ),
    motor_classificacao AS (
        SELECT
            s.id_produto,
            s.id_localidade,
            s.preco_atual,
            s.data_referencia_atual,
            s.preco_estimado,
            COALESCE(r.preco_referencia_calc, s.preco_atual) AS preco_referencia_calc,
            COALESCE(r.metodo_calculo, 'gamma_cold_start') AS metodo_calculo,
            COALESCE(r.usou_fallback_12m, FALSE) AS usou_fallback_12m,
            CASE
                WHEN s.preco_atual < (COALESCE(r.preco_referencia_calc, s.preco_atual) * 0.85)
                    THEN 'VERDE'
                WHEN s.preco_atual > (COALESCE(r.preco_referencia_calc, s.preco_atual) * 1.15)
                    THEN 'VERMELHO'
                ELSE 'AMARELO'
            END AS status_cor,
            CASE
                WHEN s.preco_atual IS NOT NULL
                 AND COALESCE(r.preco_referencia_calc, s.preco_atual) > 0
                    THEN ROUND(
                        ((s.preco_atual / COALESCE(r.preco_referencia_calc, s.preco_atual)) - 1) * 100,
                        2
                    )
                ELSE 0
            END AS variacao_pct,
            s.preco_mes_anterior,
            CASE
                WHEN s.preco_mes_anterior IS NOT NULL
                 AND s.preco_mes_anterior > 0
                    THEN ROUND(
                        ((s.preco_atual / s.preco_mes_anterior) - 1) * 100,
                        2
                    )
                ELSE NULL
            END AS variacao_mom_pct
        FROM serie_temporal s
        LEFT JOIN base_referencia r
            ON r.id_produto = s.id_produto
           AND r.id_localidade = s.id_localidade
    )
    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade,
        preco_referencia, preco_atual,
        data_referencia_atual, usou_fallback_12m,
        status_cor, fonte, calculado_em,
        metodo_calculo, variacao_mom_pct, preco_mes_anterior,
        preco_estimado
    )
    SELECT
        m.id_produto,
        m.id_localidade,
        ROUND(m.preco_referencia_calc, 4) AS preco_referencia,
        m.preco_atual,
        m.data_referencia_atual,
        m.usou_fallback_12m,
        m.status_cor,
        'municipio'::TEXT AS fonte,
        NOW() AS calculado_em,
        m.metodo_calculo,
        m.variacao_mom_pct,
        m.preco_mes_anterior,
        m.preco_estimado
    FROM motor_classificacao m
    ON CONFLICT (id_produto, id_localidade, data_referencia_atual)
    DO UPDATE SET
        preco_referencia   = EXCLUDED.preco_referencia,
        preco_atual        = EXCLUDED.preco_atual,
        usou_fallback_12m  = EXCLUDED.usou_fallback_12m,
        status_cor         = EXCLUDED.status_cor,
        fonte              = EXCLUDED.fonte,
        calculado_em       = NOW(),
        metodo_calculo     = EXCLUDED.metodo_calculo,
        variacao_mom_pct   = EXCLUDED.variacao_mom_pct,
        preco_mes_anterior = EXCLUDED.preco_mes_anterior,
        preco_estimado     = EXCLUDED.preco_estimado,
        is_forecast        = false;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade_v11] Concluido: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);

    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
    RAISE NOTICE '[sp_calcular_sazonalidade_v11] MV atualizada.';
END;
$$;

-- ============================================================================
-- SECAO 3: Atualiza sp_executar_carga_completa para chamar V11
-- ============================================================================

CREATE OR REPLACE PROCEDURE staging.sp_executar_carga_completa()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Iniciando (V11 - Baseline 24-25)...';

    ANALYZE staging.fact_precos_mensais;

    CALL staging.sp_calcular_sazonalidade_v11();

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Concluido em % seg',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

COMMENT ON PROCEDURE staging.sp_calcular_sazonalidade_v11 IS
    'V11 - Baseline Bi-Anual (2024+2025) com dados reais (is_interpolado=FALSE). '
    'Fallback 2026 para produtos novos. Remove filtro assassino categoria_b2c.';

COMMENT ON PROCEDURE staging.sp_executar_carga_completa IS
    'V11 - Executa carga + motor preditivo V11 (Baseline 24-25).';

-- ============================================================================
-- SECAO 4: Permissoes
-- ============================================================================

GRANT EXECUTE ON PROCEDURE staging.sp_calcular_sazonalidade_v11()
    TO role_api_reader;

COMMIT;
