-- ============================================================================
-- QUERO COMPRAR — Fase 16: Baseline 2025 com Imputação Matemática de Gaps
-- PostgreSQL 16+  |  Polars (Layer A) + Confiança (Layer B)
--
-- MOTIVAÇÃO:
--   A média simples de 2025 (AVG(preco_medio) WHERE ano=2025) sofre de viés
--   de amostragem: produtos com gaps de 1-2 meses na entressafra têm a média
--   calculada apenas sobre os meses com dados, ignorando a sazonalidade real.
--
-- SOLUÇÃO:
--   Camada A: Interpolação linear de gaps de 1-2 meses via Polars
--   Camada B: Score de confiança C = meses_reais / 12; se C < 0.50 → fallback
--
-- ARQUITETURA:
--   staging.baseline_2025_interpolado  ← populada por pipeline/imputar_gaps_baseline.py
--       ↑                                        ↑
--   sp_calcular_sazonalidade_baseline()   script Python (Polars)
--       ↑
--   sp_executar_carga_completa()
--
-- SUMÁRIO:
--   1. Cria staging.baseline_2025_interpolado
--   2. Atualiza sp_calcular_sazonalidade_baseline() com confidence threshold
-- ============================================================================

BEGIN;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 1 — Tabela de Baseline com Imputação
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE TABLE IF NOT EXISTS staging.baseline_2025_interpolado (
    id_baseline           BIGSERIAL       PRIMARY KEY,
    id_produto            INTEGER         NOT NULL,
    id_localidade         INTEGER         NOT NULL,
    media_interpolada     NUMERIC(14,4),              -- AVG após interpolação
    peso_confianca        NUMERIC(4,2)    NOT NULL DEFAULT 0,  -- C = meses_reais / 12
    qtd_meses_reais       SMALLINT        NOT NULL DEFAULT 0,  -- meses com dado real
    qtd_meses_grid        SMALLINT        NOT NULL DEFAULT 0,  -- meses no grid (≤12)
    calculado_em          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_baseline_2025_interpolado UNIQUE (id_produto, id_localidade)
);

CREATE INDEX IF NOT EXISTS idx_baseline2025_interp_prod_loc
    ON staging.baseline_2025_interpolado (id_produto, id_localidade);

COMMENT ON TABLE staging.baseline_2025_interpolado IS
    'Baseline 2025 com gaps imputados por interpolação linear (Layer A) '
    'e score de confiança C (Layer B). Populada por pipeline/imputar_gaps_baseline.py.';

COMMENT ON COLUMN staging.baseline_2025_interpolado.media_interpolada IS
    'Média dos 12 meses após interpolação linear de gaps ≤2 meses';

COMMENT ON COLUMN staging.baseline_2025_interpolado.peso_confianca IS
    'C = qtd_meses_reais / 12. Se < 0.50, o sistema abandona a baseline '
    'e usa fallback 12m (Layer B)';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 2 — Stored Procedure Atualizada (com confidence threshold)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Mudanças em relação à V3 (05_recalibracao_baseline_2025.sql):
