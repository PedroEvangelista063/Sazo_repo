-- ============================================================================
-- QUERO COMPRAR — Fase 30: Engine Preditiva — Forecast 2026 com Baseline 24-25
-- PostgreSQL 16+
--
-- OBJETIVO:
--   Implementar a Regra de Negócio de Forecasting para 2026:
--     1. Proibir interpolação linear (Data Healing) para meses futuros do ano vigente
--     2. Projetar meses sem dado real usando a MODA do status_cor do Baseline 2024-2025
--     3. Marcar projeção com is_forecast = TRUE + tendencia_futura (QUEDA/ALTA/ESTAVEL)
--     4. UPSERT orgânico: quando scraper traz dado real, substitui projeção e is_forecast = FALSE
--
-- ARQUITETURA (4 CTEs + 1 UPSERT):
--   1. baseline_ponderado   — FULL JOIN das baselines 25_26 (primária) e 24_25 (fallback*0.5)
--   2. dados_reais_2026     — Linhas reais vindas do scraper (is_interpolado = FALSE)
--   3. projecao_faltantes   — Gera linhas para meses 2026 sem dado real, usando baseline
--   4. uniao_final          — UNION ALL dados_reais + projecao_faltantes
--   5. UPSERT em mart.sazonalidade_produto + REFRESH MV
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 0: Dropar MV PRIMEIRO para permitir ALTER TABLE nas colunas usadas pela MV
-- ============================================================================

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

-- ============================================================================
-- SEÇÃO 1: DDL — Garantir colunas de forecast na mart
-- ============================================================================

-- is_forecast já existe (Fase 26), mas garantimos default
ALTER TABLE mart.sazonalidade_produto
    ALTER COLUMN is_forecast SET DEFAULT FALSE,
    ALTER COLUMN tendencia_futura TYPE TEXT;

-- Nova coluna: baseline_confianca (0-100) — % de meses com dado no baseline
ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS baseline_confianca NUMERIC(5,2) DEFAULT 0;

COMMENT ON COLUMN mart.sazonalidade_produto.baseline_confianca IS
    'Percentual de meses (2024-2025) com dado real para este (produto,localidade,mes). '
    'Usado para ordenar/filtrar projeções no frontend.';

-- Nova coluna: forecast_method — rastreabilidade
ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS forecast_method TEXT
        CHECK (forecast_method IS NULL 
               OR forecast_method IN ('gamma_forecast_baseline', 'alpha_baseline_25_26', 'beta_media_disponivel', 'beta_weighted_25_24'));

COMMENT ON COLUMN mart.sazonalidade_produto.forecast_method IS
    'Método de geração: NULL=dado real; gamma_forecast_baseline=projetado via baseline histórico.';

-- Índice parcial para buscar projeções rapidamente
CREATE INDEX IF NOT EXISTS idx_sazonalidade_forecast
    ON mart.sazonalidade_produto (is_forecast)
    WHERE is_forecast = TRUE;

-- ============================================================================
-- SEÇÃO 2: Baseline 2024-2025 — Moda do status_cor por mês
-- ============================================================================
-- Cria/Atualiza mart.sazonalidade_baseline_24_25 (tabela permanente)
-- Base: TODOS os dados reais de 2024 e 2025 da mart.sazonalidade_produto (que já têm status_cor)

DROP TABLE IF EXISTS mart.sazonalidade_baseline_24_25;

CREATE TABLE mart.sazonalidade_baseline_24_25 AS
WITH dados_reais AS (
    SELECT
        s.id_produto,
        s.id_localidade,
        CAST(SPLIT_PART(s.data_referencia_atual, '-', 2) AS INTEGER) AS mes,
        s.status_cor,
        COUNT(*) AS freq
    FROM mart.sazonalidade_produto s
    WHERE CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER) IN (2024, 2025)
      AND s.is_forecast = FALSE
    GROUP BY s.id_produto, s.id_localidade, mes, s.status_cor
),
moda_por_mes AS (
    SELECT DISTINCT ON (id_produto, id_localidade, mes)
        id_produto,
        id_localidade,
        mes,
        status_cor AS status_cor_mode,
        freq,
        SUM(freq) OVER (PARTITION BY id_produto, id_localidade, mes) AS total_meses
    FROM dados_reais
    ORDER BY id_produto, id_localidade, mes, freq DESC
)
SELECT
    id_produto,
    id_localidade,
    mes,
    status_cor_mode,
    ROUND((freq::NUMERIC / total_meses) * 100, 2) AS confianca,
    'BASELINE_24_25' AS fonte,
    NOW() AS atualizado_em
FROM moda_por_mes;

