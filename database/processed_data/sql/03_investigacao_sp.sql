-- ============================================================================
-- INVESTIGAÇÃO SP — 1.245 gaps jan-jun/2026
-- Contexto: SP tem ~1.245 combinações (produto × mês) sem dado em jan-jun/2026
--           vs ~0 gaps no mesmo período de 2025.
-- Foco: APENAS ALIMENTO_VAREJO (categoria_b2c). Jul-dez/2026 são futuros.
-- ============================================================================

-- ============================================================================
-- BLOCO 0 — Setup: produtos SP + ALIMENTO_VAREJO (CTE reutilizável)
-- ============================================================================
-- Reduz digitação nas queries seguintes.
WITH
sp_alimento AS (
    SELECT
        dp.id_produto,
        dp.nome_produto,
        dp.categoria_b2c,
        dp.classificao_produto,
        dp.id_categoria,
        dp.status_fonte,
        dp.status_imagem
    FROM staging.dim_produto dp
    WHERE dp.categoria_b2c = 'ALIMENTO_VAREJO'
)
-- ↑ Esta CTE é apenas definicional; cada bloco abaixo a redeclara
--   com os JOINs necessários para evitar dependência entre queries.
SELECT 'Setup OK' AS status, COUNT(*) AS produtos_sp_alimento
FROM sp_alimento;


-- ============================================================================
-- BLOCO 1 — PRODUTOS SP: 2025 vs 2026 jan-jun
-- ============================================================================
-- Para cada produto, quantos meses com dado em cada período.
-- Ordenado do produto MAIS presente em 2025 para o MENOS presente.
-- Esperado: maioria dos produtos com 12/12 em 2025 e 0-6/6 em 2026 jan-jun.
-- ============================================================================
WITH
sp_dados AS (
    SELECT
        dp.id_produto,
        dp.nome_produto
    FROM staging.dim_produto dp
    WHERE dp.categoria_b2c = 'ALIMENTO_VAREJO'
),
meses_2025 AS (
    SELECT
        fpm.id_produto,
        COUNT(DISTINCT fpm.mes) AS meses_2025
    FROM staging.fact_precos_mensais fpm
    JOIN sp_dados dp ON fpm.id_produto = dp.id_produto
    JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
    WHERE dl.uf = 'SP'
      AND fpm.ano = 2025
    GROUP BY fpm.id_produto
),
meses_2026_jan_jun AS (
    SELECT
        fpm.id_produto,
        COUNT(DISTINCT fpm.mes) AS meses_2026_jan_jun
    FROM staging.fact_precos_mensais fpm
    JOIN sp_dados dp ON fpm.id_produto = dp.id_produto
    JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
    WHERE dl.uf = 'SP'
      AND fpm.ano = 2026
      AND fpm.mes BETWEEN 1 AND 6
    GROUP BY fpm.id_produto
)
SELECT
    dp.nome_produto,
    COALESCE(m25.meses_2025, 0)        AS meses_2025,
    COALESCE(m26.meses_2026_jan_jun, 0) AS meses_2026_jan_jun,
    CASE
        WHEN COALESCE(m25.meses_2025, 0) = 0 THEN 'SEM BASE 2025'
        WHEN COALESCE(m26.meses_2026_jan_jun, 0) = 0 THEN 'SUMUIU EM 2026'
        WHEN COALESCE(m26.meses_2026_jan_jun, 0) < COALESCE(m25.meses_2025, 0)
            THEN 'COBERTURA PARCIAL'
        ELSE 'OK'
    END AS status
FROM sp_dados dp
LEFT JOIN meses_2025 m25 ON dp.id_produto = m25.id_produto
LEFT JOIN meses_2026_jan_jun m26 ON dp.id_produto = m26.id_produto
ORDER BY COALESCE(m25.meses_2025, 0) DESC, dp.nome_produto;
-- ↑ Produtos com 12 meses em 2025 aparecem primeiro; os que sumiram, no fim.


