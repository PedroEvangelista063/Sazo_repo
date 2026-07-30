-- ============================================================================
-- QUERO COMPRAR — Fase 41: Proxy Hierárquico — Produto Pai para Órfãos
-- PostgreSQL 16+
--
-- OBJETIVO:
--   Preencher os gaps de projeção para produtos que não têm histórico em
--   2024-2025 (Data Drift da CONAB — maior granularidade em 2026).
--   Ex: "Abacate Avocado" não tem dados em 2024-2025, mas "ABACATE" tem.
--       Usamos a sazonalidade do Produto Pai como proxy para o Produto Filho.
--
-- METÁFORA:
--   Se o Sanduíche (Fase 40) é a camada de média histórica, o Proxy
--   Hierárquico é a "herança genética": o filho herda a sazonalidade do pai,
--   mas com seu próprio nível de preço (ajustado pelo ratio real conhecido).
--
-- ARQUITETURA:
--   Step 3 adicionado ao sp_project_sandwich_prices_2026:
--   1. Identifica produtos órfãos (existem em Jan-Jul 2026 mas sem projeção Ago-Dez)
--   2. Para cada órfão, encontra o Produto Pai (primeira palavra do nome = produto existente)
--   3. Copia a sazonalidade (status_cor) + preço ajustado por ratio do Produto Pai
--   4. forecast_method = 'PROXY_HIERARQUICO' para rastreabilidade
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: DDL — Adicionar PROXY_HIERARQUICO ao CHECK constraint
-- ============================================================================

ALTER TABLE mart.sazonalidade_produto
    DROP CONSTRAINT IF EXISTS chk_forecast_method;

ALTER TABLE mart.sazonalidade_produto
    DROP CONSTRAINT IF EXISTS sazonalidade_produto_forecast_method_check;

ALTER TABLE mart.sazonalidade_produto
    ADD CONSTRAINT chk_forecast_method
    CHECK (forecast_method IS NULL
           OR forecast_method IN (
               'gamma_forecast_baseline',
               'alpha_baseline_25_26',
               'beta_media_disponivel',
               'beta_weighted_25_24',
               'SANDUICHE_MEDIA_24_25',
               'PROXY_HIERARQUICO'            -- ← NOVO: proxy por produto pai
           ));

COMMENT ON COLUMN mart.sazonalidade_produto.forecast_method IS
    'Método de geração: NULL=dado real; SANDUICHE_MEDIA_24_25=média histórica; '
    'PROXY_HIERARQUICO=herança de produto pai; demais=baselines ponderados.';

-- ============================================================================
-- SEÇÃO 2: Função Auxiliar — Encontrar Produto Pai por nome
-- ============================================================================
-- Estratégia: extrai a primeira palavra do nome do produto e busca um produto
-- em dim_produto que:
--   (a) tenha esse nome como início do nome (ILIKE 'palavra%')
--   (b) tenha projeção sanduíche para o mês alvo
--   (c) seja diferente do próprio produto (não é auto-referência)
--
-- Retorna o id_produto do pai encontrado ou NULL se não houver match.

CREATE OR REPLACE FUNCTION staging.fn_encontrar_produto_pai(
    p_id_produto_filho INTEGER,
    p_mes_alvo         SMALLINT DEFAULT 8
)
RETURNS INTEGER
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_nome_filho TEXT;
    v_primeira_palavra TEXT;
    v_id_pai INTEGER;
BEGIN
    -- Obtém o nome do produto filho
    SELECT p.nome_produto INTO v_nome_filho
    FROM staging.dim_produto p
    WHERE p.id_produto = p_id_produto_filho;

    IF v_nome_filho IS NULL THEN
        RETURN NULL;
    END IF;

    -- Extrai a primeira palavra (antes do primeiro espaço)
    v_primeira_palavra := SPLIT_PART(v_nome_filho, ' ', 1);

    IF v_primeira_palavra = '' THEN
        RETURN NULL;
    END IF;

    -- Busca um produto pai:
    -- 1. Nome começa com a primeira palavra (case insensitive)
    -- 2. Tem projeção sanduíche para o mês alvo em 2026
    -- 3. É diferente do produto filho
    -- 4. É o mais curto (genérico) entre os candidatos
    SELECT p.id_produto INTO v_id_pai
    FROM staging.dim_produto p
    WHERE p.nome_produto ILIKE v_primeira_palavra || '%'
      AND p.id_produto != p_id_produto_filho
      AND EXISTS (
          SELECT 1 FROM mart.sazonalidade_produto s
          WHERE s.id_produto = p.id_produto
            AND s.ano = 2026
            AND s.mes = p_mes_alvo
            AND s.forecast_method IN ('SANDUICHE_MEDIA_24_25')
      )
    ORDER BY LENGTH(p.nome_produto) ASC  -- o mais genérico (mais curto) primeiro
    LIMIT 1;

    RETURN v_id_pai;
