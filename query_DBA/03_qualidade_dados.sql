-- =============================================================================
-- 03_qualidade_dados.sql — 🔍 Qualidade de dados (gaps, órfãos, duplicatas)
-- =============================================================================
-- Kit do DBA — Quero Comprar VG
-- Adaptado do docs/QUERY_CONSULTA_BANCO.md e validado contra o banco local.
--
-- Uso: ./conectar_dba.sh -f 03_qualidade_dados.sql
-- =============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 3.1  GAP DETALHADO POR PRODUTO × LOCALIDADE
--      Mostra quais MESES específicos estão faltando (produtos com dado parcial)
-- ────────────────────────────────────────────────────────────────────────────
WITH periodos AS (
    SELECT generate_series(2024, 2026) AS ano,
           generate_series(1, 12) AS mes
),
gaps_detalhados AS (
    SELECT
        p.id_produto,
        p.nome_produto,
        l.id_localidade,
        l.uf,
        COALESCE(l.municipio_nome, '(agregado UF)') AS localidade,
        COUNT(*) FILTER (WHERE f.id_fato IS NULL)   AS meses_ausentes,
        string_agg(
            CASE WHEN f.id_fato IS NULL
                 THEN per.ano || '-' || LPAD(per.mes::TEXT, 2, '0')
                 ELSE NULL END,
            ', ' ORDER BY per.ano, per.mes
        ) AS quais_meses_faltam,
        COUNT(*) FILTER (WHERE f.id_fato IS NOT NULL) AS meses_presentes
    FROM staging.dim_produto p
    CROSS JOIN staging.dim_localidade l
    CROSS JOIN periodos per
    LEFT JOIN staging.fact_precos_mensais f
        ON f.id_produto = p.id_produto
        AND f.id_localidade = l.id_localidade
        AND f.ano = per.ano AND f.mes = per.mes
    GROUP BY p.id_produto, p.nome_produto, l.id_localidade, l.uf, l.municipio_nome
)
SELECT nome_produto, uf, localidade, meses_ausentes, meses_presentes, quais_meses_faltam
FROM gaps_detalhados
WHERE meses_ausentes > 0 AND meses_presentes > 0
ORDER BY meses_ausentes DESC, nome_produto
LIMIT 50;

-- ────────────────────────────────────────────────────────────────────────────
-- 3.2  RANKING DE PRODUTOS COM MAIS GAPS — taxa de ocupação
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    p.nome_produto,
    COUNT(DISTINCT f.id_localidade)                                    AS localidades_atingidas,
    COUNT(*)                                                           AS total_registros,
    COUNT(DISTINCT f.ano || '-' || LPAD(f.mes::TEXT, 2, '0'))          AS meses_unicos,
    ROUND(COUNT(*)::NUMERIC /
        NULLIF(COUNT(DISTINCT f.id_localidade) *
               COUNT(DISTINCT f.ano || '-' || LPAD(f.mes::TEXT, 2, '0')), 0), 3) AS taxa_ocupacao,
    COALESCE(MIN(f.ano || '-' || LPAD(f.mes::TEXT, 2, '0')), 'NUNCA')  AS primeira_coleta,
    COALESCE(MAX(f.ano || '-' || LPAD(f.mes::TEXT, 2, '0')), 'NUNCA')  AS ultima_coleta
FROM staging.fact_precos_mensais f
JOIN staging.dim_produto p ON p.id_produto = f.id_produto
GROUP BY p.nome_produto
HAVING COUNT(*) > 1
ORDER BY taxa_ocupacao ASC
LIMIT 30;

-- ────────────────────────────────────────────────────────────────────────────
-- 3.3  LOCALIDADES ÓRFÃS — existem na dimensão mas NUNCA receberam dado
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    l.id_localidade,
    l.uf,
    COALESCE(l.municipio_nome, '(agregado UF)') AS localidade,
    l.criado_em::timestamp,
    CASE
        WHEN l.municipio_nome IS NULL OR l.municipio_nome = ''
             THEN 'Agregado UF — normal se não coletado'
        ELSE 'Município sem dado — POSSÍVEL ERRO DE ETL'
    END AS diagnostico
FROM staging.dim_localidade l
WHERE NOT EXISTS (
    SELECT 1 FROM staging.fact_precos_mensais f
    WHERE f.id_localidade = l.id_localidade
)
ORDER BY l.uf, l.municipio_nome;

