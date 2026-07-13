-- ============================================================================
-- QUERO COMPRAR — Fase 29: Foco 2025-2026 + Mapping Variedades CONAB
-- PostgreSQL 16+
--
-- MUDANCAS:
--   1. sp_calcular_sazonalidade_v11() → baseline 2025-2026, apenas >=2025
--   2. vw_api_produtos_sazonalidade → filtro ano >= 2025
--   3. dim_conab_produto_mapping → tabela de mapping CONAB → variedades locais
--   4. sp_sincronizar_variedades_conab() → distribui precos CONAB para variedades
-- ============================================================================

BEGIN;

-- ============================================================================
-- SECAO 1: Delete stale sazonalidade rows for hidden years
-- ============================================================================

DELETE FROM mart.sazonalidade_produto
WHERE split_part(data_referencia_atual::text, '-', 1)::integer < 2025;

-- ============================================================================
-- SECAO 2: Nova Procedure V12 — Baseline 2025-2026
-- ============================================================================

CREATE OR REPLACE PROCEDURE staging.sp_calcular_sazonalidade_v11()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio  TIMESTAMPTZ;
    v_fim     TIMESTAMPTZ;
    v_total   INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_calcular_sazonalidade_v11] V12 (Baseline 25-26)...';

    WITH baseline_25_26 AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            AVG(COALESCE(f.preco_curado, f.preco_medio)) AS media_baseline,
            COUNT(*) AS qtd_meses
        FROM staging.fact_precos_mensais f
        WHERE f.ano IN (2025, 2026)
          AND f.is_interpolado = FALSE
          AND COALESCE(f.preco_curado, f.preco_medio) > 0
        GROUP BY f.id_produto, f.id_localidade
        HAVING COUNT(*) >= 1
    ),
    base_referencia AS (
        SELECT
            b.id_produto,
            b.id_localidade,
            b.media_baseline AS preco_referencia_calc,
            'alpha_baseline_25_26' AS metodo_calculo,
            FALSE AS usou_fallback_12m
        FROM baseline_25_26 b
    ),
    todos_meses AS (
        SELECT DISTINCT
            f.id_produto,
            f.id_localidade,
            COALESCE(f.preco_curado, f.preco_medio) AS preco_atual,
            f.is_interpolado AS preco_estimado,
            f.ano,
            f.mes,
            f.ano::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0') AS data_referencia_atual
        FROM staging.fact_precos_mensais f
        WHERE f.ano >= 2025
          AND COALESCE(f.preco_curado, f.preco_medio) > 0
    ),
    serie_temporal AS (
        SELECT
            m.*,
            LAG(m.preco_atual) OVER (
                PARTITION BY m.id_produto, m.id_localidade
                ORDER BY m.ano, m.mes
            ) AS preco_mes_anterior
        FROM todos_meses m
    ),
    motor_classificacao AS (
        SELECT
            s.id_produto,
            s.id_localidade,
            s.preco_atual,
            s.data_referencia_atual,
            s.preco_estimado,
            COALESCE(r.preco_referencia_calc, s.preco_atual) AS preco_referencia_calc,
            COALESCE(r.metodo_calculo, 'gamma_cold_start') AS metodo_calculo,
            COALESCE(r.usou_fallback_12m, FALSE) AS usou_fallback_12m,
            CASE
                WHEN s.preco_atual < (COALESCE(r.preco_referencia_calc, s.preco_atual) * 0.85)
                    THEN 'VERDE'
                WHEN s.preco_atual > (COALESCE(r.preco_referencia_calc, s.preco_atual) * 1.15)
                    THEN 'VERMELHO'
                ELSE 'AMARELO'
            END AS status_cor,
            CASE
                WHEN s.preco_atual IS NOT NULL
                 AND COALESCE(r.preco_referencia_calc, s.preco_atual) > 0
                    THEN ROUND(
                        ((s.preco_atual / COALESCE(r.preco_referencia_calc, s.preco_atual)) - 1) * 100,
                        2
                    )
                ELSE 0
            END AS variacao_pct,
            s.preco_mes_anterior,
            CASE
                WHEN s.preco_mes_anterior IS NOT NULL
                 AND s.preco_mes_anterior > 0
                    THEN ROUND(
                        ((s.preco_atual / s.preco_mes_anterior) - 1) * 100,
                        2
                    )
                ELSE NULL
            END AS variacao_mom_pct
        FROM serie_temporal s
        LEFT JOIN base_referencia r
            ON r.id_produto = s.id_produto
           AND r.id_localidade = s.id_localidade
    )
    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade,
        preco_referencia, preco_atual,
        data_referencia_atual, usou_fallback_12m,
        status_cor, fonte, calculado_em,
        metodo_calculo, variacao_mom_pct, preco_mes_anterior,
        preco_estimado
    )
    SELECT
        m.id_produto,
        m.id_localidade,
        ROUND(m.preco_referencia_calc, 4) AS preco_referencia,
        m.preco_atual,
        m.data_referencia_atual,
        m.usou_fallback_12m,
        m.status_cor,
        'municipio'::TEXT AS fonte,
        NOW() AS calculado_em,
        m.metodo_calculo,
        m.variacao_mom_pct,
        m.preco_mes_anterior,
        m.preco_estimado
    FROM motor_classificacao m
    ON CONFLICT (id_produto, id_localidade, data_referencia_atual)
    DO UPDATE SET
        preco_referencia   = EXCLUDED.preco_referencia,
        preco_atual        = EXCLUDED.preco_atual,
        usou_fallback_12m  = EXCLUDED.usou_fallback_12m,
        status_cor         = EXCLUDED.status_cor,
        fonte              = EXCLUDED.fonte,
        calculado_em       = NOW(),
        metodo_calculo     = EXCLUDED.metodo_calculo,
        variacao_mom_pct   = EXCLUDED.variacao_mom_pct,
        preco_mes_anterior = EXCLUDED.preco_mes_anterior,
        preco_estimado     = EXCLUDED.preco_estimado,
        is_forecast        = false;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade_v11] Concluido: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);

    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
    RAISE NOTICE '[sp_calcular_sazonalidade_v11] MV atualizada.';
