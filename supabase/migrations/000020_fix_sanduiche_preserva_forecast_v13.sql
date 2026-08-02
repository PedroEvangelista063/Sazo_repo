-- ============================================================================
-- QUERO COMPRAR — Migration 000020: Sanduíche Sazonal v7 — preserva forecast_method v13
-- PostgreSQL 17+  |  Forward-only  |  Idempotent (CREATE OR REPLACE)
--
-- OBJETIVO:
--   O sp_project_sandwich_prices_2026 (v6, aplicada via database/40/51/57 no banco
--   vivo) projeta o PREÇO NUMÉRICO dos meses faltantes. Porém, ao rodar DEPOIS da
--   Engine V13 (migration 000019), ele SOBRESCREVIA o forecast_method v13
--   (ANCHOR_2024_MARGIN_2025 / PROXY_CATEGORIA_UF / LOCF_MES_ANTERIOR) com
--   métodos antigos (SANDUICHE_MEDIA_24_25 / SANDUICHE_FATOR_SAZONAL /
--   PROXY_HIERARQUICO) — a grade ficava 100% preenchida, mas os tooltips v13 do
--   frontend (SazonalidadeNacional.tsx) caíam no texto genérico '📈 Estimativa'.
--
--   A v7 corrige isso: TODOS os Steps preservam o forecast_method v13 já
--   existente na célula — o Sanduíche só projeta preço/status; o método de
--   geração do status continua sendo o da Engine V13.
--
--   Esta migration espelha exatamente database/57_expurgo_e_recalibragem.sql
--   (FASE 2, procedure v7) para a cadeia de migrations Supabase — assim a
--   replicação em produção leva o fix junto com a 000019.
--
-- COMPATIBILIDADE:
--   - CREATE OR REPLACE PROCEDURE (idempotente) — sem DDL destrutiva.
--   - Depende apenas de objetos já existentes (fn_status_cor_regra_25,
--     fn_sandwich_historical_price, fn_preco_base_2026, fn_fator_sazonal_mensal,
--     fn_encontrar_produto_pai, mart.fator_kg_produto_uf, staging.dim_localidade,
--     staging.dim_produto, staging.fact_precos_mensais).
--   - Se o ambiente NÃO tiver as funções de apoio (cadeia Supabase pura),
--     o GRANT abaixo ainda funciona; o CALL é protegido por guard EXISTS no
--     sp_executar_carga_completa (000019, etapa 6).
-- ============================================================================

BEGIN;

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

COMMENT ON PROCEDURE staging.sp_project_sandwich_prices_2026 IS
    'Sanduíche Sazonal v7 (±25%%) — projeta PREÇO numérico dos meses faltantes de 2026. '
    'v7: preserva o forecast_method da Engine V13 (ANCHOR_2024_MARGIN_2025 / '
    'PROXY_CATEGORIA_UF / LOCF_MES_ANTERIOR) em TODOS os Steps — o Sanduíche só '
    'projeta preço/status, o método de geração continua sendo o da V13. '
    'SANDUICHE_MEDIA_24_25/SANDUICHE_FATOR_SAZONAL/PROXY_HIERARQUICO só são '
    'atribuídos em células sem método v13. (000020)';

GRANT ALL ON PROCEDURE staging.sp_project_sandwich_prices_2026 TO role_etl_writer;

COMMIT;
