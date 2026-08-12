-- ============================================================
-- MIGRATION: 81_fase2_subconjunto_seguro
-- Fase 2 da Auditoria de Nomenclatura — SUBCONJUNTO SEGURO
-- (aprovado pelo usuário em 2026-08-12)
--   Renomeia 4 funções + 1 tabela + 1 view com dependentes vivos
--   e reescreve TODOS os corpos chamadores (funções + views) na
--   mesma transação — wrappers ficam puramente vestigiais.
-- Idempotente: guard por objeto (só renomeia se o novo nome NÃO
--   existir com a mesma identidade; CREATE OR REPLACE no resto).
-- Compatibilidade: wrappers de função (30 dias) p/ os nomes
--   antigos — remover em 2026-09-30 junto com a Fase 3.
-- NÃO toca: MV vw_api_produtos_sazonalidade, roles, fact_precos_mensais,
--   sp_executar_carga_completa, sp_project_sandwich_prices_2026 (só
--   o corpo é reescrito, o nome permanece).
--
-- ⚠️ GUARD DE IDEMPOTÊNCIA: pg_get_function_identity_arguments INCLUI
--   nomes de parâmetros IN — todo wrapper DEVE replicar os nomes de
--   parâmetros do original exatamente.
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- BLOCO 1: Renomear Tabela staging.baseline_2025_interpolado
-- (sem dependentes no catálogo — pg_depend view_refs=0, triggers=0)
-- ────────────────────────────────────────────────────────────
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='staging' AND tablename='baseline_2025_interpolado')
       AND NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='staging' AND tablename='baseline_sazonal_interpolado') THEN
        ALTER TABLE staging.baseline_2025_interpolado RENAME TO baseline_sazonal_interpolado;
        RAISE NOTICE 'RENOMEADO: staging.baseline_2025_interpolado → staging.baseline_sazonal_interpolado';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────
-- BLOCO 2: Renomear View staging.vw_fluxos_regionais
-- (sem dependentes no catálogo)
-- ────────────────────────────────────────────────────────────
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_views WHERE schemaname='staging' AND viewname='vw_fluxos_regionais')
       AND NOT EXISTS (SELECT 1 FROM pg_views WHERE schemaname='staging' AND viewname='vw_abastecimento_logistico') THEN
        ALTER VIEW staging.vw_fluxos_regionais RENAME TO vw_abastecimento_logistico;
        RAISE NOTICE 'RENOMEADO: staging.vw_fluxos_regionais → staging.vw_abastecimento_logistico';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────
-- BLOCO 3: Renomear as 4 funções (guard de idempotência —
-- só renomeia se o NOVO nome NÃO existir com a mesma identidade)
-- ────────────────────────────────────────────────────────────
DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT p.oid, p.proname, n.nspname
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE (n.nspname, p.proname) IN (
            ('staging', 'fn_normalizar_nome_produto'),
            ('staging', 'fn_estatisticas_volatilidade_24m'),
            ('staging', 'fn_status_cor_zscore'),
            ('staging', 'fn_encontrar_produto_pai')
        )
        AND p.proname NOT LIKE 'pg_%'
        AND NOT EXISTS (
            SELECT 1
            FROM pg_proc p2 JOIN pg_namespace n2 ON n2.oid = p2.pronamespace
            WHERE n2.nspname = n.nspname
              AND p2.proname = CASE p.proname
                    WHEN 'fn_normalizar_nome_produto'       THEN 'normalizar_nome_produto'
                    WHEN 'fn_estatisticas_volatilidade_24m' THEN 'estatisticas_volatilidade_24m'
                    WHEN 'fn_status_cor_zscore'             THEN 'calcular_semaforo_preco'
                    WHEN 'fn_encontrar_produto_pai'         THEN 'encontrar_produto_pai'
                END
              AND pg_get_function_identity_arguments(p2.oid) = pg_get_function_identity_arguments(p.oid)
        )
    LOOP
        EXECUTE format('ALTER FUNCTION %I.%I(%s) RENAME TO %I',
            r.nspname, r.proname,
            pg_get_function_identity_arguments(r.oid),
            CASE r.proname
                WHEN 'fn_normalizar_nome_produto'       THEN 'normalizar_nome_produto'
                WHEN 'fn_estatisticas_volatilidade_24m' THEN 'estatisticas_volatilidade_24m'
                WHEN 'fn_status_cor_zscore'             THEN 'calcular_semaforo_preco'
                WHEN 'fn_encontrar_produto_pai'         THEN 'encontrar_produto_pai'
            END
        );
        RAISE NOTICE 'RENOMEADO: %.% → %', r.nspname, r.proname,
            CASE r.proname
                WHEN 'fn_normalizar_nome_produto' THEN 'normalizar_nome_produto'
                WHEN 'fn_estatisticas_volatilidade_24m' THEN 'estatisticas_volatilidade_24m'
                WHEN 'fn_status_cor_zscore' THEN 'calcular_semaforo_preco'
                WHEN 'fn_encontrar_produto_pai' THEN 'encontrar_produto_pai'
            END;
    END LOOP;
END $$;

