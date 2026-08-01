-- ============================================================================
-- QUERO COMPRAR — Migration 000016: RLS Policies — Todos os Schemas
-- PostgreSQL 17+  |  Forward-only  |  Idempotent
--
-- OBJETIVO:
--   Estender a camada de RLS (iniciada na 000015) para TODAS as tabelas
--   dos schemas raw/staging/mart/ops que estavam sem policies.
--
--   Auditoria remota (2026-08-01) constatou:
--     - raw: RLS DESATIVADO em 4 tabelas (coleta_bruta, controle_carga,
--       precos_municipio, precos_uf)
--     - staging: 9 tabelas com RLS ativo mas SEM policies
--     - mart: 7 tabelas com RLS ativo mas SEM policies
--     - ops: 4 tabelas com RLS ativo mas SEM policies
--
-- PADRÃO DE POLICIES (herdado da 000015):
--   role_etl_writer -> etl_writer_all (FOR ALL, USING/CHECK true)
--   role_api_reader -> api_reader_select (FOR SELECT) APENAS em mart
--                      (staging é default-deny para a API — design da 000015)
--
-- FUNDAMENTAÇÃO:
--   Segue a decisão de arquitetura da 000015: RLS como defesa em
--   profundidade. Mesmo que um GRANT vaze, a policy impede acesso.
--   role_etl_writer e service_role seguem com acesso via policies/grants.
-- ============================================================================

BEGIN;
SET lock_timeout = '30s';

-- ============================================================================
-- SEÇÃO 1: RAW — Habilitar RLS (estava DESATIVADO)
-- ============================================================================
-- raw é a camada de ingestão (dados brutos da CONAB). role_etl_writer
-- precisa de acesso total para carga; nenhuma outra role deve ler.
-- ----------------------------------------------------------------------------

ALTER TABLE raw.coleta_bruta ENABLE ROW LEVEL SECURITY;
ALTER TABLE raw.controle_carga ENABLE ROW LEVEL SECURITY;
ALTER TABLE raw.precos_municipio ENABLE ROW LEVEL SECURITY;
ALTER TABLE raw.precos_uf ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS etl_writer_all ON raw.coleta_bruta;
CREATE POLICY etl_writer_all ON raw.coleta_bruta
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS etl_writer_all ON raw.controle_carga;
CREATE POLICY etl_writer_all ON raw.controle_carga
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS etl_writer_all ON raw.precos_municipio;
CREATE POLICY etl_writer_all ON raw.precos_municipio
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS etl_writer_all ON raw.precos_uf;
CREATE POLICY etl_writer_all ON raw.precos_uf
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

-- ============================================================================
-- SEÇÃO 2: STAGING — Policies faltantes (RLS já ativo)
-- ============================================================================
-- Apenas role_etl_writer. Default-deny para role_api_reader (design 000015).
-- ----------------------------------------------------------------------------

DROP POLICY IF EXISTS etl_writer_all ON staging.baseline_2025_interpolado;
CREATE POLICY etl_writer_all ON staging.baseline_2025_interpolado
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS etl_writer_all ON staging.confianca_baseline;
CREATE POLICY etl_writer_all ON staging.confianca_baseline
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS etl_writer_all ON staging.dim_categoria;
CREATE POLICY etl_writer_all ON staging.dim_categoria
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS etl_writer_all ON staging.dim_conab_produto_mapping;
CREATE POLICY etl_writer_all ON staging.dim_conab_produto_mapping
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS etl_writer_all ON staging.dim_fluxo_abastecimento;
CREATE POLICY etl_writer_all ON staging.dim_fluxo_abastecimento
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS etl_writer_all ON staging.dim_localidade;
CREATE POLICY etl_writer_all ON staging.dim_localidade
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS etl_writer_all ON staging.fato_cotacao_regional;
CREATE POLICY etl_writer_all ON staging.fato_cotacao_regional
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS etl_writer_all ON staging.precos_rejeitados;
CREATE POLICY etl_writer_all ON staging.precos_rejeitados
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS etl_writer_all ON staging.status_fonte_produto;
CREATE POLICY etl_writer_all ON staging.status_fonte_produto
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

-- ============================================================================
-- SEÇÃO 3: MART — Policies faltantes (RLS já ativo)
-- ============================================================================
-- mart é a camada de consumo da API: role_etl_writer (ALL) +
-- role_api_reader (SELECT). Segue o padrão de sazonalidade_produto.
-- ----------------------------------------------------------------------------

