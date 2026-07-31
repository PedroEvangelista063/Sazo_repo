-- =====================================================================
-- MIGRATION 59 — FIX data_referencia_atual NULL (bug da migration 58)
-- =====================================================================
-- Causa raiz: a migration 58 recriou sp_calcular_sazonalidade preenchendo
-- preco_atual/preco_referencia/preco_mes_anterior/variacao_mom_pct, mas
-- NÃO preencheu a coluna data_referencia_atual. Como a MV
-- vw_api_produtos_sazonalidade deriva ano/mes de data_referencia_atual
-- via split_part, as 475 linhas reais inseridas no reprocessamento
-- (MILHO 447 + Abobrinha Brasileira/Italiana + Coco Seco) ficaram com
-- ano/mes/data_referencia_atual NULL, quebrando o endpoint
-- GET /api/v1/sazonalidade (pydantic ValidationError: data_referencia_atual
-- requer pattern ^\d{4}-\d{2}$) quando por_pagina > ~5.
--
-- Fix:
--   1) Recriar sp_calcular_sazonalidade preenchendo
--      data_referencia_atual = ano || '-' || LPAD(mes, 2, '0')
--      no INSERT e no ON CONFLICT DO UPDATE.
--   2) Backfill das 475 linhas órfãs do Mart.
-- =====================================================================

BEGIN;

-- =====================================================================
-- 1) PROCEDURE CORRIGIDA (preenche data_referencia_atual)
-- =====================================================================

CREATE OR REPLACE PROCEDURE staging.sp_calcular_sazonalidade(IN p_ano_alvo smallint DEFAULT NULL::smallint, IN p_mes_alvo smallint DEFAULT NULL::smallint)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_ano   SMALLINT;
    v_mes   SMALLINT;
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
    v_total  INTEGER;
BEGIN
    v_inicio := clock_timestamp();

    IF p_ano_alvo IS NULL OR p_mes_alvo IS NULL THEN
        SELECT MAX(ano), MAX(mes) INTO v_ano, v_mes
        FROM staging.fact_precos_mensais;
    ELSE
        v_ano := p_ano_alvo;
        v_mes := p_mes_alvo;
    END IF;

    RAISE NOTICE '[sp_calcular_sazonalidade] Alvo: %-%', v_ano, v_mes;

    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade, ano, mes,
        preco_medio, media_movel_12m, indice_sazonalidade,
        status_cor, fonte, calculado_em,
        preco_atual, preco_referencia, preco_mes_anterior, variacao_mom_pct,
        data_referencia_atual
    )
    WITH precos_12m AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            f.ano,
            f.mes,
            f.preco_medio,
            AVG(f.preco_medio) OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano, f.mes
                ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
            ) AS media_movel_12m,
            COUNT(*) OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano, f.mes
                ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
            ) AS meses_no_window,
            LAG(f.preco_medio) OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano, f.mes
            ) AS preco_mes_anterior
        FROM staging.fact_precos_mensais f
        WHERE (f.ano < v_ano OR (f.ano = v_ano AND f.mes <= v_mes))
          AND f.preco_medio IS NOT NULL
    )
    SELECT
        p.id_produto,
        p.id_localidade,
        p.ano,
        p.mes,
        p.preco_medio,
        p.media_movel_12m,
        CASE
            WHEN p.media_movel_12m IS NOT NULL AND p.media_movel_12m > 0
            THEN ROUND(p.preco_medio / p.media_movel_12m, 4)
            ELSE NULL
        END AS indice_sazonalidade,
        CASE
            WHEN p.meses_no_window < 6 THEN 'AMARELO'
            WHEN p.media_movel_12m IS NULL OR p.media_movel_12m = 0 THEN 'AMARELO'
            WHEN (p.preco_medio / p.media_movel_12m) < 0.85 THEN 'VERDE'
            WHEN (p.preco_medio / p.media_movel_12m) > 1.15 THEN 'VERMELHO'
            ELSE 'AMARELO'
        END AS status_cor,
        'municipio' AS fonte,
        NOW() AS calculado_em,
        p.preco_medio AS preco_atual,
        p.preco_medio AS preco_referencia,
        p.preco_mes_anterior,
        CASE
            WHEN p.preco_mes_anterior IS NULL OR p.preco_mes_anterior <= 0
                 OR p.preco_medio IS NULL OR p.preco_medio <= 0
            THEN NULL
            ELSE ROUND(((p.preco_medio / p.preco_mes_anterior) - 1) * 100, 4)
        END AS variacao_mom_pct,
        p.ano::TEXT || '-' || LPAD(p.mes::TEXT, 2, '0') AS data_referencia_atual
    FROM precos_12m p
    WHERE p.ano = v_ano AND p.mes = v_mes
    ON CONFLICT (id_produto, id_localidade, ano, mes)
    DO UPDATE SET
        preco_medio         = EXCLUDED.preco_medio,
        media_movel_12m     = EXCLUDED.media_movel_12m,
        indice_sazonalidade = EXCLUDED.indice_sazonalidade,
        status_cor          = EXCLUDED.status_cor,
        calculado_em        = NOW(),
        preco_atual         = EXCLUDED.preco_atual,
        preco_referencia    = EXCLUDED.preco_referencia,
        preco_mes_anterior  = EXCLUDED.preco_mes_anterior,
        variacao_mom_pct    = EXCLUDED.variacao_mom_pct,
        data_referencia_atual = EXCLUDED.data_referencia_atual;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$procedure$;

-- =====================================================================
-- 2) BACKFILL das linhas órfãs (data_referencia_atual NULL, ano/mes OK)
-- =====================================================================

UPDATE mart.sazonalidade_produto
SET data_referencia_atual = ano::TEXT || '-' || LPAD(mes::TEXT, 2, '0')
WHERE data_referencia_atual IS NULL
  AND ano IS NOT NULL
  AND mes IS NOT NULL;

DO $$
DECLARE
    v_n BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_n
    FROM mart.sazonalidade_produto
    WHERE data_referencia_atual IS NULL AND ano IS NOT NULL AND mes IS NOT NULL;
    RAISE NOTICE '[59] Linhas ainda sem data_referencia_atual: %', v_n;
END;
$$;

COMMIT;

-- =====================================================================
-- 3) REFRESH DA MATERIALIZED VIEW (fora da transação)
-- =====================================================================

REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- =====================================================================
-- VERIFICAÇÃO MANUAL:
--   SELECT COUNT(*) FROM mart.sazonalidade_produto
--   WHERE data_referencia_atual IS NULL;   -- esperado: 0
--   GET /api/v1/sazonalidade?uf=CE&por_pagina=1000  -- esperado: HTTP 200
-- =====================================================================