-- ────────────────────────────────────────────────────────────
-- BLOCO 4: WRAPPERS DE COMPATIBILIDADE (30 dias — remover junto
-- com a Fase 3 em 2026-09-30). Assinatura EXATA + volatility +
-- DEFAULTs + nomes de parâmetros do original.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION staging.fn_normalizar_nome_produto(p_nome text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT staging.normalizar_nome_produto(p_nome);
$$;
COMMENT ON FUNCTION staging.fn_normalizar_nome_produto(TEXT) IS
    'DEPRECATED 2026-08: use staging.normalizar_nome_produto(TEXT). Removida em 2026-09-30.';

CREATE OR REPLACE FUNCTION staging.fn_estatisticas_volatilidade_24m()
RETURNS TABLE(
    id_produto integer, id_localidade integer, media_historica numeric,
    desvio_padrao_historico numeric, n_meses integer, desvio_efetivo numeric
)
LANGUAGE sql
STABLE
AS $$
    SELECT * FROM staging.estatisticas_volatilidade_24m();
$$;
COMMENT ON FUNCTION staging.fn_estatisticas_volatilidade_24m() IS
    'DEPRECATED 2026-08: use staging.estatisticas_volatilidade_24m(). Removida em 2026-09-30.';

CREATE OR REPLACE FUNCTION staging.fn_status_cor_zscore(
    p_preco_exibido numeric, p_preco_referencia numeric, p_desvio_padrao numeric
)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT staging.calcular_semaforo_preco(p_preco_exibido, p_preco_referencia, p_desvio_padrao);
$$;
COMMENT ON FUNCTION staging.fn_status_cor_zscore(NUMERIC, NUMERIC, NUMERIC) IS
    'DEPRECATED 2026-08: use staging.calcular_semaforo_preco(NUMERIC, NUMERIC, NUMERIC). Removida em 2026-09-30.';

CREATE OR REPLACE FUNCTION staging.fn_encontrar_produto_pai(
    p_id_produto_filho integer, p_mes_alvo smallint DEFAULT 8
)
RETURNS integer
LANGUAGE sql
STABLE
AS $$
    SELECT staging.encontrar_produto_pai(p_id_produto_filho, p_mes_alvo);
$$;
COMMENT ON FUNCTION staging.fn_encontrar_produto_pai(INTEGER, SMALLINT) IS
    'DEPRECATED 2026-08: use staging.encontrar_produto_pai(INTEGER, SMALLINT). Removida em 2026-09-30.';

-- ────────────────────────────────────────────────────────────
-- BLOCO 5: REESCREVER CORPOS CHAMADORES (funções PL/pgSQL + views)
-- Extraídos do catálogo vivo via pg_get_functiondef/pg_get_viewdef
-- e substituídos SOMENTE os nomes das 4 funções — fidelidade 100%.
-- CREATE OR REPLACE mantém OID + ACLs; wrappers ficam vestigiais.
-- ────────────────────────────────────────────────────────────
-- 5.1 — função consolidar_produtos_duplicados
CREATE OR REPLACE FUNCTION staging.consolidar_produtos_duplicados(p_dry_run boolean DEFAULT true)
 RETURNS TABLE(acao text, nome_grupo text, id_afetado integer, nome_afetado text, detalhe text)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_count        INTEGER;
    v_total_precos INTEGER := 0;
    v_total_sfp    INTEGER := 0;
    v_canonico     INTEGER;
    v_grupo_nome   TEXT;
BEGIN
    -- ============================================================
    -- Passo 1: DRY-RUN — apenas mostra o relatório
    -- ============================================================
    IF p_dry_run THEN
        RETURN QUERY
        SELECT
            'DRY-RUN'::TEXT,
            r.grupo_normalizado,
            r.id_canonico,
            r.nome_canonico,
            format('%s duplicatas, %s registros de preço afetados',
                r.total_duplicatas, r.qtd_precos_afetados)
        FROM staging.relatorio_normalizacao_produtos() r
        ORDER BY r.qtd_precos_afetados DESC;
        RETURN;
    END IF;

    -- ============================================================
    -- Passo 2: Executa a consolidação
    -- ============================================================
    RAISE NOTICE '[normalizacao] INICIANDO consolidação de produtos duplicados...';

    -- Temp table com grupos de produtos duplicados
    CREATE TEMP TABLE IF NOT EXISTS tmp_grupos_normalizacao ON COMMIT DROP AS
    WITH normalizados AS (
        SELECT
            p.id_produto,
            p.nome_produto,
            staging.normalizar_nome_produto(p.nome_produto) AS nome_normalizado,
            (SELECT COUNT(*) FROM staging.fact_precos_mensais fp WHERE fp.id_produto = p.id_produto) AS qtd_precos
        FROM staging.dim_produto p
    ),
    grupos AS (
        SELECT
            nome_normalizado,
            COUNT(*) AS qtd_produtos
        FROM normalizados
        GROUP BY nome_normalizado
        HAVING COUNT(*) > 1
    ),
    canonical AS (
        SELECT DISTINCT ON (n.nome_normalizado)
            n.nome_normalizado,
            n.id_produto AS id_canonico,
            n.nome_produto AS nome_canonico,
            n.qtd_precos
        FROM normalizados n
        JOIN grupos g ON g.nome_normalizado = n.nome_normalizado
        ORDER BY n.nome_normalizado, n.qtd_precos DESC NULLS LAST, n.id_produto ASC
    ),
    duplicatas AS (
        SELECT n.*
        FROM normalizados n
        JOIN grupos g ON g.nome_normalizado = n.nome_normalizado
    )
    SELECT
        d.id_produto,
        d.nome_produto,
        d.nome_normalizado,
        c.id_canonico,
        c.nome_canonico,
        d.qtd_precos
    FROM duplicatas d
    JOIN canonical c ON c.nome_normalizado = d.nome_normalizado;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RAISE NOTICE '[normalizacao] % linhas na temp table de grupos', v_count;

    -- Reporta grupos encontrados
    RETURN QUERY
    SELECT
        'GRUPO'::TEXT,
        tg.nome_normalizado,
        tg.id_produto,
        tg.nome_produto,
        format('canônico=%s (%s), precos=%s',
            tg.id_canonico, tg.nome_canonico, tg.qtd_precos)
    FROM tmp_grupos_normalizacao tg
    ORDER BY tg.nome_normalizado, tg.id_produto;

    -- Para cada canônico, processa suas duplicatas
    FOR v_canonico, v_grupo_nome IN
        SELECT DISTINCT id_canonico, nome_normalizado FROM tmp_grupos_normalizacao
    LOOP
        -- 3a. Atualiza fact_precos_mensais: redireciona FKs das duplicatas para o canônico
        WITH dups AS (
            SELECT id_produto FROM tmp_grupos_normalizacao
            WHERE id_canonico = v_canonico AND id_produto != v_canonico
        ),
        updated AS (
            UPDATE staging.fact_precos_mensais fp
            SET id_produto = v_canonico
            FROM dups d
            WHERE fp.id_produto = d.id_produto
            RETURNING fp.id_produto
        )
        SELECT COUNT(*) INTO v_count FROM updated;

        IF v_count > 0 THEN
            v_total_precos := v_total_precos + v_count;
            RETURN QUERY
            SELECT
                'FK-PRECOS'::TEXT,
                v_grupo_nome,
                v_canonico,
                (SELECT nome_canonico FROM tmp_grupos_normalizacao WHERE id_canonico = v_canonico LIMIT 1),
                format('%s registros em fact_precos_mensais redirecionados', v_count);
        END IF;

        -- 3b. Atualiza status_fonte_produto: redireciona FKs das duplicatas para o canônico
        WITH dups AS (
            SELECT id_produto FROM tmp_grupos_normalizacao
            WHERE id_canonico = v_canonico AND id_produto != v_canonico
        ),
        updated AS (
            UPDATE staging.status_fonte_produto sfp
            SET id_produto = v_canonico
            FROM dups d
            WHERE sfp.id_produto = d.id_produto
            RETURNING sfp.id_produto
        )
        SELECT COUNT(*) INTO v_count FROM updated;

        IF v_count > 0 THEN
            v_total_sfp := v_total_sfp + v_count;
            RETURN QUERY
            SELECT
                'FK-STATUS_FONTE'::TEXT,
                v_grupo_nome,
                v_canonico,
                (SELECT nome_canonico FROM tmp_grupos_normalizacao WHERE id_canonico = v_canonico LIMIT 1),
                format('%s registros em status_fonte_produto redirecionados', v_count);
        END IF;

        -- 4. Remove duplicatas (exceto canônico)
        WITH dups AS (
            SELECT id_produto FROM tmp_grupos_normalizacao
            WHERE id_canonico = v_canonico AND id_produto != v_canonico
        ),
        deleted AS (
            DELETE FROM staging.dim_produto dp
            USING dups d
            WHERE dp.id_produto = d.id_produto
            RETURNING dp.id_produto, dp.nome_produto
        )
        SELECT COUNT(*) INTO v_count FROM deleted;

        IF v_count > 0 THEN
            RETURN QUERY
            SELECT
                'DELETE'::TEXT,
                v_grupo_nome,
                v_canonico,
                (SELECT nome_canonico FROM tmp_grupos_normalizacao WHERE id_canonico = v_canonico LIMIT 1),
                format('%s produtos duplicados removidos', v_count);
        END IF;

        -- 5. Atualiza nome do canônico para o nome normalizado (se diferente)
        UPDATE staging.dim_produto dp
        SET nome_produto = v_grupo_nome
        WHERE dp.id_produto = v_canonico
          AND dp.nome_produto != v_grupo_nome;

        GET DIAGNOSTICS v_count = ROW_COUNT;
        IF v_count > 0 THEN
            RETURN QUERY
            SELECT
                'RENAME'::TEXT,
                v_grupo_nome,
                v_canonico,
                (SELECT nome_canonico FROM tmp_grupos_normalizacao WHERE id_canonico = v_canonico LIMIT 1),
                'nome atualizado para o normalizado';
        END IF;
    END LOOP;

    -- Limpa temp table
    DROP TABLE IF EXISTS tmp_grupos_normalizacao;

    -- Totais finais
    RETURN QUERY
    SELECT 'FIM'::TEXT,
        format('%s preços + %s status_fonte consolidados',
            v_total_precos, v_total_sfp)::TEXT,
        NULL::INTEGER,
        NULL::TEXT,
        'consolidação concluída'::TEXT;

    RAISE NOTICE '[normalizacao] CONCLUÍDO: % preços + % status_fonte_produto consolidados',
        v_total_precos, v_total_sfp;
END;
$function$;

-- 5.2 — função consolidar_produtos_por_lista
CREATE OR REPLACE FUNCTION staging.consolidar_produtos_por_lista(p_produtos text[], p_dry_run boolean DEFAULT true)
 RETURNS TABLE(acao text, nome_grupo text, id_afetado integer, nome_afetado text, detalhe text)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_count         INTEGER;
    v_removidos     INTEGER := 0;
    v_total_precos  INTEGER := 0;
    v_total_sfp     INTEGER := 0;
    v_canonico      INTEGER;
    v_grupo_nome    TEXT;
    v_produto       TEXT;
BEGIN
    -- Valida entrada
    IF p_produtos IS NULL OR array_length(p_produtos, 1) = 0 THEN
        RETURN QUERY SELECT 'ERRO'::TEXT, 'Nenhum produto informado'::TEXT,
            NULL::INTEGER, NULL::TEXT, 'Informe ao menos um nome normalizado'::TEXT;
        RETURN;
    END IF;

    -- ============================================================
    -- DRY-RUN: relatorio dos grupos solicitados
    -- ============================================================
    IF p_dry_run THEN
        RETURN QUERY
        WITH normalizados AS (
            SELECT
                p.id_produto,
                p.nome_produto,
                staging.normalizar_nome_produto(p.nome_produto) AS nome_normalizado,
                (SELECT COUNT(*) FROM staging.fact_precos_mensais fp WHERE fp.id_produto = p.id_produto) AS qtd_precos
            FROM staging.dim_produto p
            WHERE staging.normalizar_nome_produto(p.nome_produto) = ANY(p_produtos)
        ),
        grupos AS (
            SELECT
                nome_normalizado,
                COUNT(*) AS qtd_produtos
            FROM normalizados
            GROUP BY nome_normalizado
            HAVING COUNT(*) > 1
        ),
        canonical AS (
            SELECT DISTINCT ON (n.nome_normalizado)
                n.nome_normalizado,
                n.id_produto AS id_canonico,
                n.nome_produto AS nome_canonico,
                n.qtd_precos
            FROM normalizados n
            JOIN grupos g ON g.nome_normalizado = n.nome_normalizado
            ORDER BY n.nome_normalizado, n.qtd_precos DESC NULLS LAST, n.id_produto ASC
        ),
        stats AS (
            SELECT
                c.nome_normalizado,
                c.id_canonico,
                c.nome_canonico,
                g.qtd_produtos,
                SUM(n.qtd_precos) AS total_precos_grupo
            FROM grupos g
            JOIN canonical c ON c.nome_normalizado = g.nome_normalizado
            JOIN normalizados n ON n.nome_normalizado = g.nome_normalizado
            GROUP BY c.nome_normalizado, c.id_canonico, c.nome_canonico, g.qtd_produtos
        )
        SELECT
            'DRY-RUN'::TEXT,
            s.nome_normalizado,
            s.id_canonico,
            s.nome_canonico,
            format('%s duplicatas, %s registros de preco no grupo',
                s.qtd_produtos, s.total_precos_grupo)
        FROM stats s
        ORDER BY s.total_precos_grupo DESC;

        -- Mostra tambem os que NAO tem duplicatas (1 variante apenas)
        RETURN QUERY
        WITH normalizados AS (
            SELECT
                p.id_produto,
                p.nome_produto,
                staging.normalizar_nome_produto(p.nome_produto) AS nome_normalizado,
                (SELECT COUNT(*) FROM staging.fact_precos_mensais fp WHERE fp.id_produto = p.id_produto) AS qtd_precos
            FROM staging.dim_produto p
            WHERE staging.normalizar_nome_produto(p.nome_produto) = ANY(p_produtos)
        ),
        singletons AS (
            SELECT
                nome_normalizado,
                COUNT(*) AS qtd_produtos
            FROM normalizados
            GROUP BY nome_normalizado
            HAVING COUNT(*) = 1
        )
        SELECT
            'SEM-DUP'::TEXT,
            s.nome_normalizado,
            n.id_produto,
            n.nome_produto,
            format('1 unica variante, %s registros de preco - nada a consolidar',
                n.qtd_precos)
        FROM singletons s
        JOIN normalizados n ON n.nome_normalizado = s.nome_normalizado
        ORDER BY s.nome_normalizado;

        RETURN;
    END IF;

    -- ============================================================
    -- EXECUCAO REAL
    -- ============================================================
    RAISE NOTICE '[consolidar_fluxo] INICIANDO consolidacao seletiva de % produtos...',
        array_length(p_produtos, 1);

    -- Temp table com grupos de produtos duplicados (apenas os solicitados)
    CREATE TEMP TABLE IF NOT EXISTS tmp_consolidar_fluxo ON COMMIT DROP AS
    WITH normalizados AS (
        SELECT
            p.id_produto,
            p.nome_produto,
            staging.normalizar_nome_produto(p.nome_produto) AS nome_normalizado,
            (SELECT COUNT(*) FROM staging.fact_precos_mensais fp WHERE fp.id_produto = p.id_produto) AS qtd_precos
        FROM staging.dim_produto p
        WHERE staging.normalizar_nome_produto(p.nome_produto) = ANY(p_produtos)
    ),
    grupos AS (
        SELECT
            nome_normalizado,
            COUNT(*) AS qtd_produtos
        FROM normalizados
        GROUP BY nome_normalizado
        HAVING COUNT(*) > 1
    ),
    canonical AS (
        SELECT DISTINCT ON (n.nome_normalizado)
            n.nome_normalizado,
            n.id_produto AS id_canonico,
            n.nome_produto AS nome_canonico,
            n.qtd_precos
        FROM normalizados n
        JOIN grupos g ON g.nome_normalizado = n.nome_normalizado
        ORDER BY n.nome_normalizado, n.qtd_precos DESC NULLS LAST, n.id_produto ASC
    ),
    duplicatas AS (
        SELECT n.*
        FROM normalizados n
        JOIN grupos g ON g.nome_normalizado = n.nome_normalizado
    )
    SELECT
        d.id_produto,
        d.nome_produto,
        d.nome_normalizado,
        c.id_canonico,
        c.nome_canonico,
        d.qtd_precos
    FROM duplicatas d
    JOIN canonical c ON c.nome_normalizado = d.nome_normalizado;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RAISE NOTICE '[consolidar_fluxo] % linhas na temp table', v_count;

    IF v_count = 0 THEN
        RETURN QUERY SELECT 'FIM'::TEXT, 'Nenhuma duplicata encontrada'::TEXT,
            NULL::INTEGER, NULL::TEXT, 'Nada a consolidar'::TEXT;
        DROP TABLE IF EXISTS tmp_consolidar_fluxo;
        RETURN;
    END IF;

    -- Reporta grupos encontrados
    RETURN QUERY
    SELECT
        'GRUPO'::TEXT,
        tg.nome_normalizado,
        tg.id_produto,
        tg.nome_produto,
        format('canonico=%s (%s), precos=%s',
            tg.id_canonico, tg.nome_canonico, tg.qtd_precos)
    FROM tmp_consolidar_fluxo tg
    ORDER BY tg.nome_normalizado, tg.id_produto;

    -- Para cada canonico, processa suas duplicatas
    FOR v_canonico, v_grupo_nome IN
        SELECT DISTINCT id_canonico, nome_normalizado FROM tmp_consolidar_fluxo
    LOOP
        -- ============================================================
        -- Passo 1: fact_precos_mensais
        -- Estrategia em 2 passos para evitar conflitos UNIQUE:
        --   a) Remove registros duplicados que conflitariam (canonico ja tem dado,
        --      OU duas duplicatas tem dado para mesma localidade/ano/mes)
        --   b) Redireciona os registros restantes para o canonico
        -- ============================================================

        -- 1a. Remove registros que causariam conflito de unicidade
        WITH dups AS (
            SELECT id_produto FROM tmp_consolidar_fluxo
            WHERE id_canonico = v_canonico AND id_produto != v_canonico
        ),
        removidos AS (
            DELETE FROM staging.fact_precos_mensais fp
            USING dups d
            WHERE fp.id_produto = d.id_produto
              AND EXISTS (
                  SELECT 1 FROM staging.fact_precos_mensais fp2
                  WHERE (
                      -- Conflito com dados ja existentes do canonico
                      (fp2.id_produto = v_canonico)
                      -- OU conflito intra-duplicata (outra duplicata com ctid menor ja ocupa este slot)
                      OR (fp2.id_produto IN (SELECT id_produto FROM dups) AND fp2.ctid < fp.ctid)
                  )
                    AND fp2.id_localidade = fp.id_localidade
                    AND fp2.ano = fp.ano
                    AND fp2.mes = fp.mes
              )
            RETURNING 1
        )
        SELECT COUNT(*) INTO v_removidos FROM removidos;

        IF v_removidos > 0 THEN
            RETURN QUERY
            SELECT
                'FK-PRECOS-REMOVE'::TEXT,
                v_grupo_nome,
                v_canonico,
                (SELECT nome_canonico FROM tmp_consolidar_fluxo WHERE id_canonico = v_canonico LIMIT 1),
                format('%s registros conflitantes removidos (canonico ou outra duplicata ja tinha dado)', v_removidos);
        END IF;

        -- 1b. Redireciona os demais registros para o canonico (sem risco de conflito)
        WITH dups AS (
            SELECT id_produto FROM tmp_consolidar_fluxo
            WHERE id_canonico = v_canonico AND id_produto != v_canonico
        ),
        updated AS (
            UPDATE staging.fact_precos_mensais fp
            SET id_produto = v_canonico
            FROM dups d
            WHERE fp.id_produto = d.id_produto
            RETURNING fp.id_produto
        )
        SELECT COUNT(*) INTO v_count FROM updated;

        IF v_count > 0 THEN
            v_total_precos := v_total_precos + v_count;
            RETURN QUERY
            SELECT
                'FK-PRECOS'::TEXT,
                v_grupo_nome,
                v_canonico,
                (SELECT nome_canonico FROM tmp_consolidar_fluxo WHERE id_canonico = v_canonico LIMIT 1),
                format('%s registros em fact_precos_mensais redirecionados', v_count);
        END IF;

        -- ============================================================
        -- Passo 2: status_fonte_produto
        -- ============================================================
        WITH dups AS (
            SELECT id_produto FROM tmp_consolidar_fluxo
            WHERE id_canonico = v_canonico AND id_produto != v_canonico
        ),
        updated AS (
            UPDATE staging.status_fonte_produto sfp
            SET id_produto = v_canonico
            FROM dups d
            WHERE sfp.id_produto = d.id_produto
            RETURNING sfp.id_produto
        )
        SELECT COUNT(*) INTO v_count FROM updated;

        IF v_count > 0 THEN
            v_total_sfp := v_total_sfp + v_count;
            RETURN QUERY
            SELECT
                'FK-STATUS_FONTE'::TEXT,
                v_grupo_nome,
                v_canonico,
                (SELECT nome_canonico FROM tmp_consolidar_fluxo WHERE id_canonico = v_canonico LIMIT 1),
                format('%s registros em status_fonte_produto redirecionados', v_count);
        END IF;

        -- ============================================================
        -- Passo 3: Remove duplicatas (exceto canonico)
        -- ============================================================
        WITH dups AS (
            SELECT id_produto FROM tmp_consolidar_fluxo
            WHERE id_canonico = v_canonico AND id_produto != v_canonico
        ),
        deleted AS (
            DELETE FROM staging.dim_produto dp
            USING dups d
            WHERE dp.id_produto = d.id_produto
            RETURNING dp.id_produto, dp.nome_produto
        )
        SELECT COUNT(*) INTO v_count FROM deleted;

        IF v_count > 0 THEN
            RETURN QUERY
            SELECT
                'DELETE'::TEXT,
                v_grupo_nome,
                v_canonico,
                (SELECT nome_canonico FROM tmp_consolidar_fluxo WHERE id_canonico = v_canonico LIMIT 1),
                format('%s produtos duplicados removidos', v_count);
        END IF;

        -- ============================================================
        -- Passo 4: Atualiza nome do canonico para o normalizado
        -- ============================================================
        UPDATE staging.dim_produto dp
        SET nome_produto = v_grupo_nome
        WHERE dp.id_produto = v_canonico
          AND dp.nome_produto != v_grupo_nome;

        GET DIAGNOSTICS v_count = ROW_COUNT;
        IF v_count > 0 THEN
            RETURN QUERY
            SELECT
                'RENAME'::TEXT,
                v_grupo_nome,
                v_canonico,
                (SELECT nome_canonico FROM tmp_consolidar_fluxo WHERE id_canonico = v_canonico LIMIT 1),
                'nome atualizado para o normalizado';
        END IF;
    END LOOP;

    -- Totais finais (antes do DROP para poder consultar a temp table)
    RETURN QUERY
    SELECT 'FIM'::TEXT,
        format('%s precos + %s status_fonte consolidados em %s produtos',
            v_total_precos, v_total_sfp,
            (SELECT COUNT(DISTINCT nome_normalizado) FROM tmp_consolidar_fluxo))::TEXT,
        NULL::INTEGER,
        NULL::TEXT,
        'consolidacao seletiva concluida'::TEXT;

    -- Limpa temp table (DEPOIS do SELECT final)
    DROP TABLE IF EXISTS tmp_consolidar_fluxo;

    RAISE NOTICE '[consolidar_fluxo] CONCLUIDO: %s precos + %s status_fonte consolidados',
        v_total_precos, v_total_sfp;
END;
$function$;

-- 5.3 — função fn_importar_fluxos_json
CREATE OR REPLACE FUNCTION staging.fn_importar_fluxos_json()
 RETURNS TABLE(acao text, fluxo_id integer, item text, produto text, destino text, detalhe text)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_fluxos    JSONB;
    v_fluxo     JSONB;
    v_item      TEXT;
    v_item_norm TEXT;
    v_id_prod   INTEGER;
    v_count     INTEGER := 0;
    v_skip      INTEGER := 0;
