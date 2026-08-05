-- ============================================================================
-- QUERO COMPRAR — HOTFIX 66: Quality Gate BR Nacional + correção do Erro 500
-- Branch: refatoracao-dado-historico/db
--
-- O QUE FAZ:
--   1. Corrige o bug bloqueante (Erro 500) em mart.fn_br_nacional_por_mes e
--      mart.fn_br_nacional_snapshot: o GROUP BY do nível 1 referenciava
--      `v.categoria_final` (que NÃO é coluna da MV — é alias de
--      COALESCE(v.categoria,'ALIMENTO_VAREJO')). Passa a usar o alias BARE
--      `categoria_final`, como já faz fn_br_nacional_sazonalidade.
--   2. Quality Gate Nacional em fn_br_nacional_por_mes,
--      fn_br_nacional_sazonalidade e na seleção do mês mais recente da
--      fn_br_nacional_snapshot: mantém apenas REAL_ATUAL e HISTORICO_BASE com
--      defasagem <= 1 ano (exclui FALLBACK_DIMENSAO e histórico com defasagem
--      >1 ano; belt-and-suspenders via metadado_transparencia->>'procedencia').
--
-- NÃO faz REFRESH da MV (a MV V17 é recarregada pelo pipeline).
-- NÃO inventa valores para meses futuros: sem dado real a função não emite linha.
-- ============================================================================

BEGIN;

-- ============================================================================
-- FASE 1 + 2 — mart.fn_br_nacional_por_mes
-- Corrige o GROUP BY (alias BARE) e aplica o quality gate no nível 1.
-- Mantém a MESMA assinatura, o MESMO RETURNS TABLE (mesma ordem) e a MESMA
-- estrutura do corpo (CTE uf_consolidado com peso=COUNT localidades, AVG de
-- preço, BOOL_OR de flags, MODE de status_cor; nível 2 com
-- SUM(valor*peso)/SUM(peso), HAVING COUNT(DISTINCT uf)>=5, paginação).
-- ============================================================================