-- ============================================================================
-- BLOCO 2 — PRODUTOS QUE SUMIRAM EM 2026 (jan-jun)
-- ============================================================================
-- Produtos que existiam consistentemente em 2025 (>=6 meses) e têm ZERO
-- registros em jan-jun/2026. Esses são os candidatos a gap crítico.
-- ============================================================================
WITH
sp_dados AS (
    SELECT
        dp.id_produto,
        dp.nome_produto
    FROM staging.dim_produto dp
    WHERE dp.categoria_b2c = 'ALIMENTO_VAREJO'
),
meses_2025 AS (
    SELECT
        fpm.id_produto,
        COUNT(DISTINCT fpm.mes) AS meses_2025
    FROM staging.fact_precos_mensais fpm
    JOIN sp_dados dp ON fpm.id_produto = dp.id_produto
    JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
    WHERE dl.uf = 'SP'
      AND fpm.ano = 2025
    GROUP BY fpm.id_produto
),
meses_2026_jan_jun AS (
    SELECT
        fpm.id_produto,
        COUNT(DISTINCT fpm.mes) AS meses_2026_jan_jun
    FROM staging.fact_precos_mensais fpm
    JOIN sp_dados dp ON fpm.id_produto = dp.id_produto
    JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
    WHERE dl.uf = 'SP'
      AND fpm.ano = 2026
      AND fpm.mes BETWEEN 1 AND 6
    GROUP BY fpm.id_produto
)
SELECT
    dp.nome_produto,
    m25.meses_2025,
    ARRAY(
        SELECT fpm.mes
        FROM staging.fact_precos_mensais fpm
        JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
        WHERE fpm.id_produto = dp.id_produto
          AND dl.uf = 'SP'
          AND fpm.ano = 2025
        ORDER BY fpm.mes
    ) AS meses_presentes_2025
FROM sp_dados dp
JOIN meses_2025 m25 ON dp.id_produto = m25.id_produto
LEFT JOIN meses_2026_jan_jun m26 ON dp.id_produto = m26.id_produto
WHERE m25.meses_2025 >= 6
  AND COALESCE(m26.meses_2026_jan_jun, 0) = 0
ORDER BY m25.meses_2025 DESC, dp.nome_produto;
-- ↑ Estes produtos estavam ativos em 2025 e simplesmente não aparecem em 2026.
--    Causa possível: falha na carga CONAB, produto descontinuado na fonte,
--    ou problema na classificação semântica (categoria_b2c alterada).


-- ============================================================================
-- BLOCO 3 — COBERTURA PARCIAL (menos meses em 2026 que em 2025)
-- ============================================================================
-- Produtos que existem em ambos os períodos, mas com menos meses de cobertura
-- em 2026 jan-jun do que em 2025. Indica que alguns meses específicos falharam.
-- ============================================================================
WITH
sp_dados AS (
    SELECT
        dp.id_produto,
        dp.nome_produto
    FROM staging.dim_produto dp
    WHERE dp.categoria_b2c = 'ALIMENTO_VAREJO'
),
meses_2025 AS (
    SELECT
        fpm.id_produto,
        COUNT(DISTINCT fpm.mes) AS meses_2025
    FROM staging.fact_precos_mensais fpm
    JOIN sp_dados dp ON fpm.id_produto = dp.id_produto
    JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
    WHERE dl.uf = 'SP'
      AND fpm.ano = 2025
    GROUP BY fpm.id_produto
),
meses_2026_jan_jun AS (
    SELECT
        fpm.id_produto,
        COUNT(DISTINCT fpm.mes) AS meses_2026_jan_jun
    FROM staging.fact_precos_mensais fpm
    JOIN sp_dados dp ON fpm.id_produto = dp.id_produto
    JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
    WHERE dl.uf = 'SP'
      AND fpm.ano = 2026
      AND fpm.mes BETWEEN 1 AND 6
    GROUP BY fpm.id_produto
)
SELECT
    dp.nome_produto,
    m25.meses_2025,
    m26.meses_2026_jan_jun,
    (m25.meses_2025 - m26.meses_2026_jan_jun) AS meses_perdidos,
    CASE
        WHEN m26.meses_2026_jan_jun = 1 THEN 'CRÍTICO — só 1 mês em 2026'
        WHEN m26.meses_2026_jan_jun <= 3 THEN 'ALERTA — menos da metade'
        ELSE 'OBSERVACAO'
    END AS gravidade
