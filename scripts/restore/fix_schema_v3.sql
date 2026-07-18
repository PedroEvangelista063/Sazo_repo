-- Fix raw.coleta_bruta - UUID PK, text fields
DROP TABLE IF EXISTS raw.coleta_bruta CASCADE;
CREATE TABLE raw.coleta_bruta (
    id UUID PRIMARY KEY,
    fonte_id TEXT,
    payload_bruto JSONB NOT NULL,
    data_coleta TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    competencia_alvo TEXT,
    processado BOOLEAN NOT NULL DEFAULT false
);

-- Fix ops.quarentena_coleta - UUID PK, text raw_id
DROP TABLE IF EXISTS ops.quarentena_coleta CASCADE;
CREATE TABLE ops.quarentena_coleta (
    id UUID PRIMARY KEY,
    raw_id TEXT NOT NULL,
    motivo_falha TEXT NOT NULL,
    data_rejeicao TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
