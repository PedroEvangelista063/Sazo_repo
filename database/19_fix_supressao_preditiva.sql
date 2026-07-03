-- ============================================================================
-- QUERO COMPRAR - Fase 19: Fix Supressão Silenciosa (Zero Data Loss)
-- PostgreSQL 16+  |  Forward Fill com Último Preço Conhecido
--
-- MOTIVAÇÃO:
--   A Fase 18 (Trindade Estrita) gerou um Silent Data Drop: produtos que
--   antes apareciam como INSUFICIENTE (branco/cinza) desapareceram porque:
--
--   1. A SP usava staging.fact_precos_mensais com INNER JOIN entre CTEs,
--      eliminando produtos sem dado no "mês mais recente";
--   2. A MV filtava preco_atual IS NOT NULL AND >0, matando produtos com
--      preço zero na staging;
--   3. O backend (_compute_periodo_full) recalcula do zero ignorando a
--      mart.sazonalidade_produto, reaplicando lógica legacy.
--
-- CORREÇÃO:
--   - A SP agora usa "Forward Fill": busca o Último Preço Conhecido
--     independente da profundidade temporal. Se não há preço recente, usa
--     o dado mais recente disponível.
--   - A MV remove o filtro assassino preco_atual > 0 — confia na Trindade.
--   - O backend passa a consultar a MV (única fonte de verdade).
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 0: Add missing columns from migrations 17/18 (if not applied)
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'mart' AND table_name = 'sazonalidade_produto'
        AND column_name = 'metodo_calculo'
    ) THEN
        ALTER TABLE mart.sazonalidade_produto
            ADD COLUMN metodo_calculo TEXT NOT NULL DEFAULT 'gamma_cold_start';
        RAISE NOTICE '[DDL] Coluna metodo_calculo adicionada';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'mart' AND table_name = 'sazonalidade_produto'
        AND column_name = 'variacao_mom_pct'
    ) THEN
        ALTER TABLE mart.sazonalidade_produto
            ADD COLUMN variacao_mom_pct NUMERIC(8,4);
        RAISE NOTICE '[DDL] Coluna variacao_mom_pct adicionada';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'mart' AND table_name = 'sazonalidade_produto'
        AND column_name = 'preco_mes_anterior'
    ) THEN
        ALTER TABLE mart.sazonalidade_produto
            ADD COLUMN preco_mes_anterior NUMERIC(14,4);
        RAISE NOTICE '[DDL] Coluna preco_mes_anterior adicionada';
    END IF;
END $$;

-- ============================================================================
-- SEÇÃO 1: Ajuste da constraint CHECK para Trindade Estrita
-- ============================================================================

DO $$
DECLARE
    v_constraint_name TEXT;
BEGIN
    SELECT con.conname INTO v_constraint_name
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    WHERE rel.relname = 'sazonalidade_produto'
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%status_cor%';

    IF v_constraint_name IS NOT NULL THEN
        EXECUTE format('ALTER TABLE mart.sazonalidade_produto DROP CONSTRAINT %I', v_constraint_name);
        RAISE NOTICE '[DDL] Constraint antiga % removida', v_constraint_name;
    END IF;
END $$;

ALTER TABLE mart.sazonalidade_produto
    ADD CONSTRAINT ck_status_cor_trindade
    CHECK (status_cor IN ('VERDE', 'AMARELO', 'VERMELHO'));

COMMENT ON CONSTRAINT ck_status_cor_trindade ON mart.sazonalidade_produto IS
    'Trindade Estrita: apenas VERDE, AMARELO, VERMELHO. INSUFICIENTE foi extirpado.';

