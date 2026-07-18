-- Drop and recreate tables matching LOCAL schema exactly

DROP TABLE IF EXISTS staging.confianca_baseline CASCADE;
CREATE TABLE staging.confianca_baseline (
    id_confianca SERIAL PRIMARY KEY,
    id_produto INTEGER NOT NULL,
    id_localidade INTEGER NOT NULL,
    confiavel_2025 BOOLEAN NOT NULL DEFAULT false,
    score_confianca NUMERIC(5,2) NOT NULL DEFAULT 0,
    meses_reais INTEGER NOT NULL DEFAULT 0,
    meses_interpolados INTEGER NOT NULL DEFAULT 0,
    media_2025_curada NUMERIC(12,2),
    calculado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TABLE IF EXISTS staging.baseline_2025_interpolado CASCADE;
CREATE TABLE staging.baseline_2025_interpolado (
    id_baseline SERIAL PRIMARY KEY,
    id_produto INTEGER NOT NULL,
    id_localidade INTEGER NOT NULL,
    media_interpolada NUMERIC(12,2),
    peso_confianca NUMERIC(5,2) NOT NULL DEFAULT 0,
    qtd_meses_reais INTEGER NOT NULL DEFAULT 0,
    qtd_meses_grid INTEGER NOT NULL DEFAULT 0,
    calculado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TABLE IF EXISTS raw.coleta_bruta CASCADE;
CREATE TABLE raw.coleta_bruta (
    id SERIAL PRIMARY KEY,
    fonte_id INTEGER,
    payload_bruto JSONB NOT NULL,
    data_coleta TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    competencia_alvo TEXT,
    processado BOOLEAN NOT NULL DEFAULT false
);

DROP TABLE IF EXISTS ops.quarentena_coleta CASCADE;
CREATE TABLE ops.quarentena_coleta (
    id SERIAL PRIMARY KEY,
    raw_id INTEGER NOT NULL,
    motivo_falha TEXT NOT NULL,
    data_rejeicao TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TABLE IF EXISTS ops.config_agente CASCADE;
CREATE TABLE ops.config_agente (
    chave TEXT PRIMARY KEY,
    valor TEXT NOT NULL,
    descricao TEXT,
    atualizado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
