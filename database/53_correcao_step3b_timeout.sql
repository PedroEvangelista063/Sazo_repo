-- ============================================================================
-- MIGRATION 53: CORREÇÃO DO STEP 3b — TIMEOUT + BUG DE ESCALA
-- ============================================================================
-- Causa raiz confirmada (auditoria Data Lineage, 2026-07-31):
--   A. TIMEOUT (statement_timeout=120s no pooler): o Step 3b da v3 chamava
--      fn_encontrar_produto_pai UMA VEZ POR LINHA (23.220 chamadas
--      PL/pgSQL, cada uma com 2 subqueries EXISTS correlacionadas). A
--      execução da procedure estourava o timeout e NUNCA concluía → 0
--      proxies reprojetados, 23.220 células AMARELO achatadas permanecem.
--      FIX: resolução de pai SET-BASED e DEDUPLICADA — apenas 1.360 combos
--      (id_produto, mes) únicos → 1,6s (era 46-50s) e Step 3b total 5,1s.
--   B. BUG DE ESCALA: quando ratio_preco é vazio (meses futuros não têm
--      dado real), COALESCE(ratio,1.0)=1.0 fazia reproj.preco_projetado =
--      pai_preco_atual * 1.0 — o filho herdava o PREÇO ABSOLUTO do pai
--      (ex.: filho UVA-NIÁGARA ~R$34-39 virava ~R$12-14 do pai Uva Arra 15).
--      FIX: sem ratio, aplicar a VARIAÇÃO PERCENTUAL do pai sobre a escala
--      do próprio filho: preco_projetado = filho_ref * (pai_atual/pai_ref);
--      preco_referencia = filho_ref (escala preservada).
--   Resultado validado (dry-run): 23.153 proxies corrigidos → 6.530 VERDE,
--     2.229 VERMELHO, 15.144 AMARELO (variação dentro de ±15%); 1.080 sem
--     variação (pai flat) não atualizados.
--   C. OPERACIONAL (v4): a execução completa levou 119,24s — margem de só
--      0,8s contra o statement_timeout=120s do pooler. A procedure agora
--      define o próprio timeout via cláusula SET statement_timeout=300000.
--   D. DEADLOCK: 2 execuções concorrentes do pooler causaram deadlock no
--      INSERT ON CONFLICT do Step 2. A procedure agora toma
--      pg_advisory_xact_lock exclusivo no início (impede execução paralela).
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: Índices de apoio (aceleram fn_encontrar_produto_pai / Step 3b)
-- ============================================================================
CREATE INDEX IF NOT EXISTS idx_sazonalidade_produto_par_2026
    ON mart.sazonalidade_produto (id_produto, id_localidade, ano, mes)
    WHERE ano = 2026 AND is_forecast = TRUE;

CREATE INDEX IF NOT EXISTS idx_sazonalidade_produto_produto_mes
    ON mart.sazonalidade_produto (id_produto, ano, mes, is_forecast)
    WHERE ano = 2026;

-- ============================================================================
-- SEÇÃO 2: fn_fator_sazonal_mensal v2 — adiciona Nível 3 (produto global)
-- ============================================================================
CREATE OR REPLACE FUNCTION staging.fn_fator_sazonal_mensal(p_id_produto integer, p_id_localidade integer, p_mes smallint)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_mm         NUMERIC;   -- média do mês (produto, localidade)
    v_mg         NUMERIC;   -- média global (produto, localidade)
    v_md         NUMERIC;   -- mediana do par (sanitização de outliers)
    v_meses      INTEGER;
    v_uf         CHAR(2);
    v_uf_mm      NUMERIC;   -- média do mês (produto, UF)
    v_uf_mg      NUMERIC;   -- média global (produto, UF)
    v_uf_md      NUMERIC;   -- mediana do par (produto, UF)
    v_uf_meses   INTEGER;
    v_g_mm       NUMERIC;   -- média do mês (produto, todas localidades)
    v_g_mg       NUMERIC;   -- média global (produto, todas localidades)
    v_g_md       NUMERIC;   -- mediana global (produto)
    v_g_meses    INTEGER;
