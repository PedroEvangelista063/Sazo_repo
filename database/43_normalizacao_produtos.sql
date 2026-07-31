-- ============================================================================
-- QUERO COMPRAR — Fase 43: Normalização de Produtos (Dedup + Limpeza)
-- PostgreSQL 16+
--
-- OBJETIVO:
--   Produtos com nomes duplicados, com 'NÃO INFORMADO', caracteres especiais
--   ou sufixos de variedade impedem a ligação correta com o mapa regional
--   de fluxos de abastecimento (flows.json).
--
--   Exemplos de problemas encontrados:
--     - 'BANANA', 'Banana Nanica', 'BANANA - NANICA', 'BANANA - PRATA',
--       'banana nanica', 'Banana Prata MG' → mesmo produto base 'BANANA'
--     - 'TOMATE' e 'TOMATE - NÃO INFORMADO' → mesmo produto
--     - 'BATATA', 'batata', 'BATATA - INGLESA', 'BATATA - NÃO INFORMADO'
--     - 'BATATA DOCE' e 'BATATA-DOCE - NÃO INFORMADO' → (hífen + NÃO INFORMADO)
--
-- SOLUÇÃO:
--   1. Função fn_normalizar_nome_produto() — limpa nome: UPPER, remove
--      'NÃO INFORMADO', normaliza hífens, colapsa espaços, remove
--      sufixos de variedade para produtos base conhecidos.
--   2. Função fn_relatorio_normalizacao() — DRY-RUN: relatório de grupos
--      de produtos que seriam consolidados, sem modificar dados.
--   3. Função fn_consolidar_produtos_duplicados() — identifica grupos,
--      elege o canônico (o com mais dados), atualiza FKs em
--      fact_precos_mensais E status_fonte_produto, remove duplicatas.
--      p_dry_run=TRUE (padrão) para segurança.
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: Função de normalização de nome
-- ============================================================================
-- Regras:
--   1. UPPER() + TRIM()
--   2. Remove ' - NÃO INFORMADO' do final
--   3. Remove ' NÃO INFORMADO' do final (variação sem hífen)
--   4. Substitui hífens simples entre palavras por espaço
--      (ex: BATATA-DOCE → BATATA DOCE)
--   5. Colapsa múltiplos espaços em um
--   6. Remove sufixos de variedade para produtos base conhecidos.
--      ⚠️ Ordem importa: subprodutos (BATATA DOCE) ANTES do pai (BATATA).
--      A condição SEM `AND v_nome != '...'` garante que o nome exato
--      do subproduto seja preservado (ex: BATATA DOCE não vira BATATA).
--
--    Lista de bases (expansível):
--      BANANA, TOMATE, BATATA DOCE, BATATA, MILHO, MACA, MAMAO, LARANJA,
--      FEIJAO (...), CEBOLA, ALHO, CAFE, ARROZ, MANDIOCA,
--      FARINHA DE (...), CARNE (...), LEITE DE VACA, OVOS DE GALINHA,
--      OLEO DE SOJA, ACUCAR, PAO, MANTEIGA, MACARRAO, SAL
-- ============================================================================

CREATE OR REPLACE FUNCTION staging.fn_normalizar_nome_produto(
    p_nome TEXT
)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE STRICT
AS $$
DECLARE
    v_nome TEXT;
