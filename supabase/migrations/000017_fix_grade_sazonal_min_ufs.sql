-- ============================================================================
-- Migration 000017: Ajuste de flexibilização de UFs na Grade Sazonal Nacional
-- ============================================================================
-- Propósito: Adicionar parâmetro p_min_ufs (DEFAULT 1) na função mart.fn_br_nacional_sazonalidade.
-- Isso permite exibir produtos com cobertura em menos de 3 UFs na Grade Sazonal,
-- eliminando o gap de informações (ausência de dados) no frontend B2C.

DROP FUNCTION IF EXISTS mart.fn_br_nacional_sazonalidade(INTEGER, TEXT);

CREATE OR REPLACE FUNCTION mart.fn_br_nacional_sazonalidade(
    p_ano       INTEGER,
    p_categoria TEXT DEFAULT NULL,
    p_min_ufs   INTEGER DEFAULT 1
)
RETURNS TABLE(
    produto             TEXT,
    classificao_produto TEXT,
    categoria           TEXT,
    mes                 INTEGER,
    data_referencia_atual TEXT,
    status_cor          TEXT,
    is_forecast         BOOLEAN,
    baseline_confianca  NUMERIC,
    total_ufs           BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_categoria_filter TEXT := COALESCE(p_categoria, '%%');
    v_min_ufs          INTEGER := GREATEST(COALESCE(p_min_ufs, 1), 1);
BEGIN
    RETURN QUERY
    WITH uf_por_mes AS (
        SELECT
            v.produto,
            v.classificao_produto,
            COALESCE(v.categoria, 'ALIMENTO_VAREJO') AS categoria_final,
            v.uf,
            v.mes,
            MODE() WITHIN GROUP (ORDER BY v.status_cor) AS uf_status_cor,
            BOOL_OR(v.is_forecast)       AS uf_forecast,
            MAX(v.baseline_confianca)    AS uf_confianca
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.ano = p_ano
          AND (p_categoria IS NULL OR v.categoria ILIKE v_categoria_filter)
        GROUP BY v.produto, v.classificao_produto, categoria_final, v.uf, v.mes
    )
    SELECT
        upm.produto,
        upm.classificao_produto,
        upm.categoria_final,
        upm.mes,
        (p_ano || '-' || LPAD(upm.mes::TEXT, 2, '0'))::TEXT AS data_ref,
        MODE() WITHIN GROUP (ORDER BY upm.uf_status_cor) AS status_cor_nac,
        BOOL_OR(upm.uf_forecast) AS is_forecast_nac,
        MAX(upm.uf_confianca) AS confianca_nac,
        COUNT(DISTINCT upm.uf) AS total_ufs_nac
    FROM uf_por_mes upm
    GROUP BY upm.produto, upm.classificao_produto, upm.categoria_final, upm.mes
    HAVING COUNT(DISTINCT upm.uf) >= v_min_ufs
    ORDER BY upm.produto, upm.mes;
END;
$$;

COMMENT ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER) IS
    'Sazonalidade BR Nacional: retorna 12 meses de um ano. Moda da moda por UF, HAVING COUNT(DISTINCT uf) >= p_min_ufs (DEFAULT 1).';

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER) TO PUBLIC;
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER) TO role_api_reader;
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER) TO role_etl_writer;
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER) TO anon;
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER) TO service_role;
