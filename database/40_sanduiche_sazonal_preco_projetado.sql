-- ============================================================================
-- QUERO COMPRAR — Fase 40: Sanduíche Sazonal — Preço Numérico Projetado
-- PostgreSQL 16+
--
-- OBJETIVO:
--   Estender a Engine Preditiva (Fase 30) para projetar também o PREÇO
--   NUMÉRICO (preco_atual + preco_referencia) dos meses futuros de 2026,
--   não apenas o status_cor (semáforo).
--
--   Metáfora do "Sanduíche de Folhas":
--     Camada 1 (2024):     Dados históricos — base
--     Camada 2 (2025):     Dados históricos — ajuste fino
--     Camada 3 (2026 real): Dados reais coletados até Julho
--     Camada 4 (Sanduíche): Média 24-25 projetada para Ago-Dez 2026
--       ↓ Quando scraper chega, camada 4 é SOBRESCRITA por dado real
--
-- ARQUITETURA:
--   1. Cria função auxiliar para calcular média histórica de preço por mês
--      (com tendência por produto + localidade)
--   2. Adiciona forecast_method 'SANDUICHE_MEDIA_24_25' ao CHECK constraint
--   3. Recria sp_calcular_forecast_2026 com projeção numérica de preços
--   4. Mantém DISTINCT ON + ORDER BY is_forecast ASC (real > projeção)
--
-- FIX aplicados após code review:
--   - Tendência calculada por (produto, localidade) ao invés de inflação global
--   - Grade futura baseada em staging.fact_precos_mensais (não na engine 30)
--   - Fallback de localidade respeita mesma UF (evita cruzar SP com CE)
--   - ON CONFLICT verifica is_forecast do registro EXISTENTE (race condition)
--   - Nome da procedure em inglês, conforme padrão do projeto
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: DDL — Estender CHECK constraint do forecast_method
-- ============================================================================

ALTER TABLE mart.sazonalidade_produto
    DROP CONSTRAINT IF EXISTS chk_forecast_method;

-- FIX: Supabase pode ter constraint com nome auto-gerado
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
                'SANDUICHE_MEDIA_24_25',  -- ← NOVO: sanduíche histórico
                'SANDUICHE_FATOR_SAZONAL',-- ← Fase 51: índice de sazonalidade
                'PROXY_HIERARQUICO'
            ));

COMMENT ON COLUMN mart.sazonalidade_produto.forecast_method IS
    'Método de geração: NULL=dado real; SANDUICHE_MEDIA_24_25=média histórica 24-25 projetada; demais=baselines ponderados.';

-- ============================================================================
-- SEÇÃO 2: Função Auxiliar — Média Histórica de Preço por (prod, loc, mes)
-- ============================================================================
-- Calcula o preço médio de um determinado mês nos anos base (2024 e 2025).
-- Usa dados de staging.fact_precos_mensais (fonte real, não projetada).
-- Retorna o preço médio + tendência específica do (produto, localidade) +
-- confiança baseada em quantos anos têm dados.
--
-- Fallback chain:
--   1. Média do (produto, localidade, mês) em 2024-2025
--   2. Média do (produto, localidade, ANY mês) em 2024-2025
--   3. Média do (produto, mesma UF, mesmo mês) em 2024-2025
--   4. Média do (produto, ANY localidade, ANY mês) em 2024-2025