BEGIN
    -- ================================================================
    -- Fluxos embutidos do config/flows.json (104 fluxos, v2.0)
    -- Fonte: CEASA/MS Rota dos Alimentos 2025, PROHORT/Conab 2024-2025
    -- ================================================================
    v_fluxos := '[{"id":1,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"norte","destino_uf":"TO","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"baixa","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":2,"item":"Manga","categoria":"Hortifrúti","origem_uf":"PE","origem_polo":"Petrolina/Juazeiro","destino_regiao_id":"norte","destino_uf":"TO","meses":[9,10,11,12],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":3,"item":"Melancia","categoria":"Hortifrúti","origem_uf":"TO","origem_polo":"Lagoa da Confusão","destino_regiao_id":"sudeste","destino_uf":"SP","meses":[6,7,8,9],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":4,"item":"Maçã","categoria":"Hortifrúti","origem_uf":"RS","origem_polo":"Vacaria","destino_regiao_id":"norte","destino_uf":"TO","meses":[3,4,5,6],"sazonalidade":"media","preco_referencial":"Alto","cor_indicadora":"#3B82F6","tipo":"importado","ano_referencia":2026},{"id":5,"item":"Carne Bovina","categoria":"Carnes","origem_uf":"TO","origem_polo":"Araguaína","destino_regiao_id":"norte","destino_uf":"TO","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#059669","tipo":"autossuficiente","ano_referencia":2026},{"id":6,"item":"Arroz","categoria":"Grãos","origem_uf":"TO","origem_polo":"Formoso do Araguaia","destino_regiao_id":"norte","destino_uf":"TO","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#059669","tipo":"autossuficiente","ano_referencia":2026},{"id":7,"item":"Batata","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA Curitiba","destino_regiao_id":"norte","destino_uf":"TO","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Alto","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":8,"item":"Tambaqui","categoria":"Peixes","origem_uf":"TO","origem_polo":"Porto Nacional","destino_regiao_id":"norte","destino_uf":"TO","meses":[1,2,3,4],"sazonalidade":"media","preco_referencial":"Médio","cor_indicadora":"#059669","tipo":"autossuficiente","ano_referencia":2026},{"id":9,"item":"Ovos","categoria":"Proteína Animal","origem_uf":"GO","origem_polo":"Anápolis","destino_regiao_id":"norte","destino_uf":"TO","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":10,"item":"Feijão","categoria":"Grãos","origem_uf":"MG","origem_polo":"Unaí","destino_regiao_id":"norte","destino_uf":"TO","meses":[1,2,3,4,5],"sazonalidade":"alta","preco_referencial":"Alto","cor_indicadora":"#3B82F6","tipo":"importado","ano_referencia":2026},{"id":11,"item":"Manga","categoria":"Hortifrúti","origem_uf":"PE","origem_polo":"Petrolina/Juazeiro","destino_regiao_id":"norte","destino_uf":"PA","meses":[8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":12,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"norte","destino_uf":"PA","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"baixa","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":13,"item":"Arroz","categoria":"Grãos","origem_uf":"TO","origem_polo":"Formoso do Araguaia","destino_regiao_id":"norte","destino_uf":"PA","meses":[6,7,8,9,10],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":14,"item":"Batata","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA Curitiba","destino_regiao_id":"norte","destino_uf":"AM","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Alto","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":15,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"norte","destino_uf":"AM","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"baixa","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":16,"item":"Manga","categoria":"Hortifrúti","origem_uf":"PE","origem_polo":"Petrolina/Juazeiro","destino_regiao_id":"norte","destino_uf":"AM","meses":[8,9,10,11],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":17,"item":"Batata","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA Curitiba","destino_regiao_id":"norte","destino_uf":"RO","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Alto","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":18,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"norte","destino_uf":"RO","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"baixa","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":19,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"norte","destino_uf":"AC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"baixa","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":20,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"norte","destino_uf":"RR","meses":[1,2,3,4,5,6,7,8],"sazonalidade":"media","preco_referencial":"Alto","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":21,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"norte","destino_uf":"AP","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"baixa","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":22,"item":"Manga","categoria":"Hortifrúti","origem_uf":"PE","origem_polo":"Petrolina/Juazeiro","destino_regiao_id":"nordeste","destino_uf":"MA","meses":[8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":23,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"nordeste","destino_uf":"MA","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"baixa","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":24,"item":"Manga","categoria":"Hortifrúti","origem_uf":"BA","origem_polo":"Juazeiro","destino_regiao_id":"nordeste","destino_uf":"PE","meses":[9,10,11,12,1,2],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":25,"item":"Melão","categoria":"Hortifrúti","origem_uf":"RN","origem_polo":"CEASA-RN","destino_regiao_id":"nordeste","destino_uf":"CE","meses":[7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":26,"item":"Melão","categoria":"Hortifrúti","origem_uf":"CE","origem_polo":"CEASA-CE","destino_regiao_id":"nordeste","destino_uf":"RN","meses":[7,8,9,10],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":27,"item":"Manga","categoria":"Hortifrúti","origem_uf":"PE","origem_polo":"Petrolina/Juazeiro","destino_regiao_id":"nordeste","destino_uf":"CE","meses":[8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":28,"item":"Manga","categoria":"Hortifrúti","origem_uf":"PE","origem_polo":"Petrolina/Juazeiro","destino_regiao_id":"nordeste","destino_uf":"PB","meses":[8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":29,"item":"Manga","categoria":"Hortifrúti","origem_uf":"PE","origem_polo":"Petrolina/Juazeiro","destino_regiao_id":"nordeste","destino_uf":"PI","meses":[8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":30,"item":"Batata","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA Curitiba","destino_regiao_id":"nordeste","destino_uf":"BA","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Alto","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":31,"item":"Manga","categoria":"Hortifrúti","origem_uf":"BA","origem_polo":"Juazeiro","destino_regiao_id":"nordeste","destino_uf":"SE","meses":[10,11,12,1,2],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":32,"item":"Manga","categoria":"Hortifrúti","origem_uf":"BA","origem_polo":"Juazeiro","destino_regiao_id":"nordeste","destino_uf":"AL","meses":[10,11,12,1,2],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":33,"item":"Banana","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"centro-oeste","destino_uf":"MS","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":34,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA Curitiba","destino_regiao_id":"centro-oeste","destino_uf":"MS","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":35,"item":"Banana","categoria":"Hortifrúti","origem_uf":"CE","origem_polo":"CEASA-CE","destino_regiao_id":"centro-oeste","destino_uf":"MS","meses":[1,2,3,4,5,6],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#3B82F6","tipo":"importado","ano_referencia":2026},{"id":36,"item":"Batata","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA Curitiba","destino_regiao_id":"centro-oeste","destino_uf":"MS","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":37,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"centro-oeste","destino_uf":"DF","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"baixa","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":38,"item":"Banana","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"centro-oeste","destino_uf":"DF","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":39,"item":"Batata","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA Curitiba","destino_regiao_id":"centro-oeste","destino_uf":"MT","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Alto","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":40,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"sudeste","destino_uf":"SP","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"baixa","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":41,"item":"Banana","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"sudeste","destino_uf":"SP","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":42,"item":"Batata","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA Curitiba","destino_regiao_id":"sudeste","destino_uf":"SP","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":43,"item":"Maçã","categoria":"Hortifrúti","origem_uf":"RS","origem_polo":"Vacaria","destino_regiao_id":"sudeste","destino_uf":"SP","meses":[3,4,5,6,7],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#3B82F6","tipo":"importado","ano_referencia":2026},{"id":44,"item":"Manga","categoria":"Hortifrúti","origem_uf":"PE","origem_polo":"Petrolina/Juazeiro","destino_regiao_id":"sudeste","destino_uf":"SP","meses":[8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":45,"item":"Feijão","categoria":"Grãos","origem_uf":"MG","origem_polo":"Unaí","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":46,"item":"Batata","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA Curitiba","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":47,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"baixa","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":48,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"sudeste","destino_uf":"ES","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"baixa","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":49,"item":"Banana","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"sudeste","destino_uf":"ES","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":50,"item":"Manga","categoria":"Hortifrúti","origem_uf":"BA","origem_polo":"Juazeiro","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[9,10,11,12,1,2],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#3B82F6","tipo":"importado","ano_referencia":2026},{"id":51,"item":"Manga","categoria":"Hortifrúti","origem_uf":"BA","origem_polo":"Juazeiro","destino_regiao_id":"sudeste","destino_uf":"MG","meses":[10,11,12,1,2],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#3B82F6","tipo":"importado","ano_referencia":2026},{"id":52,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"sudeste","destino_uf":"MG","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"baixa","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":53,"item":"Arroz","categoria":"Grãos","origem_uf":"MT","origem_polo":"IMEA-MT","destino_regiao_id":"sudeste","destino_uf":"SP","meses":[6,7,8,9,10],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":54,"item":"Banana","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"centro-oeste","destino_uf":"GO","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":55,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"centro-oeste","destino_uf":"MT","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"baixa","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":56,"item":"Ovos","categoria":"Proteína Animal","origem_uf":"GO","origem_polo":"Anápolis","destino_regiao_id":"centro-oeste","destino_uf":"MS","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":57,"item":"Batata","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA Curitiba","destino_regiao_id":"sul","destino_uf":"RS","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":58,"item":"Batata","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA Curitiba","destino_regiao_id":"sul","destino_uf":"SC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":59,"item":"Cebola","categoria":"Hortifrúti","origem_uf":"SC","origem_polo":"CEASA-SC","destino_regiao_id":"sul","destino_uf":"PR","meses":[11,12,1,2,3],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":60,"item":"Cebola","categoria":"Hortifrúti","origem_uf":"SC","origem_polo":"CEASA-SC","destino_regiao_id":"sul","destino_uf":"RS","meses":[11,12,1,2,3],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":61,"item":"Maçã","categoria":"Hortifrúti","origem_uf":"RS","origem_polo":"Vacaria","destino_regiao_id":"sul","destino_uf":"PR","meses":[3,4,5,6,7],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":62,"item":"Maçã","categoria":"Hortifrúti","origem_uf":"RS","origem_polo":"Vacaria","destino_regiao_id":"sul","destino_uf":"SC","meses":[3,4,5,6,7],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":63,"item":"Manga","categoria":"Hortifrúti","origem_uf":"PE","origem_polo":"Petrolina/Juazeiro","destino_regiao_id":"sul","destino_uf":"PR","meses":[8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":64,"item":"Manga","categoria":"Hortifrúti","origem_uf":"PE","origem_polo":"Petrolina/Juazeiro","destino_regiao_id":"sul","destino_uf":"RS","meses":[8,9,10,11],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#1E3A8A","tipo":"importado","ano_referencia":2026},{"id":65,"item":"Melancia","categoria":"Hortifrúti","origem_uf":"TO","origem_polo":"Lagoa da Confusão","destino_regiao_id":"centro-oeste","destino_uf":"DF","meses":[6,7,8,9],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":66,"item":"Carne Bovina","categoria":"Carnes","origem_uf":"MT","origem_polo":"IMEA-MT","destino_regiao_id":"sul","destino_uf":"PR","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":67,"item":"Carne Bovina","categoria":"Carnes","origem_uf":"MT","origem_polo":"IMEA-MT","destino_regiao_id":"sudeste","destino_uf":"SP","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":68,"item":"Carne Bovina","categoria":"Carnes","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":69,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"BA","origem_polo":"CEASA-BA","destino_regiao_id":"centro-oeste","destino_uf":"MS","meses":[4,5,6,7,8,9,10],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#3B82F6","tipo":"importado","ano_referencia":2026},{"id":70,"item":"Banana","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"nordeste","destino_uf":"CE","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#3B82F6","tipo":"importado","ano_referencia":2026},{"id":71,"item":"Banana","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEAGESP","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":72,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEAGESP","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":73,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEAGESP","destino_regiao_id":"centro-oeste","destino_uf":"MS","meses":[5,6,7,8,9,10],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":74,"item":"Banana","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEAGESP","destino_regiao_id":"sul","destino_uf":"PR","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":75,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEAGESP","destino_regiao_id":"sul","destino_uf":"PR","meses":[5,6,7,8,9,10],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":76,"item":"Banana","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEAGESP","destino_regiao_id":"centro-oeste","destino_uf":"DF","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":77,"item":"Batata","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEAGESP","destino_regiao_id":"sul","destino_uf":"SC","meses":[3,4,5,6,7],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":78,"item":"Banana","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEAGESP","destino_regiao_id":"sudeste","destino_uf":"ES","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":79,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEAGESP","destino_regiao_id":"sudeste","destino_uf":"ES","meses":[5,6,7,8,9,10],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":80,"item":"Carne Bovina","categoria":"Carnes","origem_uf":"MS","origem_polo":"CEASA-MS","destino_regiao_id":"sudeste","destino_uf":"SP","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":81,"item":"Carne Bovina","categoria":"Carnes","origem_uf":"MS","origem_polo":"CEASA-MS","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":82,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"PA","origem_polo":"CEASA-PA","destino_regiao_id":"norte","destino_uf":"AM","meses":[4,5,6,7,8,9],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":83,"item":"Arroz","categoria":"Grãos","origem_uf":"PA","origem_polo":"CEASA-PA","destino_regiao_id":"norte","destino_uf":"AP","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":84,"item":"Arroz","categoria":"Grãos","origem_uf":"PA","origem_polo":"CEASA-PA","destino_regiao_id":"nordeste","destino_uf":"MA","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":85,"item":"Banana","categoria":"Hortifrúti","origem_uf":"AM","origem_polo":"CEASA-AM","destino_regiao_id":"norte","destino_uf":"RR","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":86,"item":"Banana","categoria":"Hortifrúti","origem_uf":"AM","origem_polo":"CEASA-AM","destino_regiao_id":"norte","destino_uf":"RO","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":87,"item":"Banana","categoria":"Hortifrúti","origem_uf":"RO","origem_polo":"CEASA-RO","destino_regiao_id":"norte","destino_uf":"AC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":88,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"ES","origem_polo":"CEASA-ES","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[4,5,6,7,8,9],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":89,"item":"Café","categoria":"Grãos","origem_uf":"ES","origem_polo":"CEASA-ES","destino_regiao_id":"sudeste","destino_uf":"MG","meses":[5,6,7,8,9,10],"sazonalidade":"alta","preco_referencial":"Alto","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":90,"item":"Banana","categoria":"Hortifrúti","origem_uf":"RJ","origem_polo":"CEASA-RJ","destino_regiao_id":"sudeste","destino_uf":"ES","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":91,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"RJ","origem_polo":"CEASA-RJ","destino_regiao_id":"sudeste","destino_uf":"MG","meses":[4,5,6,7,8,9],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":92,"item":"Arroz","categoria":"Grãos","origem_uf":"MA","origem_polo":"CEASA-MA","destino_regiao_id":"nordeste","destino_uf":"PI","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":93,"item":"Melão","categoria":"Hortifrúti","origem_uf":"RN","origem_polo":"CEASA-RN","destino_regiao_id":"nordeste","destino_uf":"CE","meses":[7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":94,"item":"Coco","categoria":"Hortifrúti","origem_uf":"AL","origem_polo":"CEASA-AL","destino_regiao_id":"nordeste","destino_uf":"PE","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":95,"item":"Banana","categoria":"Hortifrúti","origem_uf":"PB","origem_polo":"CEASA-PB","destino_regiao_id":"nordeste","destino_uf":"PE","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":96,"item":"Laranja","categoria":"Hortifrúti","origem_uf":"SE","origem_polo":"CEASA-SE","destino_regiao_id":"nordeste","destino_uf":"BA","meses":[3,4,5,6,7,8],"sazonalidade":"alta","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":97,"item":"Tomate","categoria":"Hortifrúti","origem_uf":"DF","origem_polo":"CEASA-DF","destino_regiao_id":"centro-oeste","destino_uf":"GO","meses":[4,5,6,7,8,9,10],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":98,"item":"Açaí","categoria":"Hortifrúti","origem_uf":"AP","origem_polo":"CEASA-AP","destino_regiao_id":"norte","destino_uf":"PA","meses":[7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Alto","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":99,"item":"Arroz","categoria":"Grãos","origem_uf":"PI","origem_polo":"CEASA-PI","destino_regiao_id":"nordeste","destino_uf":"CE","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":100,"item":"Carne Bovina","categoria":"Carnes","origem_uf":"PA","origem_polo":"CEASA-PA","destino_regiao_id":"norte","destino_uf":"RR","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Alto","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":101,"item":"Castanha","categoria":"Hortifrúti","origem_uf":"AC","origem_polo":"CEASA-AC","destino_regiao_id":"norte","destino_uf":"RO","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Alto","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":102,"item":"Açaí","categoria":"Hortifrúti","origem_uf":"AC","origem_polo":"CEASA-AC","destino_regiao_id":"norte","destino_uf":"AM","meses":[7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Alto","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":103,"item":"Arroz","categoria":"Grãos","origem_uf":"RR","origem_polo":"CEASA-RR","destino_regiao_id":"norte","destino_uf":"AM","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Baixo","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":104,"item":"Banana","categoria":"Hortifrúti","origem_uf":"RR","origem_polo":"CEASA-RR","destino_regiao_id":"norte","destino_uf":"PA","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"nenhuma","preco_referencial":"Médio","cor_indicadora":"#10B981","tipo":"exportado","ano_referencia":2026},{"id":105,"item":"Milho","categoria":"Hortifrúti","origem_uf":"MT","origem_polo":"CEASA-MT","destino_regiao_id":"sudeste","destino_uf":"SP","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":106,"item":"Milho","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA-PR","destino_regiao_id":"sul","destino_uf":"SC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":107,"item":"Milho","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"centro-oeste","destino_uf":"DF","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":108,"item":"Milho","categoria":"Hortifrúti","origem_uf":"MS","origem_polo":"CEASA-MS","destino_regiao_id":"sudeste","destino_uf":"MG","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":109,"item":"Milho","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA-PR","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":110,"item":"Leite de Vaca","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":111,"item":"Leite de Vaca","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"centro-oeste","destino_uf":"DF","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":112,"item":"Leite de Vaca","categoria":"Hortifrúti","origem_uf":"RS","origem_polo":"CEASA-RS","destino_regiao_id":"sul","destino_uf":"SC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":113,"item":"Leite de Vaca","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA-PR","destino_regiao_id":"sudeste","destino_uf":"SP","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":114,"item":"Leite de Vaca","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"sudeste","destino_uf":"ES","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":115,"item":"Farinha de Mandioca","categoria":"Hortifrúti","origem_uf":"PA","origem_polo":"CEASA-PA","destino_regiao_id":"nordeste","destino_uf":"MA","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":116,"item":"Farinha de Mandioca","categoria":"Hortifrúti","origem_uf":"PA","origem_polo":"CEASA-PA","destino_regiao_id":"norte","destino_uf":"AP","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"media","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":117,"item":"Farinha de Mandioca","categoria":"Hortifrúti","origem_uf":"BA","origem_polo":"CEASA-BA","destino_regiao_id":"nordeste","destino_uf":"SE","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":118,"item":"Farinha de Mandioca","categoria":"Hortifrúti","origem_uf":"BA","origem_polo":"CEASA-BA","destino_regiao_id":"nordeste","destino_uf":"AL","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":119,"item":"Farinha de Mandioca","categoria":"Hortifrúti","origem_uf":"PA","origem_polo":"CEASA-PA","destino_regiao_id":"norte","destino_uf":"AM","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"media","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":120,"item":"Batata Doce","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEASA-SP","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":121,"item":"Batata Doce","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA-PR","destino_regiao_id":"sul","destino_uf":"SC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":122,"item":"Batata Doce","categoria":"Hortifrúti","origem_uf":"RS","origem_polo":"CEASA-RS","destino_regiao_id":"sul","destino_uf":"SC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":123,"item":"Batata Doce","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEASA-SP","destino_regiao_id":"centro-oeste","destino_uf":"DF","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":124,"item":"Batata Doce","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"nordeste","destino_uf":"BA","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":125,"item":"Soja em Grãos","categoria":"Hortifrúti","origem_uf":"MT","origem_polo":"CEASA-MT","destino_regiao_id":"sudeste","destino_uf":"SP","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":126,"item":"Soja em Grãos","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA-PR","destino_regiao_id":"sul","destino_uf":"SC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":127,"item":"Soja em Grãos","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"sudeste","destino_uf":"MG","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":128,"item":"Soja em Grãos","categoria":"Hortifrúti","origem_uf":"RS","origem_polo":"CEASA-RS","destino_regiao_id":"sul","destino_uf":"SC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":129,"item":"Alho","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"sudeste","destino_uf":"SP","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":130,"item":"Alho","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":131,"item":"Alho","categoria":"Hortifrúti","origem_uf":"GO","origem_polo":"CEASA-GO","destino_regiao_id":"centro-oeste","destino_uf":"DF","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":132,"item":"Alho","categoria":"Hortifrúti","origem_uf":"RS","origem_polo":"CEASA-RS","destino_regiao_id":"sul","destino_uf":"SC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":133,"item":"Feijão Preto","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA-PR","destino_regiao_id":"sudeste","destino_uf":"SP","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":134,"item":"Feijão Preto","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA-PR","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":135,"item":"Feijão Preto","categoria":"Hortifrúti","origem_uf":"RS","origem_polo":"CEASA-RS","destino_regiao_id":"sul","destino_uf":"SC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":136,"item":"Feijão Preto","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA-PR","destino_regiao_id":"sudeste","destino_uf":"MG","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":137,"item":"Óleo de Soja","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA-PR","destino_regiao_id":"sul","destino_uf":"SC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":138,"item":"Óleo de Soja","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA-PR","destino_regiao_id":"sul","destino_uf":"RS","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":139,"item":"Óleo de Soja","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEASA-SP","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":140,"item":"Óleo de Soja","categoria":"Hortifrúti","origem_uf":"MT","origem_polo":"CEASA-MT","destino_regiao_id":"centro-oeste","destino_uf":"GO","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":141,"item":"Óleo de Soja","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEASA-SP","destino_regiao_id":"sudeste","destino_uf":"MG","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":142,"item":"Farinha de Trigo","categoria":"Hortifrúti","origem_uf":"RS","origem_polo":"CEASA-RS","destino_regiao_id":"sul","destino_uf":"SC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":143,"item":"Farinha de Trigo","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA-PR","destino_regiao_id":"sul","destino_uf":"SC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":144,"item":"Farinha de Trigo","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEASA-SP","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":145,"item":"Farinha de Trigo","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEASA-SP","destino_regiao_id":"sudeste","destino_uf":"MG","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":146,"item":"Farinha de Trigo","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA-PR","destino_regiao_id":"centro-oeste","destino_uf":"DF","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":147,"item":"Cenoura","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":148,"item":"Cenoura","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEASA-SP","destino_regiao_id":"centro-oeste","destino_uf":"DF","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":149,"item":"Cenoura","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA-PR","destino_regiao_id":"sul","destino_uf":"SC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":150,"item":"Cenoura","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"nordeste","destino_uf":"BA","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":151,"item":"Mandioca","categoria":"Hortifrúti","origem_uf":"PA","origem_polo":"CEASA-PA","destino_regiao_id":"nordeste","destino_uf":"MA","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":152,"item":"Mandioca","categoria":"Hortifrúti","origem_uf":"PA","origem_polo":"CEASA-PA","destino_regiao_id":"norte","destino_uf":"AP","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"media","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":153,"item":"Mandioca","categoria":"Hortifrúti","origem_uf":"BA","origem_polo":"CEASA-BA","destino_regiao_id":"nordeste","destino_uf":"SE","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":154,"item":"Mandioca","categoria":"Hortifrúti","origem_uf":"BA","origem_polo":"CEASA-BA","destino_regiao_id":"nordeste","destino_uf":"AL","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":155,"item":"Abacate","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEASA-SP","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":156,"item":"Abacate","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"centro-oeste","destino_uf":"DF","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":157,"item":"Abacate","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEASA-SP","destino_regiao_id":"centro-oeste","destino_uf":"GO","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":158,"item":"Abacate","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEASA-SP","destino_regiao_id":"sul","destino_uf":"PR","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":159,"item":"Tangerina","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEASA-SP","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":160,"item":"Tangerina","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEASA-SP","destino_regiao_id":"sul","destino_uf":"PR","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":161,"item":"Tangerina","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"centro-oeste","destino_uf":"DF","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":162,"item":"Tangerina","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEASA-SP","destino_regiao_id":"sudeste","destino_uf":"MG","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":163,"item":"Alface","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEASA-SP","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":164,"item":"Alface","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":165,"item":"Alface","categoria":"Hortifrúti","origem_uf":"SP","origem_polo":"CEASA-SP","destino_regiao_id":"centro-oeste","destino_uf":"DF","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":166,"item":"Alface","categoria":"Hortifrúti","origem_uf":"PR","origem_polo":"CEASA-PR","destino_regiao_id":"sul","destino_uf":"SC","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":167,"item":"Manteiga","categoria":"Hortifrúti","origem_uf":"RS","origem_polo":"CEASA-RS","destino_regiao_id":"sudeste","destino_uf":"SP","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":168,"item":"Manteiga","categoria":"Hortifrúti","origem_uf":"SC","origem_polo":"CEASA-SC","destino_regiao_id":"sudeste","destino_uf":"RJ","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":169,"item":"Manteiga","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"centro-oeste","destino_uf":"GO","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"},{"id":170,"item":"Manteiga","categoria":"Hortifrúti","origem_uf":"MG","origem_polo":"CEASA-MG","destino_regiao_id":"centro-oeste","destino_uf":"DF","meses":[1,2,3,4,5,6,7,8,9,10,11,12],"sazonalidade":"alta","preco_referencial":"Médio","cor_indicadora":"#6366F1","tipo":"exportado"}]'::JSONB;

    -- Limpa tabela para recarga
    DELETE FROM staging.dim_fluxo_abastecimento;

    -- ================================================================
    -- Processa cada fluxo e faz o matching com dim_produto
    -- ================================================================
    FOR v_fluxo IN SELECT * FROM jsonb_array_elements(v_fluxos)
    LOOP
        v_item := v_fluxo->>'item';

        -- Mapeamento manual para itens cujo nome normalizado não bate direto
        v_item_norm := CASE v_item
            WHEN 'Ovos'      THEN 'OVOS DE GALINHA'
            WHEN 'Maçã'      THEN 'MACA'
            WHEN 'Café'      THEN 'CAFE'
            WHEN 'Feijão'    THEN 'FEIJAO COMUM CORES'
            ELSE UPPER(TRANSLATE(v_item, 'áâãàéêèíîóôõúûç', 'aaaaeeeiiooouuc'))
        END;

        -- Normaliza via normalizar_nome_produto para consistência
        v_item_norm := staging.normalizar_nome_produto(v_item_norm);

        -- Busca id_produto (pelo canônico — o com mais dados)
        SELECT dp.id_produto INTO v_id_prod
        FROM staging.dim_produto dp
        WHERE staging.normalizar_nome_produto(dp.nome_produto) = v_item_norm
        ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp WHERE fp.id_produto = dp.id_produto) DESC
        LIMIT 1;

        -- Se encontrou match, insere o fluxo
        IF v_id_prod IS NOT NULL THEN
            INSERT INTO staging.dim_fluxo_abastecimento (
                id_produto, produto_nome, origem_uf, origem_polo,
                destino_regiao_id, destino_uf, meses, sazonalidade,
                preco_referencial, tipo, ano_referencia
            ) VALUES (
                v_id_prod,
                v_item,
                v_fluxo->>'origem_uf',
                v_fluxo->>'origem_polo',
                v_fluxo->>'destino_regiao_id',
                v_fluxo->>'destino_uf',
                ARRAY(SELECT jsonb_array_elements_text(v_fluxo->'meses')::INTEGER),
                v_fluxo->>'sazonalidade',
                v_fluxo->>'preco_referencial',
                v_fluxo->>'tipo',
                COALESCE((v_fluxo->>'ano_referencia')::INTEGER, 2026)
            )
            ON CONFLICT (id_produto, origem_uf, destino_uf, tipo)
            DO UPDATE SET
                meses = ARRAY(
                    SELECT DISTINCT UNNEST(
                        EXCLUDED.meses || staging.dim_fluxo_abastecimento.meses
                    ) ORDER BY 1
                ),
                sazonalidade = EXCLUDED.sazonalidade,
                preco_referencial = EXCLUDED.preco_referencial,
                criado_em = NOW();

            v_count := v_count + 1;

            RETURN QUERY
            SELECT 'INSERIDO'::TEXT,
                   (v_fluxo->>'id')::INTEGER,
                   v_item,
                   (SELECT nome_produto FROM staging.dim_produto WHERE id_produto = v_id_prod),
                   v_fluxo->>'destino_uf',
                   format('id_produto=%s', v_id_prod);
        ELSE
            v_skip := v_skip + 1;

            RETURN QUERY
            SELECT 'IGNORADO'::TEXT,
                   (v_fluxo->>'id')::INTEGER,
                   v_item,
                   'sem match em dim_produto',
                   v_fluxo->>'destino_uf',
                   'produto não encontrado no banco';
        END IF;
    END LOOP;

    -- Totais finais
    RETURN QUERY
    SELECT 'FIM'::TEXT,
           NULL::INTEGER,
           format('%s fluxos importados', v_count)::TEXT,
           format('%s ignorados (sem match)', v_skip)::TEXT,
           NULL::TEXT,
           format('%s fluxos na tabela', v_count)::TEXT;

    RAISE NOTICE '[fluxos] Importados: % | Ignorados: % | Total na tabela: %',
        v_count, v_skip, (SELECT COUNT(*) FROM staging.dim_fluxo_abastecimento);