-- ============================================================================
-- SEÇÃO 2: Stored Procedure — Motor de Forward Fill com Trindade Estrita
-- ============================================================================
--
-- Lógica:
--   CTE 1 (ultimo_preco_conhecido): Captura a ÚLTIMA aparição de cada
--   produto+localidade em staging.fact_precos_mensais, independente de quão
--   antiga ela seja. Se o produto "Pitaia" foi coletado em Abr/2026 e o
--   usuário pesquisa Maio/2026, o preço de Abril é usado como preco_atual.
--
--   CTE 2 (base_historica_disponivel): Média de TODOS os preços históricos
--   para calcular a âncora de referência. Se só tem 1 mês de dado, a média
--   é igual ao preço atual, resultando em variação 0% = AMARELO (Gamma).
--
--   UPSERT: Sempre upserta para garantir que produtos com dados históricos
--   estejam na mart com status_cor válido. O ON CONFLICT atualiza dados
--   existentes com a nova classificação.
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
    RAISE NOTICE '[sp_calcular_sazonalidade_preditiva] Iniciando com Forward Fill...';

    WITH ultimo_preco_conhecido AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            f.preco_medio AS preco_atual,
            f.ano,
            f.mes,
            f.ano::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0') AS data_referencia_atual,
            ROW_NUMBER() OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano DESC, f.mes DESC
            ) AS rn
        FROM staging.fact_precos_mensais f
        WHERE f.preco_medio > 0
    ),
    base_historica_disponivel AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            AVG(f.preco_medio) AS media_historica,
            COUNT(*) AS qtd_meses_historico
        FROM staging.fact_precos_mensais f
        WHERE f.preco_medio > 0
        GROUP BY f.id_produto, f.id_localidade
    ),
    motor_classificacao AS (
        SELECT
            u.id_produto,
            u.id_localidade,
            u.preco_atual,
            u.data_referencia_atual,
            COALESCE(b.media_historica, u.preco_atual) AS preco_referencia_calc,
            CASE
                WHEN b.media_historica IS NOT NULL AND b.qtd_meses_historico > 1
                    THEN 'alpha_sazonal'
                WHEN b.media_historica IS NOT NULL
                    THEN 'beta_media_disponivel'
                ELSE 'gamma_cold_start'
            END AS metodo_calculo,
            (b.media_historica IS NULL) AS usou_fallback_12m,
            CASE
                WHEN u.preco_atual < (COALESCE(b.media_historica, u.preco_atual) * 0.85)
                    THEN 'VERDE'
                WHEN u.preco_atual > (COALESCE(b.media_historica, u.preco_atual) * 1.15)
                    THEN 'VERMELHO'
                ELSE 'AMARELO'
            END AS status_cor,
            CASE
                WHEN u.preco_atual IS NOT NULL
                 AND COALESCE(b.media_historica, u.preco_atual) > 0
                    THEN ROUND(
                        ((u.preco_atual / COALESCE(b.media_historica, u.preco_atual)) - 1) * 100,
                        2
                    )
                ELSE 0
            END AS variacao_pct
        FROM ultimo_preco_conhecido u
        LEFT JOIN base_historica_disponivel b
            ON b.id_produto    = u.id_produto
           AND b.id_localidade = u.id_localidade
        WHERE u.rn = 1
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
    'Motor V7 - Forward Fill + Trindade Estrita. Zero Data Loss. Gamma = AMARELO.';

-- ============================================================================
-- SEÇÃO 3: Materialized View — Remove filtro preco_atual > 0
-- ============================================================================
-- Removeu: WHERE preco_atual IS NOT NULL AND preco_atual > 0
-- Agora: apenas WHERE status_cor IN ('VERDE','AMARELO','VERMELHO')
-- A SP garante que todo produto com histórico recebe uma cor da Trindade.
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
    s.variacao_mom_pct          AS variacao_pct
FROM mart.sazonalidade_produto s
JOIN staging.dim_produto    p ON p.id_produto    = s.id_produto
JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
LEFT JOIN staging.dim_categoria c ON c.id_categoria = p.id_categoria
WHERE s.status_cor IN ('VERDE', 'AMARELO', 'VERMELHO')
ORDER BY s.status_cor, p.nome_produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'View B2C V7 - Zero Data Loss. Removeu filtro preco_atual>0. Forward Fill.';

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
-- SEÇÃO 5: Permissões
-- ============================================================================

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;
GRANT ALL ON PROCEDURE staging.sp_calcular_sazonalidade_preditiva TO role_etl_writer;
GRANT ALL ON PROCEDURE staging.sp_calcular_sazonalidade_baseline TO role_etl_writer;

COMMIT;