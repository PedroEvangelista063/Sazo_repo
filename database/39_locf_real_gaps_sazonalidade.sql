-- ============================================================================
-- MIGRATION 039 — LOCF (Last Observation Carried Forward) Real
-- PostgreSQL compatível (todas as versões)
--
-- Técnica: COUNT(preco_atual) OVER cria grupos onde NULLs consecutivos
-- herdam o mesmo group_id do último preço não-nulo. MAX() propaga.
-- Funciona para gaps de qualquer profundidade em único passe.
--
-- Fallback chain:
--   1. preco_atual real (se existir)
--   2. LOCF group-and-max — último preço conhecido (qualquer profundidade)
--   3. NOCB group-and-max — próximo preço disponível (qualquer profundidade)
--   4. Média do produto
--
-- Execução:
--   PGPASSWORD=postgres_dev_local psql -h localhost -p 5432 -U postgres \
--     -d quero_comprar -f database/39_locf_real_gaps_sazonalidade.sql
-- ============================================================================

BEGIN;

-- Grade de todos os meses-alvo
WITH grade_meses AS (
    SELECT generate_series(1, 12) AS mes
),
-- Todos os produtos + localidades que existem no período
produtos_loc AS (
    SELECT DISTINCT sp.id_produto, sp.id_localidade
    FROM mart.sazonalidade_produto sp
    WHERE (sp.ano = 2025 AND sp.mes BETWEEN 7 AND 12)
       OR (sp.ano = 2026 AND sp.mes BETWEEN 1 AND 10)
),
-- Grade completa: cada produto+localidade x cada mês
grade_completa AS (
    SELECT pl.id_produto, pl.id_localidade, gm.mes,
           CASE WHEN gm.mes >= 7 THEN 2025 ELSE 2026 END AS ano
    FROM produtos_loc pl
    CROSS JOIN grade_meses gm
    WHERE (gm.mes >= 7 AND gm.mes <= 12)  -- 2025 jul-dez
       OR (gm.mes >= 1 AND gm.mes <= 10)   -- 2026 jan-out
),
-- Dados existentes (precos reais ou sinteticos)
dados_existentes AS (
    SELECT sp.id_produto, sp.id_localidade, sp.ano, sp.mes,
           sp.preco_atual, sp.preco_referencia, sp.status_cor,
           sp.is_forecast, sp.fonte, sp.baseline_confianca,
           sp.usou_fallback_12m, sp.preco_estimado
    FROM mart.sazonalidade_produto sp
    WHERE (sp.ano = 2025 AND sp.mes BETWEEN 7 AND 12)
       OR (sp.ano = 2026 AND sp.mes BETWEEN 1 AND 10)
),
-- Média geral do produto como fallback final
media_produto AS (
    SELECT id_produto, AVG(preco_atual) AS preco_medio
    FROM dados_existentes
    WHERE preco_atual IS NOT NULL AND preco_atual > 0
    GROUP BY id_produto
),
-- Grade com dados LEFT JOINed
grade_com_dados AS (
    SELECT
        gc.id_produto,
        gc.id_localidade,
        gc.ano,
        gc.mes,
        (gc.ano::TEXT || '-' || LPAD(gc.mes::TEXT, 2, '0')) AS data_ref,
        de.preco_atual,
        COALESCE(de.preco_referencia, de.preco_atual) AS preco_referencia,
        COALESCE(de.is_forecast, true) AS is_forecast,
        COALESCE(de.fonte, 'BASELINE_HISTORICO') AS fonte,
        de.baseline_confianca,
        COALESCE(de.usou_fallback_12m, false) AS usou_fallback_12m,
        COALESCE(de.preco_estimado, true) AS preco_estimado,
        COALESCE(de.status_cor, 'AMARELO') AS status_cor_original,
        mp.preco_medio
    FROM grade_completa gc
    LEFT JOIN dados_existentes de
        ON de.id_produto = gc.id_produto
        AND de.id_localidade = gc.id_localidade
        AND de.ano = gc.ano
        AND de.mes = gc.mes
    LEFT JOIN media_produto mp ON mp.id_produto = gc.id_produto
),
-- LOCF: group-and-max — preços NULL herdam o último não-nulo
-- COUNT(preco_atual) incrementa a cada preço real, agrupando NULLs consecutivos
locf_forward AS (
    SELECT *,
        COUNT(preco_atual) OVER (
            PARTITION BY id_produto, id_localidade
            ORDER BY ano, mes
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS grupo_locf
    FROM grade_com_dados
),
locf_filled AS (
    SELECT *,
        COALESCE(
            preco_atual,
            MAX(preco_atual) OVER (
                PARTITION BY id_produto, id_localidade, grupo_locf
                ORDER BY ano, mes
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )
        ) AS preco_locf
    FROM locf_forward
),
-- NOCB: reverse group-and-max — preços NULL herdam o PRÓXIMO não-nulo
nocb_forward AS (
    SELECT *,
        COUNT(preco_atual) OVER (
            PARTITION BY id_produto, id_localidade
            ORDER BY ano DESC, mes DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS grupo_nocb
    FROM locf_filled
),
nocb_filled AS (
    SELECT *,
        COALESCE(
            preco_locf,
            MAX(preco_atual) OVER (
                PARTITION BY id_produto, id_localidade, grupo_nocb
                ORDER BY ano DESC, mes DESC
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ),
            preco_medio
        ) AS preco_final
    FROM nocb_forward
)
-- Inserir/atualizar na sazonalidade_produto
INSERT INTO mart.sazonalidade_produto (
    id_produto, id_localidade, ano, mes,
    data_referencia_atual, preco_atual, preco_referencia,
    status_cor, is_forecast, fonte,
    baseline_confianca, usou_fallback_12m, preco_estimado,
    calculado_em
)
SELECT
    id_produto,
    id_localidade,
    ano,
    mes,
    data_ref,
    ROUND(preco_final, 4),
    COALESCE(preco_referencia, ROUND(preco_final, 4)),
    CASE
        WHEN preco_final IS NULL OR preco_final <= 0 THEN 'AMARELO'
        ELSE status_cor_original
    END AS status_cor_final,
    is_forecast,
    fonte,
    COALESCE(baseline_confianca, 30.0),
    usou_fallback_12m,
    preco_estimado,
    NOW()
FROM nocb_filled
-- Pula produtos sem nenhum preço real (LOCF não cria do nada)
WHERE preco_final IS NOT NULL AND preco_final > 0
ON CONFLICT (id_produto, id_localidade, ano, mes)
DO UPDATE SET
    preco_atual        = EXCLUDED.preco_atual,
    preco_referencia   = EXCLUDED.preco_referencia,
    status_cor         = CASE
                            WHEN EXCLUDED.status_cor = 'AMARELO'
                                AND mart.sazonalidade_produto.status_cor IN ('VERDE','VERMELHO')
                            THEN mart.sazonalidade_produto.status_cor
                            ELSE EXCLUDED.status_cor
                         END,
    is_forecast        = EXCLUDED.is_forecast,
    fonte              = CASE
                            WHEN mart.sazonalidade_produto.fonte = 'municipio'
                            THEN mart.sazonalidade_produto.fonte
                            ELSE EXCLUDED.fonte
                         END,
    baseline_confianca = EXCLUDED.baseline_confianca,
    usou_fallback_12m  = EXCLUDED.usou_fallback_12m,
    preco_estimado     = EXCLUDED.preco_estimado,
    calculado_em       = NOW();

COMMIT;

-- Limpeza: remove registros que ficaram sem preco (produtos sem dados reais)
DELETE FROM mart.sazonalidade_produto
WHERE preco_atual IS NULL
  AND preco_referencia IS NULL
  AND fonte = 'BASELINE_HISTORICO'
  AND ((ano = 2025 AND mes BETWEEN 7 AND 12)
    OR (ano = 2026 AND mes BETWEEN 1 AND 10));

-- Refresh da Materialized View para expor os dados à API
REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
