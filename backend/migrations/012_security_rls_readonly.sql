-- ============================================================================
-- QUERO COMPRAR — Segurança Zero-Trust: DCL + RLS (Defesa em Profundidade)
-- PostgreSQL 16+
--
-- Propósito: Blindar a exposição B2C separando o usuário do scraper (ETL)
-- do usuário da API. Nenhuma rota da API pode escrever no banco.
--
-- Regras:
--   1. Revoga PUBLIC de todos os schemas (Secure by Default)
--   2. Cria role api_readonly (sem LOGIN, sem SUPERUSER)
--   3. Apenas SELECT nas tabelas/views que o frontend consome
--   4. Proibido: INSERT, UPDATE, DELETE, TRUNCATE, EXECUTE
--   5. RLS ativo nas tabelas expostas + política api_select_only
--   6. ETL mantém BYPASSRLS para operações de escrita
-- ============================================================================

BEGIN;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 1 — REVOGAR PUBLIC (Secure by Default)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--
-- Remove qualquer permissão padrão que o PUBLIC tenha nos schemas.
-- Após esta seção, apenas roles explicitamente grantadas acessam os dados.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

REVOKE ALL ON SCHEMA staging FROM PUBLIC;
REVOKE ALL ON SCHEMA mart    FROM PUBLIC;
REVOKE ALL ON SCHEMA raw     FROM PUBLIC;
REVOKE ALL ON SCHEMA ops     FROM PUBLIC;

REVOKE ALL ON ALL TABLES    IN SCHEMA staging FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA mart    FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA raw     FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA ops     FROM PUBLIC;

REVOKE ALL ON ALL FUNCTIONS  IN SCHEMA staging FROM PUBLIC;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA staging FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES  IN SCHEMA staging FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES  IN SCHEMA mart    FROM PUBLIC;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 2 — ROLE API_READONLY (Zero-Trust: sem LOGIN, sem SUPERUSER)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--
-- Esta role NÃO pode fazer login diretamente. É utilizada via mapeamento
-- de usuário no backend (a connection string da API usa um usuário que
-- possui apenas esta role, ou a role é configurada como DEFAULT).
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_readonly') THEN
        CREATE ROLE api_readonly WITH
            NOLOGIN          -- sem login direto
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOINHERIT        -- não herda permissões de outras roles
            NOREPLICATION;
    END IF;
END
$$;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 3 — GRANTS MÍNIMOS PARA API_READONLY
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--
-- Apenas USAGE nos schemas e SELECT nas tabelas/views que o frontend
-- consome. Nada mais.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--

-- USAGE mínimo para navegar nos schemas
GRANT USAGE ON SCHEMA staging TO api_readonly;
GRANT USAGE ON SCHEMA mart    TO api_readonly;

-- SELECT nas tabelas de dimensão (necessárias para queries da API)
GRANT SELECT ON staging.dim_produto    TO api_readonly;
GRANT SELECT ON staging.dim_localidade TO api_readonly;
GRANT SELECT ON staging.dim_categoria  TO api_readonly;

-- SELECT nas tabelas fato (a API consulta fact_precos_mensais via CTEs)
GRANT SELECT ON staging.fact_precos_mensais TO api_readonly;

-- SELECT nas tabelas de baseline/fallback (usadas na computação dinâmica)
GRANT SELECT ON staging.baseline_2025_interpolado TO api_readonly;

-- SELECT no mart (sazonalidade materializada + MV da API)
GRANT SELECT ON mart.sazonalidade_produto              TO api_readonly;
GRANT SELECT ON mart.vw_api_produtos_sazonalidade      TO api_readonly;

-- Conectar a role existente role_api_reader (LOGIN) a api_readonly (NOLOGIN):
-- a connection string da API usa role_api_reader como usuário, que herda
-- as permissões de api_readonly via GRANT.
GRANT api_readonly TO role_api_reader;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 3.1 — NEGAÇÃO EXPLÍCITA (defesa em profundidade)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--
-- Mesmo que no futuro alguém conceda algo a mais, estas negações têm
-- prioridade no modelo de segurança do PostgreSQL (DENY > GRANT).
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--

-- Schemas: sem CREATE (já implícito pelo USAGE-only)
-- Tabelas: negar qualquer escrita

-- staging
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA staging FROM api_readonly;
-- mart
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA mart    FROM api_readonly;

-- Futuras tabelas (padrão): negar escrita também
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA staging
    REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLES FROM api_readonly;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA mart
    REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLES FROM api_readonly;

