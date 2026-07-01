-- ============================================================================
-- QUERO COMPRAR - Fase 17: Seasonality MoM (Month-over-Month) Fallback
-- PostgreSQL 16+  |  Estratégias de Contorno
--
-- MOTIVAÇÃO:
--   94.7% dos produtos do CSV ficam em 'INSUFICIENTE' por falta de histórico
--   (apenas Jun-Jul 2026). Baseline 2025 + Fallback 12m não cobrem produtos
--   com < 6 meses de dados.
--
-- SOLUÇÃO:
--   Adiciona MoM (Month-over-Month) como terceiro nível de fallback:
--     Δ% = (preço_mês_atual / preço_mês_anterior - 1) * 100
--     ±10% → AMARELO  |  > +10% → VERMELHO  |  < -10% → VERDE
--
-- ARQUITETURA (cadeia de fallback):
--   1. rolling_12m  → Baseline 2025 interpolada (confidence ≥ 0.50)
--   2. fallback_12m → Média dos últimos 12 meses (≥ 3 meses de dado)
--   3. mom         → Variação mês-a-mês (últimos 2 meses)
--   4. insuficiente → Sem dados suficientes
-- ============================================================================

BEGIN;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 1 — Schema: novas colunas em mart.sazonalidade_produto
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS metodo_calculo    TEXT        NOT NULL DEFAULT 'rolling_12m',
    ADD COLUMN IF NOT EXISTS variacao_mom_pct  NUMERIC(8,4),
    ADD COLUMN IF NOT EXISTS preco_mes_anterior NUMERIC(14,4);

ALTER TABLE mart.sazonalidade_produto
    ADD CONSTRAINT ck_metodo_calculo
    CHECK (metodo_calculo IN ('rolling_12m','fallback_12m','mom','insuficiente'));

COMMENT ON COLUMN mart.sazonalidade_produto.metodo_calculo IS
    'Método usado: rolling_12m (baseline 2025), fallback_12m (média 12m), '
    'mom (mês-a-mês), insuficiente (sem dados)';

COMMENT ON COLUMN mart.sazonalidade_produto.variacao_mom_pct IS
    'Variação percentual mês-a-mês: (atual / anterior - 1) * 100. '
    'Preenchido apenas quando metodo_calculo = ''mom''.';

COMMENT ON COLUMN mart.sazonalidade_produto.preco_mes_anterior IS
    'Preço do mês anterior usado como referência no MoM. '
    'Preenchido apenas quando metodo_calculo = ''mom''.';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 2 — Stored Procedure com Cadeia de Fallback (V5)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE PROCEDURE staging.sp_calcular_sazonalidade_baseline()
