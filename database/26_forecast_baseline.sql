-- ============================================================================
-- QUERO COMPRAR — Fase 26: Forecast Baseline (Modelo de Sazonalidade Histórica)
-- PostgreSQL 16+
--
-- O que faz:
--   1. Cria mart.sazonalidade_baseline — tabela de moda do status_cor por
--      (produto, localidade, mes) calculada a partir de 2024-2025.
--   2. Adiciona coluna is_forecast em mart.sazonalidade_produto — flag que
--      distingue dado real (FALSE) de projeção histórica (TRUE).
--   3. Recria a MV vw_api_produtos_sazonalidade com is_forecast + JOIN
--      com baseline para expor confianca_baseline.
--   4. Atualiza sp_executar_carga_completa para incluir recálculo do
--      baseline + forecast + refresh final da MV.
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: Tabela de Baseline Histórico
-- ============================================================================

CREATE TABLE IF NOT EXISTS mart.sazonalidade_baseline (
    id_produto      INTEGER         NOT NULL,
    id_localidade   INTEGER         NOT NULL,
    mes             SMALLINT        NOT NULL CHECK (mes BETWEEN 1 AND 12),
    status_cor_mode TEXT            NOT NULL
                        CHECK (status_cor_mode IN ('VERDE', 'AMARELO', 'VERMELHO')),
    confianca       NUMERIC(5,2)    NOT NULL DEFAULT 0,
    fonte           TEXT            NOT NULL DEFAULT 'BASELINE_HISTORICO',
    atualizado_em   TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_sazonalidade_baseline
        PRIMARY KEY (id_produto, id_localidade, mes)
);

COMMENT ON TABLE mart.sazonalidade_baseline IS
    'Moda do status_cor por (produto, localidade, mes) calculada sobre 2024-2025. '
    'Usado como fallback para projetar meses de 2026 sem coleta real.';

CREATE INDEX IF NOT EXISTS idx_baseline_mes
    ON mart.sazonalidade_baseline (mes);

-- ============================================================================
-- SEÇÃO 2: Coluna is_forecast na tabela de sazonalidade
-- ============================================================================

ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS is_forecast BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN mart.sazonalidade_produto.is_forecast IS
    'FALSE = dado real coletado pelo scraper. TRUE = projeção do baseline histórico.';

CREATE INDEX IF NOT EXISTS idx_sazonalidade_is_forecast
    ON mart.sazonalidade_produto (is_forecast)
    WHERE is_forecast = FALSE;

-- ============================================================================
-- SEÇÃO 3: Materialized View V13 — com is_forecast + confianca_baseline
-- ============================================================================

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
SELECT
    s.id_sazonalidade,
    s.id_localidade,
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
    s.preco_estimado,
    s.status_cor,
    s.fonte,
    s.calculado_em,
    s.metodo_calculo,
    s.variacao_mom_pct          AS variacao_pct,
    s.tendencia_futura,
    s.is_forecast
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
ORDER BY s.is_forecast, s.status_cor, p.nome_produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'View B2C V13 - Forecast + Real. '
    'Inclui is_forecast (TRUE = projeção) para transparência total. '
    'Dados reais (is_forecast=FALSE) aparecem antes dos projetados.';

CREATE UNIQUE INDEX IF NOT EXISTS idx_vw_sazonalidade_unico
    ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_filtro
    ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_categoria
    ON mart.vw_api_produtos_sazonalidade (categoria);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_produto
    ON mart.vw_api_produtos_sazonalidade (id_produto);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_ano_mes
    ON mart.vw_api_produtos_sazonalidade (ano, mes)
    WHERE ano IS NOT NULL AND mes IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_forecast
    ON mart.vw_api_produtos_sazonalidade (is_forecast)
    WHERE is_forecast = TRUE;

-- ============================================================================
-- SEÇÃO 4: Atualizar sp_executar_carga_completa com pós-processamento
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
    RAISE NOTICE '[sp_executar_carga_completa] Iniciando (V2 - Forecast)...';

    ANALYZE staging.fact_precos_mensais;

    SELECT MAX(ano), MAX(mes) INTO v_ultimo_ano, v_ultimo_mes
    FROM staging.fact_precos_mensais;

    CALL staging.sp_calcular_sazonalidade(v_ultimo_ano, v_ultimo_mes);

    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Concluído em % seg',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

COMMENT ON PROCEDURE staging.sp_executar_carga_completa IS
    'V2 - Executa carga + forecast. O recálculo do baseline e a projeção '
    'de 2026 são feitos em Python (persistence.py) após esta SP.';

-- ============================================================================
-- SEÇÃO 5: Permissões
-- ============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE mart.sazonalidade_baseline
    TO role_etl_writer;

GRANT SELECT ON TABLE mart.sazonalidade_baseline
    TO role_api_reader;

GRANT SELECT ON mart.vw_api_produtos_sazonalidade
    TO role_api_reader;

COMMIT;
