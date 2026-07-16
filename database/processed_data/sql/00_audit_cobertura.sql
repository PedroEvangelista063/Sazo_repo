-- ============================================================================
-- AUDITORIA DE COBERTURA — CONAB Preços Mensais por UF
-- Fontes originais:
--   https://portaldeinformacoes.conab.gov.br/downloads/arquivos/PrecosMensalUF.txt
--   https://portaldeinformacoes.conab.gov.br/downloads/arquivos/ProhortMensal.txt
--
-- Uso: copie e cole cada bloco no DBeaver (PgSQL)
-- Objetivo: identificar gaps (UF + mês sem dados ou com poucos registros)
--
-- Diagnóstico rápido (07/2026):
--   raw.precos_uf         → 0 registros  (dados já foram para staging)
--   staging.fact_precos_mensais → 42.358 registros (2024-2026, 28 localidades)
--   staging.fato_cotacao_regional → 0 registros (ProHort ainda não carregado)
-- ============================================================================

-- ============================================================================
-- BLOCO 1 — PANORAMA GERAL: total de itens por UF (maior → menor)
-- ============================================================================
-- Quais UFs têm mais / menos dados no agregado?
SELECT
    dl.uf,
    COUNT(*)                                         AS total_itens,
    COUNT(DISTINCT fpm.id_produto)                   AS produtos_distintos,
    COUNT(DISTINCT (fpm.ano, fpm.mes))               AS meses_com_dado,
    MIN(fpm.ano)                                     AS ano_min,
    MAX(fpm.ano)                                     AS ano_max
FROM staging.fact_precos_mensais fpm
JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
GROUP BY dl.uf
ORDER BY total_itens DESC;


-- ============================================================================
-- BLOCO 2 — PANORAMA GERAL: total de itens por (ano, mês) — maior → menor
-- ============================================================================
-- Quais meses têm mais / menos dados (independente de UF)?
SELECT
    ano,
    mes,
    COUNT(*)                                         AS total_itens,
    COUNT(DISTINCT id_produto)                       AS produtos_distintos,
    COUNT(DISTINCT id_localidade)                    AS uf_distintas
FROM staging.fact_precos_mensais
GROUP BY ano, mes
ORDER BY total_itens DESC;


-- ============================================================================
-- BLOCO 3 — COBERTURA DETALHADA: (UF, ano, mês) com total de itens
-- ============================================================================
-- Grade completa: cada linha = uma UF num determinado mês/ano.
-- Ordenado do MAIOR total para o MENOR → gaps ficam no final.
-- Se uma UF aparece com 0 ou poucos itens numa combinação, é um gap.
SELECT
    dl.uf,
    fpm.ano,
    fpm.mes,
    COUNT(*)                                         AS total_itens,
    COUNT(DISTINCT fpm.id_produto)                   AS produtos_distintos
FROM staging.fact_precos_mensais fpm
JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
GROUP BY dl.uf, fpm.ano, fpm.mes
ORDER BY total_itens DESC;
-- ↑ assim os maiores vêm primeiro, os menores (gaps) no final


-- ============================================================================
-- BLOCO 4 — DETECTOR DE GAPS: combinações (UF, ano, mês) sem dados
-- ============================================================================
-- Gera todas as combinações esperadas (27 UFs + BR × anos disponíveis × 12 meses)
-- e marca o que NÃO existe na fato → gaps reais.
-- Requer que a dim_localidade tenha UFs e que haja ao menos 1 registro na fato
-- para determinar o range de anos.
WITH
anos_disponiveis AS (
    SELECT generate_series(
        (SELECT MIN(ano) FROM staging.fact_precos_mensais),
        (SELECT MAX(ano) FROM staging.fact_precos_mensais)
    ) AS ano
),
meses AS (
    SELECT generate_series(1, 12) AS mes
),
ufs AS (
    SELECT uf FROM staging.dim_localidade WHERE uf IS NOT NULL
),
grade_esperada AS (
    SELECT uf, ano, mes
    FROM ufs CROSS JOIN anos_disponiveis CROSS JOIN meses
),
grade_existente AS (
    SELECT dl.uf, fpm.ano, fpm.mes
    FROM staging.fact_precos_mensais fpm
    JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
    GROUP BY dl.uf, fpm.ano, fpm.mes
)
SELECT
    ge.uf,
    ge.ano,
    ge.mes,
    'SEM DADOS' AS status
