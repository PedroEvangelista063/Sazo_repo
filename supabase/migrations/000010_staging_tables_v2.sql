-- ============================================================================
-- Migration 010: Additional Staging Tables
-- Tabelas adicionais do staging (agro regional, baseline interpolado, etc.)
-- ============================================================================

-- dim_categoria
CREATE TABLE IF NOT EXISTS staging.dim_categoria (
    id_categoria    SERIAL PRIMARY KEY,
    nome_categoria  TEXT NOT NULL UNIQUE,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- dim_conab_produto_mapping
CREATE TABLE IF NOT EXISTS staging.dim_conab_produto_mapping (
    id_mapping      SERIAL PRIMARY KEY,
    produto_conab   TEXT NOT NULL,
    produto_normalizado TEXT NOT NULL,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- confianca_baseline
CREATE TABLE IF NOT EXISTS staging.confianca_baseline (
    id              SERIAL PRIMARY KEY,
    id_produto      INTEGER NOT NULL,
    id_localidade   INTEGER NOT NULL,
    mes             INTEGER NOT NULL,
    confianca       NUMERIC(5,2),
    calculado_em    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- baseline_2025_interpolado
CREATE TABLE IF NOT EXISTS staging.baseline_2025_interpolado (
    id              SERIAL PRIMARY KEY,
    id_produto      INTEGER NOT NULL,
    id_localidade   INTEGER NOT NULL,
    ano             SMALLINT NOT NULL,
    mes             SMALLINT NOT NULL,
    preco_medio     NUMERIC(14,4),
    is_interpolado  BOOLEAN DEFAULT FALSE,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- fato_cotacao_regional
CREATE TABLE IF NOT EXISTS staging.fato_cotacao_regional (
    id              SERIAL PRIMARY KEY,
    id_produto      INTEGER NOT NULL,
    uf              CHAR(2) NOT NULL,
    ano             SMALLINT NOT NULL,
    mes             SMALLINT NOT NULL,
    preco_medio     NUMERIC(14,4),
    fonte           TEXT,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
