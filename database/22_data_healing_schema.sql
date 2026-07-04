-- ============================================================================
-- QUERO COMPRAR — Fase 22: Data Healing Engine (Data)
-- PostgreSQL 16+  |  Cura Analítica + Corta-Fogo de Confiança
--
-- MOTIVAÇÃO:
--   Gaps temporais no histórico de 2025 corrompem a Média do Baseline.
--   Produtos sem dados na entressafra (mais caros) têm a média anual
--   artificialmente baixa, fazendo o preço atual parecer VERMELHO.
--
-- SOLUÇÃO (3 partes):
--   1. Colunas preco_curado / is_interpolado em fact_precos_mensais
--      (populadas por pipeline/data_healer.py)
--   2. Tabela staging.confianca_baseline com score de confiança
--   3. Stored Procedure atualizada: respeita Limiar de Confiança
--      Regra de Ouro: confiavel_2025 = FALSE → Fallback Beta (12 meses)
--
-- ARQUITETURA:
--   pipeline/data_healer.py (Polars) → fact_precos_mensais [+ colunas curadas]
--                                   → staging.confianca_baseline
--   sp_calcular_sazonalidade_preditiva lê confianca_baseline e decide:
--     Alpha (2025 confiável) → Beta (12m) → Gamma (cold start)
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: DDL — Novas colunas em fact_precos_mensais
-- ============================================================================

ALTER TABLE staging.fact_precos_mensais
    ADD COLUMN IF NOT EXISTS preco_curado    NUMERIC(14,4),
    ADD COLUMN IF NOT EXISTS is_interpolado  BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN staging.fact_precos_mensais.preco_curado IS
    'Preço curado: igual ao preco_medio para dados reais, '
    'interpolado para gaps ≤ 2 meses (populado pelo Data Healing Engine)';

COMMENT ON COLUMN staging.fact_precos_mensais.is_interpolado IS
    'TRUE se este mês foi preenchido por interpolação linear (Layer A)';

-- ============================================================================
-- SEÇÃO 2: DDL — Tabela de Confiança do Baseline 2025
-- ============================================================================

CREATE TABLE IF NOT EXISTS staging.confianca_baseline (
    id_confianca       BIGSERIAL       PRIMARY KEY,
    id_produto         INTEGER         NOT NULL,
    id_localidade      INTEGER         NOT NULL,
    confiavel_2025     BOOLEAN         NOT NULL DEFAULT FALSE,
    score_confianca    NUMERIC(4,2)    NOT NULL DEFAULT 0,
    meses_reais        SMALLINT        NOT NULL DEFAULT 0,
    meses_interpolados SMALLINT        NOT NULL DEFAULT 0,
    media_2025_curada  NUMERIC(14,4),
    calculado_em       TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_confianca_baseline UNIQUE (id_produto, id_localidade)
);

CREATE INDEX IF NOT EXISTS idx_confianca_2025_prod_loc
    ON staging.confianca_baseline (id_produto, id_localidade);

CREATE INDEX IF NOT EXISTS idx_confianca_2025_flag
    ON staging.confianca_baseline (confiavel_2025)
    WHERE confiavel_2025 = TRUE;

COMMENT ON TABLE staging.confianca_baseline IS
    'Layer B: Score de confiança do baseline 2025. '
    'score_confianca = (meses_reais + meses_interpolados) / 12. '
    'confiavel_2025 = TRUE quando score >= 0.50 (6+ meses com dados).';

COMMENT ON COLUMN staging.confianca_baseline.confiavel_2025 IS
    'Regra de Ouro: se FALSE ou NULL, a SP deve IGNORAR a média de 2025 '
    'e acionar a Camada Beta (fallback 12 meses)';

-- ============================================================================
-- SEÇÃO 3: Stored Procedure V8 — Motor com Limiar de Confiança
-- ============================================================================
--
-- MUDANÇAS EM RELAÇÃO À V7 (Fase 19):
--   ultimo_preco_conhecido agora usa COALESCE(preco_curado, preco_medio)
--   base_referencia substitui base_historica_disponivel com 2 fontes:
--     Alpha: média 2025 + confiança (JOIN confianca_baseline)
--     Beta:  fallback 12 meses (média móvel dos últimos 12 períodos)
--     Gamma: cold start = preco_atual (variação 0% → AMARELO)
--   Regra de Ouro: confiavel_2025 = FALSE/NULL → ignora 2025, vai para Beta
-- ============================================================================