COMMENT ON TABLE mart.sazonalidade_baseline_24_25 IS
    'Moda do status_cor por (produto, localidade, mes) calculada sobre 2024-2025 reais. '
    'Usado como fallback para projetar 2026.';

CREATE INDEX IF NOT EXISTS idx_baseline_24_25_mes
    ON mart.sazonalidade_baseline_24_25 (mes);

-- ============================================================================
-- SEÇÃO 2b: Baseline 2025-2026 — Moda do status_cor por mês (real data only)
-- ============================================================================
-- Cria/Atualiza mart.sazonalidade_baseline_25_26 (tabela permanente)
-- Base: TODOS os dados reais de 2025 e 2026 da mart.sazonalidade_produto

DROP TABLE IF EXISTS mart.sazonalidade_baseline_25_26;

CREATE TABLE mart.sazonalidade_baseline_25_26 AS
WITH dados_reais AS (
    SELECT
        s.id_produto,
        s.id_localidade,
        CAST(SPLIT_PART(s.data_referencia_atual, '-', 2) AS INTEGER) AS mes,
        s.status_cor,
        COUNT(*) AS freq
    FROM mart.sazonalidade_produto s
    WHERE CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER) IN (2025, 2026)
      AND s.is_forecast = FALSE
    GROUP BY s.id_produto, s.id_localidade, mes, s.status_cor
),
moda_por_mes AS (
    SELECT DISTINCT ON (id_produto, id_localidade, mes)
        id_produto,
        id_localidade,
        mes,
        status_cor AS status_cor_mode,
        freq,
        SUM(freq) OVER (PARTITION BY id_produto, id_localidade, mes) AS total_meses
    FROM dados_reais
    ORDER BY id_produto, id_localidade, mes, freq DESC
)
SELECT
    id_produto,
    id_localidade,
    mes,
    status_cor_mode,
    ROUND((freq::NUMERIC / total_meses) * 100, 2) AS confianca,
    'BASELINE_25_26' AS fonte,
    NOW() AS atualizado_em
FROM moda_por_mes;

COMMENT ON TABLE mart.sazonalidade_baseline_25_26 IS
    'Moda do status_cor por (produto, localidade, mes) calculada sobre 2025-2026 reais. '
    'Usado como baseline primário para projetar 2026.';

CREATE INDEX IF NOT EXISTS idx_baseline_25_26_mes
    ON mart.sazonalidade_baseline_25_26 (mes);

-- ============================================================================
-- SEÇÃO 3: Stored Procedure — Motor de Forecast 2026
-- ============================================================================