-- ────────────────────────────────────────────────────────────────────────────
-- 3.4  PRODUTOS ÓRFÃOS — cadastrados mas NUNCA coletados
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    p.id_produto,
    p.nome_produto,
    p.criado_em::timestamp,
    CASE
        WHEN p.nome_produto ~* '(Bacalhau|Camarão|Salmão|Merluza|Lagosta|Peixe|Siri|Polvo|Lula|Mexilhão|Ostra)'
             THEN 'Provável produto sem coleta (nicho/especialidade)'
        WHEN p.nome_produto ~* 'Importada|Importado'
             THEN 'Produto importado — coleta mais rara'
        ELSE 'Suspeito — verificar se deveria ter coleta'
    END AS diagnostico
FROM staging.dim_produto p
WHERE NOT EXISTS (
    SELECT 1 FROM staging.fact_precos_mensais f
    WHERE f.id_produto = p.id_produto
)
ORDER BY diagnostico, p.nome_produto;

-- ────────────────────────────────────────────────────────────────────────────
-- 3.5  DUPLICATAS CANÔNICAS — grupos do MDM (dim_produto_canonico)
--      Mostra produtos que foram unificados em um mestre (normalização M67/M70)
-- ────────────────────────────────────────────────────────────────────────────
SELECT nome_canonico,
       COUNT(*) AS variantes,
       string_agg(nome_produto_original, ' | ') AS originais
FROM mart.dim_produto_canonico
GROUP BY nome_canonico
HAVING COUNT(*) > 1
ORDER BY COUNT(*) DESC
LIMIT 30;

-- ────────────────────────────────────────────────────────────────────────────
-- 3.6  VALORES SUSPEITOS — preços extremos (0, negativos, muito altos)
-- ────────────────────────────────────────────────────────────────────────────
SELECT 'preco_medio <= 0' AS problema, COUNT(*) AS qtd FROM staging.fact_precos_mensais WHERE preco_medio <= 0
UNION ALL
SELECT 'preco_medio NULL', COUNT(*) FROM staging.fact_precos_mensais WHERE preco_medio IS NULL
UNION ALL
SELECT 'status_cor NULL no mart', COUNT(*) FROM mart.sazonalidade_produto WHERE status_cor IS NULL;

-- ────────────────────────────────────────────────────────────────────────────
-- 3.7  PREÇOS REJEITADOS — anomalias barradas pelo trigger (staging.precos_rejeitados)
--      razao explica o motivo (ex: variação > 500% da média histórica)
-- ────────────────────────────────────────────────────────────────────────────
SELECT id_rejeitado,
       id_produto,
       id_localidade,
       ano,
       mes,
       preco_medio,
       preco_medio_historico,
       razao,
       rejeitado_em::timestamp
FROM staging.precos_rejeitados
ORDER BY rejeitado_em DESC
LIMIT 30;

-- ────────────────────────────────────────────────────────────────────────────
-- 3.8  REJEIÇÕES POR MOTIVO — ranking das razões mais comuns
-- ────────────────────────────────────────────────────────────────────────────
SELECT SPLIT_PART(razao, ':', 1) AS categoria, COUNT(*) AS qtd
FROM staging.precos_rejeitados
GROUP BY 1
ORDER BY 2 DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 3.9  VISÃO GERAL DE PRODUTOS COM GAPS — muitas localidades, poucos meses
--      gap_level: GRAVE (<=2 meses/local) · MEDIO (<=6) · OK
-- ────────────────────────────────────────────────────────────────────────────
SELECT p.nome_produto,
       COUNT(DISTINCT f.id_localidade) AS qtd_localidades,
       COUNT(*)                        AS total_registros,
       ROUND(COUNT(*)::NUMERIC / NULLIF(COUNT(DISTINCT f.id_localidade), 0), 1) AS media_meses_por_local,
       CASE
           WHEN ROUND(COUNT(*)::NUMERIC / NULLIF(COUNT(DISTINCT f.id_localidade), 0), 1) <= 2 THEN 'GRAVE'
           WHEN ROUND(COUNT(*)::NUMERIC / NULLIF(COUNT(DISTINCT f.id_localidade), 0), 1) <= 6 THEN 'MEDIO'
           ELSE 'OK'
       END AS gap_level
FROM staging.fact_precos_mensais f
JOIN staging.dim_produto p ON p.id_produto = f.id_produto
GROUP BY p.nome_produto
HAVING COUNT(DISTINCT f.id_localidade) >= 5
ORDER BY media_meses_por_local ASC
LIMIT 50;
