-- =============================================================================
-- 07_migrations.sql — 📜 Migrations e objetos do banco
-- =============================================================================
-- Kit do DBA — Quero Comprar VG
-- Inspetor do schema: migrations, tabelas, views, funções, MVs, roles.
--
-- Uso: ./conectar_dba.sh -f 07_migrations.sql
-- =============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 7.1  MIGRATIONS APLICADAS — histórico de versões do schema
-- ────────────────────────────────────────────────────────────────────────────
SELECT version, name
FROM supabase_migrations.schema_migrations
ORDER BY version;

-- ────────────────────────────────────────────────────────────────────────────
-- 7.2  OBJETOS POR SCHEMA — tabelas, views e MVs da arquitetura medalhão
-- ────────────────────────────────────────────────────────────────────────────
SELECT schemaname, objtype, COUNT(*) AS qtd
FROM (
    SELECT schemaname, 'tabela' AS objtype FROM pg_tables
    WHERE schemaname IN ('raw', 'staging', 'mart', 'ops')
    UNION ALL
    SELECT schemaname, 'view' FROM pg_views
    WHERE schemaname IN ('raw', 'staging', 'mart', 'ops')
    UNION ALL
    SELECT schemaname, 'view_materializada' FROM pg_matviews
    WHERE schemaname IN ('raw', 'staging', 'mart', 'ops')
) t
GROUP BY schemaname, objtype
ORDER BY schemaname, objtype;

-- ────────────────────────────────────────────────────────────────────────────
-- 7.3  VIEWS MATERIALIZADAS — lista com status (populada? precisa refresh?)
-- ────────────────────────────────────────────────────────────────────────────
SELECT schemaname || '.' || matviewname AS mv,
       ispopulated                       AS populada,
       pg_size_pretty(pg_relation_size(format('%s.%s', schemaname, matviewname)::regclass)) AS tamanho
FROM pg_matviews
WHERE schemaname IN ('raw', 'staging', 'mart', 'ops');

-- ────────────────────────────────────────────────────────────────────────────
-- 7.4  FUNÇÕES — stored procedures e funções do banco
-- ────────────────────────────────────────────────────────────────────────────
SELECT n.nspname AS schema,
       p.proname AS funcao,
       pg_get_function_identity_arguments(p.oid) AS argumentos
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('raw', 'staging', 'mart', 'ops')
ORDER BY 1, 2;

-- ────────────────────────────────────────────────────────────────────────────
-- 7.5  ROLES E PERMISSÕES — quem pode o quê
-- ────────────────────────────────────────────────────────────────────────────
SELECT rolname, rolsuper, rolcreatedb, rolcanlogin, rolreplication
FROM pg_roles
WHERE rolname LIKE '%quero%' OR rolname IN ('role_api_reader', 'role_etl_writer', 'postgres')
ORDER BY rolname;

-- ────────────────────────────────────────────────────────────────────────────
-- 7.6  TRIGGERS — gatilhos ativos (auditoria/anomalia)
-- ────────────────────────────────────────────────────────────────────────────
SELECT event_object_schema || '.' || event_object_table AS tabela,
       trigger_name,
       action_timing,
       event_manipulation
FROM information_schema.triggers
WHERE event_object_schema IN ('raw', 'staging', 'mart', 'ops')
ORDER BY 1, 2;

-- ────────────────────────────────────────────────────────────────────────────
-- 7.7  COLUNAS DA MV PRINCIPAL — o que a API vê (vw_api_produtos_sazonalidade)
-- ────────────────────────────────────────────────────────────────────────────
SELECT column_name || ' ' || data_type AS coluna
FROM information_schema.columns
WHERE table_schema = 'mart' AND table_name = 'vw_api_produtos_sazonalidade'
ORDER BY ordinal_position;

-- ────────────────────────────────────────────────────────────────────────────
-- 7.8  RLS ATIVO — políticas de segurança por tabela (migration 000015)
--      role_etl_writer tem bypass total; role_api_reader só SELECT
-- ────────────────────────────────────────────────────────────────────────────
SELECT schemaname || '.' || tablename        AS tabela,
       policyname,
       cmd,
       roles,
       qual
FROM pg_policies
WHERE schemaname IN ('raw', 'staging', 'mart', 'ops')
ORDER BY 1, 3;

-- ────────────────────────────────────────────────────────────────────────────
-- 7.9  TABELAS COM RLS ATIVO vs SEM — segurança por camada
-- ────────────────────────────────────────────────────────────────────────────
SELECT c.relname                                AS tabela,
       n.nspname                                AS schema,
       c.relrowsecurity                         AS rls_ativo,
       c.relforcerowsecurity                    AS rls_forcado
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('raw', 'staging', 'mart', 'ops')
  AND c.relkind = 'r'
ORDER BY c.relrowsecurity DESC, n.nspname, c.relname;
