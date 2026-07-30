-- ============================================================================
-- QUERO COMPRAR — Fase 37: confianca_baseline nas funções BR + Regional
-- PostgreSQL 16+
--
-- Adiciona coluna ``confianca_baseline`` ao RETURNS TABLE de todas as 4
-- funções BR/Regionais para que a API possa exibir o indicador sem
-- hardcoded ``None``.
--
-- NOTA: DROP + CREATE porque PG não permite CREATE OR REPLACE com RETURNS
-- diferente (mesmo com RETURNS TABLE expandido).
-- ============================================================================

BEGIN;

-- ============================================================================
-- Drop functions (permissão para recriar com novo RETURNS TABLE)
-- ============================================================================

DROP FUNCTION IF EXISTS mart.fn_br_nacional_por_mes(INTEGER, INTEGER, TEXT, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS mart.fn_br_nacional_snapshot(TEXT, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS mart.fn_regional_por_mes(TEXT[], INTEGER, INTEGER, INTEGER, TEXT, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS mart.fn_regional_snapshot(TEXT[], INTEGER, TEXT, INTEGER, INTEGER);

-- ============================================================================
-- 1. mart.fn_br_nacional_por_mes — baseline_confianca (MV → AVG ponderado)
-- ============================================================================

CREATE FUNCTION mart.fn_br_nacional_por_mes(
    p_ano       INTEGER,
    p_mes       INTEGER,
    p_categoria TEXT DEFAULT NULL,
    p_limit     INTEGER DEFAULT NULL,
    p_offset    INTEGER DEFAULT 0
)
RETURNS TABLE(
    produto             TEXT,
    classificao_produto TEXT,
    categoria           TEXT,
    uf                  TEXT,
    municipio           TEXT,
    municipio_id        TEXT,
    ano                 INTEGER,
    mes                 INTEGER,
    data_referencia_atual TEXT,
    preco_referencia    NUMERIC,
    preco_atual         NUMERIC,
    usou_fallback_12m   BOOLEAN,
    preco_estimado      BOOLEAN,
    status_cor          TEXT,
    fonte               TEXT,
    is_forecast         BOOLEAN,
    total_ufs           BIGINT,
    confianca_baseline  NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_categoria_filter TEXT := COALESCE(p_categoria, '%%');
BEGIN
    RETURN QUERY
    WITH uf_consolidado AS (
        SELECT
            v.produto,
            v.classificao_produto,
            COALESCE(v.categoria, 'ALIMENTO_VAREJO') AS categoria_final,
            v.uf,
            COUNT(*)::NUMERIC AS peso_uf,
            AVG(v.preco_referencia) AS uf_preco_ref,
            AVG(v.preco_atual)      AS uf_preco_atual,
            BOOL_OR(v.usou_fallback_12m) AS uf_fallback,
            BOOL_OR(v.preco_estimado)    AS uf_estimado,
            BOOL_OR(v.is_forecast)       AS uf_forecast,
            MODE() WITHIN GROUP (ORDER BY v.status_cor) AS uf_status_cor,
            MAX(v.baseline_confianca)    AS uf_confianca
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.ano = p_ano
          AND v.mes = p_mes
          AND (p_categoria IS NULL OR v.categoria ILIKE v_categoria_filter)
        GROUP BY v.produto, v.classificao_produto, v.categoria_final, v.uf
    )
    SELECT
        uf.produto,
        uf.classificao_produto,
        uf.categoria_final,
        'BR'::TEXT                    AS uf_nacional,
        'BRASIL'::TEXT                AS municipio_nome,
        '0'::TEXT                     AS municipio_id_val,
        p_ano                         AS ano_val,
        p_mes                         AS mes_val,
        (p_ano || '-' || LPAD(p_mes::TEXT, 2, '0'))::TEXT AS data_ref,
        ROUND(SUM(uf.uf_preco_ref * uf.peso_uf) / NULLIF(SUM(uf.peso_uf), 0), 4) AS preco_ref_nac,
        ROUND(SUM(uf.uf_preco_atual * uf.peso_uf) / NULLIF(SUM(uf.peso_uf), 0), 4) AS preco_atual_nac,
        BOOL_OR(uf.uf_fallback)  AS usou_fallback_nac,
        BOOL_OR(uf.uf_estimado)  AS preco_estimado_nac,
        MODE() WITHIN GROUP (ORDER BY uf.uf_status_cor) AS status_cor_nac,
        'municipio'::TEXT        AS fonte_nac,
        BOOL_OR(uf.uf_forecast)  AS is_forecast_nac,
        COUNT(DISTINCT uf.uf)    AS total_ufs_nac,
        ROUND(
            SUM(uf.uf_confianca * uf.peso_uf) / NULLIF(SUM(uf.peso_uf), 0),
            4
        ) AS confianca_baseline_nac
    FROM uf_consolidado uf
    GROUP BY uf.produto, uf.classificao_produto, uf.categoria_final
    HAVING COUNT(DISTINCT uf.uf) >= 5
    ORDER BY status_cor_nac, uf.produto
    LIMIT p_limit OFFSET p_offset;
END;
$$;

COMMENT ON FUNCTION mart.fn_br_nacional_por_mes IS
    'Agregação BR Nacional com paginação + confianca_baseline.';

-- ============================================================================
-- 2. mart.fn_br_nacional_snapshot (delega para por_mes)
-- ============================================================================

CREATE FUNCTION mart.fn_br_nacional_snapshot(
    p_categoria TEXT DEFAULT NULL,
    p_limit     INTEGER DEFAULT NULL,
    p_offset    INTEGER DEFAULT 0
)
RETURNS TABLE(
    produto             TEXT,
    classificao_produto TEXT,
    categoria           TEXT,
    uf                  TEXT,
    municipio           TEXT,
    municipio_id        TEXT,
    ano                 INTEGER,
    mes                 INTEGER,
    data_referencia_atual TEXT,
    preco_referencia    NUMERIC,
    preco_atual         NUMERIC,
    usou_fallback_12m   BOOLEAN,
    preco_estimado      BOOLEAN,
    status_cor          TEXT,
    fonte               TEXT,
    is_forecast         BOOLEAN,
    total_ufs           BIGINT,
    confianca_baseline  NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_ultimo_ano INTEGER;
    v_ultimo_mes INTEGER;
BEGIN
    SELECT MAX(v.ano), MAX(v.mes) FILTER (WHERE v.ano = (SELECT MAX(v2.ano) FROM mart.vw_api_produtos_sazonalidade v2))
    INTO v_ultimo_ano, v_ultimo_mes
    FROM mart.vw_api_produtos_sazonalidade v;

    IF v_ultimo_ano IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT * FROM mart.fn_br_nacional_por_mes(v_ultimo_ano, v_ultimo_mes, p_categoria, p_limit, p_offset);
END;
$$;

COMMENT ON FUNCTION mart.fn_br_nacional_snapshot IS
    'Snapshot BR Nacional com paginação + confianca_baseline.';

-- ============================================================================
-- 3. mart.fn_regional_por_mes — baseline_confianca via AVG
-- ============================================================================

CREATE FUNCTION mart.fn_regional_por_mes(
    p_ufs       TEXT[],
    p_min_ufs   INTEGER DEFAULT 2,
    p_ano       INTEGER DEFAULT NULL,
    p_mes       INTEGER DEFAULT NULL,
    p_categoria TEXT DEFAULT NULL,
    p_limit     INTEGER DEFAULT NULL,
    p_offset    INTEGER DEFAULT 0
)
RETURNS TABLE(
    produto             TEXT,
    classificao_produto TEXT,
    categoria           TEXT,
    uf                  TEXT,
    municipio           TEXT,
    status_cor          TEXT,
    total_ufs           BIGINT,
    data_referencia_atual TEXT,
    is_forecast         BOOLEAN,
    fonte               TEXT,
    ano                 INTEGER,
    mes                 INTEGER,
    confianca_baseline  NUMERIC
)
LANGUAGE SQL
STABLE
AS $$
    WITH regional_data AS (
        SELECT DISTINCT ON (v.id_produto, v.uf)
            v.id_produto,
            v.produto,
            v.classificao_produto,
            v.categoria,
            v.uf,
            v.municipio,
            v.status_cor,
            v.ano,
            v.mes,
            v.data_referencia_atual,
            v.is_forecast,
            v.fonte,
            v.baseline_confianca
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.uf = ANY(p_ufs)
          AND (p_categoria IS NULL OR v.categoria = p_categoria)
          AND (p_ano IS NULL OR v.ano = p_ano)
          AND (p_mes IS NULL OR v.mes = p_mes)
        ORDER BY v.id_produto, v.uf, v.ano DESC, v.mes DESC
    ),
    regional_moda AS (
        SELECT
            id_produto,
            COUNT(DISTINCT uf) AS total_ufs,
            MODE() WITHIN GROUP (ORDER BY status_cor) AS moda_status,
            AVG(baseline_confianca) AS avg_confianca
        FROM regional_data
        GROUP BY id_produto
        HAVING COUNT(DISTINCT uf) >= p_min_ufs
    )
    SELECT
        lp.produto::TEXT,
        lp.classificao_produto::TEXT,
        lp.categoria::TEXT,
        p_ufs[1]::TEXT AS uf,
        'REGIÃO'::TEXT AS municipio,
        rm.moda_status::TEXT AS status_cor,
        rm.total_ufs::BIGINT,
        MAX(lp.data_referencia_atual)::TEXT AS data_referencia_atual,
        BOOL_OR(lp.is_forecast) AS is_forecast,
        'regiao'::TEXT AS fonte,
        COALESCE(p_ano, MAX(lp.ano))::INTEGER AS ano,
        COALESCE(p_mes, MAX(lp.mes))::INTEGER AS mes,
        ROUND(rm.avg_confianca, 4)::NUMERIC AS confianca_baseline
    FROM regional_moda rm
    JOIN regional_data lp ON lp.id_produto = rm.id_produto
    GROUP BY lp.produto, lp.classificao_produto, lp.categoria, rm.moda_status, rm.total_ufs, rm.avg_confianca
    ORDER BY rm.moda_status, lp.produto
    LIMIT p_limit OFFSET p_offset;
$$;

COMMENT ON FUNCTION mart.fn_regional_por_mes IS
    'Agregação regional por mês com paginação + confianca_baseline.';

-- ============================================================================
-- 4. mart.fn_regional_snapshot — baseline_confianca via AVG
-- ============================================================================

CREATE FUNCTION mart.fn_regional_snapshot(
    p_ufs       TEXT[],
    p_min_ufs   INTEGER DEFAULT 2,
    p_categoria TEXT DEFAULT NULL,
    p_limit     INTEGER DEFAULT NULL,
    p_offset    INTEGER DEFAULT 0
)
RETURNS TABLE(
    produto             TEXT,
    classificao_produto TEXT,
    categoria           TEXT,
    uf                  TEXT,
    municipio           TEXT,
    status_cor          TEXT,
    total_ufs           BIGINT,
    data_referencia_atual TEXT,
    is_forecast         BOOLEAN,
    fonte               TEXT,
    ano                 INTEGER,
    mes                 INTEGER,
    confianca_baseline  NUMERIC
)
LANGUAGE SQL
STABLE
AS $$
    WITH latest_per_uf AS (
        SELECT DISTINCT ON (v.id_produto, v.uf)
            v.id_produto,
            v.produto,
            v.classificao_produto,
            v.categoria,
            v.uf,
            v.municipio,
            v.status_cor,
            v.ano,
            v.mes,
            v.data_referencia_atual,
            v.is_forecast,
            v.fonte,
            v.baseline_confianca
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.uf = ANY(p_ufs)
          AND (p_categoria IS NULL OR v.categoria = p_categoria)
        ORDER BY v.id_produto, v.uf, v.ano DESC, v.mes DESC
    ),
    regional_moda AS (
        SELECT
            id_produto,
            COUNT(DISTINCT uf) AS total_ufs,
            MODE() WITHIN GROUP (ORDER BY status_cor) AS moda_status,
            AVG(baseline_confianca) AS avg_confianca
        FROM latest_per_uf
        GROUP BY id_produto
        HAVING COUNT(DISTINCT uf) >= p_min_ufs
    )
    SELECT
        lp.produto::TEXT,
        lp.classificao_produto::TEXT,
        lp.categoria::TEXT,
        p_ufs[1]::TEXT AS uf,
        'REGIÃO'::TEXT AS municipio,
        rm.moda_status::TEXT AS status_cor,
        rm.total_ufs::BIGINT,
        MAX(lp.data_referencia_atual)::TEXT AS data_referencia_atual,
        BOOL_OR(lp.is_forecast) AS is_forecast,
        'regiao'::TEXT AS fonte,
        MAX(lp.ano)::INTEGER AS ano,
        MAX(lp.mes)::INTEGER AS mes,
        ROUND(rm.avg_confianca, 4)::NUMERIC AS confianca_baseline
    FROM regional_moda rm
    JOIN latest_per_uf lp ON lp.id_produto = rm.id_produto
    GROUP BY lp.produto, lp.classificao_produto, lp.categoria, rm.moda_status, rm.total_ufs, rm.avg_confianca
    ORDER BY rm.moda_status, lp.produto
    LIMIT p_limit OFFSET p_offset;
$$;

COMMENT ON FUNCTION mart.fn_regional_snapshot IS
    'Snapshot regional com paginação + confianca_baseline.';

-- ============================================================================
-- 5. Permissões
-- ============================================================================

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_por_mes(INTEGER, INTEGER, TEXT, INTEGER, INTEGER)
    TO role_api_reader;
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_snapshot(TEXT, INTEGER, INTEGER)
    TO role_api_reader;
GRANT EXECUTE ON FUNCTION mart.fn_regional_por_mes(TEXT[], INTEGER, INTEGER, INTEGER, TEXT, INTEGER, INTEGER)
    TO role_api_reader;
GRANT EXECUTE ON FUNCTION mart.fn_regional_snapshot(TEXT[], INTEGER, TEXT, INTEGER, INTEGER)
    TO role_api_reader;

COMMIT;