LANGUAGE plpgsql
AS 
DECLARE
    v_inicio  TIMESTAMPTZ;
    v_fim     TIMESTAMPTZ;
    v_total   INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_calcular_sazonalidade_baseline] Iniciando...';

    WITH calc_base_2025 AS (
        SELECT
            b.id_produto,
            b.id_localidade,
            b.media_interpolada,
            b.peso_confianca
        FROM staging.baseline_2025_interpolado b
        WHERE b.peso_confianca >= 0.50
          AND b.media_interpolada IS NOT NULL
    ),
    calc_ultimos_precos AS (
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
        ) p ON p.id_produto    = f.id_produto
           AND p.id_localidade = f.id_localidade
        WHERE f.preco_medio IS NOT NULL
          AND (f.ano * 12 + f.mes) > (p.ultimo_periodo - 12)
          AND (f.ano * 12 + f.mes) <= p.ultimo_periodo
        GROUP BY f.id_produto, f.id_localidade
        HAVING COUNT(*) >= 3
    ),
    calc_mom_prep AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            f.preco_medio,
            f.ano,
            f.mes,
            LAG(f.preco_medio) OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano, f.mes
            ) AS preco_mes_anterior
        FROM staging.fact_precos_mensais f
        WHERE f.preco_medio IS NOT NULL
    ),
    calc_mom AS (
        SELECT DISTINCT ON (id_produto, id_localidade)
            id_produto,
            id_localidade,
            preco_medio AS preco_atual_mom,
            preco_mes_anterior,
            CASE
                WHEN preco_mes_anterior IS NOT NULL AND preco_mes_anterior > 0
                THEN ROUND(((preco_medio / preco_mes_anterior - 1) * 100)::NUMERIC, 2)
            END AS variacao_mom_pct
        FROM calc_mom_prep
        ORDER BY id_produto, id_localidade, ano DESC, mes DESC
    ),
    master_join AS (
        SELECT
            u.id_produto,
            u.id_localidade,
            u.preco_atual,
            u.data_referencia_atual,
            CASE
                WHEN b.media_interpolada IS NOT NULL AND b.peso_confianca >= 0.50
                    THEN b.media_interpolada
                WHEN f.preco_fallback_12m IS NOT NULL
                    THEN f.preco_fallback_12m
                WHEN m.preco_mes_anterior IS NOT NULL
                    THEN m.preco_mes_anterior
                ELSE NULL
            END AS preco_referencia,
            (b.media_interpolada IS NULL
             OR b.peso_confianca < 0.50
             OR b.peso_confianca IS NULL)
            AND f.preco_fallback_12m IS NOT NULL AS usou_fallback_12m,
            CASE
                WHEN b.media_interpolada IS NOT NULL AND b.peso_confianca >= 0.50
                    THEN 'rolling_12m'
                WHEN f.preco_fallback_12m IS NOT NULL
                    THEN 'fallback_12m'
                WHEN m.preco_mes_anterior IS NOT NULL
                    THEN 'mom'
                ELSE 'insuficiente'
            END AS metodo_calculo,
            m.variacao_mom_pct,
            m.preco_mes_anterior
        FROM calc_ultimos_precos u
        LEFT JOIN calc_base_2025 b
            ON b.id_produto    = u.id_produto
           AND b.id_localidade = u.id_localidade
        LEFT JOIN calc_fallback_12m f
            ON f.id_produto    = u.id_produto
           AND f.id_localidade = u.id_localidade
        LEFT JOIN calc_mom m
            ON m.id_produto    = u.id_produto
           AND m.id_localidade = u.id_localidade
    ),
    semaforo AS (
        SELECT
            mj.*,
            CASE
                WHEN mj.preco_referencia IS NULL OR mj.preco_referencia = 0
                    THEN 'INSUFICIENTE'
                WHEN mj.preco_atual IS NULL
                    THEN 'INSUFICIENTE'
                -- MoM usa ±10%
                WHEN mj.metodo_calculo = 'mom'
                     AND mj.preco_atual < mj.preco_mes_anterior * 0.90
                    THEN 'VERDE'
                WHEN mj.metodo_calculo = 'mom'
                     AND mj.preco_atual > mj.preco_mes_anterior * 1.10
                    THEN 'VERMELHO'
                WHEN mj.metodo_calculo = 'mom'
                    THEN 'AMARELO'
                -- Demais métodos usam ±15%
                WHEN mj.preco_atual < mj.preco_referencia * 0.85
                    THEN 'VERDE'
                WHEN mj.preco_atual > mj.preco_referencia * 1.15
                    THEN 'VERMELHO'
                ELSE 'AMARELO'
            END AS status_cor
        FROM master_join mj
    )
    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade,
        preco_referencia, preco_atual,
        data_referencia_atual, usou_fallback_12m,
        status_cor, fonte, calculado_em,
        metodo_calculo, variacao_mom_pct, preco_mes_anterior
    )
    SELECT
        s.id_produto,
        s.id_localidade,
        ROUND(s.preco_referencia, 4),
        s.preco_atual,
        s.data_referencia_atual,
        s.usou_fallback_12m,
        s.status_cor,
        'municipio' AS fonte,
        NOW() AS calculado_em,
        s.metodo_calculo,
        s.variacao_mom_pct,
        ROUND(s.preco_mes_anterior, 4)
    FROM semaforo s
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
        preco_mes_anterior    = EXCLUDED.preco_mes_anterior;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade_baseline] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
;

COMMENT ON PROCEDURE staging.sp_calcular_sazonalidade_baseline IS
    'Motor híbrido V5: rolling_12m → fallback_12m → mom. '
    'MoM usa Δ% mensal com ±10%; demais usam ±15%.';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 3 — Permissões
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

GRANT SELECT ON mart.sazonalidade_produto TO role_api_reader;

COMMIT;