DROP POLICY IF EXISTS etl_writer_all ON mart.fator_kg_produto_uf;
CREATE POLICY etl_writer_all ON mart.fator_kg_produto_uf
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);
DROP POLICY IF EXISTS api_reader_select ON mart.fator_kg_produto_uf;
CREATE POLICY api_reader_select ON mart.fator_kg_produto_uf
    FOR SELECT
    TO role_api_reader
    USING (true);

DROP POLICY IF EXISTS etl_writer_all ON mart.sazonalidade_baseline;
CREATE POLICY etl_writer_all ON mart.sazonalidade_baseline
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);
DROP POLICY IF EXISTS api_reader_select ON mart.sazonalidade_baseline;
CREATE POLICY api_reader_select ON mart.sazonalidade_baseline
    FOR SELECT
    TO role_api_reader
    USING (true);

DROP POLICY IF EXISTS etl_writer_all ON mart.sazonalidade_baseline_24_25;
CREATE POLICY etl_writer_all ON mart.sazonalidade_baseline_24_25
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);
DROP POLICY IF EXISTS api_reader_select ON mart.sazonalidade_baseline_24_25;
CREATE POLICY api_reader_select ON mart.sazonalidade_baseline_24_25
    FOR SELECT
    TO role_api_reader
    USING (true);

DROP POLICY IF EXISTS etl_writer_all ON mart.sazonalidade_baseline_25_26;
CREATE POLICY etl_writer_all ON mart.sazonalidade_baseline_25_26
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);
DROP POLICY IF EXISTS api_reader_select ON mart.sazonalidade_baseline_25_26;
CREATE POLICY api_reader_select ON mart.sazonalidade_baseline_25_26
    FOR SELECT
    TO role_api_reader
    USING (true);

DROP POLICY IF EXISTS etl_writer_all ON mart.sazonalidade_fact_outliers_backup_58;
CREATE POLICY etl_writer_all ON mart.sazonalidade_fact_outliers_backup_58
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);
DROP POLICY IF EXISTS api_reader_select ON mart.sazonalidade_fact_outliers_backup_58;
CREATE POLICY api_reader_select ON mart.sazonalidade_fact_outliers_backup_58
    FOR SELECT
    TO role_api_reader
    USING (true);

DROP POLICY IF EXISTS etl_writer_all ON mart.sazonalidade_legado_backup;
CREATE POLICY etl_writer_all ON mart.sazonalidade_legado_backup
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);
DROP POLICY IF EXISTS api_reader_select ON mart.sazonalidade_legado_backup;
CREATE POLICY api_reader_select ON mart.sazonalidade_legado_backup
    FOR SELECT
    TO role_api_reader
    USING (true);

DROP POLICY IF EXISTS etl_writer_all ON mart.sazonalidade_legado_backup_57;
CREATE POLICY etl_writer_all ON mart.sazonalidade_legado_backup_57
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);
DROP POLICY IF EXISTS api_reader_select ON mart.sazonalidade_legado_backup_57;
CREATE POLICY api_reader_select ON mart.sazonalidade_legado_backup_57
    FOR SELECT
    TO role_api_reader
    USING (true);

-- ============================================================================
-- SEÇÃO 4: OPS — Policies faltantes (RLS já ativo)
-- ============================================================================
-- Camada operacional/auditoria: apenas role_etl_writer.
-- ----------------------------------------------------------------------------

DROP POLICY IF EXISTS etl_writer_all ON ops.audit_llm_queries;
CREATE POLICY etl_writer_all ON ops.audit_llm_queries
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS etl_writer_all ON ops.config_agente;
CREATE POLICY etl_writer_all ON ops.config_agente
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS etl_writer_all ON ops.controle_erros_ddl;
CREATE POLICY etl_writer_all ON ops.controle_erros_ddl
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS etl_writer_all ON ops.quarentena_coleta;
CREATE POLICY etl_writer_all ON ops.quarentena_coleta
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

-- ============================================================================
-- SEÇÃO 5: HARDENING — Revogar EXECUTE de rls_auto_enable
-- ============================================================================
-- A função event-trigger public.rls_auto_enable() é SECURITY DEFINER e
-- estava executável por anon/authenticated via /rest/v1/rpc. Ela só
-- precisa ser executada pelo motor de eventos (postgres/supabase_admin).
-- ----------------------------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM anon, authenticated, PUBLIC;

-- ============================================================================
-- FIM — Migration 000016
-- ============================================================================

COMMIT;
