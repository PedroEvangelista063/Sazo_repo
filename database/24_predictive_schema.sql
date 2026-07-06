-- ============================================================================
-- QUERO COMPRAR — Fase 24: Predictive AI Schema (Tendência Futura)
-- PostgreSQL 16+
--
-- MOTIVACAO:
--   O ml_forecast_engine.py treina Holt-Winters para cada par
--   (id_produto, id_localidade) e classifica a tendência (QUEDA/ALTA/ESTAVEL).
--   Esta migration adiciona a coluna na mart e atualiza a MV para expô-la.
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: DDL — Nova coluna tendencia_futura
-- ============================================================================

ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS tendencia_futura TEXT
    CHECK (tendencia_futura IS NULL OR tendencia_futura IN ('QUEDA', 'ALTA', 'ESTAVEL'));

COMMENT ON COLUMN mart.sazonalidade_produto.tendencia_futura IS
    'Previsão ML (Holt-Winters) para o próximo mês (T+1). '
    'QUEDA = >5% abaixo do preço atual, ALTA = >5% acima, ESTAVEL = dentro de ±5%. '
    'NULL = sem dados suficientes para treinar o modelo (< 24 meses).';

-- ============================================================================
-- SEÇÃO 2: Materialized View V12 — Expõe tendencia_futura
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
    s.preco_estimado,
    s.tendencia_futura
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
    'View B2C V12 - Time-Series + Predictive AI. '
    'Expoe tendencia_futura (QUEDA/ALTA/ESTAVEL) calculada por Holt-Winters.';

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

-- ============================================================================
-- SEÇÃO 3: Permissões
-- ============================================================================

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;

COMMIT;