CREATE OR REPLACE FUNCTION staging.fn_sandwich_historical_price(
    p_id_produto    INTEGER,
    p_id_localidade INTEGER,
    p_mes           SMALLINT,
    p_ano_alvo      SMALLINT DEFAULT 2026
)
RETURNS TABLE(
    preco_medio_historico NUMERIC(14,4),
    tendencia_pct         NUMERIC(6,2),
    confianca             NUMERIC(5,2),
    meses_com_dado        INTEGER
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_preco       NUMERIC(14,4);
    v_preco_2024  NUMERIC(14,4);
    v_preco_2025  NUMERIC(14,4);
    v_tendencia   NUMERIC(6,2);
    v_confianca   NUMERIC(5,2);
    v_meses_ok    INTEGER;
    v_uf          CHAR(2);
BEGIN
    -- Obtém a UF da localidade para fallback regional
    SELECT l.uf INTO v_uf
    FROM staging.dim_localidade l
    WHERE l.id_localidade = p_id_localidade;

    -- ── Nível 1: Média do (produto, localidade, mês) em 2024-2025 ──
    SELECT
        AVG(f.preco_medio),
        COUNT(*)
    INTO v_preco, v_meses_ok
    FROM staging.fact_precos_mensais f
    WHERE f.id_produto    = p_id_produto
      AND f.id_localidade = p_id_localidade
      AND f.mes           = p_mes
      AND f.ano IN (2024, 2025)
      AND f.preco_medio IS NOT NULL
      AND f.preco_medio > 0;

    IF v_meses_ok > 0 THEN
        v_confianca := LEAST(100.0, (v_meses_ok::NUMERIC / 2.0) * 100.0);
    ELSE
        -- ── Nível 2: Média do (produto, localidade, ANY mês) ──
        SELECT AVG(f.preco_medio), COUNT(*)
        INTO v_preco, v_meses_ok
        FROM staging.fact_precos_mensais f
        WHERE f.id_produto    = p_id_produto
          AND f.id_localidade = p_id_localidade
          AND f.ano IN (2024, 2025)
          AND f.preco_medio IS NOT NULL
          AND f.preco_medio > 0;
    END IF;

    IF v_meses_ok > 0 THEN
        v_confianca := 30.0;  -- fallback por produto+localidade, confiança média-baixa
    ELSE
        -- ── Nível 3: Média do (produto, mesma UF, mesmo mês) ──
        -- FIX: não cruza localidades de UFs diferentes
        IF v_uf IS NOT NULL THEN
            SELECT AVG(f.preco_medio), COUNT(*)
            INTO v_preco, v_meses_ok
            FROM staging.fact_precos_mensais f
            JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
            WHERE f.id_produto = p_id_produto
              AND l.uf         = v_uf
              AND f.mes        = p_mes
              AND f.ano IN (2024, 2025)
              AND f.preco_medio IS NOT NULL
              AND f.preco_medio > 0;
        END IF;
    END IF;

    IF v_meses_ok > 0 THEN
        v_confianca := 20.0;  -- fallback regional, confiança baixa
    ELSE
        -- ── Nível 4: Média do (produto, ANY localidade, ANY mês) ──
        SELECT AVG(f.preco_medio), COUNT(*)
        INTO v_preco, v_meses_ok
        FROM staging.fact_precos_mensais f
        WHERE f.id_produto = p_id_produto
          AND f.ano IN (2024, 2025)
          AND f.preco_medio IS NOT NULL
          AND f.preco_medio > 0;

        IF v_meses_ok > 0 THEN
            v_confianca := 10.0;  -- fallback distante, confiança muito baixa
        ELSE
            -- Sem dados históricos — não projeta
            RETURN QUERY SELECT NULL::NUMERIC(14,4), 0::NUMERIC(6,2), 0::NUMERIC(5,2), 0;
            RETURN;
        END IF;
    END IF;

    -- ── Tendência: variação percentual 2024 → 2025 para o MESMO (prod, loc, mês) ──
    -- FIX: calculada por produto+localidade, não inflação global
    SELECT f24.preco_medio INTO v_preco_2024
    FROM staging.fact_precos_mensais f24
    WHERE f24.id_produto    = p_id_produto
      AND f24.id_localidade = p_id_localidade
      AND f24.mes           = p_mes
      AND f24.ano           = 2024
      AND f24.preco_medio IS NOT NULL
      AND f24.preco_medio > 0;

    SELECT f25.preco_medio INTO v_preco_2025
    FROM staging.fact_precos_mensais f25
    WHERE f25.id_produto    = p_id_produto
      AND f25.id_localidade = p_id_localidade
      AND f25.mes           = p_mes
      AND f25.ano           = 2025
      AND f25.preco_medio IS NOT NULL
      AND f25.preco_medio > 0;

    IF v_preco_2024 IS NOT NULL AND v_preco_2024 > 0
       AND v_preco_2025 IS NOT NULL AND v_preco_2025 > 0 THEN
        v_tendencia := ROUND(((v_preco_2025 - v_preco_2024) / v_preco_2024) * 100, 2);
    ELSE
        v_tendencia := 0;
    END IF;

    RETURN QUERY SELECT
        ROUND(v_preco, 4),
        v_tendencia,
        ROUND(v_confianca, 2)::NUMERIC(5,2),
        v_meses_ok;
END;
$$;

COMMENT ON FUNCTION staging.fn_sandwich_historical_price IS
    'Calcula o preço médio histórico de um (produto, localidade, mês) nos anos 2024-2025. '
    '4 níveis de fallback: (1) mesmo prod+loc+mês, (2) mesmo prod+loc, (3) mesmo prod+UF+mês, '
    '(4) mesmo prod global. Retorna preço, tendência (2024→2025), confiança e qtd de meses.';

-- ============================================================================
-- SEÇÃO 3: Stored Procedure — Sanduíche Sazonal (Preço Projetado)
-- ============================================================================
-- Preenche gaps de preço numérico em 2026:
--   1. Patch retroativo: Jan-mês atual onde preco_atual IS NULL → preenche com média histórica
--   2. Pre-fill futuro: mês atual+1 até Dez → insere com preço da média histórica + tendência
--
-- NUNCA sobrescreve dados reais (is_forecast = FALSE).
-- A grade de produtos é baseada em staging.fact_precos_mensais (independente da engine 30).

CREATE OR REPLACE PROCEDURE staging.sp_project_sandwich_prices_2026()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio     TIMESTAMPTZ;
    v_fim        TIMESTAMPTZ;
    v_total      INTEGER;
    v_mes_atual  INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    v_mes_atual := EXTRACT(MONTH FROM NOW())::INTEGER;  -- mês corrente (Julho = 7)

    RAISE NOTICE '[sp_project_sandwich_prices_2026] Iniciando Sanduíche Sazonal (mês atual: %)...', v_mes_atual;

    -- --------------------------------------------------------------------
    -- STEP 1: PATCH RETROATIVO (Jan a mês atual)
    -- Onde preco_atual é NULL mas registro existe (status_cor já foi projetado pela engine 30),
    -- preenche com a média histórica do mesmo mês ajustada pela tendência.
    -- --------------------------------------------------------------------
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
          AND s.mes <= v_mes_atual               -- meses já ocorridos
          AND s.preco_atual IS NULL               -- sem preço numérico
          AND s.is_forecast = TRUE                -- apenas projeções
          AND h.preco_medio_historico IS NOT NULL -- tem histórico
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
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Patch retroativo (Jan-%): % linhas preenchidas.', v_mes_atual, v_total;

    -- --------------------------------------------------------------------
    -- STEP 2: PRE-FILL FUTURO (mês atual+1 até Dezembro)
    -- Insere registros para meses futuros com preço projetado.
    -- FIX: grade baseada em staging.fact_precos_mensais (não na engine 30)
    -- --------------------------------------------------------------------
    WITH meses_futuros AS (
        SELECT generate_series(v_mes_atual + 1, 12) AS mes
    ),
    -- Produtos que têm dados históricos em staging (fonte real)
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
    -- Filtra apenas o que NÃO tem dado real ainda
    meses_sem_real AS (
        SELECT g.*
        FROM grade_futura g
        LEFT JOIN mart.sazonalidade_produto s
            ON s.id_produto    = g.id_produto
           AND s.id_localidade = g.id_localidade
           AND s.ano           = 2026
           AND s.mes           = g.mes
           AND s.is_forecast   = FALSE   -- só considera dado real
        WHERE s.id_sazonalidade IS NULL   -- não existe dado real
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
        -- Preço projetado = média histórica ajustada pela tendência do (prod, loc, mês)
        ROUND(h.preco_medio_historico * (1 + h.tendencia_pct / 100), 4),
        ROUND(h.preco_medio_historico, 4),
        2026::TEXT || '-' || LPAD(msr.mes::TEXT, 2, '0'),
        -- Status_cor: usa a moda do baseline (se disponível) ou AMARELO
        COALESCE(
            b.status_cor_mode,
            'AMARELO'
        ) AS status_cor,
        'BASELINE_HISTORICO',
        NOW(),
        TRUE,                                   -- is_forecast = TRUE (projeção)
        GREATEST(h.confianca, COALESCE(b.confianca, 0)),
        'SANDUICHE_MEDIA_24_25',
        FALSE                                    -- usou_fallback_12m: falso (dado sintético, não LOCF)
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
                                THEN mart.sazonalidade_produto.preco_atual  -- preserva dado real
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
        -- FIX: protege contra race condition — verifica registro EXISTENTE
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
        -- Garante que o trigger trg_audit_status_cor não receba NULL
        usou_fallback_12m  = COALESCE(mart.sazonalidade_produto.usou_fallback_12m, FALSE),
        calculado_em       = NOW();

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Pre-fill futuro (Ago-Dez): % linhas inseridas/atualizadas.', v_total;

    -- --------------------------------------------------------------------
    -- Refresh da MV
    -- --------------------------------------------------------------------
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Concluído em % seg.',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

COMMENT ON PROCEDURE staging.sp_project_sandwich_prices_2026 IS
    'Sanduíche Sazonal — Projeta preços numéricos para 2026. '
    'Step 1: Patch retroativo (Jan-mês atual) — preenche preco_atual onde NULL usando média histórica 24-25. '
    'Step 2: Pre-fill futuro (mês atual+1 até Dez) — insere preço projetado com ajuste de tendência. '
    'ON CONFLICT preserva dado real (is_forecast=FALSE) consultando o registro existente. '
    'forecast_method = SANDUICHE_MEDIA_24_25 para registros projetados. '
    'Grade baseada em staging.fact_precos_mensais (independente da engine 30).';

-- ============================================================================
-- SEÇÃO 4: Atualizar sp_executar_carga_completa para incluir Sanduíche
-- ============================================================================

CREATE OR REPLACE PROCEDURE staging.sp_executar_carga_completa()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Iniciando pipeline completo...';

    -- 1. Carga bruta (landing → staging)
    CALL staging.sp_carregar_landing_para_staging();
    RAISE NOTICE '[sp_executar_carga_completa] Landing → Staging OK';

    -- 2. Limpeza/normalização
    CALL staging.sp_limpar_e_normalizar_staging();
    RAISE NOTICE '[sp_executar_carga_completa] Normalização OK';

    -- 3. Enriquecimento CONAB → variedades
    CALL staging.sp_sincronizar_variedades_conab();
    RAISE NOTICE '[sp_executar_carga_completa] Sincronização CONAB OK';

    -- 4. Cálculo sazonalidade (dados reais 2025+)
    CALL staging.sp_calcular_sazonalidade_v11();
    RAISE NOTICE '[sp_executar_carga_completa] Sazonalidade v11 OK';

    -- 5. Forecast 2026 (projeta status_cor para meses faltantes via baseline 24-25)
    CALL staging.sp_calcular_forecast_2026();
    RAISE NOTICE '[sp_executar_carga_completa] Forecast 2026 (status_cor) OK';

    -- 6. NOVO: Sanduíche Sazonal (projeta PREÇO NUMÉRICO para meses faltantes)
    CALL staging.sp_project_sandwich_prices_2026();
    RAISE NOTICE '[sp_executar_carga_completa] Sanduíche Sazonal (preço numérico) OK';

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Pipeline completo em % seg',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

COMMENT ON PROCEDURE staging.sp_executar_carga_completa IS
    'Pipeline completo V13 — Executa carga + sazonalidade V11 + Forecast 2026 + Sanduíche Sazonal (preço numérico). '
    'Deve ser chamado após cada ciclo de coleta do scraper.';

-- ============================================================================
-- SEÇÃO 5: Permissões
-- ============================================================================

GRANT SELECT ON mart.sazonalidade_baseline_24_25 TO role_api_reader;
GRANT EXECUTE ON FUNCTION staging.fn_sandwich_historical_price TO role_etl_writer;
GRANT ALL ON PROCEDURE staging.sp_project_sandwich_prices_2026 TO role_etl_writer;
GRANT ALL ON PROCEDURE staging.sp_executar_carga_completa TO role_etl_writer;

COMMIT;