FROM sp_dados dp
JOIN meses_2025 m25 ON dp.id_produto = m25.id_produto
JOIN meses_2026_jan_jun m26 ON dp.id_produto = m26.id_produto
WHERE m26.meses_2026_jan_jun < m25.meses_2025
  AND m26.meses_2026_jan_jun > 0
ORDER BY meses_perdidos DESC, dp.nome_produto;
-- ↑ Produtos com maior perda de meses aparecem primeiro.


-- ============================================================================
-- BLOCO 4 — CROSS-CHECK DIM_PRODUTO
-- ============================================================================
-- Verificar se algum produto foi descontinuado, recategorizado, ou perdeu
-- o status ALIMENTO_VAREJO entre 2025 e 2026.
-- Também checa produtos órfãos (sem categoria definida) e produtos que
-- estão na fato mas não têm ALIMENTO_VAREJO.
-- ============================================================================

-- 4a. Produtos SP com dado em 2025 mas que NÃO são ALIMENTO_VAREJO
SELECT
    dp.nome_produto,
    dp.categoria_b2c,
    dp.status_fonte,
    dp.status_imagem,
    COUNT(DISTINCT fpm.mes) AS meses_2025
FROM staging.fact_precos_mensais fpm
JOIN staging.dim_produto dp ON fpm.id_produto = dp.id_produto
JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
WHERE dl.uf = 'SP'
  AND fpm.ano = 2025
  AND (dp.categoria_b2c IS NULL OR dp.categoria_b2c != 'ALIMENTO_VAREJO')
GROUP BY dp.nome_produto, dp.categoria_b2c, dp.status_fonte, dp.status_imagem
ORDER BY meses_2025 DESC;
-- ↑ Se aparecerem produtos aqui, significa que há dados na fato que foram
--   excluídos do radar B2C por recategorização.

-- 4b. Produtos ALIMENTO_VAREJO com status_fonte ou status_imagem anômalo
SELECT
    dp.nome_produto,
    dp.categoria_b2c,
    dp.status_fonte,
    dp.status_imagem,
    dp.classificao_produto
FROM staging.dim_produto dp
WHERE dp.categoria_b2c = 'ALIMENTO_VAREJO'
  AND (dp.status_fonte IS DISTINCT FROM 'CONAB'
       OR dp.status_imagem IS DISTINCT FROM 'DISPONIVEL')
ORDER BY dp.nome_produto;
-- ↑ Produtos com status atípico podem ter sido descontinuados ou estar
--   em processo de revisão manual.

-- 4c. Produtos ALIMENTO_VAREJO que existem na dim_produto mas JAMAIS
--     apareceram na fato para SP (qualquer ano)
SELECT
    dp.nome_produto,
    dp.categoria_b2c,
    dp.classificao_produto
FROM staging.dim_produto dp
WHERE dp.categoria_b2c = 'ALIMENTO_VAREJO'
  AND NOT EXISTS (
      SELECT 1
      FROM staging.fact_precos_mensais fpm
      JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
      WHERE fpm.id_produto = dp.id_produto
        AND dl.uf = 'SP'
  )
ORDER BY dp.nome_produto;
-- ↑ Produtos declarados como ALIMENTO_VAREJO mas sem NENHUM registro em SP.
--    Causa possível: produto novo que ainda não foi carregado para SP.