END;
$$;

-- ============================================================================
-- SECAO 3: Recreate MV with ano >= 2025 filter
-- ============================================================================

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade;

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
SELECT
    s.id_sazonalidade,
    s.id_localidade,
    p.id_produto,
    p.nome_produto AS produto,
    p.classificao_produto,
    p.conab_id_produto,
    p.status_fonte,
    COALESCE(c.nome_categoria, 'ALIMENTO_VAREJO'::text) AS categoria,
    l.uf,
    l.municipio_nome AS municipio,
    l.municipio_id,
    split_part(s.data_referencia_atual::text, '-'::text, 1)::integer AS ano,
    split_part(s.data_referencia_atual::text, '-'::text, 2)::integer AS mes,
    s.preco_referencia,
    s.preco_atual,
    s.data_referencia_atual,
    s.usou_fallback_12m,
    s.preco_estimado,
    s.status_cor,
    s.fonte,
    s.calculado_em,
    s.metodo_calculo,
    s.variacao_mom_pct AS variacao_pct,
    s.tendencia_futura,
    s.is_forecast
FROM mart.sazonalidade_produto s
JOIN staging.dim_produto p ON p.id_produto = s.id_produto
JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
LEFT JOIN staging.dim_categoria c ON c.id_categoria = p.id_categoria
WHERE s.status_cor IN ('VERDE', 'AMARELO', 'VERMELHO')
  AND p.categoria_b2c = 'ALIMENTO_VAREJO'
  AND (p.classificao_produto IS NULL
       OR p.classificao_produto NOT IN ('INSUMO_AGRICOLA', 'MAQUINARIO_FERRAMENTA', 'SERVICO_LOGISTICA'))
  AND (c.nome_categoria IS NULL
       OR c.nome_categoria NOT IN ('FLORES', 'OUTROS'))
  AND split_part(s.data_referencia_atual::text, '-'::text, 1)::integer >= 2025
ORDER BY s.is_forecast, s.status_cor, p.nome_produto;

CREATE UNIQUE INDEX ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;

-- ============================================================================
-- SECAO 4: Mapping Table CONAB → Variedades Locais
-- ============================================================================

