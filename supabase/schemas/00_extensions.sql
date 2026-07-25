CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'pg_stat_statements skipped — requires superuser';
END $$;