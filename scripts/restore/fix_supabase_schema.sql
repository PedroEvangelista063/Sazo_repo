-- Fix CHECK constraints on sazonalidade_produto to match local schema
ALTER TABLE mart.sazonalidade_produto DROP CONSTRAINT IF EXISTS sazonalidade_produto_fonte_check;
ALTER TABLE mart.sazonalidade_produto ADD CONSTRAINT sazonalidade_produto_fonte_check
  CHECK (fonte = ANY (ARRAY['municipio'::text, 'uf'::text, 'BASELINE_HISTORICO'::text]));

-- Drop and recreate tables with incompatible schemas
-- First, drop staging tables that have schema mismatch
DROP TABLE IF EXISTS staging.confianca_baseline CASCADE;
CREATE TABLE staging.confianca_baseline (
    id_confianca SERIAL PRIMARY KEY,
    id_produto INTEGER NOT NULL,
    id_localidade INTEGER NOT NULL,
    mes INTEGER NOT NULL,
    ano INTEGER NOT NULL,
    confianca NUMERIC(5,2) NOT NULL DEFAULT 0,
    status_cor TEXT NOT NULL DEFAULT 'INSUFICIENTE',
    qtd_meses_disponiveis INTEGER NOT NULL DEFAULT 0,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TABLE IF EXISTS staging.baseline_2025_interpolado CASCADE;
CREATE TABLE staging.baseline_2025_interpolado (
    id_baseline SERIAL PRIMARY KEY,
    id_produto INTEGER NOT NULL,
    id_localidade INTEGER NOT NULL,
    mes INTEGER NOT NULL,
    ano INTEGER NOT NULL DEFAULT 2025,
    preco_medio NUMERIC(12,2),
    status_cor TEXT NOT NULL DEFAULT 'INSUFICIENTE',
    confianca NUMERIC(5,2) NOT NULL DEFAULT 0,
    interpolado BOOLEAN NOT NULL DEFAULT FALSE,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Recreate dim_conab_produto_mapping to match local schema
DROP TABLE IF EXISTS staging.dim_conab_produto_mapping CASCADE;
CREATE TABLE staging.dim_conab_produto_mapping (
    id_mapping SERIAL PRIMARY KEY,
    conab_nome TEXT NOT NULL,
    id_produto_local INTEGER NOT NULL,
    fator_proporcao NUMERIC(10,6),
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ops tables
DROP TABLE IF EXISTS ops.quarentena_coleta CASCADE;
CREATE TABLE ops.quarentena_coleta (
    id SERIAL PRIMARY KEY,
    raw_id INTEGER,
    motivo_falha TEXT NOT NULL,
    payload JSONB,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TABLE IF EXISTS ops.config_agente CASCADE;
CREATE TABLE ops.config_agente (
    chave TEXT PRIMARY KEY,
    valor TEXT NOT NULL,
    descricao TEXT,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TABLE IF EXISTS ops.audit_llm_queries CASCADE;
CREATE TABLE ops.audit_llm_queries (
    id_audit SERIAL PRIMARY KEY,
    modelo TEXT,
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    query_text TEXT,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- raw tables
DROP TABLE IF EXISTS raw.coleta_bruta CASCADE;
CREATE TABLE raw.coleta_bruta (
    id SERIAL PRIMARY KEY,
    payload JSONB NOT NULL,
    fonte TEXT NOT NULL DEFAULT 'scraper',
    processado BOOLEAN NOT NULL DEFAULT FALSE,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TABLE IF EXISTS raw.controle_carga CASCADE;
CREATE TABLE raw.controle_carga (
    id SERIAL PRIMARY KEY,
    tipo TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pendente',
    total_linhas INTEGER DEFAULT 0,
    inseridas INTEGER DEFAULT 0,
    erro TEXT,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