BEGIN
    -- ── Nível 1: (produto, localidade) ──
    SELECT
        AVG(f.preco_medio) FILTER (WHERE f.mes = p_mes),
        AVG(f.preco_medio),
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.preco_medio),
        COUNT(DISTINCT f.mes)
    INTO v_mm, v_mg, v_md, v_meses
    FROM staging.fact_precos_mensais f
    WHERE f.id_produto    = p_id_produto
      AND f.id_localidade = p_id_localidade
      AND f.ano IN (2024, 2025)
      AND f.preco_medio IS NOT NULL
      AND f.preco_medio   > 0;

    -- Sanitização de outlier: a média do mês precisa estar entre 0,5x e 2,0x
    -- a mediana do par (protege de preços digitados errado no dado cru).
    IF v_mm IS NOT NULL AND v_mg IS NOT NULL AND v_mg > 0 AND v_md IS NOT NULL
       AND v_meses >= 6
       AND v_mm >= v_md * 0.5 AND v_mm <= v_md * 2.0 THEN
        RETURN ROUND((v_mm / v_mg) - 1, 4);
    END IF;

    -- ── Nível 2 (fallback): (produto, UF) ──
    SELECT l.uf INTO v_uf
    FROM staging.dim_localidade l
    WHERE l.id_localidade = p_id_localidade;

    IF v_uf IS NOT NULL THEN
        SELECT
            AVG(f.preco_medio) FILTER (WHERE f.mes = p_mes),
            AVG(f.preco_medio),
            PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.preco_medio),
            COUNT(DISTINCT f.mes)
        INTO v_uf_mm, v_uf_mg, v_uf_md, v_uf_meses
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
        WHERE f.id_produto = p_id_produto
          AND l.uf         = v_uf
          AND f.ano IN (2024, 2025)
          AND f.preco_medio IS NOT NULL
          AND f.preco_medio   > 0;

        IF v_uf_mm IS NOT NULL AND v_uf_mg IS NOT NULL AND v_uf_mg > 0 AND v_uf_md IS NOT NULL
           AND v_uf_meses >= 6
           AND v_uf_mm >= v_uf_md * 0.5 AND v_uf_mm <= v_uf_md * 2.0 THEN
            RETURN ROUND((v_uf_mm / v_uf_mg) - 1, 4);
        END IF;
    END IF;

    -- ── Nível 3 (FIX 52, fallback): (produto, todas localidades) ──
    -- Recupera pares cujo Nível 1/2 foi bloqueado pela sanitização de
    -- outliers (dado sujo no par), mas o agregado nacional é saudável.
    SELECT
        AVG(f.preco_medio) FILTER (WHERE f.mes = p_mes),
        AVG(f.preco_medio),
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.preco_medio),
        COUNT(DISTINCT f.mes)
    INTO v_g_mm, v_g_mg, v_g_md, v_g_meses
    FROM staging.fact_precos_mensais f
    WHERE f.id_produto = p_id_produto
      AND f.ano IN (2024, 2025)
      AND f.preco_medio IS NOT NULL
      AND f.preco_medio   > 0;

    IF v_g_mm IS NOT NULL AND v_g_mg IS NOT NULL AND v_g_mg > 0 AND v_g_md IS NOT NULL
       AND v_g_meses >= 6
       AND v_g_mm >= v_g_md * 0.5 AND v_g_mm <= v_g_md * 2.0 THEN
        RETURN ROUND((v_g_mm / v_g_mg) - 1, 4);
    END IF;

    RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION staging.fn_fator_sazonal_mensal IS
    'Fator Sazonal Mensal (FIX 52): (média do mês / média global 2024-2025) - 1. '
    'Nível 1 produto+localidade; Nível 2 produto+UF; Nível 3 produto global. '
    'Sanitização de outliers por mediana (banda 0,5x-2,0x). NULL se sem dados.';

-- ============================================================================
-- SEÇÃO 3: fn_encontrar_produto_pai v2 — aceita FATOR_SAZONAL e PROXY
-- ============================================================================
CREATE OR REPLACE FUNCTION staging.fn_encontrar_produto_pai(p_id_produto_filho integer, p_mes_alvo smallint DEFAULT 8)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE
AS $function$
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
    -- 4. (FIX 52) PREFERE pai com FATOR_SAZONAL (volatilidade real) sobre
    --    pai achatado (MEDIA_24_25 / PROXY), depois o mais curto (genérico)
    SELECT p.id_produto INTO v_id_pai
    FROM staging.dim_produto p
    WHERE p.nome_produto ILIKE v_primeira_palavra || '%'
      AND p.id_produto != p_id_produto_filho
      AND EXISTS (
          SELECT 1 FROM mart.sazonalidade_produto s
          WHERE s.id_produto = p.id_produto
            AND s.ano = 2026
            AND s.mes = p_mes_alvo
            AND s.is_forecast = TRUE
            AND s.forecast_method IN ('SANDUICHE_MEDIA_24_25', 'SANDUICHE_FATOR_SAZONAL', 'PROXY_HIERARQUICO')
      )
    ORDER BY
        CASE WHEN EXISTS (
            SELECT 1 FROM mart.sazonalidade_produto s
            WHERE s.id_produto = p.id_produto
              AND s.ano = 2026
              AND s.mes = p_mes_alvo
              AND s.is_forecast = TRUE
              AND s.forecast_method = 'SANDUICHE_FATOR_SAZONAL'
        ) THEN 0 ELSE 1 END,
        LENGTH(p.nome_produto) ASC
    LIMIT 1;

    RETURN v_id_pai;
