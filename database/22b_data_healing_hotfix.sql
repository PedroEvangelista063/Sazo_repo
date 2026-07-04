-- ============================================================================
-- QUERO COMPRAR — Hotfix Fase 22b: Data Healing (Patch de Seguranca)
-- PostgreSQL 16+
--
-- MOTIVACAO:
--   1. SP V8 processava TODO o banco (incluindo B2B: Oleo Diesel, Tratores)
--      gastando CPU e inflando mart.sazonalidade_produto com 4000+ itens
--      inuteis que o frontend B2C nunca exibe.
--   2. is_interpolado (preco estimado) nao era exposto na API, escondendo
--      do usuario quando um preco foi estimado por IA.
--
-- CORRECOES:
--   a) ALTER TABLE mart.sazonalidade_produto ADD COLUMN preco_estimado
--   b) SP V8.1: JOIN dim_produto WHERE categoria_b2c='ALIMENTO_VAREJO'
--      nas CTEs + propaga is_interpolado como preco_estimado
--   c) MV V10: preco_estimado + filtro redundante categoria_b2c
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: DDL — Nova coluna em mart.sazonalidade_produto
-- ============================================================================

ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS preco_estimado BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN mart.sazonalidade_produto.preco_estimado IS
    'TRUE se o preco_atual foi estimado por interpolacao (Layer A) '
    'devido a falta de cotacao oficial no periodo. FALSE = dado real.';

-- ============================================================================
-- SEÇÃO 2: SP V8.1 — Filtro ALIMENTO_VAREJO + preco_estimado
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
    RAISE NOTICE '[sp_calcular_sazonalidade_preditiva] Iniciando V8.1 (filtro ALIMENTO_VAREJO)...';

    WITH ultimo_preco_conhecido AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            COALESCE(f.preco_curado, f.preco_medio) AS preco_atual,
            f.is_interpolado AS preco_estimado,
            f.ano,
            f.mes,
            f.ano::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0') AS data_referencia_atual,
            ROW_NUMBER() OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano DESC, f.mes DESC
            ) AS rn
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_produto p ON p.id_produto = f.id_produto
                                   AND p.categoria_b2c = 'ALIMENTO_VAREJO'
        WHERE COALESCE(f.preco_curado, f.preco_medio) > 0
    ),
    base_2025 AS (
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
            u.id_produto,
            u.id_localidade,
            u.preco_estimado,
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
        FROM ultimo_preco_conhecido u
        LEFT JOIN base_2025 b2025
            ON b2025.id_produto    = u.id_produto
           AND b2025.id_localidade = u.id_localidade
        LEFT JOIN fallback_12m fb
            ON fb.id_produto    = u.id_produto
           AND fb.id_localidade = u.id_localidade
        WHERE u.rn = 1
    ),
    motor_classificacao AS (
        SELECT
            r.id_produto,
            r.id_localidade,
            u.preco_atual,
            u.data_referencia_atual,
            r.preco_estimado,
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
        metodo_calculo, variacao_mom_pct, preco_mes_anterior,
        preco_estimado
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
        NULL::NUMERIC(14,4),
        m.preco_estimado
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
        variacao_mom_pct      = EXCLUDED.variacao_mom_pct,
        preco_estimado        = EXCLUDED.preco_estimado;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade_preditiva] Concluido: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);

    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
    RAISE NOTICE '[sp_calcular_sazonalidade_preditiva] MV atualizada.';
END;
$$;

COMMENT ON PROCEDURE staging.sp_calcular_sazonalidade_preditiva IS
    'Motor V8.1 - Data Healing + Filtro ALIMENTO_VAREJO. '
    'Alpha (baseline 2025 se confiavel) -> Beta (fallback 12m) -> Gamma (cold start). '
    'Trindade Estrita + preco_estimado.';

-- ============================================================================
-- SEÇÃO 3: Materialized View V10 — Expõe preco_estimado
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
    'View B2C V10 - Filtro ALIMENTO_VAREJO + preco_estimado. '
    'Exclui FLORES, OUTROS, INSUMOS, MAQUINARIO, SERVICOS.';

CREATE UNIQUE INDEX IF NOT EXISTS idx_vw_sazonalidade_unico
    ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_filtro
    ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_categoria
    ON mart.vw_api_produtos_sazonalidade (categoria);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_produto
    ON mart.vw_api_produtos_sazonalidade (id_produto);

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
-- SEÇÃO 5: Permissoes
-- ============================================================================

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;
GRANT ALL ON PROCEDURE staging.sp_calcular_sazonalidade_preditiva TO role_etl_writer;
GRANT ALL ON PROCEDURE staging.sp_calcular_sazonalidade_baseline TO role_etl_writer;

COMMIT;
