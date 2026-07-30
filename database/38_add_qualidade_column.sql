-- ============================================================================
-- QUERO COMPRAR — Fase 38: Coluna _qualidade nas tabelas raw + staging
-- PostgreSQL 16+
--
-- Adiciona coluna ``_qualidade`` às tabelas que recebem dados da CONAB
-- para auditoria de linhas salvas por fallback contextual.
-- Valores: NORMAL | MES_INFERIDO | ANO_INFERIDO | ANO_INFERIDO+MES_INFERIDO
-- ============================================================================

BEGIN;

ALTER TABLE raw.precos_uf
    ADD COLUMN IF NOT EXISTS _qualidade TEXT NOT NULL DEFAULT 'NORMAL';

ALTER TABLE raw.precos_municipio
    ADD COLUMN IF NOT EXISTS _qualidade TEXT NOT NULL DEFAULT 'NORMAL';

ALTER TABLE staging.fact_precos_mensais
    ADD COLUMN IF NOT EXISTS _qualidade TEXT NOT NULL DEFAULT 'NORMAL';

COMMIT;