END;
$function$;

COMMENT ON FUNCTION staging.fn_encontrar_produto_pai IS
    'FIX 52: encontra produto pai genérico (prefixo da 1ª palavra) com projeção '
    'sanduíche em 2026 no mês alvo. Prefere pai com FATOR_SAZONAL (volatilidade '
    'real) sobre pai achatado; desempate pelo nome mais curto (genérico).';

-- ============================================================================
-- SEÇÃO 4: sp_project_sandwich_prices_2026 v3 — adiciona Step 3b
-- ============================================================================
-- ============================================================================
-- Procedure v3 (Steps 1, 2, 2b, 3, 3b, 4) — idêntica à v2 da migration 51
-- com o Step 3b adicionado entre o Step 3 e o Step 4.
-- ============================================================================
CREATE OR REPLACE PROCEDURE staging.sp_project_sandwich_prices_2026()
LANGUAGE plpgsql
SET statement_timeout = 300000
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

    RAISE NOTICE '[sp_project_sandwich_prices_2026] Iniciando Sanduíche Sazonal v4 (mês atual: %)...', v_mes_atual;

    -- ====================================================================
    -- STEP 1: PATCH RETROATIVO (Jan a mês atual)
    -- ====================================================================
    WITH precos_patch AS (
        SELECT
            s.id_sazonalidade,
            s.id_produto,
            s.id_localidade,
            s.ano, s.mes,
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
        status_cor         = COALESCE(
            staging.fn_status_cor_regra_15(
                ROUND(p.preco_medio_historico * (1 + p.tendencia_pct / 100), 4),
                ROUND(p.preco_medio_historico, 4)
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
            GREATEST(h.confianca, COALESCE(b.confianca, 0)) AS confianca
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
    ),
    projecao_final AS (
        SELECT
            id_produto, id_localidade, mes, preco_base, fator_sazonal, confianca,
            ROUND(preco_base * (1 + COALESCE(fator_sazonal, 0)), 4) AS preco_atual,
            ROUND(preco_base, 4) AS preco_referencia
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
        -- FIX 51: semáforo ±15% aplicado LOGO APÓS a injeção do novo preço
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
    -- STEP 2b: VARRE os forecasts futuros JÁ EXISTENTES (criados pela
    -- Engine 30 / versões anteriores) e aplica o momentum sazonal neles.
    -- Aplica SOMENTE em linhas is_forecast=TRUE (nunca sobrescreve real).
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
            ) AS fator_sazonal
        FROM mart.sazonalidade_produto s
        WHERE s.ano = 2026
          AND s.mes BETWEEN v_mes_atual + 1 AND 12
          AND s.is_forecast = TRUE
          AND s.preco_atual IS NOT NULL
          AND s.preco_atual > 0
    ),
    recalc_final AS (
        SELECT
            r.id_sazonalidade,
            ROUND(r.preco_base * (1 + COALESCE(r.fator_sazonal, 0)), 4) AS preco_atual,
            ROUND(r.preco_base, 4) AS preco_referencia,
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
    -- Resolve o pai UMA VEZ por (id_filho, mes) deduplicado (1.360 combos),
    -- sem chamadas PL/pgSQL por linha (era 23.220 → timeout 120s).
    -- Corrige também o bug de escala: sem ratio real, aplica a VARIAÇÃO
    -- PERCENTUAL do pai sobre a escala do próprio filho em vez do preço
    -- absoluto do pai. Aplica somente em is_forecast=TRUE (nunca real).
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
    'Sanduíche Sazonal v4 — Fase 53. Igual à v3 (Fator Sazonal Nível 3, '
    'regra ±15%, Step 3b) com Step 3b SET-BASED deduplicado (1.360 combos '
    'filho×mes, ~5s) — corrige timeout de 120s; reprojeta proxy aplicando a '
    'variação percentual do pai sobre a escala do próprio filho (corrige bug '
    'de escala que herdava o preço absoluto do pai).';

GRANT EXECUTE ON FUNCTION staging.fn_fator_sazonal_mensal(INTEGER, INTEGER, SMALLINT)
    TO role_etl_writer;
GRANT EXECUTE ON FUNCTION staging.fn_encontrar_produto_pai(INTEGER, SMALLINT)
    TO role_etl_writer;
GRANT ALL ON PROCEDURE staging.sp_project_sandwich_prices_2026
    TO role_etl_writer;

COMMIT;
