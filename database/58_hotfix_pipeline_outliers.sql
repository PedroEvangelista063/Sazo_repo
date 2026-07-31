-- =====================================================================
-- MIGRATION 58 — HOTFIX DE ORQUESTRAÇÃO, LEAK E OUTLIERS
-- =====================================================================
-- Objetivo: corrigir 4 frentes identificadas na auditoria DQ (2026-07-31)
--
--   FASE 1 — ORQUESTRADOR QUEBRADO: sp_executar_carga_completa chamava
--            sp_calcular_sazonalidade_v11() (FANTASMA — não existe no
--            servidor), fazendo o pipeline principal falhar silenciosamente
--            no passo 4. Correção: chamar sp_calcular_sazonalidade(NULL,NULL).
--
--   FASE 1b — LEAK DO MILHO: dados reais 2026 do MILHO (447 pares, batch
--             retroativo 62a14452 em 30/07/2026) nunca foram materializados
--             no Mart porque sp_calcular_sazonalidade não foi reexecutado
--             após a carga. Correção: reprocessar 2026 meses 1..7.
--
--   FASE 2 — DRIFT DE TRANSFORMAÇÃO: a variacao_mom_pct/preco_mes_anterior
--            dos reais no Mart foi calculada com COALESCE(preco_curado,
--            preco_medio) (migration 23/sp_calcular_sazonalidade_preditiva),
--            gerando aberrações como Batata Doce SP +1768% (curado 40,02 vs
--            exibido 2,33). Correção: fonte de verdade = preco_medio; recriar
--            sp_calcular_sazonalidade preenchendo preco_atual/preco_referencia/
--            preco_mes_anterior/variacao_mom_pct a partir de preco_medio (LAG)
--            e recalcular retroativamente os reais no Mart via LAG(preco_atual).
--
--   FASE 3 — HARD CAP DE OUTLIERS: novo trigger com 3 camadas:
--            (A) regra antiga mantida: preco > média_UF*5 → rejeitado;
--            (B) hard cap R$50: preco > 50 sem histórico sólido que
--                justifique → REJEITADO/ANOMALIA_PARSING (bloqueia erros de
--                unidade: Amendoim 280, Tomate 90, Pepino 230, etc.);
--            "histórico sólido" = UF n>=3 E preco <= média_UF*3, OU
--            global n>=3 E preco <= média_global*3.
--            Limpeza retroativa: mover alvos do fact para precos_rejeitados
--            (com backup auditável) e deletar do fact.
--
--   FASE 4 — Deploy Local+Supabase, REFRESH MV CONCURRENTLY e validação.
-- =====================================================================

BEGIN;

-- =====================================================================
-- FASE 1 — FIX DO ORQUESTRADOR (v11 fantasma → sp_calcular_sazonalidade)
-- =====================================================================

CREATE OR REPLACE PROCEDURE staging.sp_executar_carga_completa()
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
    v_existe BOOLEAN;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Iniciando pipeline completo...';

    -- 1. Carga bruta (landing → staging) — se existir no ambiente
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'staging' AND p.proname = 'sp_carregar_landing_para_staging'
    ) INTO v_existe;
    IF v_existe THEN
        CALL staging.sp_carregar_landing_para_staging();
        RAISE NOTICE '[sp_executar_carga_completa] Landing → Staging OK';
    ELSE
        RAISE NOTICE '[sp_executar_carga_completa] Landing → Staging SKIP (proc ausente neste ambiente)';
    END IF;

    -- 2. Limpeza/normalização — se existir no ambiente
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'staging' AND p.proname = 'sp_limpar_e_normalizar_staging'
    ) INTO v_existe;
    IF v_existe THEN
        CALL staging.sp_limpar_e_normalizar_staging();
        RAISE NOTICE '[sp_executar_carga_completa] Normalização OK';
    ELSE
        RAISE NOTICE '[sp_executar_carga_completa] Normalização SKIP (proc ausente neste ambiente)';
    END IF;

    -- 3. Enriquecimento CONAB → variedades — se existir no ambiente
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'staging' AND p.proname = 'sp_sincronizar_variedades_conab'
    ) INTO v_existe;
    IF v_existe THEN
        CALL staging.sp_sincronizar_variedades_conab();
        RAISE NOTICE '[sp_executar_carga_completa] Sincronização CONAB OK';
    ELSE
        RAISE NOTICE '[sp_executar_carga_completa] Sincronização CONAB SKIP (proc ausente neste ambiente)';
    END IF;

    -- 4. Cálculo sazonalidade (dados reais) — FIX: proc correta (a v11 não existe)
    CALL staging.sp_calcular_sazonalidade(NULL, NULL);
    RAISE NOTICE '[sp_executar_carga_completa] Sazonalidade (reais) OK';

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
$procedure$;

