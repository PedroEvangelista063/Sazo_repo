-- ============================================================================
-- MIGRATION 56: BLINDAGEM DO SANDUÍCHE SAZONAL COM fator_kg + LIMPEZA FORECAST
-- ============================================================================
-- CONTEXTO (validação E2E pós-correções — migrations 53/54/55 aplicadas):
--   A migration 53 corrigiu o PREÇO NO BANCO, mas o SP
--   sp_project_sandwich_prices_2026 (migrações 40/41/50/51) projeta preços
--   futuros SEM aplicar fator_kg (normalização R$/kg). Uma re-execução do SP
--   em 2026-07-31 15:19 (após a migration 53, 14:23) reintroduziu 671 linhas
--   forecast com preço inflado (unidade saca/caixa):
--     • 670 × SANDUICHE_FATOR_SAZONAL + 1 × SANDUICHE_MEDIA_24_25
--     • 120 pares (produto, UF) afetados — 120/120 TÊM fator_kg em
--       mart.fator_kg_produto_uf (tabela persistida pela migration 53)
--     • Verificado empiricamente: preco_atual / fator_kg reproduz EXATAMENTE
--       o preco_medio per-kg (ex.: FEIJAO COMUM CORES SC 3,79 / 2,7989 =
--       1,3541 = preco_medio ✓)
--
-- CORREÇÃO:
--   SEÇÃO 1 — Limpa as 671 linhas forecast infladas: divide preco_atual e
--             preco_referencia pelo fator_kg do par, devolve o resultado a
--             preco_medio e recalcula status_cor pela regra ±15%.
--             IDEMPOTENTE: após a correção a razão preco_atual/preco_medio
--             volta a ~1,0 → a linha sai do filtro (razão > 1,5) em re-runs.
--   SEÇÃO 2 — Recria sp_project_sandwich_prices_2026 aplicando fator_kg nos
--             Steps 1 (patch retroativo), 2 (pre-fill futuro) e 2b (momentum
--             em forecasts já existentes). Steps 3/3b (proxy hierárquico)
--             herdam preços dos pais JÁ normalizados (R$/kg) e o ratio real
--             também é per-kg → permanecem corretos. Step 4 (recalc ±15%)
--             inalterado. ON CONFLICT preserva dado real (is_forecast=FALSE).
--
-- LIMITAÇÃO DOCUMENTADA:
--   • Só é possível normalizar pares (produto, UF) com fator_kg derivado
--     (n>=5). Linhas forecast de pares sem fator mantêm o preço bruto
--     projetado (sem inflação identificável) — cobertura 120/120 dos atuais.
--   • O proxy hierárquico (Step 3b) reescala pela variação do pai sobre a
--     referência do filho; com pai corrigido, herda R$/kg automaticamente.
--
-- ⚠️ NOTA DE SUPERSEDIMENTO (aplicada no live em 2026-07-31 15:50):
--   A SEÇÃO 2 (recriação do SP como v5 ±15%) foi aplicada e depois
--   SUBSTITUÍDA pela migration 57_expurgo_e_recalibragem.sql, que:
--     (a) expurgou 38.882 células forecast legadas (forecast_method IS NULL),
--     (b) criou fn_status_cor_regra_25 (±25%) como semáforo oficial,
--     (c) recriou o SP como v6 (±25%) sobre a v5 (fator_kg preservado).
--   → Se um ambiente já tiver o 57_expurgo, NÃO re-executar esta SEÇÃO 2
--     isolada (downgrade do semáforo para ±15%). O arquivo fica como
--     registro histórico do fix fator_kg + limpeza das 671 linhas.
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: Limpeza das 671 linhas forecast infladas (razão > 1,5 com fator_kg)
-- ============================================================================
WITH infladas AS (
    SELECT
        s.id_sazonalidade,
        s.preco_atual,
        s.preco_referencia,
        s.preco_medio,
        f.fator_kg
    FROM mart.sazonalidade_produto s
    JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
    JOIN mart.fator_kg_produto_uf f
        ON f.id_produto = s.id_produto
       AND f.uf         = l.uf
    WHERE s.is_forecast = TRUE
      AND s.preco_medio > 0
      AND s.preco_atual > 0
      AND s.preco_atual / s.preco_medio > 1.5
)
UPDATE mart.sazonalidade_produto s
SET
    preco_atual      = ROUND(i.preco_atual / i.fator_kg, 4),
    preco_referencia = ROUND(COALESCE(i.preco_referencia, i.preco_atual) / i.fator_kg, 4),
    preco_medio      = ROUND(i.preco_atual / i.fator_kg, 4),
    status_cor       = COALESCE(
        staging.fn_status_cor_regra_15(
            ROUND(i.preco_atual / i.fator_kg, 4),
            ROUND(COALESCE(i.preco_referencia, i.preco_atual) / i.fator_kg, 4)
        ),
        s.status_cor
    ),
    calculado_em     = NOW()
FROM infladas i
WHERE s.id_sazonalidade = i.id_sazonalidade
  AND i.fator_kg IS NOT NULL
  AND i.fator_kg > 0;

