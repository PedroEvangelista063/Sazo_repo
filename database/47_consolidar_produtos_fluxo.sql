-- ============================================================================
-- QUERO COMPRAR — Fase 47: Consolidação Seletiva de Produtos dos Fluxos
-- PostgreSQL 16+
--
-- OBJETIVO:
--   Consolidar apenas os produtos que estão nos fluxos de abastecimento
--   (dim_fluxo_abastecimento), deixando o restante intacto.
--
--   Produtos-alvo (11 com duplicatas):
--     TOMATE (24), BANANA (17), MANGA (15), BATATA (11), ARROZ (8),
--     CARNE BOVINA (7), MACA (4), CEBOLA (2), FEIJAO COMUM CORES (2),
--     MELANCIA (2), OVOS DE GALINHA (2)
--     + TAMBAQUI, CAFE, LARANJA, COCO (1 cada, sem duplicatas)
--
-- FUNCAO:
--   staging.fn_consolidar_produtos_por_lista(TEXT[], BOOLEAN)
--     p_produtos: array de nomes normalizados para consolidar
--     p_dry_run: TRUE (padrao) = relatorio; FALSE = executa
-- ============================================================================

BEGIN;

-- ============================================================================
-- Funcao: fn_consolidar_produtos_por_lista
-- ============================================================================
-- Consolida apenas produtos especificos, identificados pelo nome normalizado.
-- Parametros:
--   p_produtos TEXT[]   - Array de nomes normalizados (ex: ARRAY['TOMATE','BANANA'])
--   p_dry_run BOOLEAN   - TRUE (padrao): relatorio; FALSE: executa
-- ============================================================================

CREATE OR REPLACE FUNCTION staging.fn_consolidar_produtos_por_lista(
    p_produtos  TEXT[],
    p_dry_run   BOOLEAN DEFAULT TRUE
)
RETURNS TABLE(
    acao            TEXT,
    nome_grupo      TEXT,
    id_afetado      INTEGER,
    nome_afetado    TEXT,
    detalhe         TEXT
)
LANGUAGE plpgsql
AS $$
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
                staging.fn_normalizar_nome_produto(p.nome_produto) AS nome_normalizado,
                (SELECT COUNT(*) FROM staging.fact_precos_mensais fp WHERE fp.id_produto = p.id_produto) AS qtd_precos
            FROM staging.dim_produto p
            WHERE staging.fn_normalizar_nome_produto(p.nome_produto) = ANY(p_produtos)
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
                staging.fn_normalizar_nome_produto(p.nome_produto) AS nome_normalizado,
                (SELECT COUNT(*) FROM staging.fact_precos_mensais fp WHERE fp.id_produto = p.id_produto) AS qtd_precos
            FROM staging.dim_produto p
            WHERE staging.fn_normalizar_nome_produto(p.nome_produto) = ANY(p_produtos)
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
            staging.fn_normalizar_nome_produto(p.nome_produto) AS nome_normalizado,
            (SELECT COUNT(*) FROM staging.fact_precos_mensais fp WHERE fp.id_produto = p.id_produto) AS qtd_precos
        FROM staging.dim_produto p
        WHERE staging.fn_normalizar_nome_produto(p.nome_produto) = ANY(p_produtos)
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
$$;

COMMENT ON FUNCTION staging.fn_consolidar_produtos_por_lista IS
    'Consolida apenas produtos especificos dos fluxos de abastecimento. '
    'p_produtos: array de nomes normalizados (ex: ARRAY[''TOMATE'',''BANANA'']). '
    'p_dry_run=TRUE (padrao): relatorio. p_dry_run=FALSE: executa.';

-- ============================================================================
-- Permissoes
-- ============================================================================

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_etl_writer') THEN
        GRANT EXECUTE ON FUNCTION staging.fn_consolidar_produtos_por_lista(TEXT[], BOOLEAN) TO role_etl_writer;
    END IF;
END
$$;

COMMIT;