CREATE OR REPLACE FUNCTION mart.fn_br_nacional_por_mes(p_ano integer, p_mes integer, p_categoria text DEFAULT NULL::text, p_limit integer DEFAULT NULL::integer, p_offset integer DEFAULT 0)
 RETURNS TABLE(produto text, classificao_produto text, categoria text, uf text, municipio text, municipio_id text, ano integer, mes integer, data_referencia_atual text, preco_referencia numeric, preco_atual numeric, usou_fallback_12m boolean, preco_estimado boolean, status_cor text, fonte text, is_forecast boolean, total_ufs bigint, confianca_baseline numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
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
          AND v.tipo_dado IN ('REAL_ATUAL', 'HISTORICO_BASE')
          AND COALESCE(v.idade_dado_anos, 0) <= 1
          AND COALESCE(v.metadado_transparencia->>'procedencia', '') NOT LIKE 'sem_historico_real%'
        GROUP BY v.produto, v.classificao_produto, categoria_final, v.uf
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
$function$;

-- ============================================================================
-- FASE 1 + 2 — mart.fn_br_nacional_snapshot
-- Corrige o mesmo bug (a delegação agora usa por_mes corrigido) e aplica o
-- quality gate também na seleção do mês mais recente (MAX(ano)/MAX(mes)) para
-- NÃO escolher um mês que só tenha FALLBACK_DIMENSAO/histórico defasado.
-- ============================================================================

CREATE OR REPLACE FUNCTION mart.fn_br_nacional_snapshot(p_categoria text DEFAULT NULL::text, p_limit integer DEFAULT NULL::integer, p_offset integer DEFAULT 0)
 RETURNS TABLE(produto text, classificao_produto text, categoria text, uf text, municipio text, municipio_id text, ano integer, mes integer, data_referencia_atual text, preco_referencia numeric, preco_atual numeric, usou_fallback_12m boolean, preco_estimado boolean, status_cor text, fonte text, is_forecast boolean, total_ufs bigint, confianca_baseline numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_ultimo_ano INTEGER;
    v_ultimo_mes INTEGER;
BEGIN
    SELECT MAX(v.ano), MAX(v.mes) FILTER (WHERE v.ano = (
        SELECT MAX(v2.ano)
        FROM mart.vw_api_produtos_sazonalidade v2
        WHERE v2.tipo_dado IN ('REAL_ATUAL', 'HISTORICO_BASE')
          AND COALESCE(v2.idade_dado_anos, 0) <= 1
          AND COALESCE(v2.metadado_transparencia->>'procedencia', '') NOT LIKE 'sem_historico_real%'
    ))
    INTO v_ultimo_ano, v_ultimo_mes
    FROM mart.vw_api_produtos_sazonalidade v
    WHERE v.tipo_dado IN ('REAL_ATUAL', 'HISTORICO_BASE')
      AND COALESCE(v.idade_dado_anos, 0) <= 1
      AND COALESCE(v.metadado_transparencia->>'procedencia', '') NOT LIKE 'sem_historico_real%';

    IF v_ultimo_ano IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT * FROM mart.fn_br_nacional_por_mes(v_ultimo_ano, v_ultimo_mes, p_categoria, p_limit, p_offset);
END;
$function$;

-- ============================================================================
-- FASE 2 — mart.fn_br_nacional_sazonalidade
-- Mantém assinatura (integer, text DEFAULT NULL, integer DEFAULT 1), as colunas
-- ano_referencia/tipo_dado no retorno e a agregação MODE de tipo_dado no nível
-- 2. Aplica o quality gate no nível 1.
-- ============================================================================

CREATE OR REPLACE FUNCTION mart.fn_br_nacional_sazonalidade(p_ano integer, p_categoria text DEFAULT NULL::text, p_min_ufs integer DEFAULT 1)
 RETURNS TABLE(produto text, classificao_produto text, categoria text, mes integer, data_referencia_atual text, status_cor text, is_forecast boolean, baseline_confianca numeric, total_ufs bigint, forecast_method text, calculado_em timestamp with time zone, ano_referencia integer, tipo_dado text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_categoria_filter TEXT := COALESCE(p_categoria, '%%');
    v_min_ufs INTEGER := COALESCE(p_min_ufs, 1);
BEGIN
    RETURN QUERY
    WITH uf_por_mes AS (
        -- Nível 1: consolida por (produto, UF, mes) — moda dentro da UF
        SELECT
            v.produto,
            v.classificao_produto,
            COALESCE(v.categoria, 'ALIMENTO_VAREJO') AS categoria_final,
            v.uf,
            v.mes,
            MODE() WITHIN GROUP (ORDER BY v.status_cor) AS uf_status_cor,
            BOOL_OR(v.is_forecast)       AS uf_forecast,
            MAX(v.baseline_confianca)    AS uf_confianca,
            MODE() WITHIN GROUP (ORDER BY v.forecast_method) AS uf_forecast_method,
            MAX(v.calculado_em)          AS uf_calculado_em,
            MODE() WITHIN GROUP (ORDER BY v.ano_referencia) AS uf_ano_ref,
            MODE() WITHIN GROUP (ORDER BY v.tipo_dado) AS uf_tipo_dado
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.ano = p_ano
          AND (p_categoria IS NULL OR v.categoria ILIKE v_categoria_filter)
          AND v.tipo_dado IN ('REAL_ATUAL', 'HISTORICO_BASE')
          AND COALESCE(v.idade_dado_anos, 0) <= 1
          AND COALESCE(v.metadado_transparencia->>'procedencia', '') NOT LIKE 'sem_historico_real%'
        GROUP BY v.produto, v.classificao_produto, categoria_final, v.uf, v.mes
    )
    -- Nível 2: agrega por (produto, mes) — moda da moda entre UFs
    SELECT
        upm.produto,
        upm.classificao_produto,
        upm.categoria_final,
        upm.mes,
        (p_ano || '-' || LPAD(upm.mes::TEXT, 2, '0'))::TEXT AS data_ref,
        MODE() WITHIN GROUP (ORDER BY upm.uf_status_cor) AS status_cor_nac,
        BOOL_OR(upm.uf_forecast) AS is_forecast_nac,
        MAX(upm.uf_confianca) AS confianca_nac,
        COUNT(DISTINCT upm.uf) AS total_ufs_nac,
        MODE() WITHIN GROUP (ORDER BY upm.uf_forecast_method) AS forecast_method_nac,
        MAX(upm.uf_calculado_em) AS calculado_em_nac,
        MODE() WITHIN GROUP (ORDER BY upm.uf_ano_ref) AS ano_referencia_nac,
        MODE() WITHIN GROUP (ORDER BY upm.uf_tipo_dado) AS tipo_dado_nac
    FROM uf_por_mes upm
    GROUP BY upm.produto, upm.classificao_produto, upm.categoria_final, upm.mes
    HAVING COUNT(DISTINCT upm.uf) >= v_min_ufs
    ORDER BY upm.produto, upm.mes;
END;
$function$;

COMMIT;

-- ============================================================================
-- Grants (após a transação). CREATE OR REPLACE preserva a ACL existente, mas
-- reforçamos explicitamente o acesso para role_api_reader (espelhando o atual).
-- ============================================================================

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_por_mes(INTEGER, INTEGER, TEXT, INTEGER, INTEGER) TO role_api_reader;
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_snapshot(TEXT, INTEGER, INTEGER) TO role_api_reader;
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER) TO role_api_reader;

-- ============================================================================
-- Auditoria pós-aplicação (executar MANUALMENTE fora desta migration)
-- ============================================================================
-- a. SELECT count(*) FROM mart.fn_br_nacional_por_mes(2026, 7, NULL, 100, 0);
-- b. SELECT count(*) FROM mart.fn_br_nacional_snapshot(NULL::TEXT);
-- c. SELECT tipo_dado, count(*) FROM mart.fn_br_nacional_sazonalidade(2026, NULL, 1) GROUP BY tipo_dado ORDER BY 2 DESC;
-- d. SELECT count(*) FROM mart.fn_br_nacional_por_mes(2026, 11, NULL, 100, 0);
-- e. SELECT (pg_stat_file(pg_relation_filepath('mart.vw_api_produtos_sazonalidade'::regclass))).modification AS last_refresh;