END;
$function$;

-- 5.4 — função injetar_dados_ufs_carentes
CREATE OR REPLACE FUNCTION staging.injetar_dados_ufs_carentes(p_dry_run boolean DEFAULT true)
 RETURNS TABLE(acao text, uf_destino text, produto text, fornecedor text, qtd_meses integer, detalhe text)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_produtos_base   TEXT[] := ARRAY[
        'TOMATE','BATATA','CEBOLA','CENOURA','ALFACE','BANANA',
        'MELANCIA','MANGA','MACA','LARANJA','FEIJAO','ARROZ',
        'MANDIOCA','MILHO','ALHO','BATATA DOCE','MORANGO','GOIABA',
        'PEPINO','REPOLHO','BETERRABA','VAGEM','COUVE','ABACATE',
        'ABACAXI','BERINJELA','CHUCHU','INHAME','COUVE-FLOR',
        'QUIABO','TANGERINA','MAMAO','CAFE','LEITE DE VACA',
        'CARNE BOVINA','OVOS DE GALINHA','OLEO DE SOJA','ACUCAR',
        'PAO','MANTEIGA','MACARRAO','SAL','COCO'
    ];
    v_ufs_carentes    TEXT[] := ARRAY['AC','AM','AP','PI','RO','RR','SE'];
    v_uf               TEXT;
    v_produto_norm     TEXT;
    v_id_produto       INTEGER;
    v_produto_nome     TEXT;
    v_origem_uf        TEXT;
    v_preco_proxy      NUMERIC(14,4);
    v_injetados        INTEGER := 0;
    v_skip             INTEGER := 0;
    v_batch_id         UUID := gen_random_uuid();
    v_ano              INTEGER;
    v_mes              INTEGER;
    v_meses_destino    INTEGER[];
    v_id_localidade    INTEGER;
    v_fornecedor_label TEXT;
    v_total            INTEGER := 0;
