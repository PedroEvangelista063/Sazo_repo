-- ============================================================================
-- QUERO COMPRAR — Fase 23: Time-Series Modeling (Periodic Snapshot Fact)
-- PostgreSQL 16+
--
-- MOTIVACAO:
--   A tabela mart.sazonalidade_produto agia como SCD Type 1: UNIQUE
--   (id_produto, id_localidade) sobrescrevia o histórico, guardando apenas
--   o último mês. A "Máquina do Tempo" no frontend ficava estática porque
--   a API só via 1 linha por produto+cidade.
--
--   Esta migration transforma a camada mart em Periodic Snapshot Fact:
--   cada mês com preco > 0 gera uma linha, mantendo a âncora do Baseline
--   2025 inalterada.
--
-- CORRECOES:
--   a) UNIQUE passa a ser (id_produto, id_localidade, data_referencia_atual)
--   b) SP V9: remove ROW_NUMBER()=1; processa TODOS os meses >= 2025;
--      computa variacao_mom_pct real entre meses consecutivos com LAG()
--   c) MV V11: expõe toda a série temporal; índice UNIQUE no id_sazonalidade
--      permanece (PK da tabela base)
--   d) API snapshot: DISTINCT ON latest month p/ evitar duplicatas na visão
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: DDL — Nova unicidade temporal
-- ============================================================================

ALTER TABLE mart.sazonalidade_produto DROP CONSTRAINT IF EXISTS uq_sazonalidade;

ALTER TABLE mart.sazonalidade_produto
    ADD CONSTRAINT uq_sazonalidade_mensal
    UNIQUE (id_produto, id_localidade, data_referencia_atual);

COMMENT ON CONSTRAINT uq_sazonalidade_mensal ON mart.sazonalidade_produto IS
    'Permite 1 linha por produto+localidade+mês. '
    'ON CONFLICT usa (id_produto, id_localidade, data_referencia_atual).';

CREATE INDEX IF NOT EXISTS idx_sazonalidade_temporal
    ON mart.sazonalidade_produto (id_produto, id_localidade, data_referencia_atual DESC);

COMMENT ON TABLE mart.sazonalidade_produto IS
    'Periodic Snapshot Fact: semáforo B2C por produto+localidade+mês. '
    'Baseline 2025 fixo; cada mês >= 2025 tem sua própria linha. '
    'Milhares de linhas (histórico completo), não apenas 1 por produto.';