BEGIN
    -- 1. UPPER + TRIM
    v_nome := UPPER(TRIM(p_nome));

    -- 2. Remove ' - NÃO INFORMADO'
    v_nome := REGEXP_REPLACE(v_nome, ' - NÃO INFORMADO$', '');

    -- 3. Remove 'NÃO INFORMADO' solto no final
    v_nome := REGEXP_REPLACE(v_nome, '\s+NÃO INFORMADO$', '');

    -- 4. Hífen entre palavras → espaço (ex: BATATA-DOCE → BATATA DOCE)
    v_nome := REPLACE(v_nome, '-', ' ');

    -- 5. Colapsa espaços múltiplos
    v_nome := REGEXP_REPLACE(v_nome, '\s+', ' ', 'g');
    v_nome := TRIM(v_nome);

    -- 6. Remove sufixos de variedade para produtos base
    --    ⚠️ Ordem CRÍTICA: subprodutos (BATATA DOCE) ANTES do pai (BATATA)
    --    A condição SEM `AND v_nome != '...'` garante que o nome exato
    --    do subproduto seja preservado (ex: BATATA DOCE não vira BATATA).
    v_nome := CASE
        -- Subprodutos (devem vir ANTES do pai genérico)
        WHEN v_nome ~ '^BATATA DOCE'             THEN 'BATATA DOCE'
        WHEN v_nome ~ '^FEIJAO COMUM PRETO'      THEN 'FEIJAO COMUM PRETO'
        WHEN v_nome ~ '^FEIJAO COMUM CORES'      THEN 'FEIJAO COMUM CORES'
        WHEN v_nome ~ '^FEIJAO CAUPI'            THEN 'FEIJAO CAUPI'
        WHEN v_nome ~ '^FARINHA DE MANDIOCA'     THEN 'FARINHA DE MANDIOCA'
        WHEN v_nome ~ '^FARINHA DE TRIGO'        THEN 'FARINHA DE TRIGO'
        WHEN v_nome ~ '^CARNE CAPRINA'           THEN 'CARNE CAPRINA'
        WHEN v_nome ~ '^CARNE BOVINA'            THEN 'CARNE BOVINA'
        WHEN v_nome ~ '^CARNE DE FRANGO'         THEN 'CARNE DE FRANGO'
        WHEN v_nome ~ '^CARNE OVINA'             THEN 'CARNE OVINA'
        WHEN v_nome ~ '^LEITE DE VACA'           THEN 'LEITE DE VACA'
        WHEN v_nome ~ '^OVOS DE GALINHA'         THEN 'OVOS DE GALINHA'
        WHEN v_nome ~ '^OLEO DE SOJA'            THEN 'OLEO DE SOJA'
        WHEN v_nome ~ '^FLOCOS DE MILHO'         THEN 'FLOCOS DE MILHO'
        WHEN v_nome ~ '^MACARRAO'                THEN 'MACARRAO'  -- boundary: MACARRAO NÃO vira MACA
        WHEN v_nome ~ '^ARROZ'                   THEN 'ARROZ'
        WHEN v_nome ~ '^FEIJAO'                  THEN 'FEIJAO'
        -- Produtos pai (genéricos) — boundary ( |$) evita colapsar MACARRAO em MACA, SALMÃO em SAL, etc.
        WHEN v_nome ~ '^BANANA'                  THEN 'BANANA'
        WHEN v_nome ~ '^TOMATE'                  THEN 'TOMATE'
        WHEN v_nome ~ '^BATATA'                  THEN 'BATATA'
        WHEN v_nome ~ '^MILHO'                   THEN 'MILHO'
        WHEN v_nome ~ '^MACA( |$)'               THEN 'MACA'
        WHEN v_nome ~ '^MAMAO'                   THEN 'MAMAO'
        WHEN v_nome ~ '^LARANJA'                 THEN 'LARANJA'
        WHEN v_nome ~ '^CEBOLA'                  THEN 'CEBOLA'
        WHEN v_nome ~ '^ALHO'                    THEN 'ALHO'
        WHEN v_nome ~ '^CAFE'                    THEN 'CAFE'
        WHEN v_nome ~ '^MANDIOCA'                THEN 'MANDIOCA'
        WHEN v_nome ~ '^ACUCAR'                  THEN 'ACUCAR'
        WHEN v_nome ~ '^PAO'                     THEN 'PAO'
        WHEN v_nome ~ '^MANTEIGA'                THEN 'MANTEIGA'
        WHEN v_nome ~ '^SAL( |$)'                THEN 'SAL'  -- boundary: SALMÃO, SALSÃO, SALSA NÃO viram SAL
        ELSE v_nome
    END;

    -- 7. Colapsa espaços novamente (pode ter sobrado do CASE)
    v_nome := REGEXP_REPLACE(v_nome, '\s+', ' ', 'g');
    v_nome := TRIM(v_nome);

    RETURN v_nome;
END;
$$;

