-- ============================================================================
-- Migration 009: Forecast Engine v2 (Ponderado)
-- Baselines 24-25 e 25-26, CTE baseline_ponderado, forecast_method
-- ============================================================================

-- Colunas de forecast na mart
ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS is_forecast BOOLEAN DEFAULT FALSE;

ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS tendencia_futura TEXT;

ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS baseline_confianca NUMERIC(5,2) DEFAULT 0;

ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS forecast_method TEXT
        CHECK (forecast_method IS NULL 
               OR forecast_method IN ('gamma_forecast_baseline', 'alpha_baseline_25_26', 'beta_media_disponivel', 'beta_weighted_25_24'));

COMMENT ON COLUMN mart.sazonalidade_produto.is_forecast IS 'TRUE = projeção, FALSE = dado real';
COMMENT ON COLUMN mart.sazonalidade_produto.baseline_confianca IS 'Confiança efetiva (0-100)';
COMMENT ON COLUMN mart.sazonalidade_produto.forecast_method IS 'Método de geração: NULL=dado real';

-- Índice parcial para forecast
CREATE INDEX IF NOT EXISTS idx_sazonalidade_forecast
    ON mart.sazonalidade_produto (is_forecast)
    WHERE is_forecast = TRUE;

CREATE INDEX IF NOT EXISTS idx_sazonalidade_confianca
    ON mart.sazonalidade_produto (baseline_confianca DESC);

-- Baseline 24-25 (fallback)
CREATE TABLE IF NOT EXISTS mart.sazonalidade_baseline_24_25 (
    id_produto      INTEGER NOT NULL,
    id_localidade   INTEGER NOT NULL,
    mes             INTEGER NOT NULL,
    status_cor_mode TEXT NOT NULL,
    confianca       NUMERIC(5,2),
    fonte           TEXT DEFAULT 'BASELINE_24_25',
    atualizado_em   TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (id_produto, id_localidade, mes)
);

-- Baseline 25-26 (primária)
CREATE TABLE IF NOT EXISTS mart.sazonalidade_baseline_25_26 (
    id_produto      INTEGER NOT NULL,
    id_localidade   INTEGER NOT NULL,
    mes             INTEGER NOT NULL,
    status_cor_mode TEXT NOT NULL,
    confianca       NUMERIC(5,2),
    fonte           TEXT DEFAULT 'BASELINE_25_26',
    atualizado_em   TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (id_produto, id_localidade, mes)
);

-- CHECK constraint para forecast_method
ALTER TABLE mart.sazonalidade_produto
    ADD CONSTRAINT chk_forecast_method
    CHECK (forecast_method IS NULL 
           OR forecast_method IN ('gamma_forecast_baseline', 'alpha_baseline_25_26', 'beta_media_disponivel', 'beta_weighted_25_24'));
