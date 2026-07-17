-- ============================================================================
-- Migration 007: Materialized Views
-- View principal para a API B2C
-- ============================================================================

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
SELECT
    s.id_sazonalidade,
    p.nome_produto       AS produto,
    l.uf,
    l.municipio_nome     AS municipio,
    l.municipio_id,
    s.ano,
    s.mes,
    s.preco_medio,
    s.media_movel_12m,
    s.indice_sazonalidade,
    s.status_cor,
    s.fonte,
    s.calculado_em
FROM mart.sazonalidade_produto s
JOIN staging.dim_produto    p ON p.id_produto    = s.id_produto
JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
WHERE s.status_cor != 'INSUFICIENTE'
ORDER BY s.ano DESC, s.mes DESC, p.nome_produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'View única para a API consultar — contém produto, localidade e status do semáforo';

CREATE UNIQUE INDEX idx_vw_api_unique
    ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

CREATE INDEX idx_vw_api_filtro
    ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);