-- ============================================================================
-- SEÇÃO 2: SP V9 — Motor Time-Series (Tunnel of Time)
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
    RAISE NOTICE '[sp_calcular_sazonalidade_preditiva] Iniciando V9 (Time-Series)...';

    WITH base_2025 AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            AVG(COALESCE(f.preco_curado, f.preco_medio)) AS media_2025,
            COUNT(*) AS qtd_meses_2025,
            cb.confiavel_2025
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_produto p ON p.id_produto = f.id_produto
                                   AND p.categoria_b2c = 'ALIMENTO_VAREJO'
        LEFT JOIN staging.confianca_baseline cb
            ON cb.id_produto    = f.id_produto
           AND cb.id_localidade = f.id_localidade
        WHERE f.ano = 2025
          AND COALESCE(f.preco_curado, f.preco_medio) > 0
        GROUP BY f.id_produto, f.id_localidade, cb.confiavel_2025
    ),
    fallback_12m AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            AVG(COALESCE(f.preco_curado, f.preco_medio)) AS media_fallback,
            COUNT(*) AS qtd_12m
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_produto p ON p.id_produto = f.id_produto
                                   AND p.categoria_b2c = 'ALIMENTO_VAREJO'
        JOIN (
            SELECT
                f2.id_produto,
                f2.id_localidade,
                MAX(f2.ano * 12 + f2.mes) AS ultimo_periodo
            FROM staging.fact_precos_mensais f2
            JOIN staging.dim_produto p2 ON p2.id_produto = f2.id_produto
                                        AND p2.categoria_b2c = 'ALIMENTO_VAREJO'
            WHERE COALESCE(f2.preco_curado, f2.preco_medio) > 0
            GROUP BY f2.id_produto, f2.id_localidade
        ) per ON per.id_produto    = f.id_produto
             AND per.id_localidade = f.id_localidade
        WHERE COALESCE(f.preco_curado, f.preco_medio) > 0
          AND (f.ano * 12 + f.mes) > (per.ultimo_periodo - 12)
          AND (f.ano * 12 + f.mes) <= per.ultimo_periodo
        GROUP BY f.id_produto, f.id_localidade
        HAVING COUNT(*) >= 3
    ),
    base_referencia AS (
        SELECT
            COALESCE(b2025.id_produto, fb.id_produto) AS id_produto,
            COALESCE(b2025.id_localidade, fb.id_localidade) AS id_localidade,
            CASE
                WHEN b2025.confiavel_2025 = TRUE AND b2025.media_2025 IS NOT NULL
                    THEN b2025.media_2025
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
        FROM base_2025 b2025
        FULL JOIN fallback_12m fb
            ON fb.id_produto    = b2025.id_produto
           AND fb.id_localidade = b2025.id_localidade
    ),
    todos_meses AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            COALESCE(f.preco_curado, f.preco_medio) AS preco_atual,
            f.is_interpolado AS preco_estimado,
            f.ano,
            f.mes,
            f.ano::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0') AS data_referencia_atual
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_produto p ON p.id_produto = f.id_produto
                                   AND p.categoria_b2c = 'ALIMENTO_VAREJO'
        WHERE f.ano >= 2025
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
            COALESCE(r.metodo_calculo, 'gamma_cold_start')   AS metodo_calculo,
            COALESCE(r.usou_fallback_12m, FALSE)             AS usou_fallback_12m,
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
            ON r.id_produto    = s.id_produto
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
        preco_referencia      = EXCLUDED.preco_referencia,
        preco_atual           = EXCLUDED.preco_atual,
        usou_fallback_12m     = EXCLUDED.usou_fallback_12m,
        status_cor            = EXCLUDED.status_cor,
        fonte                 = EXCLUDED.fonte,
        calculado_em          = NOW(),
        metodo_calculo        = EXCLUDED.metodo_calculo,
        variacao_mom_pct      = EXCLUDED.variacao_mom_pct,
        preco_mes_anterior    = EXCLUDED.preco_mes_anterior,
        preco_estimado        = EXCLUDED.preco_estimado;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade_preditiva] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);

    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
    RAISE NOTICE '[sp_calcular_sazonalidade_preditiva] MV atualizada.';
END;
$$;

COMMENT ON PROCEDURE staging.sp_calcular_sazonalidade_preditiva IS
    'Motor V9 - Time-Series (Periodic Snapshot Fact). '
    'Processa TODOS os meses >=2025, não apenas o último. '
    'Alpha (baseline 2025 se confiável) -> Beta (fallback 12m) -> Gamma (cold start). '
    'variacao_mom_pct real entre meses consecutivos via LAG(). '
    'UNIQUE em (id_produto, id_localidade, data_referencia_atual).';

-- ============================================================================
-- SEÇÃO 3: Materialized View V11 — Série Temporal
-- ============================================================================

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
SELECT
    s.id_sazonalidade,
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
    s.status_cor,
    s.fonte,
    s.calculado_em,
    s.metodo_calculo,
    s.variacao_mom_pct          AS variacao_pct,
    s.preco_estimado
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
ORDER BY s.status_cor, p.nome_produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'View B2C V11 - Time-Series. '
    'Expoe multiplas linhas por produto+localidade (uma por mes com dados). '
    'Filtro ALIMENTO_VAREJO + exclusao de FLORES, OUTROS, INSUMOS, MAQUINARIO, SERVICOS.';

CREATE UNIQUE INDEX IF NOT EXISTS idx_vw_sazonalidade_unico
    ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_filtro
    ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_categoria
    ON mart.vw_api_produtos_sazonalidade (categoria);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_produto
    ON mart.vw_api_produtos_sazonalidade (id_produto);

-- Índice composto para consultas temporais (ano+mes sem função)
CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_ano_mes
    ON mart.vw_api_produtos_sazonalidade (ano, mes)
    WHERE ano IS NOT NULL AND mes IS NOT NULL;

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

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;
GRANT ALL ON PROCEDURE staging.sp_calcular_sazonalidade_preditiva TO role_etl_writer;
GRANT ALL ON PROCEDURE staging.sp_calcular_sazonalidade_baseline TO role_etl_writer;

COMMIT;
