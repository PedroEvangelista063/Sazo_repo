-- =============================================================================
-- 04_sazonalidade.sql — 🟢🟡🔴 Monitoramento da sazonalidade (mart)
-- =============================================================================
-- Kit do DBA — Quero Comprar VG
-- Distribuição de status, forecast e transparência de dados históricos.
--
-- Uso: ./conectar_dba.sh -f 04_sazonalidade.sql
-- =============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 4.1  DISTRIBUIÇÃO DE STATUS — semáforo geral (verde/amarelo/vermelho)
-- ────────────────────────────────────────────────────────────────────────────
SELECT status_cor,
       COUNT(*)                                          AS total,
       COUNT(*) FILTER (WHERE is_forecast = TRUE)        AS forecast,
       COUNT(*) FILTER (WHERE is_forecast = FALSE)       AS dado_real
FROM mart.sazonalidade_produto
GROUP BY status_cor
ORDER BY 2 DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 4.2  STATUS POR ANO — evolução do semáforo no tempo
-- ────────────────────────────────────────────────────────────────────────────
SELECT ano, status_cor, COUNT(*) AS total
FROM mart.sazonalidade_produto
GROUP BY ano, status_cor
ORDER BY ano, status_cor;

-- ────────────────────────────────────────────────────────────────────────────
-- 4.3  PROPORÇÃO DE FORECAST — quantos registros são projeção vs dado real
-- ────────────────────────────────────────────────────────────────────────────
SELECT ano,
       COUNT(*) FILTER (WHERE is_forecast = TRUE)  AS forecast,
       COUNT(*) FILTER (WHERE is_forecast = FALSE) AS real,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_forecast = TRUE) / NULLIF(COUNT(*), 0), 1) AS pct_forecast
FROM mart.sazonalidade_produto
GROUP BY ano
ORDER BY ano;

-- ────────────────────────────────────────────────────────────────────────────
-- 4.4  TRANSPARÊNCIA — tipo_dado e ano_referencia (qualidade do dado exibido)
-- ────────────────────────────────────────────────────────────────────────────
SELECT ano,
       tipo_dado,
       COUNT(*) AS total
FROM mart.sazonalidade_produto
GROUP BY ano, tipo_dado
ORDER BY ano, tipo_dado;

-- ────────────────────────────────────────────────────────────────────────────
-- 4.5  MÉTODOS DE FORECAST — quais técnicas foram usadas
-- ────────────────────────────────────────────────────────────────────────────
SELECT forecast_method, COUNT(*) AS total, MIN(baseline_confianca) AS conf_min, MAX(baseline_confianca) AS conf_max
FROM mart.sazonalidade_produto
WHERE is_forecast = TRUE
GROUP BY forecast_method
ORDER BY 2 DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 4.6  TENDÊNCIAS — QUEDA/ALTA/ESTAVEL por produto (top variacões)
-- ────────────────────────────────────────────────────────────────────────────
SELECT p.nome_produto,
       s.tendencia_futura,
       s.variacao_mom_pct,
       s.status_cor
FROM mart.sazonalidade_produto s
JOIN staging.dim_produto p ON p.id_produto = s.id_produto
WHERE s.variacao_mom_pct IS NOT NULL
  AND s.ano = (SELECT MAX(ano) FROM mart.sazonalidade_produto)
ORDER BY ABS(s.variacao_mom_pct) DESC
LIMIT 20;

-- ────────────────────────────────────────────────────────────────────────────
-- 4.7  TOP PRODUTOS POR UF — 5 mais baratos da competência mais recente
-- ────────────────────────────────────────────────────────────────────────────
WITH mais_recente AS (
    SELECT MAX(ano * 100 + mes) AS competencia FROM mart.sazonalidade_produto
)
SELECT p.nome_produto, l.uf, s.status_cor, s.preco_medio
FROM mart.sazonalidade_produto s
JOIN staging.dim_produto p     ON p.id_produto = s.id_produto
JOIN staging.dim_localidade l  ON l.id_localidade = s.id_localidade
JOIN mais_recente mr           ON (s.ano * 100 + s.mes) = mr.competencia
WHERE s.status_cor = 'VERDE'
ORDER BY s.preco_medio ASC
LIMIT 15;