-- =====================================================================
-- FASE 2 — UNIFICAR FONTE DE VERDADE NA sp_calcular_sazonalidade
-- =====================================================================
-- A versão anterior só gravava preco_medio/media_movel/indice/status/fonte.
-- A partir de agora grava também preco_atual=preco_medio,
-- preco_referencia=preco_medio, preco_mes_anterior=LAG(preco_medio) e
-- variacao_mom_pct derivada de preco_medio (nunca de preco_curado).

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
        preco_atual, preco_referencia, preco_mes_anterior, variacao_mom_pct
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
            WHEN p.media_movel_12m IS NULL OR p.media_movel_12m = 0 THEN 'AMARELO'
            WHEN (p.preco_medio / p.media_movel_12m) < 0.85 THEN 'VERDE'
            WHEN (p.preco_medio / p.media_movel_12m) > 1.15 THEN 'VERMELHO'
            ELSE 'AMARELO'
        END AS status_cor,
        'municipio' AS fonte,
        NOW() AS calculado_em,
        p.preco_medio AS preco_atual,
        p.preco_medio AS preco_referencia,
        p.preco_mes_anterior,
        CASE
            WHEN p.preco_mes_anterior IS NULL OR p.preco_mes_anterior <= 0
                 OR p.preco_medio IS NULL OR p.preco_medio <= 0
            THEN NULL
            ELSE ROUND(((p.preco_medio / p.preco_mes_anterior) - 1) * 100, 4)
        END AS variacao_mom_pct
    FROM precos_12m p
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
        preco_mes_anterior  = EXCLUDED.preco_mes_anterior,
        variacao_mom_pct    = EXCLUDED.variacao_mom_pct;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$procedure$;

-- =====================================================================
-- FASE 3 — CLASSIFICADOR DE ANOMALIA DE PREÇO (reutilizável)
-- =====================================================================
-- Retorna o motivo de rejeição (TEXT) ou NULL se o preço é aceitável.
-- Camada A: preco > média_UF*5 → 'EXCEDE_500PCT_MEDIA_UF'
-- Camada B: preco > 50 sem histórico sólido → 'HARD_CAP_50_SEM_HISTORICO'
--   histórico sólido = UF n>=3 E preco <= média_UF*3
--                      OU global n>=3 E preco <= média_global*3

CREATE OR REPLACE FUNCTION staging.fn_classificar_preco_anomalia(
    p_id_produto     INTEGER,
    p_id_localidade  INTEGER,
    p_ano            SMALLINT,
    p_mes            SMALLINT,
    p_preco          NUMERIC
) RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_uf       CHAR(2);
    v_media_uf NUMERIC(14,4);
    v_n_uf     INTEGER;
    v_media_g  NUMERIC(14,4);
    v_n_g      INTEGER;
BEGIN
    IF p_preco IS NULL OR p_preco <= 0 THEN
        RETURN NULL;
    END IF;

    SELECT uf INTO v_uf
    FROM staging.dim_localidade
    WHERE id_localidade = p_id_localidade;

    -- ----- Camada A: histórico na mesma UF (qualquer município) -----
    IF v_uf IS NOT NULL THEN
        SELECT AVG(f.preco_medio), COUNT(*)
        INTO v_media_uf, v_n_uf
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
        WHERE f.id_produto = p_id_produto
          AND l.uf         = v_uf
          AND NOT (f.ano = p_ano AND f.mes = p_mes)
          AND f.preco_medio IS NOT NULL;

        -- Preço > 500% da média da UF → quarentena (regra original mantida)
        IF v_media_uf IS NOT NULL AND p_preco > (v_media_uf * 5.0) THEN
            RETURN 'EXCEDE_500PCT_MEDIA_UF';
        END IF;
    END IF;

    -- ----- Camada B: hard cap de bom senso (> R$50) -----
    IF p_preco > 50.0 THEN
        -- histórico global (qualquer localidade) excluindo o próprio par
        SELECT AVG(f.preco_medio), COUNT(*)
        INTO v_media_g, v_n_g
        FROM staging.fact_precos_mensais f
        WHERE f.id_produto = p_id_produto
          AND NOT (f.id_localidade = p_id_localidade AND f.ano = p_ano AND f.mes = p_mes)
          AND f.preco_medio IS NOT NULL;

        -- justificado: histórico UF sólido e preço dentro de 3x da média UF
        IF v_uf IS NOT NULL AND v_n_uf >= 3
           AND v_media_uf IS NOT NULL AND p_preco <= (v_media_uf * 3.0) THEN
            RETURN NULL;
        END IF;

        -- justificado: histórico global sólido e preço dentro de 3x da média global
        IF v_n_g >= 3
           AND v_media_g IS NOT NULL AND p_preco <= (v_media_g * 3.0) THEN
            RETURN NULL;
        END IF;

        RETURN 'HARD_CAP_50_SEM_HISTORICO';
    END IF;

    RETURN NULL;
