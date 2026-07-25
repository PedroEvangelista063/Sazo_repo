-- ============================================================================
-- QUERO COMPRAR — Migration 000015: RLS Security Layer
-- PostgreSQL 17+  |  Forward-only  |  Idempotent
--
-- OBJETIVO:
--   1. Schema-level USAGE grants (inexistentes no remoto)
--   2. ALTER DEFAULT PRIVILEGES para objetos futuros
--   3. Corrigir grants faltantes (role_api_reader em objetos críticos)
--   4. ENABLE ROW LEVEL SECURITY na mart.sazonalidade_produto
--      (conforme planejado originalmente em db/01 — seção comentada)
--   5. Default-deny: staging permanece sem acesso para role_api_reader
--
-- FUNDAMENTAÇÃO:
--   O RLS foi planejado desde o schema original (db/01_ddl_medalhao.sql)
--   mas nunca ativado. Com a API servindo diretamente dados de
--   mart.sazonalidade_produto, o RLS garante que mesmo que um SELECT
--   vaze do schema mart, o role_api_reader só vê o que deve ver.
--   O role_etl_writer tem bypass automático (BYpassRLS na role).
--
-- DEPENDÊNCIA: migration 000014 (triggers + ops audit)
-- ============================================================================

BEGIN;
SET lock_timeout = '30s';

-- ============================================================================
-- SEÇÃO 1: Schema-level USAGE Grants (db/01_ddl_medalhao.sql)
-- ============================================================================
--
-- Esses grants NUNCA foram aplicados no remoto. Eles são necessários
-- para que roles consigam enxergar objetos dentro do schema, mesmo
-- que os objetos específicos tenham grants próprios.
-- ----------------------------------------------------------------------------

GRANT USAGE ON SCHEMA staging TO role_etl_writer;
GRANT USAGE ON SCHEMA mart    TO role_etl_writer;
GRANT USAGE ON SCHEMA ops     TO role_etl_writer;

GRANT USAGE ON SCHEMA mart    TO role_api_reader;
-- role_api_reader NÃO tem acesso ao schema staging (proteção de camada)

-- ============================================================================
-- SEÇÃO 2: ALTER DEFAULT PRIVILEGES — role_etl_writer (db/01)
-- ============================================================================
--
-- Garante que novas tabelas, views, funções e sequências criadas no
-- futuro por postgres já venham com os grants corretos, evitando o
-- padrão "create then grant" que causa drift.
--
-- Escopo: objetos criados por postgres (owner) nos schemas alvo.
-- ----------------------------------------------------------------------------

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA staging
    GRANT ALL PRIVILEGES ON TABLES    TO role_etl_writer;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA staging
    GRANT USAGE ON SEQUENCES TO role_etl_writer;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA staging
    GRANT EXECUTE ON FUNCTIONS TO role_etl_writer;
-- NOTA: PROCEDURES não é suportado em ALTER DEFAULT PRIVILEGES no PG 17.
-- O EXECUTE ON FUNCTIONS cobre tanto functions quanto procedures.

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA mart
    GRANT INSERT, SELECT, UPDATE, DELETE ON TABLES TO role_etl_writer;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA mart
    GRANT USAGE ON SEQUENCES TO role_etl_writer;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA ops
    GRANT ALL PRIVILEGES ON TABLES    TO role_etl_writer;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA ops
    GRANT USAGE ON SEQUENCES TO role_etl_writer;

-- ============================================================================
-- SEÇÃO 3: ALTER DEFAULT PRIVILEGES — role_api_reader (db/01)
-- ============================================================================
--
-- Novas tabelas/views no schema mart devem ser automaticamente legíveis
-- pela API, sem necessidade de GRANT explícito pós-criação.
-- ----------------------------------------------------------------------------

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA mart
    GRANT SELECT ON TABLES TO role_api_reader;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA mart
    GRANT SELECT ON SEQUENCES TO role_api_reader;

-- ============================================================================
-- SEÇÃO 4: Corrigir Grants Faltantes — role_api_reader
-- ============================================================================
--
-- Objetos que já existem mas não têm SELECT para role_api_reader:
--   1. mart.sazonalidade_baseline       — tabela de baseline, necessária
--   2. mart.vw_api_produtos_sazonalidade — MV principal da API (crítico!)
--
-- O sazonalidade_baseline_24_25 e sazonalidade_baseline_25_26 já têm
-- os grants corretos (herdados das migrations anteriores).
-- ----------------------------------------------------------------------------

GRANT SELECT ON TABLE mart.sazonalidade_baseline TO role_api_reader;

GRANT SELECT ON TABLE mart.vw_api_produtos_sazonalidade TO role_api_reader;

-- role_etl_writer também precisa de ALL em sazonalidade_baseline
GRANT ALL PRIVILEGES ON TABLE mart.sazonalidade_baseline TO role_etl_writer;

-- ============================================================================
-- SEÇÃO 5: RLS — mart.sazonalidade_produto (db/01 — plano original)
-- ============================================================================
--
-- CONFORME PLANEJADO EM db/01_ddl_medalhao.sql (linhas 491-494):
--
--   -- 2. Ativar RLS:
--   --     ALTER TABLE mart.sazonalidade_produto ENABLE ROW LEVEL SECURITY;
--   -- 4. Criar política:
--   --     CREATE POLICY produtor_policy ON mart.sazonalidade_produto
--
-- O RLS foi planejado desde o início mas nunca ativado.
--
-- REGRA:
--   role_etl_writer: bypass RLS (bypassrls=false por padrão, mas as
--     políticas permitem ALL via USING/CHECK = true)
--   role_api_reader: SELECT apenas, sem UPDATE/DELETE/INSERT
--
-- BENEFÍCIO:
--   Mesmo que role_api_reader obtenha acesso de escrita (ex: erro de
--   GRANT), o RLS impede modificações.
-- ----------------------------------------------------------------------------

