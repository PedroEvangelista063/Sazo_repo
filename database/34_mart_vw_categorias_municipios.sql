-- ============================================================================
-- QUERO COMPRAR — Fase 34: Views mart para categorias e municipios
-- PostgreSQL 16+
--
-- Cria views no schema mart para substituir as queries diretas em staging.*
-- nos endpoints /categorias e /municipios.
--
-- Problema:
--   GET /api/v1/categorias → staging.dim_categoria (M5)
--   GET /api/v1/municipios → staging.dim_localidade  (M5)
--   Regra documentada: API só lê de mart.vw_*
--
-- Solução:
--   mart.vw_categorias → categorias com contagem de produtos
--   mart.vw_municipios → municipios disponíveis por UF
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. mart.vw_categorias
-- ============================================================================

CREATE OR REPLACE VIEW mart.vw_categorias AS
SELECT
    c.id_categoria,
    c.nome_categoria,
    c.descricao,
    COUNT(DISTINCT p.id_produto) AS total_produtos
FROM staging.dim_categoria c
LEFT JOIN staging.dim_produto p
    ON p.id_categoria = c.id_categoria
   AND p.categoria_b2c = 'ALIMENTO_VAREJO'
GROUP BY c.id_categoria, c.nome_categoria, c.descricao
ORDER BY c.nome_categoria;

COMMENT ON VIEW mart.vw_categorias IS
    'Categorias com contagem de produtos B2C (ALIMENTO_VAREJO). Substitui query direta em staging.dim_categoria.';

GRANT SELECT ON mart.vw_categorias TO role_api_reader;


-- ============================================================================
-- 2. mart.vw_municipios
-- ============================================================================

CREATE OR REPLACE VIEW mart.vw_municipios AS
SELECT DISTINCT
    l.uf,
    l.municipio_nome AS municipio
FROM staging.dim_localidade l
WHERE l.municipio_nome IS NOT NULL
  AND l.municipio_nome != ''
ORDER BY l.uf, l.municipio_nome;

COMMENT ON VIEW mart.vw_municipios IS
    'Municípios disponíveis por UF. Substitui query direta em staging.dim_localidade.';

GRANT SELECT ON mart.vw_municipios TO role_api_reader;

COMMIT;
