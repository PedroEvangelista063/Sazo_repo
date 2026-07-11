-- ===================================================================
-- FASE 1 — ELT LANDING ZONE (ARQUITETURA POMAR)
-- Schema: raw (bronze layer) + ops (quarantine)
-- Filosofia: "Scrape Now, Parse Later"
-- ===================================================================

-- 1.1. CESTA DE FRUTAS — Landing Zone (sem FK, sem constraints pesadas)
CREATE SCHEMA IF NOT EXISTS raw;

CREATE TABLE IF NOT EXISTS raw.coleta_bruta (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fonte_id        VARCHAR(128)    NOT NULL,
    payload_bruto   JSONB           NOT NULL,
    data_coleta     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    competencia_alvo VARCHAR(7)     NOT NULL,
    processado      BOOLEAN         NOT NULL DEFAULT FALSE
);

-- Comentários de documentação (sem constraints de domínio — desempenho first)
COMMENT ON TABLE  raw.coleta_bruta          IS 'Landing Zone ELT — dados brutos sem validação';
COMMENT ON COLUMN raw.coleta_bruta.id       IS 'UUID gerado pelo banco (gen_random_uuid)';
COMMENT ON COLUMN raw.coleta_bruta.fonte_id IS 'Identificador do micro-motor extrator (ex: CONAB_API, CEASA_SP, DISCOVERY_AUTONOMO)';
COMMENT ON COLUMN raw.coleta_bruta.payload_bruto IS 'HTML inteiro, JSON interceptado ou texto puro — sem parsing';
COMMENT ON COLUMN raw.coleta_bruta.competencia_alvo IS 'Formato YYYY-MM — restrito a 2024-01 até 2026-12';

-- Índice essential para a esteira de triagem (sem unique — pode haver duplicatas naturais)
CREATE INDEX IF NOT EXISTS idx_coleta_bruta_processado
    ON raw.coleta_bruta (processado)
    WHERE processado = FALSE;

CREATE INDEX IF NOT EXISTS idx_coleta_bruta_competencia
    ON raw.coleta_bruta (competencia_alvo);

-- 1.2. QUARENTENA — Registro de rejeições da esteira de triagem
CREATE SCHEMA IF NOT EXISTS ops;

CREATE TABLE IF NOT EXISTS ops.quarentena_coleta (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    raw_id          UUID            NOT NULL,
    motivo_falha    TEXT            NOT NULL,
    data_rejeicao   TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  ops.quarentena_coleta IS 'Registro de itens rejeitados pela esteira de triagem (sorting engine)';

CREATE INDEX IF NOT EXISTS idx_quarentena_raw_id
    ON ops.quarentena_coleta (raw_id);