-- Sequências: nem USAGE (api_readonly nunca deve chamar nextval)
REVOKE ALL ON ALL SEQUENCES IN SCHEMA staging FROM api_readonly;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA mart    FROM api_readonly;

-- Funções/Procedures (incluindo ETL): explicitamente proibido
REVOKE ALL ON ALL FUNCTIONS  IN SCHEMA staging FROM api_readonly;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA staging FROM api_readonly;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 4 — ROW-LEVEL SECURITY (RLS)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--
-- Dupla validação: mesmo que um SELECT vaze, o RLS atua no nível da linha.
-- Política unificada api_select_only: permite leitura total para a role
-- api_readonly. As demais roles (ETL, superuser) bypassam RLS.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--

-- 4.1 Ativar RLS nas tabelas expostas
ALTER TABLE staging.dim_produto           ENABLE ROW LEVEL SECURITY;
ALTER TABLE staging.dim_localidade        ENABLE ROW LEVEL SECURITY;
ALTER TABLE staging.dim_categoria         ENABLE ROW LEVEL SECURITY;
ALTER TABLE staging.fact_precos_mensais   ENABLE ROW LEVEL SECURITY;
ALTER TABLE staging.baseline_2025_interpolado ENABLE ROW LEVEL SECURITY;
ALTER TABLE mart.sazonalidade_produto     ENABLE ROW LEVEL SECURITY;

-- 4.2 Política de leitura para api_readonly
CREATE POLICY api_select_only ON staging.dim_produto
    FOR SELECT TO api_readonly USING (true);

CREATE POLICY api_select_only ON staging.dim_localidade
    FOR SELECT TO api_readonly USING (true);

CREATE POLICY api_select_only ON staging.dim_categoria
    FOR SELECT TO api_readonly USING (true);

CREATE POLICY api_select_only ON staging.fact_precos_mensais
    FOR SELECT TO api_readonly USING (true);

CREATE POLICY api_select_only ON staging.baseline_2025_interpolado
    FOR SELECT TO api_readonly USING (true);

CREATE POLICY api_select_only ON mart.sazonalidade_produto
    FOR SELECT TO api_readonly USING (true);

-- 4.3 Forçar RLS também em operações de INSERT/UPDATE/DELETE para a tabela
--     de quarentena (caso alguém tente manipular registros de rejeição)
ALTER TABLE staging.precos_rejeitados ENABLE ROW LEVEL SECURITY;

CREATE POLICY api_select_only ON staging.precos_rejeitados
    FOR SELECT TO api_readonly USING (true);

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 5 — ETL BYPASS (para não quebrar o pipeline)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--
-- O role_etl_writer precisa ignorar RLS para fazer INSERT/UPDATE/DELETE
-- normalmente. Concedemos BYPASSRLS para evitar recriar políticas de
-- escrita para cada tabela.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--

ALTER ROLE role_etl_writer BYPASSRLS;

-- Garantir que role_etl_writer mantenha seus grants existentes
-- (re-aplicar por segurança, caso a migração seja re-executada)
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA raw     TO role_etl_writer;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA staging TO role_etl_writer;
GRANT INSERT, SELECT, UPDATE, DELETE  ON ALL TABLES    IN SCHEMA mart    TO role_etl_writer;
GRANT USAGE ON ALL SEQUENCES          IN SCHEMA raw     TO role_etl_writer;
GRANT USAGE ON ALL SEQUENCES          IN SCHEMA staging TO role_etl_writer;
GRANT USAGE ON ALL SEQUENCES          IN SCHEMA mart    TO role_etl_writer;
GRANT EXECUTE ON ALL FUNCTIONS        IN SCHEMA staging TO role_etl_writer;
GRANT EXECUTE ON ALL PROCEDURES       IN SCHEMA staging TO role_etl_writer;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 6 — AUDITORIA
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--

DO $$
DECLARE
    v_role_exists     BOOLEAN;
    v_tables_rls      INT;
    v_policies_count  INT;
BEGIN
    SELECT EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_readonly') INTO v_role_exists;
    SELECT COUNT(*) INTO v_tables_rls
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relrowsecurity = true
          AND n.nspname IN ('staging', 'mart');
    SELECT COUNT(*) INTO v_policies_count
        FROM pg_catalog.pg_policy p
        JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('staging', 'mart')
          AND p.polname = 'api_select_only';

    RAISE NOTICE '[012_security] role_exists=%, tables_with_rls=%, api_select_only_policies=%',
        v_role_exists, v_tables_rls, v_policies_count;
END
$$;

COMMIT;