END;
$function$;

-- =====================================================================
-- FASE 3 — TRIGGER BLINDADO (substitui o trigger antigo)
-- =====================================================================

CREATE OR REPLACE FUNCTION staging.trg_valida_anomalia_preco()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_razao      TEXT;
    v_motivo     TEXT;
    v_dados_brutos JSONB;
    v_uf         CHAR(2);
BEGIN
    SELECT uf INTO v_uf
    FROM staging.dim_localidade
    WHERE id_localidade = NEW.id_localidade;

    v_razao := staging.fn_classificar_preco_anomalia(
        NEW.id_produto,
        NEW.id_localidade,
        NEW.ano,
        NEW.mes,
        NEW.preco_medio
    );

    IF v_razao IS NULL THEN
        RETURN NEW;
    END IF;

    v_motivo := CASE v_razao
        WHEN 'EXCEDE_500PCT_MEDIA_UF'
            THEN 'Preço excede 500% da média histórica do mesmo produto na mesma UF'
        WHEN 'HARD_CAP_50_SEM_HISTORICO'
            THEN 'ANOMALIA_PARSING: preço > R$50 sem histórico sólido que justifique'
        ELSE 'Preço anômalo (' || v_razao || ')'
    END;

    v_dados_brutos := jsonb_build_object(
        'produto_id',      NEW.id_produto,
        'localidade_id',   NEW.id_localidade,
        'uf',              v_uf,
        'ano',             NEW.ano,
        'mes',             NEW.mes,
        'preco_enviado',   NEW.preco_medio,
        'razao_codigo',    v_razao
    );

    INSERT INTO staging.precos_rejeitados (
        id_produto, id_localidade, ano, mes,
        preco_medio, preco_medio_historico, razao,
        dados_brutos, batch_id
    ) VALUES (
        NEW.id_produto, NEW.id_localidade, NEW.ano, NEW.mes,
        NEW.preco_medio, NULL,
        v_motivo,
        v_dados_brutos, NEW.batch_id
    );

    RETURN NULL;  -- aborta esta linha, mas não a transação
END;
$function$;

DROP TRIGGER IF EXISTS trg_valida_anomalia_preco ON staging.fact_precos_mensais;
CREATE TRIGGER trg_valida_anomalia_preco
    BEFORE INSERT ON staging.fact_precos_mensais
    FOR EACH ROW
    WHEN (NEW.preco_medio IS NOT NULL)
    EXECUTE FUNCTION staging.trg_valida_anomalia_preco();

-- =====================================================================
-- FASE 3 — LIMPEZA RETROATIVA: mover alvos do fact para precos_rejeitados
-- =====================================================================
-- Backup auditável + DELETE idempotente. Só 2026 (janela da auditoria).

CREATE TABLE IF NOT EXISTS mart.sazonalidade_fact_outliers_backup_58 AS
SELECT f.id_fato, f.id_produto, f.id_localidade, f.ano, f.mes,
       f.preco_medio, f.batch_id, f.loaded_at, f.preco_curado,
       f.is_interpolado, f.fonte,
       staging.fn_classificar_preco_anomalia(
           f.id_produto, f.id_localidade, f.ano, f.mes, f.preco_medio
       ) AS razao
FROM staging.fact_precos_mensais f
WHERE f.ano = 2026
  AND f.preco_medio > 0
   AND staging.fn_classificar_preco_anomalia(
          f.id_produto, f.id_localidade, f.ano, f.mes, f.preco_medio
      ) IS NOT NULL;

DO $$
DECLARE
    v_n BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_n FROM mart.sazonalidade_fact_outliers_backup_58;
    RAISE NOTICE '[58] Backup de outliers do fact: % linhas', v_n;
END;
$$;

-- Insere nos rejeitados (evitando duplicar o que o trigger já pegou)
INSERT INTO staging.precos_rejeitados (
    id_produto, id_localidade, ano, mes,
    preco_medio, preco_medio_historico, razao,
    dados_brutos, batch_id
)
SELECT b.id_produto, b.id_localidade, b.ano, b.mes,
       b.preco_medio, NULL,
       CASE b.razao
           WHEN 'EXCEDE_500PCT_MEDIA_UF'
               THEN 'Preço excede 500% da média histórica do mesmo produto na mesma UF'
           WHEN 'HARD_CAP_50_SEM_HISTORICO'
               THEN 'ANOMALIA_PARSING: preço > R$50 sem histórico sólido que justifique'
           ELSE 'Preço anômalo (' || b.razao || ')'
       END,
       jsonb_build_object(
           'produto_id',    b.id_produto,
           'localidade_id', b.id_localidade,
           'uf',            (SELECT dl.uf FROM staging.dim_localidade dl WHERE dl.id_localidade = b.id_localidade),
           'ano',           b.ano,
           'mes',           b.mes,
           'preco_enviado', b.preco_medio,
           'razao_codigo',  b.razao,
           'origem',        'limpeza_retroativa_58'
       ),
       b.batch_id
