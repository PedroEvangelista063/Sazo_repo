-- =============================================================================
-- 09_volatilidade_forecast.sql — 📊 Volatilidade, baselines e forecast
-- =============================================================================
-- Kit do DBA — Quero Comprar VG
-- Origem: database/65_limiares_cores_dinamicos_zscore.sql, 30_engine_preditiva_forecast_2026.sql,
--         63_dado_historico_real_transparencia.sql
-- Validado em 2026-08-06 contra o banco local.
--
-- Uso: ./conectar_dba.sh -f 09_volatilidade_forecast.sql
-- =============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 9.1  ESTATÍSTICAS DE VOLATILIDADE (24 meses reais) — base do semáforo ±1σ
--      AVG/STDDEV por (id_produto, id_localidade) na janela dos últimos 24 meses
-- ────────────────────────────────────────────────────────────────────────────
SELECT *
FROM staging.fn_estatisticas_volatilidade_24m()
LIMIT 30;

-- ────────────────────────────────────────────────────────────────────────────
-- 9.2  FUNÇÃO DE SEMÁFORO DINÂMICO — teste direto da regra Z-Score (±1σ)
--      Exemplo: preco_exibido=10, referencia=8, desvio=1.5 → acima de +1σ
-- ────────────────────────────────────────────────────────────────────────────
SELECT staging.fn_status_cor_zscore(10.0, 8.0, 1.5)  AS acima_1sig,
       staging.fn_status_cor_zscore(8.0,  8.0, 1.5)  AS na_media,
       staging.fn_status_cor_zscore(6.0,  8.0, 1.5)  AS abaixo_1sig,
       staging.fn_status_cor_zscore(8.0,  8.0, 0.0)  AS desvio_zero;

-- ────────────────────────────────────────────────────────────────────────────
-- 9.3  LIMIARES GRAVADOS NO MART — desvio_padrao_historico / limites
--      (colunas adicionadas pela migration 65, MV V18)
-- ────────────────────────────────────────────────────────────────────────────
SELECT s.id_produto,
       s.id_localidade,
       s.ano,
       s.mes,
       s.status_cor,
       ROUND(s.desvio_padrao_historico, 2) AS desvio_hist,
       ROUND(s.limite_superior, 2)         AS lim_sup,
       ROUND(s.limite_inferior, 2)         AS lim_inf,
       s.preco_exibido
FROM mart.sazonalidade_produto s
WHERE s.desvio_padrao_historico IS NOT NULL
  AND s.ano = (SELECT MAX(ano) FROM mart.sazonalidade_produto)
  AND s.mes  = (SELECT MAX(mes)  FROM mart.sazonalidade_produto WHERE ano = (SELECT MAX(ano) FROM mart.sazonalidade_produto))
LIMIT 30;

-- ────────────────────────────────────────────────────────────────────────────
-- 9.4  COBERTURA DA ESTATÍSTICA — quantos produtos/localidades têm desvio
-- ────────────────────────────────────────────────────────────────────────────
SELECT COUNT(*)                                              AS total_linhas_mart,
       COUNT(*) FILTER (WHERE desvio_padrao_historico IS NULL) AS sem_estatistica,
       ROUND(100.0 * COUNT(*) FILTER (WHERE desvio_padrao_historico IS NULL)
             / NULLIF(COUNT(*), 0), 1)                       AS pct_sem_estatistica
FROM mart.sazonalidade_produto;

-- ────────────────────────────────────────────────────────────────────────────
-- 9.5  BASELINES DE SAZONALIDADE — moda do status_cor por produto/local/mês
--      24_25 = fallback (confiança reduzida) · 25_26 = primária
-- ────────────────────────────────────────────────────────────────────────────
SELECT 'baseline_24_25' AS baseline, status_cor_mode, COUNT(*), MIN(confianca) AS conf_min, MAX(confianca) AS conf_max
FROM mart.sazonalidade_baseline_24_25
GROUP BY status_cor_mode
UNION ALL
SELECT 'baseline_25_26', status_cor_mode, COUNT(*), MIN(confianca), MAX(confianca)
FROM mart.sazonalidade_baseline_25_26
GROUP BY status_cor_mode
ORDER BY 1, 2;

-- ────────────────────────────────────────────────────────────────────────────
-- 9.6  CONFIABILIDADE DO BASELINE (staging.confianca_baseline)
--      Score 0-100 por produto/localidade; meses_reais vs interpolados
-- ────────────────────────────────────────────────────────────────────────────
SELECT p.nome_produto,
       l.uf,
       cb.score_confianca,
       cb.confiavel_2025,
       cb.meses_reais,
       cb.meses_interpolados,
       ROUND(cb.media_2025_curada, 2) AS media_2025
FROM staging.confianca_baseline cb
JOIN staging.dim_produto     p ON p.id_produto = cb.id_produto
JOIN staging.dim_localidade  l ON l.id_localidade = cb.id_localidade
ORDER BY cb.score_confianca DESC
LIMIT 20;

-- ────────────────────────────────────────────────────────────────────────────
-- 9.7  VIEW ÂNCORA — dado exibido por ano de referência (N → N-1 → N-2)
--      Core da transparência: qual ano real sustenta cada célula
-- ────────────────────────────────────────────────────────────────────────────
SELECT id_produto,
       id_localidade,
       mes,
       ano_referencia,
       tipo_dado,
       idade_dado_anos,
       status_cor,
       preco_exibido,
       fonte
FROM mart.vw_anchor_sazonalidade
WHERE ano_referencia IS NOT NULL
ORDER BY idade_dado_anos DESC
LIMIT 20;

-- ────────────────────────────────────────────────────────────────────────────
-- 9.8  DISTRIBUIÇÃO DO TIPO DE DADO — quanto é REAL vs HISTÓRICO vs FALLBACK
-- ────────────────────────────────────────────────────────────────────────────
SELECT tipo_dado, COUNT(*) AS qtd
FROM mart.vw_anchor_sazonalidade
GROUP BY tipo_dado
ORDER BY qtd DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 9.9  FORECAST POR MÉTODO — quais técnicas foram usadas nas projeções
-- ────────────────────────────────────────────────────────────────────────────
SELECT forecast_method,
       COUNT(*)                                   AS projecoes,
       ROUND(AVG(baseline_confianca), 1)          AS confianca_media,
       MIN(ano * 100 + mes)                       AS de_competencia,
       MAX(ano * 100 + mes)                       AS ate_competencia
FROM mart.sazonalidade_produto
WHERE is_forecast = TRUE
GROUP BY forecast_method
ORDER BY projecoes DESC;