--   calc_base_2025 agora lê de staging.baseline_2025_interpolado em vez
--   de calcular AVG direto da fact_precos_mensais.
--
--   master_join agora aplica a Regra do Threshold (Layer B):
--     preco_referencia = CASE
--         WHEN b.peso_confianca >= 0.50 THEN b.media_interpolada
--         ELSE f.preco_fallback_12m
--     END
--
--   usou_fallback_12m = TRUE quando C < 0.50 OU produto sem 2025
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE PROCEDURE staging.sp_calcular_sazonalidade_baseline()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio  TIMESTAMPTZ;
    v_fim     TIMESTAMPTZ;
    v_total   INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_calcular_sazonalidade_baseline] Iniciando...';

    WITH calc_base_2025 AS (
        -- ================================================================
        -- CTE 1: Baseline 2025 com Imputação (Layer A + Layer B)
        -- Lê da tabela populada pelo Polars, que já aplicou interpolação
        -- linear com limit=2 e calculou o score de confiança.
        --
        -- Produtos sem registro em baseline_2025_interpolado retornam NULL
        -- e automaticamente acionam o fallback 12m no master_join.
        -- ================================================================
        SELECT
            b.id_produto,
            b.id_localidade,
            b.media_interpolada,
            b.peso_confianca
        FROM staging.baseline_2025_interpolado b
        WHERE b.peso_confianca >= 0.50  -- Layer B: ignora baselines fracas
          AND b.media_interpolada IS NOT NULL
    ),
    calc_ultimos_precos AS (
        -- ================================================================
        -- CTE 2: Último preço registrado de cada produto+localidade
        -- Subquery com rn=1 para evitar duplicatas no ON CONFLICT
        -- ================================================================
        SELECT * FROM (
            SELECT
                f.id_produto,
                f.id_localidade,
                f.preco_medio   AS preco_atual,
                f.ano,
                f.mes,
                f.ano::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0')
                                AS data_referencia_atual,
                ROW_NUMBER() OVER (
                    PARTITION BY f.id_produto, f.id_localidade
                    ORDER BY f.ano DESC, f.mes DESC
                ) AS rn
            FROM staging.fact_precos_mensais f
            WHERE f.preco_medio IS NOT NULL
        ) sub
        WHERE rn = 1
    ),
    calc_fallback_12m AS (
        -- ================================================================
        -- CTE 3: Preço Âncora Secundário (Fallback 12 Meses)
        -- ================================================================
        SELECT
            f.id_produto,
            f.id_localidade,
            AVG(f.preco_medio) AS preco_fallback_12m
        FROM staging.fact_precos_mensais f
        JOIN (
            SELECT
                id_produto,
                id_localidade,
                MAX(ano * 12 + mes) AS ultimo_periodo
            FROM staging.fact_precos_mensais
            WHERE preco_medio IS NOT NULL
            GROUP BY id_produto, id_localidade
        ) p ON p.id_produto      = f.id_produto
           AND p.id_localidade   = f.id_localidade
        WHERE f.preco_medio IS NOT NULL
          AND (f.ano * 12 + f.mes) > (p.ultimo_periodo - 12)
          AND (f.ano * 12 + f.mes) <= p.ultimo_periodo
        GROUP BY f.id_produto, f.id_localidade
        HAVING COUNT(*) >= 3
    ),
    master_join AS (
        -- ================================================================
        -- CTE 4: Motor Lógico com Confidence Threshold (Layer B)
        --
        -- Regra de decisão:
        --   Se peso_confianca >= 0.50 → usa media_interpolada (baseline 2025)
        --   Senão → usa preco_fallback_12m (média 12 meses)
        --
        -- usou_fallback_12m:
        --   TRUE quando o fallback foi acionado (qualquer motivo)
        --   FALSE apenas quando a baseline 2025 interpolada foi usada
        -- ================================================================
        SELECT
            u.id_produto,
            u.id_localidade,
            u.preco_atual,
            u.data_referencia_atual,
            CASE
                -- Layer B ativo: baseline interpolada confiável
                WHEN b.media_interpolada IS NOT NULL AND b.peso_confianca >= 0.50
                    THEN b.media_interpolada
                -- Fallback: baseline fraca ou ausente
                WHEN f.preco_fallback_12m IS NOT NULL
                    THEN f.preco_fallback_12m
                ELSE NULL
            END AS preco_referencia,
            -- Flag para o frontend
            (b.media_interpolada IS NULL
             OR b.peso_confianca < 0.50
             OR b.peso_confianca IS NULL)
            AND f.preco_fallback_12m IS NOT NULL AS usou_fallback_12m,
            CASE
                WHEN CASE
                        WHEN b.media_interpolada IS NOT NULL AND b.peso_confianca >= 0.50
                            THEN b.media_interpolada
                        WHEN f.preco_fallback_12m IS NOT NULL
                            THEN f.preco_fallback_12m
                        ELSE NULL
                     END IS NULL
                    THEN 'INSUFICIENTE'
                WHEN CASE
                        WHEN b.media_interpolada IS NOT NULL AND b.peso_confianca >= 0.50
                            THEN b.media_interpolada
                        WHEN f.preco_fallback_12m IS NOT NULL
                            THEN f.preco_fallback_12m
                        ELSE NULL
                     END = 0
                    THEN 'INSUFICIENTE'
                WHEN u.preco_atual IS NULL
                    THEN 'INSUFICIENTE'
                WHEN u.preco_atual < (
                        CASE
                            WHEN b.media_interpolada IS NOT NULL AND b.peso_confianca >= 0.50
                                THEN b.media_interpolada
                            WHEN f.preco_fallback_12m IS NOT NULL
                                THEN f.preco_fallback_12m
                            ELSE NULL
                        END * 0.85)
                    THEN 'VERDE'
                WHEN u.preco_atual > (
                        CASE
                            WHEN b.media_interpolada IS NOT NULL AND b.peso_confianca >= 0.50
                                THEN b.media_interpolada
                            WHEN f.preco_fallback_12m IS NOT NULL
                                THEN f.preco_fallback_12m
                            ELSE NULL
                        END * 1.15)
                    THEN 'VERMELHO'
                ELSE 'AMARELO'
            END AS status_cor
        FROM calc_ultimos_precos u
        LEFT JOIN calc_base_2025 b
            ON b.id_produto    = u.id_produto
           AND b.id_localidade = u.id_localidade
        LEFT JOIN calc_fallback_12m f
            ON f.id_produto    = u.id_produto
           AND f.id_localidade = u.id_localidade
    )
    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade,
        preco_referencia, preco_atual,
        data_referencia_atual, usou_fallback_12m,
        status_cor, fonte, calculado_em
    )
    SELECT
        mj.id_produto,
        mj.id_localidade,
        ROUND(mj.preco_referencia, 4),
        mj.preco_atual,
        mj.data_referencia_atual,
        mj.usou_fallback_12m,
        mj.status_cor,
        'municipio' AS fonte,
        NOW() AS calculado_em
    FROM master_join mj
    ON CONFLICT (id_produto, id_localidade)
    DO UPDATE SET
        preco_referencia      = EXCLUDED.preco_referencia,
        preco_atual           = EXCLUDED.preco_atual,
        data_referencia_atual = EXCLUDED.data_referencia_atual,
        usou_fallback_12m     = EXCLUDED.usou_fallback_12m,
        status_cor            = EXCLUDED.status_cor,
        fonte                 = EXCLUDED.fonte,
        calculado_em          = NOW();

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade_baseline] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

COMMENT ON PROCEDURE staging.sp_calcular_sazonalidade_baseline IS
    'Motor híbrido V4: Baseline 2025 com imputação matemática (Polars) + '
    'confidence threshold 0.50 (Layer B). Fallback 12m quando C < 0.50.';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 3 — Permissões
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

GRANT SELECT, INSERT, UPDATE ON staging.baseline_2025_interpolado TO role_etl_writer;
GRANT USAGE ON SEQUENCE staging.baseline_2025_interpolado_id_baseline_seq TO role_etl_writer;
GRANT SELECT ON staging.baseline_2025_interpolado TO role_api_reader;

COMMIT;