-- ============================================================================
-- SEÇÃO 2: Recria o SP — projeção SEMPRE normalizada por fator_kg (R$/kg)
-- ============================================================================
CREATE OR REPLACE PROCEDURE staging.sp_project_sandwich_prices_2026()
LANGUAGE plpgsql
SET statement_timeout TO '300000'
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

    -- Lock de exclusividade: impede deadlock/dupla execução concorrente.
    PERFORM pg_advisory_xact_lock(hashtext('sp_project_sandwich_prices_2026'));

    RAISE NOTICE '[sp_project_sandwich_prices_2026] Iniciando Sanduíche Sazonal v5 (fator_kg) (mês atual: %)...', v_mes_atual;

    -- ====================================================================
    -- STEP 1: PATCH RETROATIVO (Jan a mês atual) — FIX 56: / fator_kg
    -- ====================================================================
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
        -- FIX 56: projeção normalizada para R$/kg
        preco_atual        = ROUND(p.preco_medio_historico * (1 + p.tendencia_pct / 100) / p.fator_kg, 4),
        preco_referencia   = ROUND(p.preco_medio_historico / p.fator_kg, 4),
        status_cor         = COALESCE(
            staging.fn_status_cor_regra_15(
                ROUND(p.preco_medio_historico * (1 + p.tendencia_pct / 100) / p.fator_kg, 4),
                ROUND(p.preco_medio_historico / p.fator_kg, 4)
            ),
            s.status_cor
        ),
        baseline_confianca = GREATEST(s.baseline_confianca, p.confianca),
        forecast_method    = 'SANDUICHE_MEDIA_24_25',
        usou_fallback_12m  = COALESCE(s.usou_fallback_12m, FALSE),
        calculado_em       = NOW()
    FROM precos_patch p
    WHERE s.id_sazonalidade = p.id_sazonalidade;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 1 — Patch retroativo (Jan-%): % linhas.', v_mes_atual, v_total;

    -- ====================================================================
    -- STEP 2: PRE-FILL FUTURO (mês atual+1 até Dezembro) — FATOR SAZONAL
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
            -- FIX 51: base = média real 2026; fallback média 2024-25
            COALESCE(
                staging.fn_preco_base_2026(msr.id_produto, msr.id_localidade),
                h.preco_medio_historico
            ) AS preco_base,
            -- FIX 51: momentum sazonal (pode ser NULL → variação 0%)
            staging.fn_fator_sazonal_mensal(
                msr.id_produto, msr.id_localidade, msr.mes::SMALLINT
            ) AS fator_sazonal,
            GREATEST(h.confianca, COALESCE(b.confianca, 0)) AS confianca,
            -- FIX 56: fator de normalização R$/kg do par (produto, UF)
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
            -- FIX 56: preço projetado normalizado para R$/kg
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
            staging.fn_status_cor_regra_15(pf.preco_atual, pf.preco_referencia),
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
        forecast_method    = CASE WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                  THEN mart.sazonalidade_produto.forecast_method
                                  ELSE EXCLUDED.forecast_method END,
        usou_fallback_12m  = COALESCE(mart.sazonalidade_produto.usou_fallback_12m, FALSE),
        calculado_em       = NOW();

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 2 — Pre-fill futuro c/ Fator Sazonal: % linhas.', v_total;

    -- ====================================================================
    -- STEP 2b: VARRE os forecasts futuros JÁ EXISTENTES e aplica o momentum
    -- sazonal normalizado por fator_kg. Somente is_forecast=TRUE.
    -- ====================================================================
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
            -- FIX 56: fator de normalização R$/kg do par (produto, UF)
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
            -- FIX 56: preço normalizado para R$/kg
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
            staging.fn_status_cor_regra_15(r.preco_atual, r.preco_referencia),
            'AMARELO'
        ),
        forecast_method    = CASE WHEN r.fator_sazonal IS NOT NULL
                                  THEN 'SANDUICHE_FATOR_SAZONAL'
                                  ELSE s.forecast_method END,
        calculado_em       = NOW()
    FROM recalc_final r
    WHERE s.id_sazonalidade = r.id_sazonalidade;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 2b — Momentum em forecasts existentes: % linhas.', v_total;

    -- ====================================================================
    -- STEP 3: PROXY HIERÁRQUICO — Produto Pai para Órfãos
    -- (Pais já corrigidos para R$/kg → filhos herdam escala correta)
    -- ====================================================================
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
                AND s2.forecast_method IN ('SANDUICHE_MEDIA_24_25', 'PROXY_HIERARQUICO', 'SANDUICHE_FATOR_SAZONAL')
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
              AND s.forecast_method IN ('SANDUICHE_MEDIA_24_25', 'PROXY_HIERARQUICO', 'SANDUICHE_FATOR_SAZONAL')
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
                staging.fn_status_cor_regra_15(pf.preco_projetado, pf.preco_referencia),
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
            forecast_method    = 'PROXY_HIERARQUICO',
            usou_fallback_12m  = COALESCE(mart.sazonalidade_produto.usou_fallback_12m, FALSE),
            calculado_em       = NOW();

        GET DIAGNOSTICS v_total = ROW_COUNT;
        RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 3 — Proxy: % linhas.', v_total;
    ELSE
        RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 3 — Nenhum órfão com pai.';
    END IF;

    DROP TABLE IF EXISTS tmp_orphans_proxy;

    -- ====================================================================
    -- STEP 3b (FIX 53): REPROCESSA PROXIES ACHATADOS — SET-BASED
    -- (Pais corrigidos → variação percentual herda R$/kg)
    -- ====================================================================
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
              AND sp.forecast_method IN ('SANDUICHE_MEDIA_24_25', 'SANDUICHE_FATOR_SAZONAL', 'PROXY_HIERARQUICO')
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
            staging.fn_status_cor_regra_15(r.preco_projetado, r.preco_referencia),
            'AMARELO'
        ),
        forecast_method    = 'PROXY_HIERARQUICO',
        calculado_em       = NOW()
    FROM reproj r
    WHERE s.id_sazonalidade = r.id_sazonalidade
      AND r.preco_projetado IS NOT NULL AND r.preco_projetado > 0
      AND r.preco_referencia IS NOT NULL AND r.preco_referencia > 0
      AND ABS(r.preco_projetado - r.preco_referencia) >= 0.0001;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 3b — Proxies reprojetados (variação do pai, escala do filho): % linhas.', v_total;

    -- ====================================================================
    -- STEP 4 (FIX 50): VARREDURA FINAL — recalcula ±15% em 2026 forecast
    -- ====================================================================
    WITH recalc_forecast AS (
        SELECT
            id_sazonalidade,
            CASE
                WHEN preco_atual IS NULL OR preco_atual <= 0 THEN 'AMARELO'
                ELSE COALESCE(
                    staging.fn_status_cor_regra_15(preco_atual, preco_referencia),
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
    RAISE NOTICE '[sp_project_sandwich_prices_2026] Step 4 — Recalc ±15%%: % linhas.', v_total;

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
    'Sanduíche Sazonal v5 — Projeta preços numéricos para 2026 SEMPRE normalizados '
    'por fator_kg (R$/kg) via mart.fator_kg_produto_uf (migration 53). '
    'FIX 56: Steps 1/2/2b dividem a projeção pelo fator do par (produto, UF), '
    'impedindo a reintrodução de preços inflados por unidade saca/caixa. '
    'Steps 3/3b herdam pais já corrigidos. Step 4 recalcula semáforo ±15%. '
    'ON CONFLICT preserva dado real (is_forecast=FALSE).';

-- ============================================================================
-- SEÇÃO 3: Permissões
-- ============================================================================
GRANT ALL ON PROCEDURE staging.sp_project_sandwich_prices_2026 TO role_etl_writer;

-- ============================================================================
-- SEÇÃO 4: Resumo observável (convenção de migrations 40/52/53)
-- ============================================================================
DO $$
DECLARE
    v_infladas INTEGER;
    v_restante INTEGER;
BEGIN
    SELECT count(*) INTO v_infladas
    FROM mart.sazonalidade_produto s
    JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
    JOIN mart.fator_kg_produto_uf f ON f.id_produto = s.id_produto AND f.uf = l.uf
    WHERE s.is_forecast = TRUE AND s.preco_medio > 0 AND s.preco_atual > 0
      AND s.preco_atual / s.preco_medio > 1.5;

    SELECT count(*) INTO v_restante
    FROM mart.sazonalidade_produto s
    JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
    JOIN mart.fator_kg_produto_uf f ON f.id_produto = s.id_produto AND f.uf = l.uf
    WHERE s.is_forecast = TRUE AND s.preco_medio > 0 AND s.preco_atual > 0
      AND (s.preco_atual / s.preco_medio > 5 OR s.preco_atual / s.preco_medio < 0.2);

    RAISE NOTICE '[migration_56] forecast infladas pendentes (razao>1.5)=% | outliers residuais (>5x)=%',
        v_infladas, v_restante;
END
$$;

COMMIT;

-- ============================================================================
-- Refresh da MV (fora da transação — REFRESH ... CONCURRENTLY)
-- ============================================================================
REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- ============================================================================
-- Verificação pós-aplicação (executar manualmente):
--
-- 1) Forecast infladas devem ser 0:
--    SELECT count(*) FROM mart.sazonalidade_produto s
--    JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
--    JOIN mart.fator_kg_produto_uf f ON f.id_produto = s.id_produto AND f.uf = l.uf
--    WHERE s.is_forecast = TRUE AND s.preco_medio > 0 AND s.preco_atual > 0
--      AND s.preco_atual / s.preco_medio > 1.5;
--
-- 2) Outliers >5x devem ser 0 (inclusive forecast):
--    SELECT count(*) FROM mart.sazonalidade_produto s
--    WHERE s.preco_medio > 0 AND s.preco_atual > 0
--      AND (s.preco_atual / s.preco_medio > 5 OR s.preco_atual / s.preco_medio < 0.2);
-- ============================================================================