COMMENT ON FUNCTION staging.fn_normalizar_nome_produto IS
    'Normaliza nome de produto: UPPER, remove NÃO INFORMADO, normaliza hífens, '
    'remove sufixos de variedade para bases conhecidas. IMMUTABLE para uso em índices.';


-- ============================================================================
-- SEÇÃO 2: Função de DRY-RUN — relatório de duplicatas
-- ============================================================================
-- Uso: SELECT * FROM staging.fn_relatorio_normalizacao();
-- Retorna tabela com: grupo (nome normalizado), produtos originais,
-- id canônico proposto, quantidade de registros afetados.

CREATE OR REPLACE FUNCTION staging.fn_relatorio_normalizacao()
RETURNS TABLE(
    grupo_normalizado   TEXT,
    produtos_originais  TEXT,
    id_canonico         INTEGER,
    nome_canonico       TEXT,
    total_duplicatas    BIGINT,
    qtd_precos_afetados BIGINT
)
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    RETURN QUERY
    WITH normalizados AS (
        SELECT
            p.id_produto,
            p.nome_produto,
            staging.fn_normalizar_nome_produto(p.nome_produto) AS nome_normalizado
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
            staging.fn_normalizar_nome_produto(p.nome_produto) AS nome_normalizado,
            COUNT(fp.*) AS total_precos
        FROM staging.dim_produto p
        LEFT JOIN staging.fact_precos_mensais fp ON fp.id_produto = p.id_produto
        GROUP BY staging.fn_normalizar_nome_produto(p.nome_produto)
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
$$;

COMMENT ON FUNCTION staging.fn_relatorio_normalizacao IS
    'DRY-RUN: relatório de grupos de produtos duplicados que seriam consolidados. '
    'Retorna nome normalizado, lista de produtos, id canônico proposto e total de registros afetados.';


-- ============================================================================
-- SEÇÃO 3: Função de consolidação (destrutiva — usar com cuidado!)
-- ============================================================================
-- Fluxo:
--   1. Identifica grupos com mesmo nome_normalizado
--   2. Para cada grupo, elege o canônico (o com mais dados em fact_precos_mensais)
--   3. Atualiza FKs em fact_precos_mensais para o canônico
--   4. Atualiza FKs em status_fonte_produto para o canônico
--   5. Remove os produtos duplicados
--   6. Atualiza o nome do canônico para o nome normalizado
--
-- Segurança:
--   - p_dry_run=TRUE (padrão) → apenas relatório, sem modificar dados
--   - p_dry_run=FALSE → executa a consolidação (irreversível!)
--   - Todas as FKs (fact_precos_mensais + status_fonte_produto) são
--     redirecionadas antes do DELETE

CREATE OR REPLACE FUNCTION staging.fn_consolidar_produtos_duplicados(
    p_dry_run BOOLEAN DEFAULT TRUE
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
        FROM staging.fn_relatorio_normalizacao() r
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
            staging.fn_normalizar_nome_produto(p.nome_produto) AS nome_normalizado,
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
$$;

COMMENT ON FUNCTION staging.fn_consolidar_produtos_duplicados IS
    'Consolida produtos duplicados no dim_produto. '
    'p_dry_run=TRUE (padrão): apenas relatório. '
    'p_dry_run=FALSE: executa a consolidação (irreversível!). '
    'Redireciona FKs em fact_precos_mensais E status_fonte_produto.';


-- ============================================================================
-- SEÇÃO 4: Permissões (protegidas contra roles faltantes)
-- ============================================================================

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_etl_writer') THEN
        GRANT EXECUTE ON FUNCTION staging.fn_normalizar_nome_produto(TEXT) TO role_etl_writer;
        GRANT EXECUTE ON FUNCTION staging.fn_relatorio_normalizacao() TO role_etl_writer;
        GRANT EXECUTE ON FUNCTION staging.fn_consolidar_produtos_duplicados(BOOLEAN) TO role_etl_writer;
    END IF;

    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_api_reader') THEN
        GRANT EXECUTE ON FUNCTION staging.fn_normalizar_nome_produto(TEXT) TO role_api_reader;
    END IF;
END
$$;

COMMIT;
