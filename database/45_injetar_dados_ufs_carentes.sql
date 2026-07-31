-- ============================================================================
-- QUERO COMPRAR — Fase 45: Injeção de Dados nas UFs Carentes
-- PostgreSQL 16+
--
-- OBJETIVO:
--   7 UFs (AC, AM, AP, PI, RO, RR, SE) têm cobertura muito baixa de
--   hortifrútis básicos — apenas produtos de cesta básica (arroz, feijão,
--   carne, leite, etc.). Faltam itens como ALFACE, CENOURA, CEBOLA, ABACATE,
--   etc. que existem em 20 outras UFs.
--
--   Esta função injeta dados de preço sintéticos (proxy) para esses itens
--   faltantes, usando os fluxos de abastecimento (dim_fluxo_abastecimento)
--   como referência: se o fluxo diz que GO fornece Tomate para AC, usa-se
--   o preço médio de GO como proxy para AC.
--
-- FLUXO:
--   1. Identifica produtos da lista básica ausentes em cada UF carente
--   2. Busca no dim_fluxo_abastecimento qual UF fornece aquele produto
--   3. Se o fornecedor tem preço, usa a média (proxy)
--   4. Se nenhum fornecedor tem, usa a média nacional (BR)
--   5. Insere em fact_precos_mensais com fonte='FLUXO_PROXY'
--   6. Dica: para propagar à API, executar ciclo medalhão depois
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: Constantes da lista de produtos básicos
-- ============================================================================

-- Array com os 44 hortifrútis/produtos básicos que toda UF deveria ter
-- (usado tanto no dry-run quanto na execução)

-- ============================================================================
-- SEÇÃO 2: Função de injeção
-- ============================================================================

CREATE OR REPLACE FUNCTION staging.fn_injetar_dados_ufs_carentes(
    p_dry_run BOOLEAN DEFAULT TRUE
)
RETURNS TABLE(
    acao        TEXT,
    uf_destino  TEXT,
    produto     TEXT,
    fornecedor  TEXT,
    qtd_meses   INTEGER,
    detalhe     TEXT
)
LANGUAGE plpgsql
AS $$
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
                       staging.fn_normalizar_nome_produto(p.nome_produto) AS nome_produto_norm
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
                   AND staging.fn_normalizar_nome_produto(p.nome_produto) = h.base_nome),
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
              AND staging.fn_normalizar_nome_produto(p.nome_produto) = v_produto_norm
            LIMIT 1;

            IF FOUND THEN
                CONTINUE;  -- Já existe, pula
            END IF;

            -- Busca o id_produto canônico (o com mais dados)
            SELECT dp.id_produto, dp.nome_produto INTO v_id_produto, v_produto_nome
            FROM staging.dim_produto dp
            WHERE staging.fn_normalizar_nome_produto(dp.nome_produto) = v_produto_norm
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
$$;

COMMENT ON FUNCTION staging.fn_injetar_dados_ufs_carentes IS
    'Injeta dados de preço sintéticos (FLUXO_PROXY) para hortifrútis básicos '
    'ausentes nas 7 UFs carentes (AC, AM, AP, PI, RO, RR, SE). '
    'Usa dim_fluxo_abastecimento para encontrar fornecedores. '
    'p_dry_run=TRUE (padrão): apenas relatório. '
    'p_dry_run=FALSE: executa a injeção com variação aleatória de ±10%. '
    'Após injeção, executar ciclo medalhão: CALL staging.sp_executar_carga_completa()';


-- ============================================================================
-- SEÇÃO 3: Permissões
-- ============================================================================

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_etl_writer') THEN
        GRANT EXECUTE ON FUNCTION staging.fn_injetar_dados_ufs_carentes(BOOLEAN) TO role_etl_writer;
    END IF;

    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_api_reader') THEN
        GRANT EXECUTE ON FUNCTION staging.fn_injetar_dados_ufs_carentes(BOOLEAN) TO role_api_reader;
    END IF;
END
$$;

COMMIT;
