-- ============================================================================
-- MIGRATION 79 — BR SAZONALIDADE INCLUI PROJEÇÃO (P1-1)
-- ============================================================================
-- DATA: 2026-08-11 · AUTOR: auditoria E2E + decisão de arquitetura (lead)
--
-- CONTEXTO / PROBLEMA
-- -------------------
-- A auditoria E2E real (2026-08-11) detectou dois problemas no
-- /api/v1/sazonalidade/br-sazonalidade:
--
--   P1-1: a função mart.fn_br_nacional_sazonalidade filtrava
--         tipo_dado IN ('REAL_ATUAL','HISTORICO_BASE') → as 9.055 linhas
--         FALLBACK_DIMENSAO projetadas pelo Deep Fallback (V22, migration 78)
--         nunca chegavam ao endpoint. 13/352 produtos com grade incompleta
--         (ex: Carapau = 2 meses reais no ano corrente).
--
-- DECISÃO APROVADA
-- ----------------
-- Incluir as linhas FALLBACK_DIMENSAO projetadas na saída nacional para
-- completar as grades (regra de negócio NO GRAY / NO NULL — sem buracos).
-- Contrato de API NÃO muda: mesma assinatura (5 args), mesmo RETURNS TABLE
-- (13 colunas). O que muda implicitamente é o payload: meses sem dado real
-- passam a aparecer com tipo_dado = 'FALLBACK_DIMENSAO' e a mensagem de
-- projeção do V22 (derivada de ano_referencia no backend).
--
-- DECISÃO DE AGREGAÇÃO (projeção × real)
-- --------------------------------------
-- A fonte REAL tem precedência sobre a projeção quando ambas existem no mesmo
-- (produto, mes). Implementado por agregação condicional (MODE que ignora NULL):
--   * nível UF-mês: se QUALQUER localidade real existe → o status da UF usa o
--     MODE das linhas reais (fonte_prioridade = 0); projeção só é usada quando
--     a UF-mês é 100% projetada.
--   * nível nacional (produto, mes): MODE sobre UFs-reais quando há ≥1 UF real
--     (COALESCE: real → senão projeção).
-- Justificativa: MODE como hoje (estatística dominante), mas com precedência
-- explícita REAL > projeção — a projeção nunca "vence" uma leitura real no
-- mesmo mês. Isso difere do MODE puro do 78, que poderia deixar a projeção
-- (linhas AMARELO fabricadas) empatar/vencer uma UF real.
--
-- IMPACTO NO TOTAL / GRADE
-- ------------------------
-- total = COUNT(DISTINCT produto) PODE CRESCER: produtos que só tinham
-- FALLBACK_DIMENSAO no ano corrente (histórico completo 2024/2025 no QUALITY
-- GATE, mas nenhuma coleta real ainda em 2026) passam a aparecer com a grade
-- projetada. A grid de produtos com grade incompleta (ex: Carapau = 2 meses)
-- fica completa até onde existir linha FALLBACK_DIMENSAO correspondente na MV.
--
-- MUDANÇAS NA FUNÇÃO EM RELAÇÃO AO 78 (SEÇÃO 2)
-- ---------------------------------------------
--   1) Removido o filtro tipo_dado IN ('REAL_ATUAL','HISTORICO_BASE') →
--      passa a aceitar 'FALLBACK_DIMENSAO'.
--   2) Removido o filtro metadado_transparencia->>'procedencia' NOT LIKE
--      'sem_historico_real%' (necessário para completar meses 1..corrente-1,
--      cujas linhas FALLBACK têm procedencia 'sem_historico_real' — o Deep
--      Fallback só projeta meses >= mês corrente).
--   3) Mantido COALESCE(idade_dado_anos, 0) <= 1: FALLBACK_DIMENSAO tem
--      idade_dado_anos NULL → passa. Real/HISTORICO_BASE envelhecidos
--      (idade > 1) continuam fora (comportamento 78 preservado).
--   4) Nova coluna auxiliar fonte_prioridade (0 = real, 1 = projeção) e
--      agregação condicional conforme decisão acima.
-- Nota: linhas FALLBACK_DIMENSAO só existem na MV para o ano corrente
-- (branch C fixa ano = ANO ATUAL) → para p_ano histórico (2024/2025) a saída
-- é idêntica à do 78 (sem regressão).
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1 — fn_br_nacional_sazonalidade: inclui projeção FALLBACK_DIMENSAO
-- ============================================================================
-- CREATE OR REPLACE não muda aridade → DROP das assinaturas antigas primeiro
-- (padrão 78:407-408), preservando o contrato (chamadas com 3/2 args continuam
-- OK via DEFAULTs). Assinaturas antigas: (INTEGER,TEXT) 2 args, (INTEGER,TEXT,
-- INTEGER) 3 args e (INTEGER,TEXT,INTEGER,INTEGER,INTEGER) 5 args.