BEGIN
    -- ================================================================
    -- DRY-RUN: apenas relatório, sem modificar dados
    -- ================================================================
    IF p_dry_run THEN
        RETURN QUERY
        WITH hortifruti_base AS (
            SELECT DISTINCT unnest(v_produtos_base) AS base_nome
        ),
        ufs_carentes AS (
            SELECT unnest(v_ufs_carentes) AS uf
        ),
        existentes AS (
            SELECT DISTINCT l.uf, fn.nome_produto_norm
            FROM staging.fact_precos_mensais fp
            JOIN staging.dim_localidade l ON l.id_localidade = fp.id_localidade
            JOIN (
                SELECT p.id_produto,
                       staging.normalizar_nome_produto(p.nome_produto) AS nome_produto_norm
                FROM staging.dim_produto p
            ) fn ON fn.id_produto = fp.id_produto
            WHERE l.uf = ANY (v_ufs_carentes)
        )
        SELECT
            'DRY-RUN'::TEXT,
            u.uf,
            h.base_nome,
            COALESCE(
                (SELECT string_agg(DISTINCT f.origem_uf, ', ' ORDER BY f.origem_uf)
                 FROM staging.dim_fluxo_abastecimento f
                 JOIN staging.dim_produto p ON p.id_produto = f.id_produto
                 WHERE f.destino_uf = u.uf
                   AND staging.normalizar_nome_produto(p.nome_produto) = h.base_nome),
                'sem_fluxo'
            ),
            0::INTEGER,
            'produto ausente em fact_precos_mensais'
        FROM ufs_carentes u
        CROSS JOIN hortifruti_base h
        WHERE NOT EXISTS (
            SELECT 1 FROM existentes e
            WHERE e.uf = u.uf AND e.nome_produto_norm = h.base_nome
        )
        ORDER BY u.uf, h.base_nome;

        RETURN;
    END IF;

    -- ================================================================
    -- EXECUÇÃO: injeta dados proxy
    -- ================================================================
    RAISE NOTICE '[injetar_ufs] INICIANDO injeção para UFs carentes (batch=%s)', v_batch_id;

    -- Itera sobre cada UF carente
    FOREACH v_uf IN ARRAY v_ufs_carentes LOOP

        -- Busca id_localidade para esta UF (preferencialmente o agregado UF, senão qualquer uma)
        SELECT dl.id_localidade INTO v_id_localidade
        FROM staging.dim_localidade dl
        WHERE dl.uf = v_uf AND dl.municipio_id = '0'
        LIMIT 1;

        IF v_id_localidade IS NULL THEN
            SELECT dl.id_localidade INTO v_id_localidade
            FROM staging.dim_localidade dl
            WHERE dl.uf = v_uf
            LIMIT 1;
        END IF;

        IF v_id_localidade IS NULL THEN
            RAISE WARNING '[injetar_ufs] UF % não tem localidade cadastrada, pulando', v_uf;
            CONTINUE;
        END IF;

        -- Itera sobre cada produto base
        FOREACH v_produto_norm IN ARRAY v_produtos_base LOOP

            -- Verifica se o produto já existe para esta UF
            PERFORM 1
            FROM staging.fact_precos_mensais fp
            JOIN staging.dim_produto p ON p.id_produto = fp.id_produto
            WHERE fp.id_localidade = v_id_localidade
              AND staging.normalizar_nome_produto(p.nome_produto) = v_produto_norm
            LIMIT 1;

            IF FOUND THEN
                CONTINUE;  -- Já existe, pula
            END IF;

            -- Busca o id_produto canônico (o com mais dados)
            SELECT dp.id_produto, dp.nome_produto INTO v_id_produto, v_produto_nome
            FROM staging.dim_produto dp
            WHERE staging.normalizar_nome_produto(dp.nome_produto) = v_produto_norm
            ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp2 WHERE fp2.id_produto = dp.id_produto) DESC
            LIMIT 1;

            IF v_id_produto IS NULL THEN
                v_skip := v_skip + 1;
                CONTINUE;
            END IF;

            -- Tenta 1: Busca UF fornecedora no dim_fluxo_abastecimento
            SELECT f.origem_uf INTO v_origem_uf
            FROM staging.dim_fluxo_abastecimento f
            WHERE f.id_produto = v_id_produto
              AND f.destino_uf = v_uf
            LIMIT 1;

            -- Tenta 2: Se não achou fluxo, busca qualquer UF que tenha o produto
            IF v_origem_uf IS NULL THEN
                SELECT l.uf INTO v_origem_uf
                FROM staging.fact_precos_mensais fp
                JOIN staging.dim_localidade l ON l.id_localidade = fp.id_localidade
                WHERE fp.id_produto = v_id_produto
                  AND l.uf != v_uf AND l.uf != 'BR'
                  AND fp.preco_medio IS NOT NULL
                GROUP BY l.uf
                ORDER BY COUNT(*) DESC
                LIMIT 1;
            END IF;

            -- Calcula preço proxy
            v_preco_proxy := NULL;

            IF v_origem_uf IS NOT NULL THEN
                SELECT AVG(fp.preco_medio) INTO v_preco_proxy
                FROM staging.fact_precos_mensais fp
                JOIN staging.dim_localidade l ON l.id_localidade = fp.id_localidade
                WHERE fp.id_produto = v_id_produto
                  AND l.uf = v_origem_uf
                  AND fp.preco_medio IS NOT NULL;

                IF v_preco_proxy IS NOT NULL THEN
                    v_fornecedor_label := v_origem_uf;
                END IF;
            END IF;

            -- Fallback 1: Média nacional (BR)
            IF v_preco_proxy IS NULL THEN
                SELECT AVG(fp.preco_medio) INTO v_preco_proxy
                FROM staging.fact_precos_mensais fp
                JOIN staging.dim_localidade l ON l.id_localidade = fp.id_localidade
                WHERE fp.id_produto = v_id_produto
                  AND l.uf = 'BR'
                  AND fp.preco_medio IS NOT NULL;

                IF v_preco_proxy IS NOT NULL THEN
                    v_fornecedor_label := 'BR (nacional)';
                END IF;
            END IF;

            -- Fallback 2: Média geral
            IF v_preco_proxy IS NULL THEN
                SELECT AVG(fp.preco_medio) INTO v_preco_proxy
                FROM staging.fact_precos_mensais fp
                WHERE fp.id_produto = v_id_produto
                  AND fp.preco_medio IS NOT NULL;

                IF v_preco_proxy IS NOT NULL THEN
                    v_fornecedor_label := 'GERAL';
                END IF;
            END IF;

            -- Se não tem preço de jeito nenhum, pula
            IF v_preco_proxy IS NULL OR v_preco_proxy <= 0 THEN
                v_skip := v_skip + 1;
                CONTINUE;
            END IF;

            -- Determina meses: usa do fluxo, ou todos os 12
            SELECT f.meses INTO v_meses_destino
            FROM staging.dim_fluxo_abastecimento f
            WHERE f.id_produto = v_id_produto
              AND f.destino_uf = v_uf
            LIMIT 1;

            IF v_meses_destino IS NULL OR array_length(v_meses_destino, 1) IS NULL THEN
                v_meses_destino := ARRAY[1,2,3,4,5,6,7,8,9,10,11,12];
            END IF;

            -- Injeta para cada ano × mês
            FOR v_ano IN 2024..2026 LOOP
                FOREACH v_mes IN ARRAY v_meses_destino LOOP
                    INSERT INTO staging.fact_precos_mensais (
                        id_produto, id_localidade, ano, mes,
                        preco_medio, fonte, batch_id
                    ) VALUES (
                        v_id_produto,
                        v_id_localidade,
                        v_ano,
                        v_mes,
                        ROUND(v_preco_proxy * (1 + (random() - 0.5) * 0.2)::NUMERIC, 4),
                        'FLUXO_PROXY',
                        v_batch_id
                    )
                    ON CONFLICT (id_produto, id_localidade, ano, mes)
                    DO UPDATE SET
                        preco_medio = CASE WHEN staging.fact_precos_mensais.fonte = 'FLUXO_PROXY'
                                          THEN EXCLUDED.preco_medio
                                          ELSE staging.fact_precos_mensais.preco_medio END,
                        fonte = CASE WHEN staging.fact_precos_mensais.fonte = 'FLUXO_PROXY'
                                    THEN 'FLUXO_PROXY'
                                    ELSE staging.fact_precos_mensais.fonte END,
                        batch_id = v_batch_id;
                END LOOP;
            END LOOP;

            v_injetados := v_injetados + 1;

            RETURN QUERY
            SELECT
                'INJETADO'::TEXT,
                v_uf,
                v_produto_nome,
                v_fornecedor_label,
                array_length(v_meses_destino, 1),
                format('preco_proxy=R$%s, batch=%s',
                    ROUND(v_preco_proxy::NUMERIC, 2), v_batch_id);
        END LOOP;
    END LOOP;

    -- Refresh da MV para que os novos dados apareçam na API
    IF v_injetados > 0 THEN
        REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
    END IF;

    -- Relatório final
    RETURN QUERY
    SELECT 'FIM'::TEXT,
           '7 UFs processadas'::TEXT,
           format('%s produtos injetados', v_injetados)::TEXT,
           format('%s pulados', v_skip)::TEXT,
           0::INTEGER,
           format('batch=%s', v_batch_id)::TEXT;

    RAISE NOTICE '[injetar_ufs] CONCLUÍDO: % produtos injetados, % ignorados, batch=%s',
        v_injetados, v_skip, v_batch_id;
    RAISE NOTICE '[injetar_ufs] Para propagar à API, execute: CALL staging.sp_executar_carga_completa()';
END;
$function$;

-- 5.5 — função relatorio_normalizacao_produtos
CREATE OR REPLACE FUNCTION staging.relatorio_normalizacao_produtos()
 RETURNS TABLE(grupo_normalizado text, produtos_originais text, id_canonico integer, nome_canonico text, total_duplicatas bigint, qtd_precos_afetados bigint)
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    RETURN QUERY
    WITH normalizados AS (
        SELECT
            p.id_produto,
            p.nome_produto,
            staging.normalizar_nome_produto(p.nome_produto) AS nome_normalizado
        FROM staging.dim_produto p
    ),
    grupos AS (
        SELECT
            nome_normalizado,
            COUNT(*) AS qtd_produtos,
            STRING_AGG(id_produto::TEXT || '=' || nome_produto, ' | ' ORDER BY nome_produto) AS produtos_lista
        FROM normalizados
        GROUP BY nome_normalizado
        HAVING COUNT(*) > 1
    ),
    canonical AS (
        SELECT DISTINCT ON (n.nome_normalizado)
            n.nome_normalizado,
            n.id_produto AS id_canonico,
            n.nome_produto AS nome_canonico
        FROM normalizados n
        JOIN grupos g ON g.nome_normalizado = n.nome_normalizado
        ORDER BY n.nome_normalizado,
            (SELECT COUNT(*) FROM staging.fact_precos_mensais fp WHERE fp.id_produto = n.id_produto) DESC
    ),
    precos_count AS (
        SELECT
            staging.normalizar_nome_produto(p.nome_produto) AS nome_normalizado,
            COUNT(fp.*) AS total_precos
        FROM staging.dim_produto p
        LEFT JOIN staging.fact_precos_mensais fp ON fp.id_produto = p.id_produto
        GROUP BY staging.normalizar_nome_produto(p.nome_produto)
    )
    SELECT
        g.nome_normalizado,
        g.produtos_lista,
        c.id_canonico,
        c.nome_canonico,
        g.qtd_produtos,
        COALESCE(pc.total_precos, 0)
    FROM grupos g
    JOIN canonical c ON c.nome_normalizado = g.nome_normalizado
    LEFT JOIN precos_count pc ON pc.nome_normalizado = g.nome_normalizado
    ORDER BY g.qtd_produtos DESC, g.nome_normalizado;
END;
$function$;

-- 5.6 — função sp_calcular_sazonalidade
CREATE OR REPLACE PROCEDURE staging.sp_calcular_sazonalidade(IN p_ano_alvo smallint DEFAULT NULL::smallint, IN p_mes_alvo smallint DEFAULT NULL::smallint)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_ano   SMALLINT;
    v_mes   SMALLINT;
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
    v_total  INTEGER;