-- ============================================================================
-- BLOCO 5 — GAP REAL vs MÊS FUTURO
-- ============================================================================
-- Deixar explícito: quantos gaps são REAIS (jan-jun/2026, já deveriam ter
-- sido carregados) vs ESPERADOS (jul-dez/2026, meses futuros).
-- Também compara com 2025 para referência.
-- ============================================================================
WITH
sp_produtos AS (
    SELECT dp.id_produto
    FROM staging.dim_produto dp
    WHERE dp.categoria_b2c = 'ALIMENTO_VAREJO'
),
grade_esperada_2025 AS (
    -- Produtos SP × 12 meses = grade completa para 2025
    SELECT
        p.id_produto,
        m.mes
    FROM sp_produtos p
    CROSS JOIN LATERAL (SELECT generate_series(1, 12) AS mes) m
),
grade_esperada_2026_jan_jun AS (
    -- Produtos SP × 6 meses (jan-jun) = grade parcial para 2026
    SELECT
        p.id_produto,
        m.mes
    FROM sp_produtos p
    CROSS JOIN LATERAL (SELECT generate_series(1, 6) AS mes) m
),
grade_esperada_2026_jul_dez AS (
    -- Produtos SP × 6 meses (jul-dez) = grade futura
    SELECT
        p.id_produto,
        m.mes
    FROM sp_produtos p
    CROSS JOIN LATERAL (SELECT generate_series(7, 12) AS mes) m
),
dados_sp AS (
    SELECT
        fpm.id_produto,
        fpm.mes,
        fpm.ano
    FROM staging.fact_precos_mensais fpm
    JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
    WHERE dl.uf = 'SP'
)
SELECT
    '2025 (completo)' AS periodo,
    COUNT(*) AS combinacoes_esperadas,
    COUNT(*) FILTER (WHERE ex.id_produto IS NULL) AS gaps,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE ex.id_produto IS NULL) / COUNT(*),
        2
    ) AS pct_gap
FROM grade_esperada_2025 g
LEFT JOIN dados_sp ex ON g.id_produto = ex.id_produto
                     AND g.mes = ex.mes
                     AND ex.ano = 2025

UNION ALL

SELECT
    '2026 jan-jun (real)' AS periodo,
    COUNT(*) AS combinacoes_esperadas,
    COUNT(*) FILTER (WHERE ex.id_produto IS NULL) AS gaps,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE ex.id_produto IS NULL) / COUNT(*),
        2
    ) AS pct_gap
FROM grade_esperada_2026_jan_jun g
LEFT JOIN dados_sp ex ON g.id_produto = ex.id_produto
                     AND g.mes = ex.mes
                     AND ex.ano = 2026

UNION ALL

SELECT
    '2026 jul-dez (futuro — ignorar)' AS periodo,
    COUNT(*) AS combinacoes_esperadas,
    COUNT(*) FILTER (WHERE ex.id_produto IS NULL) AS gaps,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE ex.id_produto IS NULL) / COUNT(*),
        2
    ) AS pct_gap
FROM grade_esperada_2026_jul_dez g
LEFT JOIN dados_sp ex ON g.id_produto = ex.id_produto
                     AND g.mes = ex.mes
                     AND ex.ano = 2026;
-- ↑ A última linha (jul-dez) mostra quantos gaps são ESPERADOS por serem
--   meses futuros. O número real de gaps a investigar está na linha
--   "2026 jan-jun (real)".


-- ============================================================================
-- BLOCO 6 — DETALHAMENTO DOS GAPS REAIS (jan-jun/2026)
-- ============================================================================
-- Lista exaustiva de cada (produto, mês) que está faltando em SP
-- no período jan-jun/2026, útil para exportar e cruzar com a CONAB.
-- ============================================================================
WITH
sp_produtos AS (
    SELECT dp.id_produto, dp.nome_produto
    FROM staging.dim_produto dp
    WHERE dp.categoria_b2c = 'ALIMENTO_VAREJO'
),
grade_esperada AS (
    SELECT
        p.id_produto,
        p.nome_produto,
        m.mes
    FROM sp_produtos p
    CROSS JOIN LATERAL (SELECT generate_series(1, 6) AS mes) m
),
dados_sp_2026 AS (
    SELECT DISTINCT
        fpm.id_produto,
        fpm.mes
    FROM staging.fact_precos_mensais fpm
    JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
    WHERE dl.uf = 'SP'
      AND fpm.ano = 2026
      AND fpm.mes BETWEEN 1 AND 6
)
SELECT
    g.nome_produto,
    g.mes AS mes_faltante,
    'GAP REAL — jan-jun/2026' AS tipo
FROM grade_esperada g
LEFT JOIN dados_sp_2026 ex ON g.id_produto = ex.id_produto
                          AND g.mes = ex.mes
WHERE ex.id_produto IS NULL
ORDER BY g.nome_produto, g.mes;
-- ↑ Exporte esta lista para cruzar com o spreadsheet CONAB e identificar
--   quais produtos/meses foram afetados por falha de carga vs dados
--   que a CONAB simplesmente não publicou para SP.