DROP FUNCTION IF EXISTS mart.fn_br_nacional_sazonalidade(INTEGER, TEXT);
DROP FUNCTION IF EXISTS mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER);
DROP FUNCTION IF EXISTS mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER, INTEGER, INTEGER);

CREATE FUNCTION mart.fn_br_nacional_sazonalidade(
    p_ano       INTEGER,
    p_categoria TEXT DEFAULT NULL,
    p_min_ufs   INTEGER DEFAULT 1,
    p_limit     INTEGER DEFAULT NULL,
    p_offset    INTEGER DEFAULT 0
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
    total_ufs           BIGINT,
    forecast_method     TEXT,
    calculado_em        TIMESTAMPTZ,
    ano_referencia      INTEGER,
    tipo_dado           TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_categoria_filter TEXT := COALESCE(p_categoria, '%%');
    v_min_ufs INTEGER := COALESCE(p_min_ufs, 1);
BEGIN
    RETURN QUERY
    WITH produto_canonico AS (
        SELECT
            v.id_produto,
            COALESCE(dc.nome_canonico, v.produto) AS produto,
            v.classificao_produto,
            COALESCE(cat_mestre.nome_categoria, v.categoria, 'ALIMENTO_VAREJO') AS categoria,
            v.uf,
            v.mes,
            v.status_cor,
            v.is_forecast,
            v.baseline_confianca,
            v.forecast_method,
            v.calculado_em,
            v.ano_referencia,
            v.tipo_dado,
            -- FASE 79: precedência da fonte — REAL > projeção na agregação.
            CASE WHEN v.tipo_dado IN ('REAL_ATUAL', 'HISTORICO_BASE')
                 THEN 0
                 ELSE 1
            END AS fonte_prioridade
        FROM mart.vw_api_produtos_sazonalidade v
        LEFT JOIN mart.dim_produto_canonico dc
               ON dc.id_produto_original = v.id_produto
        LEFT JOIN staging.dim_categoria cat_mestre
               ON cat_mestre.id_categoria = dc.id_categoria_mestre
        WHERE v.ano = p_ano
          AND (p_categoria IS NULL
               OR COALESCE(cat_mestre.nome_categoria, v.categoria, 'ALIMENTO_VAREJO') ILIKE v_categoria_filter)
          -- FASE 79: inclui FALLBACK_DIMENSAO (Deep Fallback V22) para
          -- completar as grades. Filtro de procedencia 'sem_historico_real%'
          -- REMOVIDO (bloquearia meses 1..corrente-1). FALLBACK tem
          -- idade_dado_anos NULL → passa o COALESCE <= 1.
          AND v.tipo_dado IN ('REAL_ATUAL', 'HISTORICO_BASE', 'FALLBACK_DIMENSAO')
          AND COALESCE(v.idade_dado_anos, 0) <= 1
    ),
    uf_por_mes AS (
        SELECT
            pc.produto,
            pc.classificao_produto,
            COALESCE(pc.categoria, 'ALIMENTO_VAREJO') AS categoria_final,
            pc.uf,
            pc.mes,
            -- FASE 79: MODE condicional — MODE ignora NULLs, então cada UF-mês
            -- computa o status REAL (quando existe) e o status PROJEÇÃO.
            MODE() WITHIN GROUP (ORDER BY CASE WHEN pc.fonte_prioridade = 0 THEN pc.status_cor END)
                AS uf_status_cor_real,
            MODE() WITHIN GROUP (ORDER BY CASE WHEN pc.fonte_prioridade = 1 THEN pc.status_cor END)
                AS uf_status_cor_proj,
            BOOL_OR(pc.fonte_prioridade = 0) AS uf_tem_real,
            BOOL_OR(pc.is_forecast) AS uf_forecast,
            MAX(pc.baseline_confianca) AS uf_confianca,
            MODE() WITHIN GROUP (ORDER BY CASE WHEN pc.fonte_prioridade = 0 THEN pc.forecast_method END)
                AS uf_forecast_method,
            MAX(pc.calculado_em) AS uf_calculado_em,
            MODE() WITHIN GROUP (ORDER BY CASE WHEN pc.fonte_prioridade = 0 THEN pc.ano_referencia END)
                AS uf_ano_ref_real,
            MODE() WITHIN GROUP (ORDER BY CASE WHEN pc.fonte_prioridade = 1 THEN pc.ano_referencia END)
                AS uf_ano_ref_proj,
            MODE() WITHIN GROUP (ORDER BY CASE WHEN pc.fonte_prioridade = 0 THEN pc.tipo_dado END)
                AS uf_tipo_dado_real,
            MODE() WITHIN GROUP (ORDER BY CASE WHEN pc.fonte_prioridade = 1 THEN pc.tipo_dado END)
                AS uf_tipo_dado_proj
        FROM produto_canonico pc
        GROUP BY pc.produto, pc.classificao_produto, categoria_final, pc.uf, pc.mes
    ),
    nacional AS (
        SELECT
            upm.produto,
            MODE() WITHIN GROUP (ORDER BY upm.classificao_produto) AS classificao_produto,
            MODE() WITHIN GROUP (ORDER BY upm.categoria_final)     AS categoria,
            upm.mes,
            (p_ano || '-' || LPAD(upm.mes::TEXT, 2, '0'))::TEXT AS data_ref,
            -- FASE 79: status nacional = MODE sobre UFs com dado REAL; se nenhuma
            -- UF tem real no mês, usa o MODE das projeções (COALESCE no final).
            MODE() WITHIN GROUP (ORDER BY CASE WHEN upm.uf_tem_real THEN upm.uf_status_cor_real END)
                AS status_cor_nac_real,
            MODE() WITHIN GROUP (ORDER BY CASE WHEN NOT upm.uf_tem_real THEN upm.uf_status_cor_proj END)
                AS status_cor_nac_proj,
            BOOL_OR(upm.uf_forecast)                              AS is_forecast_nac,
            MAX(upm.uf_confianca)                                 AS confianca_nac,
            COUNT(DISTINCT upm.uf)                                AS total_ufs_nac,
            MODE() WITHIN GROUP (ORDER BY upm.uf_forecast_method)  AS forecast_method_nac,
            MAX(upm.uf_calculado_em)                              AS calculado_em_nac,
            MODE() WITHIN GROUP (ORDER BY CASE WHEN upm.uf_tem_real THEN upm.uf_ano_ref_real END)
                AS ano_referencia_nac_real,
            MODE() WITHIN GROUP (ORDER BY CASE WHEN NOT upm.uf_tem_real THEN upm.uf_ano_ref_proj END)
                AS ano_referencia_nac_proj,
            MODE() WITHIN GROUP (ORDER BY CASE WHEN upm.uf_tem_real THEN upm.uf_tipo_dado_real END)
                AS tipo_dado_nac_real,
            MODE() WITHIN GROUP (ORDER BY CASE WHEN NOT upm.uf_tem_real THEN upm.uf_tipo_dado_proj END)
                AS tipo_dado_nac_proj
        FROM uf_por_mes upm
        GROUP BY upm.produto, upm.mes
        HAVING COUNT(DISTINCT upm.uf) >= v_min_ufs
    ),
    -- FASE 78 — paginação push-down NO NÍVEL DE PRODUTO (grade de 12 meses):
    -- LIMIT/OFFSET após o ORDER BY do conjunto DISTINTO de produtos. p_limit
    -- NULL = sem limite (usado pelo COUNT(DISTINCT produto) no backend).
    pagina AS (
        SELECT n.produto
        FROM nacional n
        GROUP BY n.produto
        ORDER BY n.produto
        LIMIT p_limit OFFSET p_offset
    )
    SELECT
        n.produto,
        n.classificao_produto,
        n.categoria,
        n.mes,
        n.data_ref                AS data_referencia_atual,
        COALESCE(n.status_cor_nac_real, n.status_cor_nac_proj) AS status_cor,
        n.is_forecast_nac         AS is_forecast,
        n.confianca_nac           AS baseline_confianca,
        n.total_ufs_nac           AS total_ufs,
        n.forecast_method_nac     AS forecast_method,
        n.calculado_em_nac        AS calculado_em,
        COALESCE(n.ano_referencia_nac_real, n.ano_referencia_nac_proj) AS ano_referencia,
        COALESCE(n.tipo_dado_nac_real, n.tipo_dado_nac_proj)          AS tipo_dado
    FROM nacional n
    JOIN pagina pg ON pg.produto = n.produto
    ORDER BY n.produto, n.mes;
END;
$$;

COMMENT ON FUNCTION mart.fn_br_nacional_sazonalidade IS
    'Sazonalidade BR Nacional — retorna os 12 meses de um ano por produto '
    'canônico. Moda da moda por UF, HAVING COUNT(DISTINCT uf) >= p_min_ufs '
    '(default 1). FASE 78: paginação push-down por PRODUTO (p_limit/p_offset '
    'sobre o DISTINCT de produtos, ORDER BY produto; p_limit NULL = sem '
    'limite). FASE 79 (P1-1): inclui linhas FALLBACK_DIMENSAO (Deep Fallback '
    'V22) na saída para completar grades — a fonte REAL tem precedência sobre '
    'a projeção no mesmo (produto, mes): MODE condicional real-primeiro nos '
    'níveis UF-mês e nacional, com COALESCE real -> projeção. Removidos os '
    'filtros tipo_dado IN (real/histórico) e procedencia sem_historico_real. '
    'Contrato 13 colunas preservado; total (COUNT DISTINCT produto) pode '
    'crescer. Uso: SELECT * FROM mart.fn_br_nacional_sazonalidade(2026); '
    'SELECT * FROM mart.fn_br_nacional_sazonalidade(2026, NULL, 1, 100, 0);';

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER, INTEGER, INTEGER)
    TO role_api_reader;

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER, INTEGER, INTEGER)
    TO role_etl_writer;

-- ============================================================================
-- SEÇÃO 2 — Prova embutida (saída do psql)
-- ============================================================================
DO $$
DECLARE
    v_ano            int := EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER;
    v_total_br       int;
    v_linhas_projec  int;
    v_meses_por_prod int;
BEGIN
    SELECT count(*) INTO v_total_br
      FROM mart.fn_br_nacional_sazonalidade(v_ano);
    SELECT count(*) INTO v_linhas_projec
      FROM mart.fn_br_nacional_sazonalidade(v_ano)
     WHERE tipo_dado = 'FALLBACK_DIMENSAO';
    SELECT min(qtd) INTO v_meses_por_prod FROM (
        SELECT count(*) AS qtd
          FROM mart.fn_br_nacional_sazonalidade(v_ano)
         GROUP BY produto
    ) t;
    RAISE NOTICE 'QG-79: fn_br_nacional_%_sem_limit=% linhas | projecao_FALLBACK=% | menor_grade_por_produto=%',
        v_ano, v_total_br, v_linhas_projec, v_meses_por_prod;
END $$;

COMMIT;