CREATE OR REPLACE PROCEDURE staging.sp_calcular_forecast_2026()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio  TIMESTAMPTZ;
    v_fim     TIMESTAMPTZ;
    v_total   INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_calcular_forecast_2026] Iniciando Forecast 2026...';

    -- --------------------------------------------------------------------
    -- CTE 1: baseline_ponderado — FULL JOIN 25_26 (primária) + 24_25 (fallback*0.5)
    -- --------------------------------------------------------------------
    WITH baseline_ponderado AS (
        SELECT
            COALESCE(bl_25_26.id_produto, bl_24_25.id_produto) AS id_produto,
            COALESCE(bl_25_26.id_localidade, bl_24_25.id_localidade) AS id_localidade,
            COALESCE(bl_25_26.mes, bl_24_25.mes) AS mes,
            COALESCE(bl_25_26.status_cor_mode, bl_24_25.status_cor_mode) AS status_cor_mode,
            CASE
                WHEN bl_25_26.status_cor_mode IS NOT NULL AND bl_25_26.confianca >= 30
                    THEN bl_25_26.confianca
                WHEN bl_24_25.status_cor_mode IS NOT NULL
                    THEN bl_24_25.confianca * 0.5
                ELSE 0
            END AS confianca,
            'beta_weighted_25_24' AS forecast_method
        FROM mart.sazonalidade_baseline_25_26 bl_25_26
        FULL JOIN mart.sazonalidade_baseline_24_25 bl_24_25
            ON bl_25_26.id_produto = bl_24_25.id_produto
           AND bl_25_26.id_localidade = bl_24_25.id_localidade
           AND bl_25_26.mes = bl_24_25.mes
    ),
    -- --------------------------------------------------------------------
    -- CTE 2: dados_reais_2026 — O que o scraper trouxe de real (não interpolado)
    -- FIX: extrai ano e mes de data_referencia_atual para alinhar com uq_sazonalidade
    -- --------------------------------------------------------------------
    dados_reais_2026 AS (
        SELECT DISTINCT
            s.id_produto,
            s.id_localidade,
            CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER) AS ano,
            CAST(SPLIT_PART(s.data_referencia_atual, '-', 2) AS INTEGER) AS mes,
            s.preco_atual,
            s.preco_referencia,
            s.data_referencia_atual,
            s.preco_estimado,
            s.usou_fallback_12m,
            s.status_cor,
            s.fonte,
            s.calculado_em,
            s.metodo_calculo,
            s.variacao_mom_pct,
            s.preco_mes_anterior,
            FALSE AS is_forecast,
            s.tendencia_futura,
            0::NUMERIC(5,2) AS baseline_confianca,
            NULL::TEXT AS forecast_method
        FROM mart.sazonalidade_produto s
        WHERE CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER) = 2026
          AND s.is_forecast = FALSE
    ),
    -- --------------------------------------------------------------------
    -- CTE 3: projecao_faltantes — Meses 2026 SEM dado real → usa baseline
    -- --------------------------------------------------------------------
    meses_2026 AS (
        SELECT generate_series(1, 12) AS mes
    ),
    produtos_com_baseline AS (
        SELECT DISTINCT id_produto, id_localidade
        FROM baseline_ponderado
    ),
    grade_completa AS (
        SELECT
            p.id_produto,
            p.id_localidade,
            m.mes
        FROM produtos_com_baseline p
        CROSS JOIN meses_2026 m
    ),
    meses_com_dado_real AS (
        SELECT DISTINCT id_produto, id_localidade, mes
        FROM dados_reais_2026
    ),
    meses_faltantes AS (
        SELECT g.id_produto, g.id_localidade, g.mes
        FROM grade_completa g
        LEFT JOIN meses_com_dado_real r
            ON r.id_produto = g.id_produto
           AND r.id_localidade = g.id_localidade
           AND r.mes = g.mes
        WHERE r.id_produto IS NULL
    ),
    projecao_faltantes AS (
        SELECT
            mf.id_produto,
            mf.id_localidade,
            2026 AS ano,
            mf.mes,
            b.status_cor_mode       AS status_cor,
            b.confianca             AS baseline_confianca,
            'beta_weighted_25_24' AS metodo_calculo,
            TRUE                    AS is_forecast,
            'BASELINE_HISTORICO'::TEXT AS fonte,
            NOW()                   AS calculado_em,
            CASE
                WHEN LAG(b.status_cor_mode) OVER (PARTITION BY b.id_produto, b.id_localidade ORDER BY b.mes) IS NULL
                    THEN 'ESTAVEL'
                WHEN LAG(b.status_cor_mode) OVER (PARTITION BY b.id_produto, b.id_localidade ORDER BY b.mes) = b.status_cor_mode
                    THEN 'ESTAVEL'
                WHEN LAG(b.status_cor_mode) OVER (PARTITION BY b.id_produto, b.id_localidade ORDER BY b.mes) = 'VERDE'
                     AND b.status_cor_mode = 'AMARELO'
                    THEN 'ALTA'
                WHEN LAG(b.status_cor_mode) OVER (PARTITION BY b.id_produto, b.id_localidade ORDER BY b.mes) = 'AMARELO'
                     AND b.status_cor_mode = 'VERDE'
                    THEN 'QUEDA'
                WHEN LAG(b.status_cor_mode) OVER (PARTITION BY b.id_produto, b.id_localidade ORDER BY b.mes) = 'VERMELHO'
                     AND b.status_cor_mode = 'AMARELO'
                    THEN 'QUEDA'
                WHEN LAG(b.status_cor_mode) OVER (PARTITION BY b.id_produto, b.id_localidade ORDER BY b.mes) = 'AMARELO'
                     AND b.status_cor_mode = 'VERMELHO'
                    THEN 'ALTA'
                ELSE 'ESTAVEL'
            END AS tendencia_futura,
            2026::TEXT || '-' || LPAD(mf.mes::TEXT, 2, '0') AS data_referencia_atual,
            b.confianca,
            NULL::NUMERIC(14,4)     AS preco_referencia,
            NULL::NUMERIC(14,4)     AS preco_atual,
            NULL::NUMERIC(14,4)     AS preco_mes_anterior,
            0::NUMERIC(8,4)         AS variacao_mom_pct,
            FALSE                   AS preco_estimado,
            FALSE                   AS usou_fallback_12m,
            'beta_weighted_25_24' AS forecast_method
        FROM meses_faltantes mf
        JOIN baseline_ponderado b
            ON b.id_produto = mf.id_produto
           AND b.id_localidade = mf.id_localidade
           AND b.mes = mf.mes
    ),
    -- --------------------------------------------------------------------
    -- CTE 4: uniao_final — Real + Projetado
    -- FIX: adicionado ano, mes nas duas branches (UNION ALL por posição)
    -- --------------------------------------------------------------------
    uniao_final AS (
        SELECT
            id_produto, id_localidade, ano, mes,
            preco_atual, preco_referencia,
            data_referencia_atual,
            usou_fallback_12m,
            preco_estimado, status_cor, fonte,
            metodo_calculo,
            variacao_mom_pct,
            preco_mes_anterior,
            tendencia_futura,
            is_forecast,
            baseline_confianca,
            forecast_method
        FROM dados_reais_2026
        UNION ALL
        SELECT
            id_produto, id_localidade, ano, mes,
            preco_atual, preco_referencia,
            data_referencia_atual,
            usou_fallback_12m,
            preco_estimado, status_cor, fonte,
            metodo_calculo,
            variacao_mom_pct,
            preco_mes_anterior,
            tendencia_futura,
            is_forecast,
            baseline_confianca,
            forecast_method
        FROM projecao_faltantes
    )
    -- --------------------------------------------------------------------
    -- UPSERT em mart.sazonalidade_produto
    -- FIX: adicionado ano, mes no INSERT e SELECT
    -- FIX: ON CONFLICT alterado para (id_produto, id_localidade, ano, mes)
    -- FIX: DISTINCT ON com ORDER BY u.is_forecast ASC (dado real > projeção)
    -- --------------------------------------------------------------------
    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade, ano, mes,
        preco_referencia, preco_atual,
        data_referencia_atual, usou_fallback_12m,
        preco_estimado, status_cor, fonte, calculado_em,
        metodo_calculo, variacao_mom_pct, preco_mes_anterior,
        tendencia_futura, is_forecast,
        baseline_confianca, forecast_method
    )
    SELECT DISTINCT ON (u.id_produto, u.id_localidade, u.ano, u.mes)
        u.id_produto,
        u.id_localidade,
        u.ano,
        u.mes,
        ROUND(u.preco_referencia, 4),
        u.preco_atual,
        u.data_referencia_atual,
        u.usou_fallback_12m,
        u.preco_estimado,
        u.status_cor,
        u.fonte,
        NOW(),
        u.metodo_calculo,
        u.variacao_mom_pct,
        u.preco_mes_anterior,
        u.tendencia_futura,
        u.is_forecast,
        u.baseline_confianca,
        u.forecast_method
    FROM uniao_final u
    ORDER BY u.id_produto, u.id_localidade, u.ano, u.mes, u.is_forecast ASC
    ON CONFLICT (id_produto, id_localidade, ano, mes)
    DO UPDATE SET
        preco_referencia      = EXCLUDED.preco_referencia,
        preco_atual           = EXCLUDED.preco_atual,
        usou_fallback_12m     = EXCLUDED.usou_fallback_12m,
        preco_estimado        = EXCLUDED.preco_estimado,
        status_cor            = EXCLUDED.status_cor,
        fonte                 = EXCLUDED.fonte,
        calculado_em          = NOW(),
        metodo_calculo        = EXCLUDED.metodo_calculo,
        variacao_mom_pct      = EXCLUDED.variacao_mom_pct,
        preco_mes_anterior    = EXCLUDED.preco_mes_anterior,
        is_forecast           = CASE
                                    WHEN EXCLUDED.is_forecast = FALSE THEN FALSE
                                    WHEN mart.sazonalidade_produto.is_forecast = TRUE
                                         AND EXCLUDED.is_forecast = TRUE
                                    THEN TRUE
                                    ELSE mart.sazonalidade_produto.is_forecast
                                END,
        tendencia_futura      = EXCLUDED.tendencia_futura,
        baseline_confianca    = EXCLUDED.baseline_confianca,
        forecast_method       = EXCLUDED.forecast_method;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_forecast_2026] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);

    -- Refresh da MV
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
    RAISE NOTICE '[sp_calcular_forecast_2026] MV atualizada.';