FROM grade_esperada ge
LEFT JOIN grade_existente ex ON ge.uf = ex.uf
                             AND ge.ano = ex.ano
                             AND ge.mes = ex.mes
WHERE ex.uf IS NULL
ORDER BY ge.uf, ge.ano, ge.mes;
-- ↑ todas as células em branco no grid (UF × ano × mês)


-- ============================================================================
-- BLOCO 5 — GAPS PRIORITÁRIOS: UFs com menos meses de cobertura (2024+)
-- ============================================================================
-- Foco no range atual (2024-2026). UFs com poucos meses = gap.
SELECT
    dl.uf,
    COUNT(DISTINCT (fpm.ano, fpm.mes))                  AS meses_com_dado,
    COUNT(*)                                            AS total_itens,
    COUNT(DISTINCT fpm.id_produto)                      AS produtos_distintos
FROM staging.fact_precos_mensais fpm
JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
WHERE fpm.ano >= 2024
GROUP BY dl.uf
ORDER BY meses_com_dado ASC, total_itens ASC;
-- ↑ UFs com menos meses aparecem primeiro (piores)


-- ============================================================================
-- BLOCO 6 — MAPA DE CALOR: matriz (UF × ano-mês) para 2024+
-- ============================================================================
-- Visão tabular: cada coluna = um mês, cada linha = uma UF.
-- O valor é o total de registros. Célula vazia ou com número baixo = gap.
-- Ideal para copiar pro Excel e aplicar formatação condicional.
SELECT
    dl.uf,
    fpm.ano,
    fpm.mes,
    COUNT(*) AS total_itens
FROM staging.fact_precos_mensais fpm
JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
WHERE fpm.ano >= 2024
GROUP BY dl.uf, fpm.ano, fpm.mes
ORDER BY dl.uf, fpm.ano, fpm.mes;


-- ============================================================================
-- BLOCO 7 — FILTRO LIVRE (use WHERE para refinar)
-- ============================================================================
-- Exemplo: filtrar um ano e uma UF específicos
SELECT
    dl.uf,
    fpm.ano,
    fpm.mes,
    dp.nome_produto,
    fpm.preco_medio,
    fpm.preco_curado,
    fpm.is_interpolado
FROM staging.fact_precos_mensais fpm
JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
JOIN staging.dim_produto     dp ON fpm.id_produto   = dp.id_produto
WHERE 1=1
--  AND dl.uf = 'SP'
--  AND fpm.ano = 2025
--  AND fpm.mes = 6
ORDER BY dl.uf, fpm.ano, fpm.mes, dp.nome_produto;


-- ============================================================================
-- BLOCO 8 — RESUMO EXECUTIVO (uma linha por UF-ano)
-- ============================================================================
SELECT
    dl.uf,
    fpm.ano,
    COUNT(*)                                            AS total_itens,
    COUNT(DISTINCT fpm.mes)                             AS meses_cobertos,
    CASE
        WHEN COUNT(DISTINCT fpm.mes) = 12 THEN 'COMPLETO'
        WHEN COUNT(DISTINCT fpm.mes) >= 9 THEN 'PARCIAL'
        WHEN COUNT(DISTINCT fpm.mes) >= 6 THEN 'CRÍTICO'
        ELSE 'GRAVE'
    END                                                 AS status_cobertura,
    COUNT(DISTINCT fpm.id_produto)                      AS produtos_distintos
FROM staging.fact_precos_mensais fpm
JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
GROUP BY dl.uf, fpm.ano
ORDER BY dl.uf, fpm.ano;