BEGIN
    v_inicio := clock_timestamp();

    IF p_ano_alvo IS NULL OR p_mes_alvo IS NULL THEN
        SELECT MAX(ano), MAX(mes) INTO v_ano, v_mes
        FROM staging.fact_precos_mensais;
    ELSE
        v_ano := p_ano_alvo;
        v_mes := p_mes_alvo;
    END IF;

    RAISE NOTICE '[sp_calcular_sazonalidade] Alvo: %-%', v_ano, v_mes;

    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade, ano, mes,
        preco_medio, media_movel_12m, indice_sazonalidade,
        status_cor, fonte, calculado_em,
        preco_atual, preco_referencia,
        desvio_padrao_historico, limite_superior, limite_inferior,
        preco_mes_anterior, variacao_mom_pct,
        data_referencia_atual
    )
    WITH precos_12m AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            f.ano,
            f.mes,
            f.preco_medio,
            AVG(f.preco_medio) OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano, f.mes
                ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
            ) AS media_movel_12m,
            COUNT(*) OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano, f.mes
                ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
            ) AS meses_no_window,
            LAG(f.preco_medio) OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano, f.mes
            ) AS preco_mes_anterior
        FROM staging.fact_precos_mensais f
        WHERE (f.ano < v_ano OR (f.ano = v_ano AND f.mes <= v_mes))
          AND f.preco_medio IS NOT NULL
    ),
    -- Volatilidade avaliada UMA vez (MATERIALIZED) — as linhas LATERAL apenas
    -- fazem lookup por (id_produto, id_localidade), sem re-executar a função.
    volatilidade AS MATERIALIZED (
        SELECT * FROM staging.estatisticas_volatilidade_24m()
    )
    SELECT
        p.id_produto,
        p.id_localidade,
        p.ano,
        p.mes,
        p.preco_medio,
        p.media_movel_12m,
        CASE
            WHEN p.media_movel_12m IS NOT NULL AND p.media_movel_12m > 0
            THEN ROUND(p.preco_medio / p.media_movel_12m, 4)
            ELSE NULL
        END AS indice_sazonalidade,
        CASE
            WHEN p.meses_no_window < 6 THEN 'AMARELO'
            WHEN v.desvio_efetivo IS NULL THEN 'AMARELO'
            ELSE COALESCE(
                staging.calcular_semaforo_preco(
                    p.preco_medio, p.media_movel_12m, v.desvio_efetivo
                ),
                'AMARELO'
            )
        END AS status_cor,
        'municipio' AS fonte,
        NOW() AS calculado_em,
        p.preco_medio AS preco_atual,
        p.preco_medio AS preco_referencia,
        v.desvio_efetivo AS desvio_padrao_historico,
        p.media_movel_12m + v.desvio_efetivo AS limite_superior,
        p.media_movel_12m - v.desvio_efetivo AS limite_inferior,
        p.preco_mes_anterior,
        CASE
            WHEN p.preco_mes_anterior IS NULL OR p.preco_mes_anterior <= 0
                 OR p.preco_medio IS NULL OR p.preco_medio <= 0
            THEN NULL
            ELSE ROUND(((p.preco_medio / p.preco_mes_anterior) - 1) * 100, 4)
        END AS variacao_mom_pct,
        p.ano::TEXT || '-' || LPAD(p.mes::TEXT, 2, '0') AS data_referencia_atual
    FROM precos_12m p
    LEFT JOIN LATERAL (
        SELECT st.desvio_efetivo
        FROM volatilidade st
        WHERE st.id_produto = p.id_produto
          AND st.id_localidade = p.id_localidade
    ) v ON TRUE
    WHERE p.ano = v_ano AND p.mes = v_mes
    ON CONFLICT (id_produto, id_localidade, ano, mes)
    DO UPDATE SET
        preco_medio         = EXCLUDED.preco_medio,
        media_movel_12m     = EXCLUDED.media_movel_12m,
        indice_sazonalidade = EXCLUDED.indice_sazonalidade,
        status_cor          = EXCLUDED.status_cor,
        calculado_em        = NOW(),
        preco_atual         = EXCLUDED.preco_atual,
        preco_referencia    = EXCLUDED.preco_referencia,
        desvio_padrao_historico = EXCLUDED.desvio_padrao_historico,
        limite_superior     = EXCLUDED.limite_superior,
        limite_inferior     = EXCLUDED.limite_inferior,
        preco_mes_anterior  = EXCLUDED.preco_mes_anterior,
        variacao_mom_pct    = EXCLUDED.variacao_mom_pct,
        data_referencia_atual = EXCLUDED.data_referencia_atual;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$procedure$;

-- 5.7 — função sp_project_sandwich_prices_2026
CREATE OR REPLACE PROCEDURE staging.sp_project_sandwich_prices_2026()
 LANGUAGE plpgsql
 SET statement_timeout TO '300000'
