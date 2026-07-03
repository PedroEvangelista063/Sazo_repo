-- ============================================================================
-- QUERO COMPRAR - Hotfix 20: Trava de Domínio B2C (Filtro Varejo)
-- PostgreSQL 16+  |  Data Leak de Insumos B2B no Frontend B2C
--
-- MOTIVAÇÃO:
--   Ao recuperarmos 100% dos produtos na MV (Fase 19), expusemos
--   acidentalmente produtos de domínio B2B (INSUMO_AGRICOLA) na view
--   que alimenta o frontend de supermercado. Óleo Diesel, Lubrificantes
--   e Óleos Minerais não podem ser exibidos numa interface de alimentos.
--
--   A coluna `dim_produto.classificao_produto` estava vazia para todos
--   os 648 registros. Este hotfix:
--     1. Semaforiza os IDs de produtos B2B como INSUMO_AGRICOLA
--     2. Adiciona a Trava de Domínio na MV (filtro de categoria)
--     3. Exclui também FLORES e OUTROS da dim_categoria
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: Semaforização dos Produtos B2B (classificao_produto)
-- ============================================================================
-- Produtos com nome sugestivo de insumo agrícola são explicitamente
-- marcados como INSUMO_AGRICOLA para remoção da view B2C.
-- Como não há coluna de categoria que os distinga, usamos o padrão
-- semântico do nome do produto (regras de negócio da CEASA/CONAB).

UPDATE staging.dim_produto
SET classificao_produto = 'INSUMO_AGRICOLA'
WHERE id_produto IN (
    880,  -- OLEO DIESEL - NÃO INFORMADO
    860,  -- OLEO LUBRIFICANTE - 2 TEMPOS
    790,  -- OLEO LUBRIFICANTE - 20W40 HAVOLINE
    806,  -- OLEO LUBRIFICANTE - 4 TEMPOS HAVOLINE
    839,  -- OLEO LUBRIFICANTE - 4 TEMPOS MOBIL
    748,  -- OLEO LUBRIFICANTE - 5W40
    805,  -- OLEO LUBRIFICANTE - QUEIMADO
    872,  -- OLEO MINERAL - 350 G/L OLEATO DE ME
    841,  -- OLEO MINERAL - FERSOL 800 G/L ÓLEO
    750,  -- OLEO MINERAL - NÃO INFORMADO
    821,  -- OLEO MINERAL - SYNGENTA PROTEÇÃO DE
    828   -- OLEO MINERAL - TRIONA 800 ML/L ÓLEO
);

-- ============================================================================
-- SEÇÃO 2: Materialized View — com Trava de Domínio B2C
-- ============================================================================
-- Regras da Trava:
--   1. Apenas TRINDADE (VERDE/AMARELO/VERMELHO) — já existente
--   2. Apenas ALIMENTO_VAREJO (categoria_b2c) — gate principal B2C
--   3. Exclusão explícita de domínios B2B:
--        - INSUMO_AGRICOLA  (óleo diesel, lubrificantes, minerais)
--        - MAQUINARIO_FERRAMENTA (tratores, motores)
--        - SERVICO_LOGISTICA (caminhões, transporte)
--   4. Apenas categorias de consumo humano (dim_categoria):
--        - Inclui: FRUTAS, LEGUMES, VERDURAS, PESCADOS, PROTEINAS,
--                  CEREAIS_GRAOS, BEBIDAS, ALIMENTO_VAREJO
--        - Exclui: FLORES (não comestível), OUTROS (indiscriminado)

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
SELECT
    s.id_sazonalidade,
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
    s.status_cor,
    s.fonte,
    s.calculado_em,
    s.metodo_calculo,
    s.variacao_mom_pct          AS variacao_pct
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
ORDER BY s.status_cor, p.nome_produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'View B2C V8 - Trava de Dominio. Exclui: INSUMO_AGRICOLA, MAQUINARIO_FERRAMENTA, SERVICO_LOGISTICA, FLORES, OUTROS.';

CREATE UNIQUE INDEX IF NOT EXISTS idx_vw_sazonalidade_unico
    ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_filtro
    ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_categoria
    ON mart.vw_api_produtos_sazonalidade (categoria);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_produto
    ON mart.vw_api_produtos_sazonalidade (id_produto);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_classificacao
    ON mart.vw_api_produtos_sazonalidade (classificao_produto);

REFRESH MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade;

-- ============================================================================
-- SEÇÃO 3: Validação — confirma exclusão dos INSUMOS
-- ============================================================================

DO $$
DECLARE
    v_total INTEGER;
    v_diesel INTEGER;
    v_lubrificante INTEGER;
    v_mineral INTEGER;
    v_oleo_comestivel INTEGER;
    v_uva INTEGER;
BEGIN
    SELECT count(*) INTO v_total FROM mart.vw_api_produtos_sazonalidade;

    SELECT count(*) INTO v_diesel
    FROM mart.vw_api_produtos_sazonalidade WHERE produto ILIKE '%DIESEL%';

    SELECT count(*) INTO v_lubrificante
    FROM mart.vw_api_produtos_sazonalidade WHERE produto ILIKE '%LUBRIFICANTE%';

    SELECT count(*) INTO v_mineral
    FROM mart.vw_api_produtos_sazonalidade
    WHERE produto ILIKE 'OLEO MINERAL%' OR produto ILIKE 'OLEO DIESEL%' OR produto ILIKE 'OLEO LUBRIFICANTE%';

    SELECT count(*) INTO v_oleo_comestivel
    FROM mart.vw_api_produtos_sazonalidade WHERE produto IN ('OLEO DE BABACU - NÃO INFORMADO', 'OLEO DE COPAIBA - NÃO INFORMADO', 'OLEO DE MURUMURU - NÃO INFORMADO', 'OLEO DE PEQUI - NÃO INFORMADO', 'OLEO DE SOJA - REFINADO', 'OLEO VEGETAL - AGREX''OIL', 'OLEO VEGETAL - AUREO 720 G/L OLEO V', 'OLEO VEGETAL - NÃO INFORMADO');

    SELECT count(*) INTO v_uva
    FROM mart.vw_api_produtos_sazonalidade WHERE produto LIKE 'UVA - INDÚSTRIA NIÁGARA';

    RAISE NOTICE '===== HOTFIX 20: TRAVA DE DOMÍNIO B2C =====';
    RAISE NOTICE 'Produtos na MV (pre-fix 19): 2584';
    RAISE NOTICE 'Produtos na MV (pre-fix 20): 4574';
    RAISE NOTICE 'Produtos na MV (pós-fix 20):  %', v_total;
    RAISE NOTICE 'ÓLEO DIESEL na MV:            % (deve ser 0)', v_diesel;
    RAISE NOTICE 'LUBRIFICANTE na MV:           % (deve ser 0)', v_lubrificante;
    RAISE NOTICE 'OLEO MINERAL/DIESEL na MV:    % (deve ser 0)', v_mineral;
    RAISE NOTICE 'Óleo Comestível na MV:        % (deve ser > 0)', v_oleo_comestivel;
    RAISE NOTICE 'UVA INDÚSTRIA NIÁGARA na MV:  % (deve ser > 0)', v_uva;
    RAISE NOTICE '==========================================';
END $$;

COMMIT;