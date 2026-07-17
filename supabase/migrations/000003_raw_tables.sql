-- ============================================================================
-- Migration 003: RAW Tables (Bronze Layer)
-- Landing Zone: dados brutos sem validação
-- ============================================================================

-- raw.coleta_bruta — Landing Zone ELT
CREATE TABLE IF NOT EXISTS raw.coleta_bruta (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fonte_id        VARCHAR(128)    NOT NULL,
    payload_bruto   JSONB           NOT NULL,
    data_coleta     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    competencia_alvo VARCHAR(7)     NOT NULL,
    processado      BOOLEAN         NOT NULL DEFAULT FALSE
);

COMMENT ON TABLE  raw.coleta_bruta          IS 'Landing Zone ELT — dados brutos sem validação';
COMMENT ON COLUMN raw.coleta_bruta.id       IS 'UUID gerado pelo banco (gen_random_uuid)';
COMMENT ON COLUMN raw.coleta_bruta.fonte_id IS 'Identificador do micro-motor extrator';
COMMENT ON COLUMN raw.coleta_bruta.payload_bruto IS 'HTML inteiro, JSON interceptado ou texto puro — sem parsing';
COMMENT ON COLUMN raw.coleta_bruta.competencia_alvo IS 'Formato YYYY-MM — restrito a 2024-01 até 2026-12';

CREATE INDEX IF NOT EXISTS idx_coleta_bruta_processado
    ON raw.coleta_bruta (processado)
    WHERE processado = FALSE;

CREATE INDEX IF NOT EXISTS idx_coleta_bruta_competencia
    ON raw.coleta_bruta (competencia_alvo);

-- raw.precos_uf — cópia fiel CONAB
CREATE TABLE IF NOT EXISTS raw.precos_uf (
    id              BIGSERIAL   PRIMARY KEY,
    produto         TEXT,
    uf              CHAR(2),
    ano             SMALLINT,
    mes             SMALLINT,
    preco_medio     TEXT,
    _arquivo        TEXT        NOT NULL DEFAULT 'PrecosMensalUF',
    _loaded_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    _batch_id       UUID        NOT NULL DEFAULT gen_random_uuid()
);

-- raw.precos_municipio — cópia fiel CONAB
CREATE TABLE IF NOT EXISTS raw.precos_municipio (
    id              BIGSERIAL   PRIMARY KEY,
    produto         TEXT,
    municipio_id    TEXT,
    municipio_nome  TEXT,
    uf              CHAR(2),
    ano             SMALLINT,
    mes             SMALLINT,
    preco_medio     TEXT,
    _arquivo        TEXT        NOT NULL DEFAULT 'PrecosMensalMunicipio',
    _loaded_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    _batch_id       UUID        NOT NULL DEFAULT gen_random_uuid()
);

-- raw.controle_carga — controle de batches
CREATE TABLE IF NOT EXISTS raw.controle_carga (
    id              BIGSERIAL       PRIMARY KEY,
    batch_id        UUID            NOT NULL UNIQUE,
    arquivo         TEXT            NOT NULL,
    linhas_lidas    INTEGER         NOT NULL DEFAULT 0,
    linhas_inseridas INTEGER        NOT NULL DEFAULT 0,
    linhas_rejeitadas INTEGER       NOT NULL DEFAULT 0,
    duracao_seg     NUMERIC(10,2),
    status          TEXT            NOT NULL DEFAULT 'em_andamento'
                        CHECK (status IN ('em_andamento','sucesso','falha')),
    iniciado_em     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    concluido_em    TIMESTAMPTZ
);