FROM mart.sazonalidade_fact_outliers_backup_58 b
WHERE NOT EXISTS (
    SELECT 1 FROM staging.precos_rejeitados r
    WHERE r.id_produto = b.id_produto AND r.id_localidade = b.id_localidade
      AND r.ano = b.ano AND r.mes = b.mes AND r.preco_medio = b.preco_medio
);

-- Delete do fact (somente os alvos identificados)
DELETE FROM staging.fact_precos_mensais f
USING mart.sazonalidade_fact_outliers_backup_58 b
WHERE f.id_fato = b.id_fato;

DO $$
DECLARE
    v_n BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_n FROM mart.sazonalidade_fact_outliers_backup_58;
    RAISE NOTICE '[58] Outliers removidos do fact: % linhas', v_n;
END;
$$;

-- =====================================================================
-- FASE 1b — REPROCESSAMENTO 2026 (puxa MILHO e outros reais presos)
-- =====================================================================

DO $$
DECLARE
    i SMALLINT;
BEGIN
    FOR i IN 1..7 LOOP
        CALL staging.sp_calcular_sazonalidade(2026::smallint, i::smallint);
    END LOOP;
END;
$$;

-- =====================================================================
-- FASE 2 — RECÁLCULO RETROATIVO DO DRIFT (reais no Mart)
-- =====================================================================
-- Recalcula preco_mes_anterior/variacao_mom_pct dos reais via
-- LAG(preco_atual) — corrige os 1.471 divergentes / 106 aberrantes
-- (ex: Batata Doce SP +1768%).

WITH calc AS (
    SELECT
        s.id_produto,
        s.id_localidade,
        s.ano,
        s.mes,
        LAG(s.preco_atual) OVER (
            PARTITION BY s.id_produto, s.id_localidade
            ORDER BY s.ano, s.mes
        ) AS preco_ant
    FROM mart.sazonalidade_produto s
    WHERE s.is_forecast = FALSE
      AND s.preco_atual IS NOT NULL
      AND s.preco_atual > 0
)
UPDATE mart.sazonalidade_produto s
SET preco_mes_anterior = c.preco_ant,
    variacao_mom_pct   = CASE
        WHEN c.preco_ant IS NULL OR c.preco_ant <= 0 THEN NULL
        ELSE ROUND(((s.preco_atual / c.preco_ant) - 1) * 100, 4)
    END
FROM calc c
WHERE s.id_produto = c.id_produto
  AND s.id_localidade = c.id_localidade
  AND s.ano = c.ano
  AND s.mes = c.mes
  AND s.is_forecast = FALSE
  AND s.preco_atual IS NOT NULL
  AND s.preco_atual > 0;

DO $$
DECLARE
    v_n BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_n FROM mart.sazonalidade_produto
    WHERE is_forecast = FALSE AND preco_atual IS NOT NULL AND preco_atual > 0;
    RAISE NOTICE '[58] Reais com preco>0 no Mart: % linhas (variacao recalculada)', v_n;
END;
$$;

COMMIT;

-- =====================================================================
-- FASE 4 — REFRESH DA MATERIALIZED VIEW (fora da transação)
-- =====================================================================

REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- =====================================================================
-- VERIFICAÇÃO MANUAL (executar após aplicar):
--   1) MILHO real 2026 de volta ao Mart:
--      SELECT COUNT(*) FROM mart.sazonalidade_produto
--      WHERE id_produto=10440 AND ano=2026 AND is_forecast=FALSE;
--      -- esperado: ~447
--   2) Preços >50 barrados:
--      SELECT * FROM staging.precos_rejeitados
--      WHERE dados_brutos->>'origem'='limpeza_retroativa_58'
--         OR razao LIKE '%ANOMALIA_PARSING%';
--   3) Drift corrigido (Batata Doce SP 1152/3190 2026-07):
--      SELECT preco_atual, preco_mes_anterior, variacao_mom_pct
--      FROM mart.sazonalidade_produto
--      WHERE id_produto=1152 AND id_localidade=3190 AND ano=2026 AND mes=7;
--      -- esperado: variacao_mom_pct ~ +9% (2.3350 vs 2.1417), NÃO +1768%
--   4) Orquestrador sem erro:
--      CALL staging.sp_executar_carga_completa();
--      -- não deve falhar no passo 4
-- =====================================================================
