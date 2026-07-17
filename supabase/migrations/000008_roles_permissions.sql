-- ============================================================================
-- Migration 008: Roles & Permissions
-- role_etl_writer: escrita (pipeline)
-- role_api_reader: leitura (FastAPI)
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_etl_writer') THEN
        CREATE ROLE role_etl_writer WITH LOGIN PASSWORD 'mude_essa_senha_em_producao';
    END IF;

    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_api_reader') THEN
        CREATE ROLE role_api_reader WITH LOGIN PASSWORD 'mude_essa_senha_em_producao';
    END IF;
END;
$$;

-- Permissões ETL Writer
GRANT USAGE ON SCHEMA raw     TO role_etl_writer;
GRANT USAGE ON SCHEMA staging TO role_etl_writer;
GRANT USAGE ON SCHEMA mart    TO role_etl_writer;

GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA raw     TO role_etl_writer;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA staging TO role_etl_writer;
GRANT INSERT, SELECT, UPDATE, DELETE  ON ALL TABLES    IN SCHEMA mart    TO role_etl_writer;
GRANT USAGE ON ALL SEQUENCES          IN SCHEMA raw     TO role_etl_writer;
GRANT USAGE ON ALL SEQUENCES          IN SCHEMA staging TO role_etl_writer;
GRANT USAGE ON ALL SEQUENCES          IN SCHEMA mart    TO role_etl_writer;

GRANT EXECUTE ON ALL FUNCTIONS     IN SCHEMA staging TO role_etl_writer;
GRANT EXECUTE ON ALL PROCEDURES    IN SCHEMA staging TO role_etl_writer;

-- Permissões API Reader
GRANT USAGE ON SCHEMA mart TO role_api_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA mart TO role_api_reader;
GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;

-- Permissões para roles Supabase padrão
GRANT USAGE ON SCHEMA raw     TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA staging TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA mart    TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA ops     TO anon, authenticated, service_role;

GRANT SELECT ON ALL TABLES IN SCHEMA mart TO anon, authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA raw TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA staging TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA mart TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA ops TO service_role;