AS $procedure$
DECLARE
    v_inicio     TIMESTAMPTZ;
    v_fim        TIMESTAMPTZ;
    v_total      INTEGER;
    v_mes_atual  INTEGER;
    v_proxy      INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    v_mes_atual := EXTRACT(MONTH FROM NOW())::INTEGER;

    PERFORM pg_advisory_xact_lock(hashtext('sp_project_sandwich_prices_2026'));

    RAISE NOTICE '[sp_project_sandwich_prices_2026] Iniciando Sanduíche Sazonal v7 (±25%% + preserva método v13) (mês atual: %)...', v_mes_atual;

    WITH precos_patch AS (
        SELECT
            s.id_sazonalidade,
            s.id_produto,
            s.id_localidade,
            s.ano, s.mes,
            h.preco_medio_historico,
            h.tendencia_pct,
            h.confianca,
            COALESCE(NULLIF(f.fator_kg, 0), 1) AS fator_kg
        FROM mart.sazonalidade_produto s
        JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
        LEFT JOIN mart.fator_kg_produto_uf f
            ON f.id_produto = s.id_produto
           AND f.uf         = l.uf
        CROSS JOIN LATERAL staging.fn_sandwich_historical_price(
            s.id_produto, s.id_localidade, s.mes
        ) h
        WHERE s.ano = 2026
          AND s.mes <= v_mes_atual
          AND s.preco_atual IS NULL
          AND s.is_forecast = TRUE
          AND h.preco_medio_historico IS NOT NULL
    )
    UPDATE mart.sazonalidade_produto s
    SET
        preco_atual        = ROUND(p.preco_medio_historico * (1 + p.tendencia_pct / 100) / p.fator_kg, 4),
        preco_referencia   = ROUND(p.preco_medio_historico / p.fator_kg, 4),
        status_cor         = COALESCE(
            staging.fn_status_cor_regra_25(
                ROUND(p.preco_medio_historico * (1 + p.tendencia_pct / 100) / p.fator_kg, 4),
                ROUND(p.preco_medio_historico / p.fator_kg, 4)
            ),
            s.status_cor
        ),
        baseline_confianca = GREATEST(s.baseline_confianca, p.confianca),
        -- v7: preserva método v13 (ANCHOR/PROXY_CATEGORIA/LOCF) se já existir
        forecast_method    = CASE
            WHEN s.forecast_method IN ('ANCHOR_2024_MARGIN_2025', 'PROXY_CATEGORIA_UF', 'LOCF_MES_ANTERIOR')
                THEN s.forecast_method
            ELSE 'SANDUICHE_MEDIA_24_25'
        END,
        usou_fallback_12m  = COALESCE(s.usou_fallback_12m, FALSE),
        calculado_em       = NOW()
    FROM precos_patch p
    WHERE s.id_sazonalidade = p.id_sazonalidade;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 1 — Patch retroativo (Jan-%): % linhas.', v_mes_atual, v_total;

    WITH meses_futuros AS (
        SELECT generate_series(v_mes_atual + 1, 12) AS mes
    ),
    produtos_historicos AS (
        SELECT DISTINCT f.id_produto, f.id_localidade
        FROM staging.fact_precos_mensais f
        WHERE f.ano IN (2024, 2025)
          AND f.preco_medio IS NOT NULL
          AND f.preco_medio > 0
    ),
    grade_futura AS (
        SELECT p.id_produto, p.id_localidade, m.mes
        FROM produtos_historicos p
        CROSS JOIN meses_futuros m
    ),
    meses_sem_real AS (
        SELECT g.*
        FROM grade_futura g
        LEFT JOIN mart.sazonalidade_produto s
            ON s.id_produto    = g.id_produto
           AND s.id_localidade = g.id_localidade
           AND s.ano           = 2026
           AND s.mes           = g.mes
           AND s.is_forecast   = FALSE
        WHERE s.id_sazonalidade IS NULL
    ),
    projecao AS (
        SELECT
            msr.id_produto,
            msr.id_localidade,
            msr.mes,
            COALESCE(
                staging.fn_preco_base_2026(msr.id_produto, msr.id_localidade),
                h.preco_medio_historico
            ) AS preco_base,
            staging.fn_fator_sazonal_mensal(
                msr.id_produto, msr.id_localidade, msr.mes::SMALLINT
            ) AS fator_sazonal,
            GREATEST(h.confianca, COALESCE(b.confianca, 0)) AS confianca,
            COALESCE(NULLIF(f.fator_kg, 0), 1) AS fator_kg
        FROM meses_sem_real msr
        JOIN staging.dim_localidade l ON l.id_localidade = msr.id_localidade
        LEFT JOIN mart.fator_kg_produto_uf f
            ON f.id_produto = msr.id_produto
           AND f.uf         = l.uf
        CROSS JOIN LATERAL staging.fn_sandwich_historical_price(
            msr.id_produto, msr.id_localidade, msr.mes::SMALLINT
        ) h
        LEFT JOIN mart.sazonalidade_baseline_24_25 b
            ON b.id_produto    = msr.id_produto
           AND b.id_localidade = msr.id_localidade
           AND b.mes           = msr.mes
        WHERE h.preco_medio_historico IS NOT NULL
          AND h.preco_medio_historico > 0
    ),
    projecao_final AS (
        SELECT
            id_produto, id_localidade, mes, preco_base, fator_sazonal, confianca, fator_kg,
            ROUND(preco_base * (1 + COALESCE(fator_sazonal, 0)) / fator_kg, 4) AS preco_atual,
            ROUND(preco_base / fator_kg, 4) AS preco_referencia
        FROM projecao
        WHERE preco_base IS NOT NULL AND preco_base > 0
    )
    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade, ano, mes,
        preco_atual, preco_referencia,
        data_referencia_atual,
        status_cor, fonte, calculado_em,
        is_forecast, baseline_confianca, forecast_method,
        usou_fallback_12m
    )
    SELECT
        pf.id_produto,
        pf.id_localidade,
        2026,
        pf.mes,
        pf.preco_atual,
        pf.preco_referencia,
        2026::TEXT || '-' || LPAD(pf.mes::TEXT, 2, '0'),
        COALESCE(
            staging.fn_status_cor_regra_25(pf.preco_atual, pf.preco_referencia),
            'AMARELO'
        ) AS status_cor,
        'BASELINE_HISTORICO',
        NOW(),
        TRUE,
        GREATEST(pf.confianca, 0),
        CASE WHEN pf.fator_sazonal IS NOT NULL
             THEN 'SANDUICHE_FATOR_SAZONAL'
             ELSE 'SANDUICHE_MEDIA_24_25' END,
        FALSE
    FROM projecao_final pf
    ON CONFLICT (id_produto, id_localidade, ano, mes)
    DO UPDATE SET
        preco_atual        = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                  THEN mart.sazonalidade_produto.preco_atual
                                  ELSE EXCLUDED.preco_atual END,
        preco_referencia   = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                  THEN mart.sazonalidade_produto.preco_referencia
                                  ELSE EXCLUDED.preco_referencia END,
        status_cor         = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                  THEN mart.sazonalidade_produto.status_cor
                                  ELSE EXCLUDED.status_cor END,
        is_forecast        = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE THEN FALSE ELSE TRUE END,
        baseline_confianca = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                  THEN mart.sazonalidade_produto.baseline_confianca
                                  ELSE EXCLUDED.baseline_confianca END,
        forecast_method    = CASE
            WHEN mart.sazonalidade_produto.is_forecast = FALSE
                THEN mart.sazonalidade_produto.forecast_method
            WHEN mart.sazonalidade_produto.forecast_method IN ('ANCHOR_2024_MARGIN_2025', 'PROXY_CATEGORIA_UF', 'LOCF_MES_ANTERIOR')
                THEN mart.sazonalidade_produto.forecast_method
            ELSE EXCLUDED.forecast_method END,
        usou_fallback_12m  = COALESCE(mart.sazonalidade_produto.usou_fallback_12m, FALSE),
        calculado_em       = NOW();

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 2 — Pre-fill futuro c/ Fator Sazonal: % linhas.', v_total;

    WITH recalc_futuro AS (
        SELECT
            s.id_sazonalidade,
            COALESCE(
                staging.fn_preco_base_2026(s.id_produto, s.id_localidade),
                s.preco_referencia
            ) AS preco_base,
            staging.fn_fator_sazonal_mensal(
                s.id_produto, s.id_localidade, s.mes::SMALLINT
            ) AS fator_sazonal,
            COALESCE(NULLIF(f.fator_kg, 0), 1) AS fator_kg
        FROM mart.sazonalidade_produto s
        JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
        LEFT JOIN mart.fator_kg_produto_uf f
            ON f.id_produto = s.id_produto
           AND f.uf         = l.uf
        WHERE s.ano = 2026
          AND s.mes BETWEEN v_mes_atual + 1 AND 12
          AND s.is_forecast = TRUE
          AND s.preco_atual IS NOT NULL
          AND s.preco_atual > 0
    ),
    recalc_final AS (
        SELECT
            r.id_sazonalidade,
            ROUND(r.preco_base * (1 + COALESCE(r.fator_sazonal, 0)) / r.fator_kg, 4) AS preco_atual,
            ROUND(r.preco_base / r.fator_kg, 4) AS preco_referencia,
            r.fator_sazonal
        FROM recalc_futuro r
        WHERE r.preco_base IS NOT NULL AND r.preco_base > 0
    )
    UPDATE mart.sazonalidade_produto s
    SET
        preco_atual        = r.preco_atual,
        preco_referencia   = r.preco_referencia,
        status_cor         = COALESCE(
            staging.fn_status_cor_regra_25(r.preco_atual, r.preco_referencia),
            'AMARELO'
        ),
        forecast_method    = CASE
            WHEN s.forecast_method IN ('ANCHOR_2024_MARGIN_2025', 'PROXY_CATEGORIA_UF', 'LOCF_MES_ANTERIOR')
                THEN s.forecast_method
            WHEN r.fator_sazonal IS NOT NULL
                THEN 'SANDUICHE_FATOR_SAZONAL'
            ELSE s.forecast_method END,
        calculado_em       = NOW()
    FROM recalc_final r
    WHERE s.id_sazonalidade = r.id_sazonalidade;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 2b — Momentum em forecasts existentes: % linhas.', v_total;

    CREATE TEMP TABLE IF NOT EXISTS tmp_orphans_proxy ON COMMIT DROP AS
    WITH orfaos AS (
        SELECT DISTINCT s.id_produto
        FROM mart.sazonalidade_produto s
        WHERE s.ano = 2026
          AND s.mes <= v_mes_atual
          AND s.is_forecast = FALSE
          AND NOT EXISTS (
              SELECT 1 FROM mart.sazonalidade_produto s2
              WHERE s2.id_produto = s.id_produto
                AND s2.ano = 2026
                AND s2.mes = v_mes_atual + 1
                AND s2.is_forecast = TRUE
                -- v7: inclui métodos v13 — produto com forecast v13 NÃO é órfão
                AND s2.forecast_method IN ('SANDUICHE_MEDIA_24_25', 'PROXY_HIERARQUICO', 'SANDUICHE_FATOR_SAZONAL', 'ANCHOR_2024_MARGIN_2025', 'PROXY_CATEGORIA_UF', 'LOCF_MES_ANTERIOR')
          )
    ),
    orfaos_com_pai AS (
        SELECT
            o.id_produto AS id_filho,
            staging.encontrar_produto_pai(o.id_produto, (v_mes_atual + 1)::SMALLINT) AS id_pai
        FROM orfaos o
    )
    SELECT * FROM orfaos_com_pai WHERE id_pai IS NOT NULL;

    GET DIAGNOSTICS v_proxy = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 3 — % produtos órfãos com pai.', v_proxy;

    IF v_proxy > 0 THEN
        WITH meses_futuros AS (
            SELECT generate_series(v_mes_atual + 1, 12) AS mes
        ),
        ratio_preco AS (
            SELECT
                o.id_filho, o.id_pai,
                sf.id_localidade, sf.mes,
                AVG(sf.preco_atual) / NULLIF(AVG(sp.preco_atual), 0) AS ratio
            FROM tmp_orphans_proxy o
            JOIN mart.sazonalidade_produto sf ON sf.id_produto = o.id_filho
                                               AND sf.ano = 2026 AND sf.is_forecast = FALSE
                                               AND sf.preco_atual IS NOT NULL AND sf.preco_atual > 0
            JOIN mart.sazonalidade_produto sp ON sp.id_produto = o.id_pai
                                               AND sp.id_localidade = sf.id_localidade
                                               AND sp.ano = 2026 AND sp.mes = sf.mes
                                               AND sp.is_forecast = FALSE
                                               AND sp.preco_atual IS NOT NULL AND sp.preco_atual > 0
            GROUP BY o.id_filho, o.id_pai, sf.id_localidade, sf.mes
        ),
        projecao_pai AS (
            SELECT
                o.id_filho, s.id_localidade, m.mes,
                s.preco_atual AS pai_preco_atual,
                s.preco_referencia AS pai_preco_referencia,
                s.status_cor AS pai_status_cor,
                s.baseline_confianca AS pai_confianca
            FROM tmp_orphans_proxy o
            JOIN mart.sazonalidade_produto s ON s.id_produto = o.id_pai
            CROSS JOIN meses_futuros m
            WHERE s.ano = 2026 AND s.mes = m.mes
              -- v7: aceita também métodos v13 como fonte do pai
              AND s.forecast_method IN ('SANDUICHE_MEDIA_24_25', 'PROXY_HIERARQUICO', 'SANDUICHE_FATOR_SAZONAL', 'ANCHOR_2024_MARGIN_2025', 'PROXY_CATEGORIA_UF', 'LOCF_MES_ANTERIOR')
        ),
        proxy_final AS (
            SELECT
                pp.id_filho, pp.id_localidade, pp.mes,
                ROUND(pp.pai_preco_atual * COALESCE(
                    (SELECT AVG(r.ratio) FROM ratio_preco r
                     WHERE r.id_filho = pp.id_filho AND r.id_localidade = pp.id_localidade), 1.0
                ), 4) AS preco_projetado,
                ROUND(pp.pai_preco_referencia * COALESCE(
                    (SELECT AVG(r.ratio) FROM ratio_preco r
                     WHERE r.id_filho = pp.id_filho AND r.id_localidade = pp.id_localidade), 1.0
                ), 4) AS preco_referencia,
                pp.pai_status_cor, pp.pai_confianca
            FROM projecao_pai pp
        )
        INSERT INTO mart.sazonalidade_produto (
            id_produto, id_localidade, ano, mes,
            preco_atual, preco_referencia,
            data_referencia_atual,
            status_cor, fonte, calculado_em,
            is_forecast, baseline_confianca, forecast_method,
            usou_fallback_12m
        )
        SELECT
            pf.id_filho, pf.id_localidade, 2026, pf.mes,
            pf.preco_projetado, pf.preco_referencia,
            2026::TEXT || '-' || LPAD(pf.mes::TEXT, 2, '0'),
            COALESCE(
                staging.fn_status_cor_regra_25(pf.preco_projetado, pf.preco_referencia),
                'AMARELO'
            ) AS status_cor,
            'BASELINE_HISTORICO',
            NOW(),
            TRUE,
            pf.pai_confianca,
            'PROXY_HIERARQUICO',
            FALSE
        FROM proxy_final pf
        WHERE pf.preco_projetado IS NOT NULL AND pf.preco_projetado > 0
        ON CONFLICT (id_produto, id_localidade, ano, mes)
        DO UPDATE SET
            preco_atual        = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                      THEN mart.sazonalidade_produto.preco_atual
                                      ELSE EXCLUDED.preco_atual END,
            preco_referencia   = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                      THEN mart.sazonalidade_produto.preco_referencia
                                      ELSE EXCLUDED.preco_referencia END,
            status_cor         = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                      THEN mart.sazonalidade_produto.status_cor
                                      ELSE EXCLUDED.status_cor END,
            is_forecast        = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE THEN FALSE ELSE TRUE END,
            baseline_confianca = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                      THEN mart.sazonalidade_produto.baseline_confianca
                                      ELSE EXCLUDED.baseline_confianca END,
            forecast_method    = CASE
                WHEN mart.sazonalidade_produto.forecast_method IN ('ANCHOR_2024_MARGIN_2025', 'PROXY_CATEGORIA_UF', 'LOCF_MES_ANTERIOR')
                    THEN mart.sazonalidade_produto.forecast_method
                ELSE 'PROXY_HIERARQUICO'
            END,
            usou_fallback_12m  = COALESCE(mart.sazonalidade_produto.usou_fallback_12m, FALSE),
            calculado_em       = NOW();

        GET DIAGNOSTICS v_total = ROW_COUNT;
        RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 3 — Proxy: % linhas.', v_total;
    ELSE
        RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 3 — Nenhum órfão com pai.';
    END IF;

    DROP TABLE IF EXISTS tmp_orphans_proxy;

    WITH proxy_flat AS (
        SELECT s.id_sazonalidade, s.id_produto AS id_filho, s.id_localidade, s.mes,
               s.preco_referencia AS filho_ref
        FROM mart.sazonalidade_produto s
        WHERE s.ano = 2026
          AND s.mes BETWEEN v_mes_atual + 1 AND 12
          AND s.is_forecast = TRUE
          AND s.forecast_method = 'PROXY_HIERARQUICO'
          AND s.preco_atual IS NOT NULL AND s.preco_atual > 0
          AND s.preco_referencia IS NOT NULL AND s.preco_referencia > 0
          AND ABS(s.preco_atual - s.preco_referencia) < 0.0001
    ),
    filhos_distintos AS (
        SELECT DISTINCT s.id_produto AS id_filho, s.mes,
               SPLIT_PART(dp.nome_produto, ' ', 1) AS palavra
        FROM mart.sazonalidade_produto s
        JOIN staging.dim_produto dp ON dp.id_produto = s.id_produto
        WHERE s.ano = 2026
          AND s.mes BETWEEN v_mes_atual + 1 AND 12
          AND s.is_forecast = TRUE
          AND s.forecast_method = 'PROXY_HIERARQUICO'
          AND s.preco_atual IS NOT NULL AND s.preco_atual > 0
          AND s.preco_referencia IS NOT NULL AND s.preco_referencia > 0
          AND ABS(s.preco_atual - s.preco_referencia) < 0.0001
    ),
    pai_candidates AS (
        SELECT fd.id_filho, fd.mes, p.id_produto AS id_pai,
               EXISTS(
                   SELECT 1 FROM mart.sazonalidade_produto sp
                   WHERE sp.id_produto = p.id_produto
                     AND sp.mes = fd.mes AND sp.ano = 2026
                     AND sp.is_forecast = TRUE
                     AND sp.forecast_method = 'SANDUICHE_FATOR_SAZONAL'
                     AND sp.preco_atual IS NOT NULL AND sp.preco_atual > 0
               ) AS tem_fator,
               LENGTH(p.nome_produto) AS len_nome
        FROM filhos_distintos fd
        JOIN staging.dim_produto p
          ON p.nome_produto ILIKE fd.palavra || '%'
         AND p.id_produto <> fd.id_filho
        WHERE EXISTS (
            SELECT 1 FROM mart.sazonalidade_produto sp
            WHERE sp.id_produto = p.id_produto
              AND sp.mes = fd.mes AND sp.ano = 2026
              AND sp.is_forecast = TRUE
              -- v7: aceita também métodos v13 como candidato a pai
              AND sp.forecast_method IN ('SANDUICHE_MEDIA_24_25', 'SANDUICHE_FATOR_SAZONAL', 'PROXY_HIERARQUICO', 'ANCHOR_2024_MARGIN_2025', 'PROXY_CATEGORIA_UF', 'LOCF_MES_ANTERIOR')
              AND sp.preco_atual IS NOT NULL AND sp.preco_atual > 0
        )
    ),
    melhor_pai AS (
        SELECT DISTINCT ON (pc.id_filho, pc.mes)
               pc.id_filho, pc.mes, pc.id_pai
        FROM pai_candidates pc
        ORDER BY pc.id_filho, pc.mes, pc.tem_fator DESC, pc.len_nome ASC
    ),
    projecao_pai AS (
        SELECT
            pf.id_sazonalidade, pf.id_filho, pf.id_localidade, pf.mes, pf.filho_ref,
            s.preco_atual AS pai_preco_atual,
            s.preco_referencia AS pai_preco_referencia
        FROM proxy_flat pf
        JOIN melhor_pai mp ON mp.id_filho = pf.id_filho AND mp.mes = pf.mes
        JOIN mart.sazonalidade_produto s
          ON s.id_produto = mp.id_pai
         AND s.id_localidade = pf.id_localidade
         AND s.ano = 2026 AND s.mes = pf.mes AND s.is_forecast = TRUE
        WHERE s.preco_atual IS NOT NULL AND s.preco_atual > 0
          AND s.preco_referencia IS NOT NULL AND s.preco_referencia > 0
    ),
    reproj AS (
        SELECT
            pp.id_sazonalidade,
            CASE
                WHEN pp.filho_ref IS NOT NULL AND pp.filho_ref > 0
                     AND pp.pai_preco_referencia IS NOT NULL
                     AND pp.pai_preco_referencia > 0
                THEN ROUND(pp.filho_ref * (pp.pai_preco_atual / pp.pai_preco_referencia), 4)
                ELSE pp.pai_preco_atual
            END AS preco_projetado,
            CASE
                WHEN pp.filho_ref IS NOT NULL AND pp.filho_ref > 0
                THEN pp.filho_ref
                ELSE pp.pai_preco_referencia
            END AS preco_referencia
        FROM projecao_pai pp
    )
    UPDATE mart.sazonalidade_produto s
    SET
        preco_atual        = r.preco_projetado,
        preco_referencia   = r.preco_referencia,
        status_cor         = COALESCE(
            staging.fn_status_cor_regra_25(r.preco_projetado, r.preco_referencia),
            'AMARELO'
        ),
        forecast_method    = CASE
            WHEN s.forecast_method IN ('ANCHOR_2024_MARGIN_2025', 'PROXY_CATEGORIA_UF', 'LOCF_MES_ANTERIOR')
                THEN s.forecast_method
            ELSE 'PROXY_HIERARQUICO'
        END,
        calculado_em       = NOW()
    FROM reproj r
    WHERE s.id_sazonalidade = r.id_sazonalidade
      AND r.preco_projetado IS NOT NULL AND r.preco_projetado > 0
      AND r.preco_referencia IS NOT NULL AND r.preco_referencia > 0
      AND ABS(r.preco_projetado - r.preco_referencia) >= 0.0001;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 3b — Proxies reprojetados (variação do pai, escala do filho): % linhas.', v_total;

    WITH recalc_forecast AS (
        SELECT
            id_sazonalidade,
            CASE
                WHEN preco_atual IS NULL OR preco_atual <= 0 THEN 'AMARELO'
                ELSE COALESCE(
                    staging.fn_status_cor_regra_25(preco_atual, preco_referencia),
                    status_cor
                )
            END AS novo_status_cor
        FROM mart.sazonalidade_produto
        WHERE ano = 2026
          AND is_forecast = TRUE
    )
    UPDATE mart.sazonalidade_produto s
    SET status_cor   = r.novo_status_cor,
        calculado_em = NOW()
    FROM recalc_forecast r
    WHERE s.id_sazonalidade = r.id_sazonalidade
      AND r.novo_status_cor IS DISTINCT FROM s.status_cor;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 4 — Recalc ±25%%: % linhas.', v_total;

    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Concluído em % seg.',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$procedure$;

