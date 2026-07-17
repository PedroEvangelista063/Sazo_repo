-- ============================================================================
-- Migration 004: STAGING Tables (Silver Layer)
-- Star Schema: dimensões + fato + quarentena
-- ============================================================================

-- dim_produto
CREATE TABLE IF NOT EXISTS staging.dim_produto (
    id_produto      SERIAL      PRIMARY KEY,
    nome_produto    TEXT        NOT NULL UNIQUE,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- dim_localidade
CREATE TABLE IF NOT EXISTS staging.dim_localidade (
    id_localidade   SERIAL      PRIMARY KEY,
    uf              CHAR(2)     NOT NULL,
    municipio_id    TEXT,
    municipio_nome  TEXT,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_dim_localidade UNIQUE (uf, municipio_id)
);

-- fact_precos_mensais
CREATE TABLE IF NOT EXISTS staging.fact_precos_mensais (
    id_fato         BIGSERIAL       PRIMARY KEY,
    id_produto      INTEGER         NOT NULL REFERENCES staging.dim_produto(id_produto),
    id_localidade   INTEGER         NOT NULL REFERENCES staging.dim_localidade(id_localidade),
    ano             SMALLINT        NOT NULL,
    mes             SMALLINT        NOT NULL CHECK (mes BETWEEN 1 AND 12),
    preco_medio     NUMERIC(14,4)   NOT NULL CHECK (preco_medio > 0),
    batch_id        UUID            NOT NULL,
    loaded_at       TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_fact_precos_mensais UNIQUE (id_produto, id_localidade, ano, mes)
);

CREATE INDEX IF NOT EXISTS idx_fact_precos_busca
    ON staging.fact_precos_mensais (id_produto, id_localidade, ano, mes);

-- precos_rejeitados (quarentena)
CREATE TABLE IF NOT EXISTS staging.precos_rejeitados (
    id_rejeitado    BIGSERIAL   PRIMARY KEY,
    id_produto      INTEGER,
    id_localidade   INTEGER,
    ano             SMALLINT,
    mes             SMALLINT,
    preco_medio     NUMERIC(14,4),
    preco_medio_historico NUMERIC(14,4),
    razao           TEXT        NOT NULL,
    dados_brutos    JSONB,
    rejeitado_em    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    batch_id        UUID
);
