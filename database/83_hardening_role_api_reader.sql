-- ============================================================================
-- Migration 83: Hardening de Privilégios da role_api_reader
-- Resolução dos achados DB-1, DB-2 e DB-3 do Pentest
--
-- Executar: psql -U postgres -d quero_comprar -f database/83_hardening_role_api_reader.sql
-- ============================================================================

DO $$
BEGIN
    -- 1. Restringir criação de objetos no schema public (DB-1)
    --    REVOKE CREATE on schema public FROM PUBLIC impede que qualquer role
    --    não-superuser crie tabelas em public.
    REVOKE CREATE ON SCHEMA public FROM PUBLIC;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_api_reader') THEN
        REVOKE CREATE ON SCHEMA public FROM role_api_reader;
        -- Remove permissões de DML em tabelas existentes em public
        -- (não afeta tabelas do schema mart que a API precisa ler)
        REVOKE ALL ON ALL TABLES IN SCHEMA public FROM role_api_reader;
        RAISE NOTICE 'DB-1: REVOKE CREATE + ALL TABLES em public para role_api_reader';
    END IF;

    -- 2. Bloquear acesso a pg_shadow (hashes de senha) (DB-2)
    --    Aiven nega REVOKE em pg_shadow para avnadmin — usar BEGIN/EXCEPTION
    BEGIN
        REVOKE SELECT ON pg_shadow FROM PUBLIC;

        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_api_reader') THEN
            REVOKE SELECT ON pg_shadow FROM role_api_reader;
            RAISE NOTICE 'DB-2: REVOKE SELECT ON pg_shadow para role_api_reader';
        END IF;
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'DB-2: REVOKE pg_shadow ignorado (Aiven nega para avnadmin)';
    END;

    -- 3. Bloquear acesso ao schema raw / landing zone (DB-3)
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'raw') THEN
        REVOKE USAGE ON SCHEMA raw FROM PUBLIC;

        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_api_reader') THEN
            REVOKE USAGE ON SCHEMA raw FROM role_api_reader;
            REVOKE ALL ON ALL TABLES IN SCHEMA raw FROM role_api_reader;
            REVOKE ALL ON ALL SEQUENCES IN SCHEMA raw FROM role_api_reader;
            RAISE NOTICE 'DB-3: REVOKE USAGE + ALL em schema raw para role_api_reader';
        END IF;
    END IF;

    -- 4. Default privileges: garantir que tabelas futuras em raw não concedam acesso
    --    (ALTER DEFAULT PRIVILEGES só afeta objetos criados A PARTIR DESTE MOMENTO)
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'raw') THEN
        BEGIN
            ALTER DEFAULT PRIVILEGES IN SCHEMA raw REVOKE ALL ON TABLES FROM role_api_reader;
            ALTER DEFAULT PRIVILEGES IN SCHEMA raw REVOKE ALL ON SEQUENCES FROM role_api_reader;
            RAISE NOTICE 'DB-3: Default privileges em raw revogadas para role_api_reader';
        EXCEPTION WHEN OTHERS THEN
            -- Ignora se o schema raw não foi criado por um role que tenha default privileges
            RAISE NOTICE 'DB-3: Default privileges em raw ignoradas (schema não gerenciado)';
        END;
    END IF;

    -- 5. Garantir que role_api_reader pode LER o schema mart (API precisa)
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_api_reader') THEN
        IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'mart') THEN
            GRANT USAGE ON SCHEMA mart TO role_api_reader;
            GRANT SELECT ON ALL TABLES IN SCHEMA mart TO role_api_reader;
            ALTER DEFAULT PRIVILEGES IN SCHEMA mart GRANT SELECT ON TABLES TO role_api_reader;
            RAISE NOTICE 'Permissões de leitura em mart concedidas a role_api_reader';
        END IF;
    END IF;

    RAISE NOTICE 'Migration 83: Hardening de segurança da role_api_reader concluído.';
END $$;
