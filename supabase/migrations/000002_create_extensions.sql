-- ============================================================================
-- Migration 002: Create Extensions
-- pgcrypto: gen_random_uuid()
-- pg_stat_statements: monitoramento (pode falhar sem superuser)
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- pg_stat_statements pode exigir superuser no Supabase
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'pg_stat_statements skipped — requires superuser';
END $$;