-- 5.8 — view mart.vw_abastecimento_regional_completo
CREATE OR REPLACE VIEW mart.vw_abastecimento_regional_completo AS
 WITH produtos_norm AS (
         SELECT p.id_produto,
            p.nome_produto,
            staging.normalizar_nome_produto(p.nome_produto) AS nome_normalizado,
            p.categoria_b2c,
            p.status_fonte
           FROM staging.dim_produto p
        ), ultima_sazonalidade AS (
         SELECT DISTINCT ON (sp.id_produto, l_1.uf) sp.id_produto,
            l_1.uf,
            sp.status_cor,
            sp.is_forecast,
            sp.baseline_confianca,
            sp.forecast_method,
            sp.ano,
            sp.mes,
            sp.preco_atual
           FROM (mart.sazonalidade_produto sp
             JOIN staging.dim_localidade l_1 ON ((l_1.id_localidade = sp.id_localidade)))
          WHERE ((l_1.uf <> 'BR'::bpchar) AND (sp.status_cor = ANY (ARRAY['VERDE'::text, 'AMARELO'::text, 'VERMELHO'::text])))
          ORDER BY sp.id_produto, l_1.uf, sp.ano DESC, sp.mes DESC
        ), precos_por_uf AS (
         SELECT staging.normalizar_nome_produto(p.nome_produto) AS nome_norm,
            l_1.uf,
            count(*) AS qtd_registros,
            count(DISTINCT fp.fonte) AS qtd_fontes,
            bool_or((fp.fonte = 'FLUXO_PROXY'::text)) AS tem_proxy,
            bool_or((fp.fonte <> 'FLUXO_PROXY'::text)) AS tem_real,
            max(fp.preco_medio) AS preco_max,
            avg(fp.preco_medio) AS preco_medio,
            min(((fp.ano || '-'::text) || lpad((fp.mes)::text, 2, '0'::text))) AS periodo_de,
            max(((fp.ano || '-'::text) || lpad((fp.mes)::text, 2, '0'::text))) AS periodo_ate
           FROM ((staging.fact_precos_mensais fp
             JOIN staging.dim_produto p ON ((p.id_produto = fp.id_produto)))
             JOIN staging.dim_localidade l_1 ON ((l_1.id_localidade = fp.id_localidade)))
          WHERE (l_1.uf <> 'BR'::bpchar)
          GROUP BY (staging.normalizar_nome_produto(p.nome_produto)), l_1.uf
        ), regioes AS (
         SELECT r_1.id,
            r_1.nome,
            r_1.ordem
           FROM ( VALUES ('norte'::text,'Norte'::text,1), ('nordeste'::text,'Nordeste'::text,2), ('centro-oeste'::text,'Centro-Oeste'::text,3), ('sudeste'::text,'Sudeste'::text,4), ('sul'::text,'Sul'::text,5)) r_1(id, nome, ordem)
        ), fluxos_agg AS (
         SELECT f.id_produto,
            f.destino_uf,
            string_agg(DISTINCT (f.origem_uf)::text, ', '::text ORDER BY ((f.origem_uf)::text)) FILTER (WHERE (f.tipo = 'importado'::text)) AS origens_importado,
            string_agg(DISTINCT (f.origem_uf)::text, ', '::text ORDER BY ((f.origem_uf)::text)) FILTER (WHERE (f.tipo = 'exportado'::text)) AS origens_exportado,
            string_agg(DISTINCT f.origem_polo, ', '::text ORDER BY f.origem_polo) AS polos_origem,
            bool_or((f.tipo = 'autossuficiente'::text)) AS autossuficiente,
            count(*) AS qtd_fluxos
           FROM staging.dim_fluxo_abastecimento f
          GROUP BY f.id_produto, f.destino_uf
        )
 SELECT l.uf,
    l.municipio_nome AS municipio_referencia,
    pn.id_produto,
    pn.nome_produto AS produto_original,
    pn.nome_normalizado,
    pn.categoria_b2c,
    pn.status_fonte,
    COALESCE(fa.origens_importado, ''::text) AS origens_fornecedoras,
    COALESCE(fa.origens_exportado, ''::text) AS origens_compradoras,
    COALESCE(fa.polos_origem, ''::text) AS polos_origem,
    COALESCE(fa.autossuficiente, false) AS autossuficiente,
    (COALESCE(fa.qtd_fluxos, (0)::bigint))::integer AS qtd_fluxos,
        CASE
            WHEN pc.tem_real THEN 'REAL'::text
            WHEN pc.tem_proxy THEN 'PROXY'::text
            ELSE 'AUSENTE'::text
        END AS tipo_preco,
    (COALESCE(pc.qtd_registros, (0)::bigint))::integer AS qtd_registros_preco,
    (COALESCE(pc.qtd_fontes, (0)::bigint))::integer AS qtd_fontes_preco,
    pc.periodo_de,
    pc.periodo_ate,
    pc.preco_medio,
    pc.preco_max,
    sz.status_cor,
        CASE sz.status_cor
            WHEN 'VERDE'::text THEN '🟢 Safra'::text
            WHEN 'AMARELO'::text THEN '🟡 Normal'::text
            WHEN 'VERMELHO'::text THEN '🔴 Entressafra'::text
            ELSE '⚪ Indisponível'::text
        END AS status_cor_label,
    sz.is_forecast,
    sz.baseline_confianca,
    sz.forecast_method,
    sz.ano AS ultimo_ano_sazonalidade,
    sz.mes AS ultimo_mes_sazonalidade,
        CASE
            WHEN pc.tem_real THEN '🟢 Dado real'::text
            WHEN pc.tem_proxy THEN '🟡 Proxy (FLUXO_PROXY)'::text
            WHEN (fa.qtd_fluxos > 0) THEN '🔵 Tem fluxo, sem preço'::text
            ELSE '⚪ Sem dados'::text
        END AS cobertura_status,
    r.nome AS regiao_destino
   FROM (((((( SELECT DISTINCT ON (dl.uf) dl.id_localidade,
            dl.uf,
            dl.municipio_nome
           FROM staging.dim_localidade dl
          WHERE (dl.uf <> 'BR'::bpchar)
          ORDER BY dl.uf, dl.municipio_id NULLS FIRST) l
     CROSS JOIN ( SELECT DISTINCT produtos_norm.nome_normalizado,
            produtos_norm.id_produto,
            produtos_norm.nome_produto,
            produtos_norm.categoria_b2c,
            produtos_norm.status_fonte
           FROM produtos_norm) pn)
     LEFT JOIN precos_por_uf pc ON (((pc.uf = l.uf) AND (pc.nome_norm = pn.nome_normalizado))))
     LEFT JOIN ultima_sazonalidade sz ON (((sz.id_produto = pn.id_produto) AND (sz.uf = l.uf))))
     LEFT JOIN fluxos_agg fa ON (((fa.id_produto = pn.id_produto) AND (fa.destino_uf = l.uf))))
     LEFT JOIN regioes r ON ((r.id = ( SELECT f2.destino_regiao_id
           FROM staging.dim_fluxo_abastecimento f2
          WHERE ((f2.id_produto = pn.id_produto) AND (f2.destino_uf = l.uf))
         LIMIT 1))))
  WHERE (pn.nome_normalizado = ANY (ARRAY['TOMATE'::text, 'BATATA'::text, 'CEBOLA'::text, 'CENOURA'::text, 'ALFACE'::text, 'BANANA'::text, 'MELANCIA'::text, 'MANGA'::text, 'MACA'::text, 'LARANJA'::text, 'FEIJAO'::text, 'FEIJAO COMUM CORES'::text, 'FEIJAO COMUM PRETO'::text, 'FEIJAO CAUPI'::text, 'ARROZ'::text, 'MANDIOCA'::text, 'MILHO'::text, 'ALHO'::text, 'BATATA DOCE'::text, 'MORANGO'::text, 'GOIABA'::text, 'PEPINO'::text, 'REPOLHO'::text, 'BETERRABA'::text, 'VAGEM'::text, 'COUVE'::text, 'ABACATE'::text, 'ABACAXI'::text, 'BERINJELA'::text, 'CHUCHU'::text, 'INHAME'::text, 'COUVE-FLOR'::text, 'QUIABO'::text, 'TANGERINA'::text, 'MAMAO'::text, 'UVA'::text, 'CAFE'::text, 'LEITE DE VACA'::text, 'CARNE BOVINA'::text, 'CARNE CAPRINA'::text, 'CARNE DE FRANGO'::text, 'CARNE OVINA'::text, 'OVOS DE GALINHA'::text, 'OLEO DE SOJA'::text, 'ACUCAR'::text, 'PAO'::text, 'MANTEIGA'::text, 'MACARRAO'::text, 'SAL'::text, 'COCO'::text]))
  ORDER BY l.uf, pn.nome_normalizado;

-- 5.9 — view mart.vw_ancora_preco_referencia
CREATE OR REPLACE VIEW mart.vw_ancora_preco_referencia AS
 WITH "real" AS (
         SELECT sazonalidade_produto.id_sazonalidade,
            sazonalidade_produto.id_produto,
            sazonalidade_produto.id_localidade,
            sazonalidade_produto.ano,
            sazonalidade_produto.mes,
            sazonalidade_produto.data_referencia_atual,
            sazonalidade_produto.preco_atual,
            sazonalidade_produto.fonte,
            sazonalidade_produto.calculado_em
           FROM mart.sazonalidade_produto
          WHERE ((COALESCE(sazonalidade_produto.fonte, ''::text) <> 'FLUXO_PROXY'::text) AND (NOT sazonalidade_produto.is_forecast) AND (sazonalidade_produto.preco_atual IS NOT NULL) AND (sazonalidade_produto.preco_atual > (0)::numeric))
        ), tuples AS (
         SELECT DISTINCT "real".id_produto,
            "real".id_localidade,
            "real".mes
           FROM "real"
        ), anchored AS (
         SELECT t.id_produto,
            t.id_localidade,
            t.mes,
            a_1.id_sazonalidade,
            a_1.ano AS ano_referencia,
            a_1.preco_atual AS preco_exibido,
            a_1.data_referencia_atual,
            a_1.calculado_em AS data_ultima_coleta,
            a_1.fonte,
            ((EXTRACT(year FROM CURRENT_DATE))::integer - a_1.ano) AS idade_dado_anos,
                CASE
                    WHEN (a_1.ano = (EXTRACT(year FROM CURRENT_DATE))::integer) THEN 'REAL_ATUAL'::text
                    ELSE 'HISTORICO_BASE'::text
                END AS tipo_dado,
            r.preco_ref_real AS preco_referencia,
            r.n_meses AS n_meses_referencia
           FROM ((tuples t
             LEFT JOIN LATERAL ( SELECT r_1.id_sazonalidade,
                    r_1.ano,
                    r_1.preco_atual,
                    r_1.data_referencia_atual,
                    r_1.calculado_em,
                    r_1.fonte
                   FROM mart.sazonalidade_produto r_1
                  WHERE ((r_1.id_produto = t.id_produto) AND (r_1.id_localidade = t.id_localidade) AND (r_1.mes = t.mes) AND (COALESCE(r_1.fonte, ''::text) <> 'FLUXO_PROXY'::text) AND (NOT r_1.is_forecast) AND (r_1.preco_atual IS NOT NULL) AND (r_1.preco_atual > (0)::numeric) AND ((r_1.ano >= ((EXTRACT(year FROM CURRENT_DATE))::integer - 2)) AND (r_1.ano <= (EXTRACT(year FROM CURRENT_DATE))::integer)))
                  ORDER BY r_1.ano DESC, r_1.mes DESC
                 LIMIT 1) a_1 ON (true))
             LEFT JOIN LATERAL ( SELECT (avg(r2.preco_atual))::numeric(14,4) AS preco_ref_real,
                    count(*) AS n_meses
                   FROM mart.sazonalidade_produto r2
                  WHERE ((r2.id_produto = t.id_produto) AND (r2.id_localidade = t.id_localidade) AND (COALESCE(r2.fonte, ''::text) <> 'FLUXO_PROXY'::text) AND (NOT r2.is_forecast) AND (r2.preco_atual IS NOT NULL) AND (r2.preco_atual > (0)::numeric) AND ((((r2.ano * 12) + r2.mes) >= (((a_1.ano * 12) + t.mes) - 12)) AND (((r2.ano * 12) + r2.mes) <= (((a_1.ano * 12) + t.mes) - 1))))) r ON (true))
        ), volatilidade AS MATERIALIZED (
         SELECT estatisticas_volatilidade_24m.id_produto,
            estatisticas_volatilidade_24m.id_localidade,
            estatisticas_volatilidade_24m.media_historica,
            estatisticas_volatilidade_24m.desvio_padrao_historico,
            estatisticas_volatilidade_24m.n_meses,
            estatisticas_volatilidade_24m.desvio_efetivo
           FROM staging.estatisticas_volatilidade_24m() estatisticas_volatilidade_24m(id_produto, id_localidade, media_historica, desvio_padrao_historico, n_meses, desvio_efetivo)
        )
 SELECT a.id_produto,
    a.id_localidade,
    a.mes,
    a.id_sazonalidade,
    a.ano_referencia,
    a.preco_exibido,
    a.data_referencia_atual,
    a.data_ultima_coleta,
    a.fonte,
    a.idade_dado_anos,
    a.tipo_dado,
    a.preco_referencia,
    a.n_meses_referencia,
        CASE
            WHEN ((a.n_meses_referencia IS NULL) OR (a.n_meses_referencia < 6)) THEN NULL::text
            ELSE staging.calcular_semaforo_preco(a.preco_exibido, a.preco_referencia, v.desvio_efetivo)
        END AS status_cor,
    jsonb_build_object('fonte_dado', a.fonte, 'data_ultima_coleta', a.data_ultima_coleta, 'procedencia', 'coleta_real_conab', 'ano_referencia', a.ano_referencia) AS metadado_transparencia,
    v.desvio_efetivo AS desvio_padrao_historico,
    (a.preco_referencia + v.desvio_efetivo) AS limite_superior,
    (a.preco_referencia - v.desvio_efetivo) AS limite_inferior
   FROM (anchored a
     LEFT JOIN LATERAL ( SELECT st.desvio_efetivo
           FROM volatilidade st
          WHERE ((st.id_produto = a.id_produto) AND (st.id_localidade = a.id_localidade))) v ON (true))
  WHERE (a.preco_exibido IS NOT NULL);
-- ────────────────────────────────────────────────────────────
-- BLOCO 6: VIEWS DE COMPATIBILIDADE (30 dias — remover em 2026-09-30)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW staging.baseline_2025_interpolado AS SELECT * FROM staging.baseline_sazonal_interpolado;
COMMENT ON VIEW staging.baseline_2025_interpolado IS 'DEPRECATED 2026-08: use staging.baseline_sazonal_interpolado. Removida em 2026-09-30.';

CREATE OR REPLACE VIEW staging.vw_fluxos_regionais AS SELECT * FROM staging.vw_abastecimento_logistico;
COMMENT ON VIEW staging.vw_fluxos_regionais IS 'DEPRECATED 2026-08: use staging.vw_abastecimento_logistico. Removida em 2026-09-30.';

-- ────────────────────────────────────────────────────────────
-- BLOCO 7: COMMENT ON (objetos renomeados)
-- ────────────────────────────────────────────────────────────
COMMENT ON TABLE staging.baseline_sazonal_interpolado IS
    'Baseline sazonal com lacunas interpoladas (série 2024-2026).';
COMMENT ON VIEW staging.vw_abastecimento_logistico IS
    'Fluxos de abastecimento por produto: origem → destino (regiões/UF).';
COMMENT ON FUNCTION staging.normalizar_nome_produto(TEXT) IS
    'Normaliza nome de produto (caixa alta, remoção de acentos/símbolos).';
COMMENT ON FUNCTION staging.estatisticas_volatilidade_24m() IS
    'Estatísticas de volatilidade de preço por produto/localidade (janela 24m).';
COMMENT ON FUNCTION staging.calcular_semaforo_preco(NUMERIC, NUMERIC, NUMERIC) IS
    'Calcula status_cor (VERDE/AMARELO/VERMELHO) por desvio z-score do preço exibido vs referência.';
COMMENT ON FUNCTION staging.encontrar_produto_pai(INTEGER, SMALLINT) IS
    'Resolve produto pai hierárquico (proxy) para um produto filho no mês alvo.';

COMMIT;

-- ============================================================
-- Verificação pós-migração:
--   SELECT staging.fn_normalizar_nome_produto('Tomate');  -- wrapper responde
--   SELECT staging.normalizar_nome_produto('Tomate');     -- nome novo responde
--   SELECT * FROM staging.fn_estatisticas_volatilidade_24m() LIMIT 1;
--   SELECT * FROM staging.vw_fluxos_regionais LIMIT 1;    -- view de compat
--   SELECT * FROM staging.vw_abastecimento_logistico LIMIT 1;
--   SELECT * FROM mart.vw_ancora_preco_referencia LIMIT 1;    -- view reescrita
--   SELECT * FROM mart.vw_abastecimento_regional_completo LIMIT 1;
--   \df staging.*  -- conferir que nomes antigos viraram wrappers
--   2ª execução: 0 RENOMEADO (idempotência)
-- ============================================================