END;
$$;

COMMENT ON FUNCTION staging.fn_encontrar_produto_pai IS
    'Encontra o Produto Pai (genérico) de um produto filho (variedade) '
    'pela primeira palavra do nome. Ex: "Abacate Avocado" → "ABACATE". '
    'Retorna NULL se não encontrar match com projeção sanduíche.';

-- ============================================================================
-- SEÇÃO 3: Atualizar sp_project_sandwich_prices_2026 — Adicionar Step 3
-- ============================================================================

CREATE OR REPLACE PROCEDURE staging.sp_project_sandwich_prices_2026()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio     TIMESTAMPTZ;
    v_fim        TIMESTAMPTZ;
    v_total      INTEGER;
    v_mes_atual  INTEGER;
    v_proxy      INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    v_mes_atual := EXTRACT(MONTH FROM NOW())::INTEGER;

    RAISE NOTICE '[sp_project_sandwich_prices_2026] Iniciando Sanduíche Sazonal (mês atual: %)...', v_mes_atual;

    -- ====================================================================
    -- STEP 1: PATCH RETROATIVO (Jan a mês atual)
    -- ====================================================================
    WITH precos_patch AS (
        SELECT
            s.id_sazonalidade,
            s.id_produto,
            s.id_localidade,
            s.ano,
            s.mes,
            h.preco_medio_historico,
            h.tendencia_pct,
            h.confianca
        FROM mart.sazonalidade_produto s
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
        preco_atual        = ROUND(p.preco_medio_historico * (1 + p.tendencia_pct / 100), 4),
        preco_referencia   = ROUND(p.preco_medio_historico, 4),
        baseline_confianca = GREATEST(s.baseline_confianca, p.confianca),
        forecast_method    = 'SANDUICHE_MEDIA_24_25',
        usou_fallback_12m  = COALESCE(s.usou_fallback_12m, FALSE),
        calculado_em       = NOW()
    FROM precos_patch p
    WHERE s.id_sazonalidade = p.id_sazonalidade;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 1 — Patch retroativo (Jan-%): % linhas preenchidas.', v_mes_atual, v_total;

    -- ====================================================================
    -- STEP 2: PRE-FILL FUTURO (mês atual+1 até Dezembro)
    -- ====================================================================
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
        SELECT
            p.id_produto,
            p.id_localidade,
            m.mes
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
        msr.id_produto,
        msr.id_localidade,
        2026,
        msr.mes,
        ROUND(h.preco_medio_historico * (1 + h.tendencia_pct / 100), 4),
        ROUND(h.preco_medio_historico, 4),
        2026::TEXT || '-' || LPAD(msr.mes::TEXT, 2, '0'),
        COALESCE(b.status_cor_mode, 'AMARELO'),
        'BASELINE_HISTORICO',
        NOW(),
        TRUE,
        GREATEST(h.confianca, COALESCE(b.confianca, 0)),
        'SANDUICHE_MEDIA_24_25',
        FALSE
    FROM meses_sem_real msr
    CROSS JOIN LATERAL staging.fn_sandwich_historical_price(
        msr.id_produto, msr.id_localidade, msr.mes::SMALLINT
    ) h
    LEFT JOIN mart.sazonalidade_baseline_24_25 b
        ON b.id_produto    = msr.id_produto
       AND b.id_localidade = msr.id_localidade
       AND b.mes           = msr.mes
    WHERE h.preco_medio_historico IS NOT NULL
      AND h.preco_medio_historico > 0
    ON CONFLICT (id_produto, id_localidade, ano, mes)
    DO UPDATE SET
        preco_atual        = CASE
                                WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                THEN mart.sazonalidade_produto.preco_atual
                                ELSE EXCLUDED.preco_atual
                             END,
        preco_referencia   = CASE
                                WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                THEN mart.sazonalidade_produto.preco_referencia
                                ELSE EXCLUDED.preco_referencia
                             END,
        status_cor         = CASE
                                WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                THEN mart.sazonalidade_produto.status_cor
                                ELSE EXCLUDED.status_cor
                             END,
        is_forecast        = CASE
                                WHEN mart.sazonalidade_produto.is_forecast = FALSE THEN FALSE
                                ELSE TRUE
                             END,
        baseline_confianca = CASE
                                WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                THEN mart.sazonalidade_produto.baseline_confianca
                                ELSE EXCLUDED.baseline_confianca
                             END,
        forecast_method    = CASE
                                WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                THEN mart.sazonalidade_produto.forecast_method
                                ELSE 'SANDUICHE_MEDIA_24_25'
                             END,
        usou_fallback_12m  = COALESCE(mart.sazonalidade_produto.usou_fallback_12m, FALSE),
        calculado_em       = NOW();

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 2 — Pre-fill futuro (Ago-Dez): % linhas inseridas/atualizadas.', v_total;

    -- ====================================================================
    -- STEP 3: PROXY HIERÁRQUICO — Produto Pai para Órfãos
    -- ====================================================================
    -- Para produtos que têm dados reais em 2026 (Jan-Jul) mas NÃO têm
    -- histórico 2024-2025 (nem sanduíche), busca o Produto Pai pela primeira
    -- palavra do nome e copia a sazonalidade com ajuste de preço.
    --
    -- Orphans: produtos em mart.sazonalidade_produto com is_forecast=FALSE
    --          (dado real) em Jan-Jul, mas SEM projeção em Ago-Dez.
    -- Parent:  produto genérico que TEM projeção sanduíche para Ago-Dez.
    ------------------------------------------------------------------------

    -- Tabela temporária com os produtos órfãos e seus pais encontrados
    CREATE TEMP TABLE IF NOT EXISTS tmp_orphans_proxy ON COMMIT DROP AS
    WITH orfaos AS (
        -- Produtos que existem em 2026 (Jan-mes_atual) como dado real
        SELECT DISTINCT s.id_produto
        FROM mart.sazonalidade_produto s
        WHERE s.ano = 2026
          AND s.mes <= v_mes_atual
          AND s.is_forecast = FALSE        -- tem dado real
          AND NOT EXISTS (                  -- mas não tem projeção para Ago
              SELECT 1 FROM mart.sazonalidade_produto s2
              WHERE s2.id_produto = s.id_produto
                AND s2.ano = 2026
                AND s2.mes = v_mes_atual + 1
                AND s2.is_forecast = TRUE
                AND s2.forecast_method IN ('SANDUICHE_MEDIA_24_25', 'PROXY_HIERARQUICO')
          )
    ),
    orfaos_com_pai AS (
        SELECT
            o.id_produto AS id_filho,
            staging.fn_encontrar_produto_pai(o.id_produto, (v_mes_atual + 1)::SMALLINT) AS id_pai
        FROM orfaos o
    )
    SELECT * FROM orfaos_com_pai WHERE id_pai IS NOT NULL;

    GET DIAGNOSTICS v_proxy = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 3 — % produtos órfãos com pai encontrado.', v_proxy;

    -- Para cada órfão com pai, insere projeção para Ago-Dez
    IF v_proxy > 0 THEN
        WITH meses_futuros AS (
            SELECT generate_series(v_mes_atual + 1, 12) AS mes
        ),
        -- Ratio de preço: preço médio do filho / preço médio do pai no mesmo mês real
        ratio_preco AS (
            SELECT
                o.id_filho,
                o.id_pai,
                sf.id_localidade,
                sf.mes,
                AVG(sf.preco_atual) / NULLIF(AVG(sp.preco_atual), 0) AS ratio
            FROM tmp_orphans_proxy o
            JOIN mart.sazonalidade_produto sf ON sf.id_produto = o.id_filho
                                               AND sf.ano = 2026
                                               AND sf.is_forecast = FALSE
                                               AND sf.preco_atual IS NOT NULL
                                               AND sf.preco_atual > 0
            JOIN mart.sazonalidade_produto sp ON sp.id_produto = o.id_pai
                                               AND sp.id_localidade = sf.id_localidade
                                               AND sp.ano = 2026
                                               AND sp.mes = sf.mes
                                               AND sp.is_forecast = FALSE
                                               AND sp.preco_atual IS NOT NULL
                                               AND sp.preco_atual > 0
            GROUP BY o.id_filho, o.id_pai, sf.id_localidade, sf.mes
        ),
        -- Projeções do pai para cada mês futuro
        projecao_pai AS (
            SELECT
                o.id_filho,
                s.id_localidade,
                m.mes,
                s.preco_atual AS pai_preco_atual,
                s.preco_referencia AS pai_preco_referencia,
                s.status_cor AS pai_status_cor,
                s.baseline_confianca AS pai_confianca
            FROM tmp_orphans_proxy o
            JOIN mart.sazonalidade_produto s ON s.id_produto = o.id_pai
            CROSS JOIN meses_futuros m
            WHERE s.ano = 2026
              AND s.mes = m.mes
              AND s.forecast_method IN ('SANDUICHE_MEDIA_24_25', 'PROXY_HIERARQUICO')
        ),
        -- Preço ajustado do filho = preço do pai * ratio médio do (filho, localidade)
        proxy_final AS (
            SELECT
                pp.id_filho,
                pp.id_localidade,
                pp.mes,
                -- Preço do filho = preço do pai * ratio (ou 1.0 se não houver ratio)
                ROUND(pp.pai_preco_atual * COALESCE(
                    (SELECT AVG(r.ratio) FROM ratio_preco r
                     WHERE r.id_filho = pp.id_filho
                       AND r.id_localidade = pp.id_localidade),
                    1.0
                ), 4) AS preco_projetado,
                ROUND(pp.pai_preco_referencia * COALESCE(
                    (SELECT AVG(r.ratio) FROM ratio_preco r
                     WHERE r.id_filho = pp.id_filho
                       AND r.id_localidade = pp.id_localidade),
                    1.0
                ), 4) AS preco_referencia,
                pp.pai_status_cor,
                pp.pai_confianca
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
            pf.id_filho,
            pf.id_localidade,
            2026,
            pf.mes,
            pf.preco_projetado,
            pf.preco_referencia,
            2026::TEXT || '-' || LPAD(pf.mes::TEXT, 2, '0'),
            pf.pai_status_cor,
            'BASELINE_HISTORICO',
            NOW(),
            TRUE,
            pf.pai_confianca,
            'PROXY_HIERARQUICO',
            FALSE
        FROM proxy_final pf
        WHERE pf.preco_projetado IS NOT NULL
          AND pf.preco_projetado > 0
        ON CONFLICT (id_produto, id_localidade, ano, mes)
        DO UPDATE SET
            preco_atual        = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.preco_atual
                                    ELSE EXCLUDED.preco_atual
                                 END,
            preco_referencia   = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.preco_referencia
                                    ELSE EXCLUDED.preco_referencia
                                 END,
            status_cor         = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.status_cor
                                    ELSE EXCLUDED.status_cor
                                 END,
            is_forecast        = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE THEN FALSE
                                    ELSE TRUE
                                 END,
            baseline_confianca = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.baseline_confianca
                                    ELSE EXCLUDED.baseline_confianca
                                 END,
            forecast_method    = 'PROXY_HIERARQUICO',
            usou_fallback_12m  = COALESCE(mart.sazonalidade_produto.usou_fallback_12m, FALSE),
            calculado_em       = NOW();

        GET DIAGNOSTICS v_total = ROW_COUNT;
        RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 3 — Proxy Hierárquico: % linhas inseridas/atualizadas.', v_total;
    ELSE
        RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 3 — Nenhum órfão com pai — skip.';
    END IF;

    -- Limpa tabela temporária
    DROP TABLE IF EXISTS tmp_orphans_proxy;

    -- ====================================================================
    -- Refresh da MV
    -- ====================================================================
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Concluído em % seg.',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

COMMENT ON PROCEDURE staging.sp_project_sandwich_prices_2026 IS
    'Sanduíche Sazonal V2 — Projeta preços numéricos para 2026. '
    'Step 1: Patch retroativo (Jan-mês atual) — preenche preco_atual NULL. '
    'Step 2: Pre-fill futuro (mês atual+1 até Dez) — média histórica 24-25. '
    'Step 3: Proxy Hierárquico — para produtos sem histórico 24-25, usa o '
    'Produto Pai (primeira palavra do nome) como proxy de sazonalidade. '
    'forecast_method = PROXY_HIERARQUICO para rastreabilidade.';

-- ============================================================================
-- SEÇÃO 4: Permissões
-- ============================================================================

GRANT EXECUTE ON FUNCTION staging.fn_encontrar_produto_pai TO role_etl_writer;
GRANT ALL ON PROCEDURE staging.sp_project_sandwich_prices_2026 TO role_etl_writer;

-- ============================================================================
-- SEÇÃO 5: Relatório de diagnóstico (executar após CALL para auditoria)
-- ============================================================================
-- Para verificar quantos orphans foram preenchidos:
--
-- SELECT COUNT(*) AS total_proxy
-- FROM mart.sazonalidade_produto
-- WHERE ano = 2026 AND forecast_method = 'PROXY_HIERARQUICO';

COMMIT;