END;
$$;

COMMENT ON PROCEDURE staging.sp_calcular_forecast_2026 IS
    'Engine Preditiva 2026 — Projeta meses sem dado real usando baseline ponderado (25_26 primária + 24_25 fallback*0.5). '
    'is_forecast=TRUE para projeções; dado real (scraper) substitui e seta is_forecast=FALSE.';

-- ============================================================================
-- SEÇÃO 4: Materialized View V14 — com is_forecast + baseline_confianca + forecast_method
-- ============================================================================

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
SELECT
    s.id_sazonalidade,
    s.id_localidade,
    p.id_produto,
    p.nome_produto              AS produto,
    p.classificao_produto,
    p.conab_id_produto,
    p.status_fonte,
    COALESCE(c.nome_categoria, 'ALIMENTO_VAREJO') AS categoria,
    l.uf,
    l.municipio_nome            AS municipio,
    l.municipio_id,
    CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER) AS ano,
    CAST(SPLIT_PART(s.data_referencia_atual, '-', 2) AS INTEGER) AS mes,
    s.preco_referencia,
    s.preco_atual,
    s.data_referencia_atual,
    s.usou_fallback_12m,
    s.preco_estimado,
    s.status_cor,
    s.fonte,
    s.calculado_em,
    s.metodo_calculo,
    s.variacao_mom_pct          AS variacao_pct,
    s.tendencia_futura,
    s.is_forecast,
    s.baseline_confianca,
    s.forecast_method
