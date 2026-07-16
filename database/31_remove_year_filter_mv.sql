-- ============================================================================
-- QUERO COMPRAR — Fase 31: Remover filtro de ano da MV + BR Sazonalidade
-- PostgreSQL 16+
--
-- CORRECOES:
--   1. MV V15: remove filtro >= 2025, expoe dados de 2024, 2025 e 2026
--   2. fn_br_nacional_sazonalidade(): retorna 12 meses de um ano para BR
--   3. fn_br_nacional_por_mes(): mantida para compatibilidade
--   4. Grants atualizados
-- ============================================================================

BEGIN;

-- ============================================================================
-- SECAO 1: MV V15 — sem filtro de ano
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
ORDER BY ano, mes, s.is_forecast, s.status_cor, p.nome_produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'View B2C V15 — Sem filtro de ano. Expoe dados 2024-2026. '
    'Inclui is_forecast, baseline_confianca, forecast_method.';

-- Indices (drop antigos + recriar)
DROP INDEX IF EXISTS mart.idx_vw_sazonalidade_unico;
DROP INDEX IF EXISTS mart.idx_vw_sazonalidade_filtro;
DROP INDEX IF EXISTS mart.idx_vw_sazonalidade_categoria;
DROP INDEX IF EXISTS mart.idx_vw_sazonalidade_produto;
DROP INDEX IF EXISTS mart.idx_vw_sazonalidade_ano_mes;
DROP INDEX IF EXISTS mart.idx_vw_sazonalidade_forecast;
DROP INDEX IF EXISTS mart.idx_vw_sazonalidade_confianca;

CREATE UNIQUE INDEX idx_vw_sazonalidade_unico
    ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

CREATE INDEX idx_vw_sazonalidade_filtro
    ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);

CREATE INDEX idx_vw_sazonalidade_categoria
    ON mart.vw_api_produtos_sazonalidade (categoria);

CREATE INDEX idx_vw_sazonalidade_produto
    ON mart.vw_api_produtos_sazonalidade (id_produto);

CREATE INDEX idx_vw_sazonalidade_ano_mes
    ON mart.vw_api_produtos_sazonalidade (ano, mes)
    WHERE ano IS NOT NULL AND mes IS NOT NULL;

CREATE INDEX idx_vw_sazonalidade_forecast
    ON mart.vw_api_produtos_sazonalidade (is_forecast)
    WHERE is_forecast = TRUE;

CREATE INDEX idx_vw_sazonalidade_confianca
    ON mart.vw_api_produtos_sazonalidade (baseline_confianca DESC)
    WHERE is_forecast = TRUE;

-- ============================================================================
-- SECAO 2: fn_br_nacional_sazonalidade — 12 meses de um ano
-- ============================================================================

CREATE OR REPLACE FUNCTION mart.fn_br_nacional_sazonalidade(
    p_ano      INTEGER,
    p_categoria TEXT DEFAULT NULL
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
BEGIN
    RETURN QUERY
    WITH uf_por_mes AS (
        -- Nivel 1: consolida por (produto, UF, mes) — media simples dentro da UF
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
    -- Nivel 2: agrega por (produto, mes) — moda da moda entre UFs
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
    HAVING COUNT(DISTINCT upm.uf) >= 3
    ORDER BY upm.produto, upm.mes;
END;
$$;

COMMENT ON FUNCTION mart.fn_br_nacional_sazonalidade IS
    'Sazonalidade BR Nacional: retorna 12 meses de um ano. '
    'Moda da moda por UF, HAVING COUNT(DISTINCT uf) >= 3. '
    'Uso: SELECT * FROM mart.fn_br_nacional_sazonalidade(2025);';

-- ============================================================================
-- SECAO 3: Grants
-- ============================================================================

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT)
    TO role_api_reader;

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_por_mes(INTEGER, INTEGER, TEXT)
    TO role_api_reader;

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_snapshot(TEXT)
    TO role_api_reader;

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;

COMMIT;