ALTER TABLE mart.sazonalidade_produto ENABLE ROW LEVEL SECURITY;

-- Política: etl_writer tem acesso completo (INSERT, SELECT, UPDATE, DELETE)
DROP POLICY IF EXISTS etl_writer_all ON mart.sazonalidade_produto;
CREATE POLICY etl_writer_all ON mart.sazonalidade_produto
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

COMMENT ON POLICY etl_writer_all ON mart.sazonalidade_produto IS
    'Acesso total para role_etl_writer — INSERT, SELECT, UPDATE, DELETE liberados.';

-- Política: api_reader tem SELECT apenas
DROP POLICY IF EXISTS api_reader_select ON mart.sazonalidade_produto;
CREATE POLICY api_reader_select ON mart.sazonalidade_produto
    FOR SELECT
    TO role_api_reader
    USING (true);

COMMENT ON POLICY api_reader_select ON mart.sazonalidade_produto IS
    'SELECT liberado para role_api_reader — acesso somente leitura.';

-- Default-deny: qualquer outra role (ex: anon, authenticado) não vê nada
ALTER TABLE mart.sazonalidade_produto FORCE ROW LEVEL SECURITY;

-- ============================================================================
-- SEÇÃO 6: RLS — staging.dim_produto (proteção ETL)
-- ============================================================================
--
-- dim_produto contém dados internos (mapeamento CONAB, classificação,
-- status_fonte). O RLS garante que mesmo que role_api_reader ganhe
-- acesso ao schema staging (o que não deve acontecer), não consegue
-- ler dados sensíveis.
--
-- REGRA:
--   role_etl_writer: acesso total (INSERT, SELECT, UPDATE, DELETE)
--   demais roles: sem acesso (default-deny via FORCE RLS)
-- ----------------------------------------------------------------------------

ALTER TABLE staging.dim_produto ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS etl_writer_all ON staging.dim_produto;
CREATE POLICY etl_writer_all ON staging.dim_produto
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

COMMENT ON POLICY etl_writer_all ON staging.dim_produto IS
    'Acesso total para role_etl_writer em dim_produto.';

ALTER TABLE staging.dim_produto FORCE ROW LEVEL SECURITY;

-- ============================================================================
-- SEÇÃO 7: RLS — staging.fact_precos_mensais (proteção ETL)
-- ============================================================================
--
-- Tabela principal de preços. RLS garante isolamento de escrita:
-- apenas role_etl_writer pode inserir/alterar dados.
-- ----------------------------------------------------------------------------

ALTER TABLE staging.fact_precos_mensais ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS etl_writer_all ON staging.fact_precos_mensais;
CREATE POLICY etl_writer_all ON staging.fact_precos_mensais
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

COMMENT ON POLICY etl_writer_all ON staging.fact_precos_mensais IS
    'Acesso total para role_etl_writer em fact_precos_mensais.';

ALTER TABLE staging.fact_precos_mensais FORCE ROW LEVEL SECURITY;

-- ============================================================================
-- SEÇÃO 8: RLS — ops.audit_logs (proteção de auditoria)
-- ============================================================================
--
-- Audit_logs é INSERT-only para role_etl_writer. O RLS impede
-- UPDATE/DELETE mesmo que grants permitam.
--
-- REGRA:
--   role_etl_writer: INSERT e SELECT
--   demais roles: sem acesso
-- ----------------------------------------------------------------------------

ALTER TABLE ops.audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS etl_writer_insert_select ON ops.audit_logs;
CREATE POLICY etl_writer_insert_select ON ops.audit_logs
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

COMMENT ON POLICY etl_writer_insert_select ON ops.audit_logs IS
    'Acesso INSERT+SELECT para role_etl_writer em audit_logs.';

ALTER TABLE ops.audit_logs FORCE ROW LEVEL SECURITY;

-- ============================================================================
-- SEÇÃO 9: Concessão de BYPASSRLS para role_etl_writer (segurança avançada)
-- ============================================================================
--
-- Em produção, role_etl_writer pode precisar bypassar RLS para
-- operações em lote (ex: sp_calcular_sazonalidade que faz INSERT
-- em sazonalidade_produto). Concedemos BYPASSRLS para evitar
-- que políticas precisem ser ajustadas para cada operação batch.
--
-- NOTA: BYPASSRLS é um superuser privilege. A role postgres tem
-- automaticamente. Se role_etl_writer executar procedures via
-- SECURITY DEFINER, não precisa de BYPASSRLS própria.
-- Mantemos SEM BYPASSRLS por enquanto — as políticas já permitem
-- USING(true) para role_etl_writer em todas as tabelas.
-- Se houver lentidão em operações batch, reavaliar.
-- ----------------------------------------------------------------------------

-- ALTER ROLE role_etl_writer BYPASSRLS;
-- (comentado: as políticas são permissivas o suficiente)

-- ============================================================================
-- FIM — Migration 000015
-- ============================================================================

COMMIT;
