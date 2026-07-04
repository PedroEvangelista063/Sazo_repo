-- ============================================================================
-- QUERO COMPRAR — Reclassificação de Produtos Órfãos (v1.0.0-rc2)
-- PostgreSQL 16+
--
-- Problema: ~23 produtos classificados como ALIMENTO_VAREJO na dim_produto
-- NUNCA receberam cotação de nenhuma CEASA/fonte, porque são produtos
-- processados (açougue, padaria, industrializados) que CEASAs não vendem.
--
-- Solução: Reclassificar como PRODUTO_PROCESSADO para:
--   1. Limpar as métricas de gap analysis (não são "órfãos", são fora-de-escopo)
--   2. Remover do radar da MV vw_api_produtos_sazonalidade (filtra ALIMENTO_VAREJO)
--   3. Parar de desperdiçar recursos do scraper tentando encontrar preços
-- ============================================================================

BEGIN;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 1 — Produtos com nome explicitamente fora do escopo CEASA
-- (identificados via gap analysis + inspeção manual do CONAB catalog)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Carnes e aves processadas (não vendidas em CEASAs)
UPDATE staging.dim_produto
SET categoria_b2c = 'PRODUTO_PROCESSADO'
WHERE nome_produto IN (
    'CARNE MOIDA',
    'CARNE BOVINA PATINHO',
    'CARNE BOVINA ALCATRA',
    'CARNE BOVINA CONTRA FILE',
    'CARNE SUINA LOMBO',
    'CARNE SUINA PERNIL',
    'FRANGO CONGELADO',
    'FRANGO INTEIRO CONGELADO',
    'PEITO DE FRANGO CONGELADO',
    'CARNE BOVINA SECA'
)
AND categoria_b2c = 'ALIMENTO_VAREJO';

-- Panificação e massas
UPDATE staging.dim_produto
SET categoria_b2c = 'PRODUTO_PROCESSADO'
WHERE nome_produto IN (
    'PAO FRANCES',
    'PAO DE FORMA',
    'PAO DE QUEIJO',
    'MASSA PARA LASANHA',
    'MASSA PARA PAO'
)
AND categoria_b2c = 'ALIMENTO_VAREJO';

-- Industrializados e bebidas
UPDATE staging.dim_produto
SET categoria_b2c = 'PRODUTO_PROCESSADO'
WHERE nome_produto IN (
    'FLOCOS DE MILHO',
    'ERVA MATE CHIMARRAO',
    'ERVA MATE',
    'LEITE EM PO INTEGRAL',
    'LEITE UHT INTEGRAL',
    'IOGURTE NATURAL',
    'MANTEIGA COMUM',
    'QUEIJO MINAS FRESCAL',
    'QUEIJO MUSSARELA'
)
AND categoria_b2c = 'ALIMENTO_VAREJO';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 2 — Varredura auxiliar: qualquer produto ALIMENTO_VAREJO que
-- nunca apareceu na fact_precos_mensais e cujo nome contém palavras-chave
-- de produto processado. Isto captura órfãos não listados explicitamente.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

UPDATE staging.dim_produto
SET categoria_b2c = 'PRODUTO_PROCESSADO'
WHERE id_produto IN (
    SELECT p.id_produto
    FROM staging.dim_produto p
    LEFT JOIN staging.fact_precos_mensais f ON f.id_produto = p.id_produto
    WHERE p.categoria_b2c = 'ALIMENTO_VAREJO'
      AND f.id_fato IS NULL
      AND (
          p.nome_produto ~* '(?i)\b(CARNE|PAO\s|LEITE|QUEIJO|IOGURTE|MANTEIGA|'
                          'MARGARINA|PRESUNTO|SALSICHA|LINGUICA|MORTADELA|'
                          'MACARRAO|MIOJO|BISCOITO|BOLACHA|SUCO|REFRIGERANTE|'
                          'CERVEJA|VINHO|AGUA\s|ACUCAR|CAFE\s|ACHOCOLATADO|'
                          'MINGAU|SORVETE|GELEIA|MOLHO\s|MAIONESE|KETCHUP|'
                          'MOSTARDA|AZEITE|VINAGRE|SAL\s|TEMPERO|CALDO\s|'
                          'FERMENTO|CHOCOLATE|DOCE\s|GOIABADA|BANANADA|'
                          'LEITE CONDENSADO|CREME DE LEITE)\b'
      )
)
AND categoria_b2c = 'ALIMENTO_VAREJO';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 3 — Refresh da Materialized View para refletir a mudança
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 4 — Relatório de impacto
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

DO $$
DECLARE
    v_total_processado INTEGER;
    v_ainda_orfao      INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_total_processado
    FROM staging.dim_produto
    WHERE categoria_b2c = 'PRODUTO_PROCESSADO';

    SELECT COUNT(*) INTO v_ainda_orfao
    FROM staging.dim_produto p
    LEFT JOIN staging.fact_precos_mensais f ON f.id_produto = p.id_produto
    WHERE p.categoria_b2c = 'ALIMENTO_VAREJO'
      AND f.id_fato IS NULL;

    RAISE NOTICE '[reclassifica_orfaos] % produtos movidos para PRODUTO_PROCESSADO', v_total_processado;
    RAISE NOTICE '[reclassifica_orfaos] % produtos AINDA orfaos em ALIMENTO_VAREJO', v_ainda_orfao;
END;
$$;

COMMIT;