CREATE OR REPLACE PROCEDURE staging.sp_calcular_sazonalidade_preditiva()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio  TIMESTAMPTZ;
    v_fim     TIMESTAMPTZ;
    v_total   INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_calcular_sazonalidade_preditiva] Iniciando com Data Healing Engine...';

    WITH ultimo_preco_conhecido AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            COALESCE(f.preco_curado, f.preco_medio) AS preco_atual,
            f.ano,
            f.mes,
            f.ano::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0') AS data_referencia_atual,
            ROW_NUMBER() OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano DESC, f.mes DESC
            ) AS rn
        FROM staging.fact_precos_mensais f
        WHERE COALESCE(f.preco_curado, f.preco_medio) > 0
    ),
    -- Alpha: Baseline 2025 com filtro de confiança
    base_2025 AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            AVG(COALESCE(f.preco_curado, f.preco_medio)) AS media_2025,
            COUNT(*) AS qtd_meses_2025,
            cb.confiavel_2025
        FROM staging.fact_precos_mensais f
        LEFT JOIN staging.confianca_baseline cb
            ON cb.id_produto    = f.id_produto
           AND cb.id_localidade = f.id_localidade
        WHERE f.ano = 2025
          AND COALESCE(f.preco_curado, f.preco_medio) > 0
        GROUP BY f.id_produto, f.id_localidade, cb.confiavel_2025
    ),
    -- Beta: Fallback — Média Móvel dos últimos 12 meses
    fallback_12m AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            AVG(COALESCE(f.preco_curado, f.preco_medio)) AS media_fallback,
            COUNT(*) AS qtd_12m
        FROM staging.fact_precos_mensais f
        JOIN (
            SELECT
                id_produto,
                id_localidade,
                MAX(ano * 12 + mes) AS ultimo_periodo
            FROM staging.fact_precos_mensais
            WHERE COALESCE(preco_curado, preco_medio) > 0
            GROUP BY id_produto, id_localidade
        ) p ON p.id_produto    = f.id_produto
           AND p.id_localidade = f.id_localidade
        WHERE COALESCE(f.preco_curado, f.preco_medio) > 0
          AND (f.ano * 12 + f.mes) > (p.ultimo_periodo - 12)
          AND (f.ano * 12 + f.mes) <= p.ultimo_periodo
        GROUP BY f.id_produto, f.id_localidade
        HAVING COUNT(*) >= 3
    ),
    -- Motor de Referência: decide qual preço usar como âncora
    base_referencia AS (
        SELECT
            u.id_produto,
            u.id_localidade,
            CASE
                -- Alpha: Baseline 2025 confiável
                WHEN b2025.confiavel_2025 = TRUE AND b2025.media_2025 IS NOT NULL
                    THEN b2025.media_2025
                -- Beta: Fallback 12 meses
                WHEN fb.media_fallback IS NOT NULL
                    THEN fb.media_fallback
                ELSE NULL
            END AS preco_referencia_calc,
            CASE
                WHEN b2025.confiavel_2025 = TRUE AND b2025.media_2025 IS NOT NULL
                    THEN 'alpha_sazonal'
                WHEN fb.media_fallback IS NOT NULL
                    THEN 'beta_media_disponivel'
                ELSE 'gamma_cold_start'
            END AS metodo_calculo,
            (b2025.confiavel_2025 IS NULL OR b2025.confiavel_2025 = FALSE)
            AND fb.media_fallback IS NOT NULL AS usou_fallback_12m
        FROM ultimo_preco_conhecido u
        LEFT JOIN base_2025 b2025
            ON b2025.id_produto    = u.id_produto
           AND b2025.id_localidade = u.id_localidade
        LEFT JOIN fallback_12m fb
            ON fb.id_produto    = u.id_produto
           AND fb.id_localidade = u.id_localidade
        WHERE u.rn = 1
    ),
    -- Classificação: Trindade Estrita
    motor_classificacao AS (
        SELECT
            r.id_produto,
            r.id_localidade,
            u.preco_atual,
            u.data_referencia_atual,
            COALESCE(r.preco_referencia_calc, u.preco_atual) AS preco_referencia_calc,
            r.metodo_calculo,
            r.usou_fallback_12m,
            CASE
                WHEN u.preco_atual < (COALESCE(r.preco_referencia_calc, u.preco_atual) * 0.85)
                    THEN 'VERDE'
                WHEN u.preco_atual > (COALESCE(r.preco_referencia_calc, u.preco_atual) * 1.15)
                    THEN 'VERMELHO'
                ELSE 'AMARELO'
            END AS status_cor,
            CASE
                WHEN u.preco_atual IS NOT NULL
                 AND COALESCE(r.preco_referencia_calc, u.preco_atual) > 0
                    THEN ROUND(
                        ((u.preco_atual / COALESCE(r.preco_referencia_calc, u.preco_atual)) - 1) * 100,
                        2
                    )
                ELSE 0
            END AS variacao_pct
        FROM base_referencia r
        JOIN ultimo_preco_conhecido u
            ON u.id_produto    = r.id_produto
           AND u.id_localidade = r.id_localidade
           AND u.rn = 1
    )
    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade,
        preco_referencia, preco_atual,
        data_referencia_atual, usou_fallback_12m,
        status_cor, fonte, calculado_em,
        metodo_calculo, variacao_mom_pct, preco_mes_anterior
    )
    SELECT
        m.id_produto,
        m.id_localidade,
        ROUND(m.preco_referencia_calc, 4),
        m.preco_atual,
        m.data_referencia_atual,
        m.usou_fallback_12m,
        m.status_cor,
        'municipio'::TEXT AS fonte,
        NOW() AS calculado_em,
        m.metodo_calculo,
        m.variacao_pct,
        NULL::NUMERIC(14,4)
    FROM motor_classificacao m
    ON CONFLICT (id_produto, id_localidade)
    DO UPDATE SET
        preco_referencia      = EXCLUDED.preco_referencia,
        preco_atual           = EXCLUDED.preco_atual,
        data_referencia_atual = EXCLUDED.data_referencia_atual,
        usou_fallback_12m     = EXCLUDED.usou_fallback_12m,
        status_cor            = EXCLUDED.status_cor,
        fonte                 = EXCLUDED.fonte,
        calculado_em          = NOW(),
        metodo_calculo        = EXCLUDED.metodo_calculo,
        variacao_mom_pct      = EXCLUDED.variacao_mom_pct;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade_preditiva] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);

    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
    RAISE NOTICE '[sp_calcular_sazonalidade_preditiva] MV atualizada.';
