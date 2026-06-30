-- ============================================================================
-- QUERO COMPRAR — Fase 10: View de Classificação por Z-Score (Desvio Padrão)
-- PostgreSQL 16+  |  Estatística Descritiva para Precificação Inteligente
--
-- MOTIVAÇÃO:
--   A classificação existente (sp_calcular_sazonalidade_baseline) usa
--   thresholds fixos de ±15%. Isso funciona bem para a maioria dos casos,
--   mas não leva em conta a VOLATILIDADE NATURAL de cada produto.
--
--   Exemplo: Banana-prata oscila naturalmente mais que arroz beneficiado.
--   Um threshold fixo de 15% pode classificar Banana como VERMELHA em
--   oscilações sazonais normais, enquanto Arroz mal sai do AMARELO mesmo
--   em picos reais de preço.
--
--   A view Z-Score resolve isso calculando o desvio padrão real dos preços
--   de 2025 para cada produto+localidade. Produtos voláteis têm uma faixa
--   mais larga de "EQUILIBRADO"; produtos estáveis têm uma faixa mais
--   estreita. O resultado é uma classificação ADAPTATIVA.
--
-- REGRA DE CLASSIFICAÇÃO:
--   🟢 OFERTA:      preco_atual <  (media_2025 - 1*desvio_padrao)
--   🟡 EQUILIBRADO: entre ±1 desvio padrão da média de 2025
--   🔴 ALTA:        preco_atual >  (media_2025 + 1*desvio_padrao)
--   ⚪ INSUFICIENTE: sem desvio padrão (stddev NULL ou = 0)
--
-- USO:
--   SELECT * FROM mart.vw_zscore_oferta WHERE status_oferta = 'OFERTA';
--
-- VIEW LEVE (não materializada): calcula em tempo real.
-- Se necessário, criar MATERIALIZED VIEW para alta frequência.
-- ============================================================================

BEGIN;

DROP VIEW IF EXISTS mart.vw_zscore_oferta CASCADE;

CREATE VIEW mart.vw_zscore_oferta AS
WITH estatisticas_2025 AS (
    SELECT
        f.id_produto,
        f.id_localidade,
        AVG(f.preco_medio)     AS media_preco_2025,
        STDDEV(f.preco_medio)  AS desvio_padrao_2025,
        COUNT(*)               AS meses_com_dado
    FROM staging.fact_precos_mensais f
    WHERE f.ano = 2025
      AND f.preco_medio IS NOT NULL
    GROUP BY f.id_produto, f.id_localidade
),
ultimo_preco AS (
    SELECT DISTINCT ON (f.id_produto, f.id_localidade)
        f.id_produto,
        f.id_localidade,
        f.preco_medio       AS preco_atual,
        f.ano,
        f.mes,
        f.ano::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0')
                            AS data_referencia
    FROM staging.fact_precos_mensais f
    WHERE f.preco_medio IS NOT NULL
    ORDER BY f.id_produto, f.id_localidade, f.ano DESC, f.mes DESC
)
SELECT
    u.id_produto,
    p.nome_produto,
    p.classificao_produto,
    p.categoria_b2c,
    l.uf,
    l.municipio_nome        AS municipio,
    l.municipio_id,
    u.ano,
    u.mes,
    u.data_referencia,
    u.preco_atual,
    e.media_preco_2025,
    e.desvio_padrao_2025,
    e.meses_com_dado,
    CASE
        WHEN e.desvio_padrao_2025 IS NULL
          OR e.media_preco_2025 IS NULL
          OR e.meses_com_dado < 2
            THEN 'INSUFICIENTE'
        WHEN e.desvio_padrao_2025 = 0
          AND u.preco_atual < e.media_preco_2025
            THEN 'OFERTA'
        WHEN e.desvio_padrao_2025 = 0
          AND u.preco_atual > e.media_preco_2025
            THEN 'ALTA'
        WHEN e.desvio_padrao_2025 = 0
            THEN 'EQUILIBRADO'
        WHEN u.preco_atual < (e.media_preco_2025 - e.desvio_padrao_2025)
            THEN 'OFERTA'
        WHEN u.preco_atual > (e.media_preco_2025 + e.desvio_padrao_2025)
            THEN 'ALTA'
        ELSE 'EQUILIBRADO'
    END AS status_oferta,
    CASE
        WHEN u.preco_atual IS NOT NULL
         AND e.media_preco_2025 IS NOT NULL
         AND e.media_preco_2025 > 0
         AND e.desvio_padrao_2025 IS NOT NULL
         AND e.desvio_padrao_2025 > 0
            THEN ROUND(
                (u.preco_atual - e.media_preco_2025)
                / e.desvio_padrao_2025::NUMERIC,
                2
            )
        ELSE NULL
    END AS zscore
FROM ultimo_preco u
JOIN estatisticas_2025 e
    ON e.id_produto    = u.id_produto
   AND e.id_localidade = u.id_localidade
JOIN staging.dim_produto p
    ON p.id_produto = u.id_produto
JOIN staging.dim_localidade l
    ON l.id_localidade = u.id_localidade
WHERE p.categoria_b2c = 'ALIMENTO_VAREJO'
ORDER BY status_oferta, p.nome_produto, l.uf;

COMMENT ON VIEW mart.vw_zscore_oferta IS
    'Classificação adaptativa por Z-Score: calcula AVG+STDDEV dos preços'
    'de 2025 por produto+localidade e classifica o último preço como'
    'OFERTA / EQUILIBRADO / ALTA / INSUFICIENTE com base no desvio padrão.';

COMMENT ON COLUMN mart.vw_zscore_oferta.status_oferta IS
    'OFERTA (< 1σ abaixo da média), EQUILIBRADO (dentro de ±1σ), '
    'ALTA (> 1σ acima da média), INSUFICIENTE (dados insuficientes)';

COMMENT ON COLUMN mart.vw_zscore_oferta.zscore IS
    'Z-Score do preço atual: (preco_atual - media_2025) / desvio_padrao_2025. '
    'Negativo = abaixo da média; Positivo = acima da média.';

GRANT SELECT ON mart.vw_zscore_oferta TO role_api_reader;

COMMIT;
