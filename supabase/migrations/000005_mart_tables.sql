-- ============================================================================
-- Migration 005: MART Tables (Gold Layer)
-- Sazonalidade materializada + baselines para forecast
-- ============================================================================

-- sazonalidade_produto — tabela principal do mart
CREATE TABLE IF NOT EXISTS mart.sazonalidade_produto (
    id_sazonalidade     BIGSERIAL       PRIMARY KEY,
    id_produto          INTEGER         NOT NULL,
    id_localidade       INTEGER         NOT NULL,
    ano                 SMALLINT        NOT NULL,
    mes                 SMALLINT        NOT NULL CHECK (mes BETWEEN 1 AND 12),
    preco_medio         NUMERIC(14,4)   NOT NULL,
    media_movel_12m     NUMERIC(14,4),
    indice_sazonalidade NUMERIC(8,4),
    status_cor          TEXT            NOT NULL
                        CHECK (status_cor IN ('VERDE','AMARELO','VERMELHO','INSUFICIENTE')),
    fonte               TEXT            NOT NULL DEFAULT 'municipio'
                        CHECK (fonte IN ('municipio','uf')),
    calculado_em        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_sazonalidade UNIQUE (id_produto, id_localidade, ano, mes)
);

-- Índices para performance da API
CREATE INDEX IF NOT EXISTS idx_sazonalidade_api
    ON mart.sazonalidade_produto (id_localidade, id_produto, ano, mes);

CREATE INDEX IF NOT EXISTS idx_sazonalidade_status
    ON mart.sazonalidade_produto (status_cor)
    WHERE status_cor IN ('VERDE','VERMELHO');

CREATE INDEX IF NOT EXISTS idx_sazonalidade_mes
    ON mart.sazonalidade_produto (ano, mes);

-- ops.quarentena_coleta
CREATE TABLE IF NOT EXISTS ops.quarentena_coleta (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    raw_id          UUID            NOT NULL,
    motivo_falha    TEXT            NOT NULL,
    data_rejeicao   TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE ops.quarentena_coleta IS 'Registro de itens rejeitados pela esteira de triagem';

CREATE INDEX IF NOT EXISTS idx_quarentena_raw_id
    ON ops.quarentena_coleta (raw_id);