FROM mart.sazonalidade_produto s
JOIN staging.dim_produto    p ON p.id_produto    = s.id_produto
JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
LEFT JOIN staging.dim_categoria c ON c.id_categoria = p.id_categoria
WHERE s.status_cor IN ('VERDE', 'AMARELO', 'VERMELHO')
  AND p.categoria_b2c = 'ALIMENTO_VAREJO'
  AND (p.classificao_produto IS NULL
       OR p.classificao_produto NOT IN ('INSUMO_AGRICOLA', 'MAQUINARIO_FERRAMENTA', 'SERVICO_LOGISTICA'))
  AND (c.nome_categoria IS NULL
       OR c.nome_categoria NOT IN ('FLORES', 'OUTROS'))
  AND CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER) >= 2025
ORDER BY s.is_forecast, s.status_cor, p.nome_produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'View B2C V14 — Forecast + Real. '
    'Inclui is_forecast (TRUE = projeção baseline), baseline_confianca, forecast_method. '
    'Dados reais (is_forecast=FALSE) ordenados antes dos projetados.';

-- Índices
CREATE UNIQUE INDEX IF NOT EXISTS idx_vw_sazonalidade_unico
    ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_filtro
    ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_categoria
    ON mart.vw_api_produtos_sazonalidade (categoria);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_produto
    ON mart.vw_api_produtos_sazonalidade (id_produto);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_ano_mes
    ON mart.vw_api_produtos_sazonalidade (ano, mes)
    WHERE ano IS NOT NULL AND mes IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_forecast
    ON mart.vw_api_produtos_sazonalidade (is_forecast)
    WHERE is_forecast = TRUE;

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_confianca
    ON mart.vw_api_produtos_sazonalidade (baseline_confianca DESC)
    WHERE is_forecast = TRUE;

-- ============================================================================
-- SEÇÃO 5: Atualizar sp_executar_carga_completa para incluir forecast
-- ============================================================================

CREATE OR REPLACE PROCEDURE staging.sp_executar_carga_completa()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Iniciando pipeline completo...';

    -- 1. Carga bruta (landing → staging)
    CALL staging.sp_carregar_landing_para_staging();
    RAISE NOTICE '[sp_executar_carga_completa] Landing → Staging OK';

    -- 2. Limpeza/normalização
    CALL staging.sp_limpar_e_normalizar_staging();
    RAISE NOTICE '[sp_executar_carga_completa] Normalização OK';

    -- 3. Enriquecimento CONAB → variedades
    CALL staging.sp_sincronizar_variedades_conab();
    RAISE NOTICE '[sp_executar_carga_completa] Sincronização CONAB OK';

    -- 4. Cálculo sazonalidade (dados reais 2025+)
    CALL staging.sp_calcular_sazonalidade_v11();
    RAISE NOTICE '[sp_executar_carga_completa] Sazonalidade v11 OK';

    -- 5. NOVO: Forecast 2026 (projeta meses faltantes via baseline 24-25)
    CALL staging.sp_calcular_forecast_2026();
    RAISE NOTICE '[sp_executar_carga_completa] Forecast 2026 OK';

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Pipeline completo em % seg',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

COMMENT ON PROCEDURE staging.sp_executar_carga_completa IS
    'Pipeline completo V12 — Executa carga + sazonalidade V11 + Forecast 2026. '
    'Deve ser chamado após cada ciclo de coleta do scraper.';

-- ============================================================================
-- SEÇÃO 6: Permissões
-- ============================================================================

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;
GRANT SELECT ON mart.sazonalidade_baseline_24_25 TO role_api_reader;
GRANT ALL ON PROCEDURE staging.sp_calcular_forecast_2026 TO role_etl_writer;
GRANT ALL ON PROCEDURE staging.sp_executar_carga_completa TO role_etl_writer;

COMMIT;