END;
$$;

COMMENT ON PROCEDURE staging.sp_calcular_sazonalidade_preditiva IS
    'Motor V8 - Data Healing Engine. 3 camadas com Limiar de Confiança: '
    'Alpha (baseline 2025 se confiavel_2025=TRUE) → '
    'Beta (fallback 12m se confiança baixa ou sem 2025) → '
    'Gamma (cold start = AMARELO). Trindade Estrita: VERDE/AMARELO/VERMELHO.';

-- ============================================================================
-- SEÇÃO 4: Alias de compatibilidade
-- ============================================================================

CREATE OR REPLACE PROCEDURE staging.sp_calcular_sazonalidade_baseline()
LANGUAGE plpgsql
AS $$
BEGIN
    CALL staging.sp_calcular_sazonalidade_preditiva();
END;
$$;

-- ============================================================================
-- SEÇÃO 5: Permissões
-- ============================================================================

GRANT SELECT, INSERT, UPDATE ON staging.confianca_baseline TO role_etl_writer;
GRANT USAGE ON SEQUENCE staging.confianca_baseline_id_confianca_seq TO role_etl_writer;
GRANT SELECT ON staging.confianca_baseline TO role_api_reader;

GRANT ALL ON PROCEDURE staging.sp_calcular_sazonalidade_preditiva TO role_etl_writer;
GRANT ALL ON PROCEDURE staging.sp_calcular_sazonalidade_baseline TO role_etl_writer;

COMMIT;
