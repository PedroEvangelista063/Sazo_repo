-- ============================================================================
-- QUERO COMPRAR — Migration 000018: LOCF — Preenchimento de Gaps de 1 Mês
-- PostgreSQL 17+  |  Forward-only  |  Idempotent
--
-- OBJETIVO:
--   Fechar gaps de EXATAMENTE 1 mês na grade sazonal de 2025 usando LOCF
--   (Last Observation Carried Forward): o mês faltante herda o registro do
--   mês anterior da MESMA (id_produto, id_localidade).
--
--   Exemplo motivador: ABACAXI HAVAI (UF SP) tem 11/12 meses em 2025 —
--   falta apenas março/2025. O LOCF copia a linha de fevereiro/2025 para
--   março, marcando is_forecast=TRUE e forecast_method='LOCF_SINGLE_MONTH'
--   para transparência total na API (o frontend sabe que é projeção).
--
--   DETALHES TÉCNICOS:
--     - data_referencia_atual é VARCHAR(7) no formato 'YYYY-MM' (000013),
--       com CHECK chk_data_ref_ano_mes = ano || '-' || lpad(mes,2,'0').
--       As linhas LOCF respeitam essa constraint.
--     - Candidatas: séries (produto, localidade) com EXATAMENTE 11 meses
--       distintos no ano-alvo (falta 1 único mês). O mês faltante precisa
--       ser >= 2 (exige mês anterior no MESMO ano para carregar o valor).
--     - Copia TODAS as demais colunas da linha do mês anterior e ajusta
--       apenas: data_referencia_atual, is_forecast, forecast_method,
--       baseline_confianca (preservado do mês anterior) e calculado_em=NOW().
--     - Escopo: ano 2025 (grade atual). 2024/2026 também têm séries de
--       11 meses (7 e 11 respectivamente) — fora do escopo desta frente;
--       generalizar = trocar a constante 2025 nas CTEs.
--     - Idempotente: anti-join WHERE NOT EXISTS + ON CONFLICT DO NOTHING.
-- ============================================================================

BEGIN;
SET lock_timeout = '30s';

-- ============================================================================
-- SEÇÃO 1: Estender CHECK de forecast_method com 'LOCF_SINGLE_MONTH'
-- ============================================================================
-- Mantém o nome estável `chk_forecast_method` (usado por database/40 e
-- database/41 no padrão DROP+ADD) e preserva todos os valores existentes.
-- Também derruba o possível nome auto-gerado, como os ETLs fazem.
-- ----------------------------------------------------------------------------

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
               'PROXY_HIERARQUICO',
               'SANDUICHE_FATOR_SAZONAL',
               'LOCF_SINGLE_MONTH'           -- ← NOVO: LOCF de gap de 1 mês
           ));

COMMENT ON COLUMN mart.sazonalidade_produto.forecast_method IS
    'Método de geração: NULL=dado real; LOCF_SINGLE_MONTH=última observação carregada para gap de 1 mês; demais=baselines/projeções.';

-- ============================================================================
-- SEÇÃO 2: INSERT — LOCF de gaps de 1 mês (ano 2025)
-- ============================================================================

WITH alvos AS (
    -- Séries (produto, localidade) com EXATAMENTE 11 meses no ano-alvo
    SELECT id_produto, id_localidade, 2025::SMALLINT AS ano
    FROM mart.sazonalidade_produto
    WHERE ano = 2025
    GROUP BY id_produto, id_localidade
    HAVING COUNT(DISTINCT mes) = 11
),
mes_faltante AS (
    -- Único mês 2..12 ausente em cada série-alvo
    SELECT a.id_produto, a.id_localidade, a.ano, gs.mes
    FROM alvos a
    CROSS JOIN LATERAL generate_series(2, 12) AS gs(mes)
    WHERE NOT EXISTS (
        SELECT 1
        FROM mart.sazonalidade_produto s
        WHERE s.id_produto    = a.id_produto
          AND s.id_localidade = a.id_localidade
          AND s.ano           = a.ano
          AND s.mes           = gs.mes
    )
)
INSERT INTO mart.sazonalidade_produto (
    id_produto, id_localidade, ano, mes, data_referencia_atual,
    preco_medio, media_movel_12m, indice_sazonalidade, status_cor, fonte,
    calculado_em, is_forecast, tendencia_futura, baseline_confianca, forecast_method,
    preco_referencia, preco_atual, usou_fallback_12m, preco_estimado,
    metodo_calculo, variacao_mom_pct, preco_mes_anterior
)
SELECT
    f.id_produto,
    f.id_localidade,
    f.ano,
    f.mes,
    f.ano::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0') AS data_referencia_atual,
    ant.preco_medio,
    ant.media_movel_12m,
    ant.indice_sazonalidade,
    ant.status_cor,
    ant.fonte,
    NOW(),
    TRUE,                                        -- is_forecast = TRUE (projeção)
    ant.tendencia_futura,
    ant.baseline_confianca,                      -- preservado do mês anterior
    'LOCF_SINGLE_MONTH',
    ant.preco_referencia,
    ant.preco_atual,
    ant.usou_fallback_12m,
    ant.preco_estimado,
    ant.metodo_calculo,
    ant.variacao_mom_pct,
    ant.preco_mes_anterior
FROM mes_faltante f
JOIN mart.sazonalidade_produto ant
    ON ant.id_produto    = f.id_produto
   AND ant.id_localidade = f.id_localidade
   AND ant.ano           = f.ano
   AND ant.mes           = f.mes - 1            -- mês anterior no mesmo ano
WHERE NOT EXISTS (
    SELECT 1
    FROM mart.sazonalidade_produto s
    WHERE s.id_produto    = f.id_produto
      AND s.id_localidade = f.id_localidade
      AND s.ano           = f.ano
      AND s.mes           = f.mes
)
ON CONFLICT (id_produto, id_localidade, ano, mes) DO NOTHING;

-- ============================================================================
-- SEÇÃO 3: Refresh da MV da API
-- ============================================================================
-- A MV possui índice único idx_vw_sazonalidade_unico (id_sazonalidade),
-- confirmado no banco → REFRESH CONCURRENTLY é seguro.
-- ----------------------------------------------------------------------------

REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- ============================================================================
-- FIM — Migration 000018
-- ============================================================================

COMMIT;
