DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
SELECT
    s.id_sazonalidade,
    s.id_localidade,
    p.id_produto,
    p.nome_produto              AS produto,
    p.classificao_produto,
    p.conab_id_produto,
    p.status_fonte,
    COALESCE(c.nome_categoria, 'ALIMENTO_VAREJO') AS categoria,
    l.uf,
    l.municipio_nome            AS municipio,
    l.municipio_id,
    CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER) AS ano,
    CAST(SPLIT_PART(s.data_referencia_atual, '-', 2) AS INTEGER) AS mes,
    s.preco_referencia,
    s.preco_atual,
    s.data_referencia_atual,
    s.usou_fallback_12m,
    s.preco_estimado,
    s.status_cor,
    s.fonte,
    s.calculado_em,
    s.metodo_calculo,
    s.variacao_mom_pct          AS variacao_pct,
    s.tendencia_futura,
    s.is_forecast,
    s.baseline_confianca,
    s.forecast_method
FROM mart.sazonalidade_produto s
JOIN staging.dim_produto    p ON p.id_produto    = s.id_produto
JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
LEFT JOIN staging.dim_categoria c ON c.id_categoria = p.id_categoria
WHERE s.status_cor IN ('VERDE', 'AMARELO', 'VERMELHO')
  AND p.categoria_b2c = 'ALIMENTO_VAREJO'
  AND (p.classificao_produto IS NULL
       OR p.classificao_produto NOT IN ('INSUMO_AGRICOLA', 'MAQUINARIO_FERRAMENTA', 'SERVICO_LOGISTICA'))
  AND (c.nome_categoria IS NULL
       OR c.nome_categoria NOT IN ('FLORES', 'OUTROS'))
ORDER BY ano, mes, s.is_forecast, s.status_cor, p.nome_produto;
