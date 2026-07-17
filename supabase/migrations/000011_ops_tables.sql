-- ============================================================================
-- Migration 011: OPS Tables
-- Tabelas operacionais (config agente, erros DDL, audit LLM)
-- ============================================================================

-- ops.config_agente
CREATE TABLE IF NOT EXISTS ops.config_agente (
    id              SERIAL PRIMARY KEY,
    chave           TEXT NOT NULL UNIQUE,
    valor           JSONB NOT NULL,
    descricao       TEXT,
    atualizado_em   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ops.controle_erros_ddl
CREATE TABLE IF NOT EXISTS ops.controle_erros_ddl (
    id              SERIAL PRIMARY KEY,
    script          TEXT NOT NULL,
    erro            TEXT NOT NULL,
    executado_em    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ops.audit_llm_queries
CREATE TABLE IF NOT EXISTS ops.audit_llm_queries (
    id              SERIAL PRIMARY KEY,
    query_text      TEXT NOT NULL,
    response        JSONB,
    executado_em    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