CREATE TABLE IF NOT EXISTS staging.dim_conab_produto_mapping (
    id_mapping       SERIAL      PRIMARY KEY,
    conab_nome       TEXT        NOT NULL,
    id_produto_local INTEGER     NOT NULL REFERENCES staging.dim_produto(id_produto) ON DELETE CASCADE,
    fator_proporcao  NUMERIC(5,2) NOT NULL DEFAULT 1.0,
    criado_em        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (conab_nome, id_produto_local)
);

COMMENT ON TABLE staging.dim_conab_produto_mapping IS
    'Mapeia produtos CONAB (genéricos) para variedades locais. '
    'Usado por sp_sincronizar_variedades_conab() para distribuir preços CONAB '
    'a todos os produtos locais da mesma variedade.';

-- ============================================================================
-- SECAO 5: Procedure — Distribui preços CONAB para variedades locais mapeadas
-- ============================================================================

CREATE OR REPLACE PROCEDURE staging.sp_sincronizar_variedades_conab()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
    v_total  INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_sincronizar_variedades_conab] Iniciando...';

    WITH conab_prices AS (
        SELECT DISTINCT
            p.nome_produto AS conab_nome,
            f.id_localidade,
            l.uf,
            f.ano,
            f.mes,
            COALESCE(f.preco_curado, f.preco_medio) AS preco,
            f.batch_id
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_produto p ON f.id_produto = p.id_produto
        JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
        WHERE p.nome_produto ~ '^[A-Z\s-]+$'
          AND p.nome_produto ~ ' - '
          AND f.ano >= 2025
          AND COALESCE(f.preco_curado, f.preco_medio) > 0
          AND EXISTS (
              SELECT 1 FROM staging.dim_conab_produto_mapping m
              WHERE m.conab_nome = p.nome_produto
          )
    ),
    variedade_prices AS (
        SELECT
            m.id_produto_local,
            cp.id_localidade,
            cp.ano,
            cp.mes,
            ROUND(cp.preco * m.fator_proporcao, 4) AS preco_variedade,
            cp.batch_id
        FROM conab_prices cp
        JOIN staging.dim_conab_produto_mapping m
            ON m.conab_nome = cp.conab_nome
        JOIN staging.dim_produto lp ON lp.id_produto = m.id_produto_local
        -- UF filter: if local product name ends with a UF suffix (e.g., "Banana Prata SP"),
        -- only distribute to matching UF. Otherwise (no UF suffix) distribute to all UFs.
        WHERE (lp.nome_produto ~* (' ' || cp.uf || '$')
               OR NOT lp.nome_produto ~* ' (AC|AL|AP|AM|BA|CE|DF|ES|GO|MA|MT|MS|MG|PA|PB|PR|PE|PI|RJ|RN|RS|RO|RR|SC|SP|SE|TO)$')
    )
    INSERT INTO staging.fact_precos_mensais
        (id_produto, id_localidade, ano, mes, preco_medio, batch_id, is_interpolado)
    SELECT
        id_produto_local, id_localidade, ano, mes, preco_variedade, batch_id, FALSE
    FROM variedade_prices vp
    ON CONFLICT (id_produto, id_localidade, ano, mes)
    DO UPDATE SET
        preco_medio    = EXCLUDED.preco_medio,
        batch_id       = EXCLUDED.batch_id,
        is_interpolado = FALSE,
        loaded_at      = NOW();

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_sincronizar_variedades_conab] % registros atualizados em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

GRANT EXECUTE ON PROCEDURE staging.sp_sincronizar_variedades_conab()
    TO role_api_reader;

-- ============================================================================
-- SECAO 6: Update COMMENTS
-- ============================================================================

COMMENT ON PROCEDURE staging.sp_calcular_sazonalidade_v11 IS
    'V12 - Baseline Bi-Anual (2025+2026) com dados reais (is_interpolado=FALSE). '
    'Filtra fact_precos_mensais WHERE ano >= 2025. Nao exibe 2020-2024.';

COMMENT ON PROCEDURE staging.sp_executar_carga_completa IS
    'V12 - Executa carga + motor preditivo V12 (Baseline 25-26). '
    'Apenas dados de 2025 em diante sao calculados e exibidos.';

-- ============================================================================
-- SECAO 7: Remove unused tables/views from hidden years
-- ============================================================================

-- stg_impact_weights e vw_zscore_oferta referenciam 2020-2023 — manter como estao
-- pois sao usados internamente, mas sem impacto na MV publica.

COMMIT;
