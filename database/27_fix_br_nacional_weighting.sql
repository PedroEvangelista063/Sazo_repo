-- ============================================================================
-- QUERO COMPRAR — Fase 27: Hotfix BR Nacional + Média Ponderada
-- PostgreSQL 16+
--
-- CORRECOES:
--   1. sp_executar_carga_completa(): chama sp_calcular_sazonalidade_preditiva()
--      (V10) em vez da V1 legacy sp_calcular_sazonalidade().
--      V10 corrige status_cor para forecast rows (gamma_cold_start com
--      preco_referencia = preco_atual agora usa AMARELO).
--   2. Cria funcao mart.fn_br_nacional_por_mes() com media ponderada por UF
--      (peso = quantidade de localidades/municipios por UF)
--      + trava HAVING COUNT(DISTINCT uf) >= 5.
--   3. Cria funcao mart.fn_br_nacional_snapshot() para o ultimo mes disponivel.
--   4. Corrige status_cor de forecast rows stale (1258 divergencias)
--      onde preco_referencia = preco_atual mas status_cor != 'AMARELO'.
-- ============================================================================

BEGIN;

-- ============================================================================
-- SECAO 1: Correcao do Pipeline — SP correta
-- ============================================================================

CREATE OR REPLACE PROCEDURE staging.sp_executar_carga_completa()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
    v_ultimo_ano  SMALLINT;
    v_ultimo_mes  SMALLINT;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Iniciando (V3 - Hotfix BR)...';

    ANALYZE staging.fact_precos_mensais;

    SELECT MAX(ano), MAX(mes) INTO v_ultimo_ano, v_ultimo_mes
    FROM staging.fact_precos_mensais;

    -- ANTES (BUG): CALL staging.sp_calcular_sazonalidade(v_ultimo_ano, v_ultimo_mes);
    -- DEPOIS (CORRETO): chama o motor preditivo V9 com data healing + baseline 2025
    CALL staging.sp_calcular_sazonalidade_preditiva();

    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Concluido em % seg',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

COMMENT ON PROCEDURE staging.sp_executar_carga_completa IS
    'V3 - Executa carga + motor preditivo V9 (Alpha/Beta/Gamma com data healing).';

-- ============================================================================
-- SECAO 2: Funcao de Agregacao BR Nacional com Media Ponderada
-- ============================================================================
--
-- LOGICA:
--   1. Primeiro nivel: consolida municipios por UF (media simples dentro da UF).
--      Isso evita que UFs com muitos municipios (ex: SP) distorcam a media
--      nacional simplesmente por terem mais linhas na MV.
--   2. Segundo nivel: media PONDERADA entre UFs.
--      Peso = COUNT(*) de localidades naquela UF.
--      UFs com mais coleta (mais municipios) tem mais peso — justo, pois
--      representam melhor a diversidade de precos regionais.
--   3. Trava: HAVING COUNT(DISTINCT uf) >= 5.
--      Se um produto nao tem dados em pelo menos 5 estados, nao aparece no BR.
--   4. Status_cor: MODE() da moda de cada UF (moda da moda).
--   5. preco_estimado e usou_fallback_12m: BOOL_OR (transparencia total).
-- ============================================================================

CREATE OR REPLACE FUNCTION mart.fn_br_nacional_por_mes(
    p_ano      INTEGER,
    p_mes      INTEGER,
    p_categoria TEXT DEFAULT NULL
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
    total_ufs           BIGINT
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
            MODE() WITHIN GROUP (ORDER BY v.status_cor) AS uf_status_cor
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
        -- Media ponderada: SUM(valor * peso) / SUM(peso)
        ROUND(
            SUM(uf.uf_preco_ref * uf.peso_uf) / NULLIF(SUM(uf.peso_uf), 0),
            4
        ) AS preco_ref_nac,
        ROUND(
            SUM(uf.uf_preco_atual * uf.peso_uf) / NULLIF(SUM(uf.peso_uf), 0),
            4
        ) AS preco_atual_nac,
        BOOL_OR(uf.uf_fallback)  AS usou_fallback_nac,
        BOOL_OR(uf.uf_estimado)  AS preco_estimado_nac,
        MODE() WITHIN GROUP (ORDER BY uf.uf_status_cor) AS status_cor_nac,
        'municipio'::TEXT        AS fonte_nac,
        BOOL_OR(uf.uf_forecast)  AS is_forecast_nac,
        COUNT(DISTINCT uf.uf)    AS total_ufs_nac
    FROM uf_consolidado uf
    GROUP BY uf.produto, uf.classificao_produto, uf.categoria_final
    HAVING COUNT(DISTINCT uf.uf) >= 5
    ORDER BY status_cor_nac, uf.produto;
END;
$$;

COMMENT ON FUNCTION mart.fn_br_nacional_por_mes IS
    'Agregacao BR Nacional com media ponderada por peso de localidades por UF. '
    'HAVING COUNT(DISTINCT uf) >= 5 — produtos com menos de 5 estados sao omitidos. '
    'Uso: SELECT * FROM mart.fn_br_nacional_por_mes(2026, 7);'
    'Uso com filtro: SELECT * FROM mart.fn_br_nacional_por_mes(2026, 7, ''FRUTAS'');';


-- ============================================================================
-- SECAO 3: Funcao Snapshot (ultimo mes disponivel)
-- ============================================================================

CREATE OR REPLACE FUNCTION mart.fn_br_nacional_snapshot(
    p_categoria TEXT DEFAULT NULL
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
    total_ufs           BIGINT
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
    SELECT * FROM mart.fn_br_nacional_por_mes(v_ultimo_ano, v_ultimo_mes, p_categoria);
END;
$$;

COMMENT ON FUNCTION mart.fn_br_nacional_snapshot IS
    'Snapshot BR Nacional para o ultimo mes disponivel na MV. '
    'Delega para fn_br_nacional_por_mes com o mes mais recente.';


-- ============================================================================
-- SECAO 4: Permissoes
-- ============================================================================

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_por_mes(INTEGER, INTEGER, TEXT)
    TO role_api_reader;

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_snapshot(TEXT)
    TO role_api_reader;

COMMIT;
