-- ============================================================================
-- QUERO COMPRAR — Fase 48: Fluxos de Abastecimento (Reimportacao Completa)
-- Descricao: Reimporta todos os 166 fluxos com matching canonico via ORDER BY
--             166 fluxos de 32 produtos
-- PostgreSQL 16+
-- ============================================================================

BEGIN;

-- ============================================================================
-- Passo 1: Limpa tabela para recarga completa
-- ============================================================================
DELETE FROM staging.dim_fluxo_abastecimento;

-- ============================================================================
-- Passo 2: Insere todos os fluxos com matching canonico
--          (ORDER BY qtd_dados DESC garante o produto com mais registros)
-- ============================================================================

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'GO',
       'CEASA-GO',
       'norte',
       'TO',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'baixa',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Manga
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manga',
       'PE',
       'Petrolina/Juazeiro',
       'norte',
       'TO',
       ARRAY[9,10,11,12],
       'alta',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Melancia
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Melancia',
       'TO',
       'Lagoa da Confusão',
       'sudeste',
       'SP',
       ARRAY[6,7,8,9],
       'alta',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MELANCIA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Maçã
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Maçã',
       'RS',
       'Vacaria',
       'norte',
       'TO',
       ARRAY[3,4,5,6],
       'media',
       'Alto',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = 'MACA'
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Carne Bovina
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Carne Bovina',
       'TO',
       'Araguaína',
       'norte',
       'TO',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'autossuficiente',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('CARNE BOVINA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Arroz
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Arroz',
       'TO',
       'Formoso do Araguaia',
       'norte',
       'TO',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'autossuficiente',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ARROZ'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Batata
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata',
       'PR',
       'CEASA Curitiba',
       'norte',
       'TO',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Alto',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tambaqui
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tambaqui',
       'TO',
       'Porto Nacional',
       'norte',
       'TO',
       ARRAY[1,2,3,4],
       'media',
       'Médio',
       'autossuficiente',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TAMBAQUI'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Ovos
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Ovos',
       'GO',
       'Anápolis',
       'norte',
       'TO',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = 'OVOS DE GALINHA'
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Feijão
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Feijão',
       'MG',
       'Unaí',
       'norte',
       'TO',
       ARRAY[1,2,3,4,5],
       'alta',
       'Alto',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = 'FEIJAO COMUM CORES'
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Manga
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manga',
       'PE',
       'Petrolina/Juazeiro',
       'norte',
       'PA',
       ARRAY[8,9,10,11,12],
       'alta',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'GO',
       'CEASA-GO',
       'norte',
       'PA',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'baixa',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Arroz
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Arroz',
       'TO',
       'Formoso do Araguaia',
       'norte',
       'PA',
       ARRAY[6,7,8,9,10],
       'alta',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ARROZ'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Batata
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata',
       'PR',
       'CEASA Curitiba',
       'norte',
       'AM',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Alto',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'GO',
       'CEASA-GO',
       'norte',
       'AM',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'baixa',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Manga
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manga',
       'PE',
       'Petrolina/Juazeiro',
       'norte',
       'AM',
       ARRAY[8,9,10,11],
       'alta',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Batata
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata',
       'PR',
       'CEASA Curitiba',
       'norte',
       'RO',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Alto',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'GO',
       'CEASA-GO',
       'norte',
       'RO',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'baixa',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'GO',
       'CEASA-GO',
       'norte',
       'AC',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'baixa',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'GO',
       'CEASA-GO',
       'norte',
       'RR',
       ARRAY[1,2,3,4,5,6,7,8],
       'media',
       'Alto',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'GO',
       'CEASA-GO',
       'norte',
       'AP',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'baixa',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Manga
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manga',
       'PE',
       'Petrolina/Juazeiro',
       'nordeste',
       'MA',
       ARRAY[8,9,10,11,12],
       'alta',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'GO',
       'CEASA-GO',
       'nordeste',
       'MA',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'baixa',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Manga
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manga',
       'BA',
       'Juazeiro',
       'nordeste',
       'PE',
       ARRAY[9,10,11,12,1,2],
       'alta',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Melão
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Melão',
       'RN',
       'CEASA-RN',
       'nordeste',
       'CE',
       ARRAY[7,8,9,10,11,12],
       'alta',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MELAO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Melão',
       'CE',
       'CEASA-CE',
       'nordeste',
       'RN',
       ARRAY[7,8,9,10],
       'alta',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MELAO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Manga
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manga',
       'PE',
       'Petrolina/Juazeiro',
       'nordeste',
       'CE',
       ARRAY[8,9,10,11,12],
       'alta',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manga',
       'PE',
       'Petrolina/Juazeiro',
       'nordeste',
       'PB',
       ARRAY[8,9,10,11,12],
       'alta',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manga',
       'PE',
       'Petrolina/Juazeiro',
       'nordeste',
       'PI',
       ARRAY[8,9,10,11,12],
       'alta',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Batata
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata',
       'PR',
       'CEASA Curitiba',
       'nordeste',
       'BA',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Alto',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Manga
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manga',
       'BA',
       'Juazeiro',
       'nordeste',
       'SE',
       ARRAY[10,11,12,1,2],
       'alta',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manga',
       'BA',
       'Juazeiro',
       'nordeste',
       'AL',
       ARRAY[10,11,12,1,2],
       'alta',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Banana
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'MG',
       'CEASA-MG',
       'centro-oeste',
       'MS',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'PR',
       'CEASA Curitiba',
       'centro-oeste',
       'MS',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Banana
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'CE',
       'CEASA-CE',
       'centro-oeste',
       'MS',
       ARRAY[1,2,3,4,5,6],
       'alta',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Batata
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata',
       'PR',
       'CEASA Curitiba',
       'centro-oeste',
       'MS',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'GO',
       'CEASA-GO',
       'centro-oeste',
       'DF',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'baixa',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Banana
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'MG',
       'CEASA-MG',
       'centro-oeste',
       'DF',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Batata
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata',
       'PR',
       'CEASA Curitiba',
       'centro-oeste',
       'MT',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Alto',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'GO',
       'CEASA-GO',
       'sudeste',
       'SP',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'baixa',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Banana
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'MG',
       'CEASA-MG',
       'sudeste',
       'SP',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Batata
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata',
       'PR',
       'CEASA Curitiba',
       'sudeste',
       'SP',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Maçã
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Maçã',
       'RS',
       'Vacaria',
       'sudeste',
       'SP',
       ARRAY[3,4,5,6,7],
       'alta',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = 'MACA'
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Manga
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manga',
       'PE',
       'Petrolina/Juazeiro',
       'sudeste',
       'SP',
       ARRAY[8,9,10,11,12],
       'alta',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Feijão
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Feijão',
       'MG',
       'Unaí',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = 'FEIJAO COMUM CORES'
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Batata
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata',
       'PR',
       'CEASA Curitiba',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'GO',
       'CEASA-GO',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'baixa',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'GO',
       'CEASA-GO',
       'sudeste',
       'ES',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'baixa',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Banana
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'MG',
       'CEASA-MG',
       'sudeste',
       'ES',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Manga
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manga',
       'BA',
       'Juazeiro',
       'sudeste',
       'RJ',
       ARRAY[9,10,11,12,1,2],
       'alta',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manga',
       'BA',
       'Juazeiro',
       'sudeste',
       'MG',
       ARRAY[10,11,12,1,2],
       'alta',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'GO',
       'CEASA-GO',
       'sudeste',
       'MG',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'baixa',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Arroz
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Arroz',
       'MT',
       'IMEA-MT',
       'sudeste',
       'SP',
       ARRAY[6,7,8,9,10],
       'alta',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ARROZ'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Banana
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'MG',
       'CEASA-MG',
       'centro-oeste',
       'GO',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'GO',
       'CEASA-GO',
       'centro-oeste',
       'MT',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'baixa',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Ovos
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Ovos',
       'GO',
       'Anápolis',
       'centro-oeste',
       'MS',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = 'OVOS DE GALINHA'
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Batata
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata',
       'PR',
       'CEASA Curitiba',
       'sul',
       'RS',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata',
       'PR',
       'CEASA Curitiba',
       'sul',
       'SC',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Cebola
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Cebola',
       'SC',
       'CEASA-SC',
       'sul',
       'PR',
       ARRAY[11,12,1,2,3],
       'alta',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('CEBOLA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Cebola',
       'SC',
       'CEASA-SC',
       'sul',
       'RS',
       ARRAY[11,12,1,2,3],
       'alta',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('CEBOLA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Maçã
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Maçã',
       'RS',
       'Vacaria',
       'sul',
       'PR',
       ARRAY[3,4,5,6,7],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = 'MACA'
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Maçã',
       'RS',
       'Vacaria',
       'sul',
       'SC',
       ARRAY[3,4,5,6,7],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = 'MACA'
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Manga
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manga',
       'PE',
       'Petrolina/Juazeiro',
       'sul',
       'PR',
       ARRAY[8,9,10,11,12],
       'alta',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manga',
       'PE',
       'Petrolina/Juazeiro',
       'sul',
       'RS',
       ARRAY[8,9,10,11],
       'alta',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Melancia
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Melancia',
       'TO',
       'Lagoa da Confusão',
       'centro-oeste',
       'DF',
       ARRAY[6,7,8,9],
       'alta',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MELANCIA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Carne Bovina
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Carne Bovina',
       'MT',
       'IMEA-MT',
       'sul',
       'PR',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('CARNE BOVINA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Carne Bovina',
       'MT',
       'IMEA-MT',
       'sudeste',
       'SP',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('CARNE BOVINA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Carne Bovina',
       'GO',
       'CEASA-GO',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('CARNE BOVINA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'BA',
       'CEASA-BA',
       'centro-oeste',
       'MS',
       ARRAY[4,5,6,7,8,9,10],
       'alta',
       'Médio',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Banana
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'MG',
       'CEASA-MG',
       'nordeste',
       'CE',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'importado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'SP',
       'CEAGESP',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'SP',
       'CEAGESP',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'SP',
       'CEAGESP',
       'centro-oeste',
       'MS',
       ARRAY[5,6,7,8,9,10],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Banana
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'SP',
       'CEAGESP',
       'sul',
       'PR',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'SP',
       'CEAGESP',
       'sul',
       'PR',
       ARRAY[5,6,7,8,9,10],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Banana
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'SP',
       'CEAGESP',
       'centro-oeste',
       'DF',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Batata
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata',
       'SP',
       'CEAGESP',
       'sul',
       'SC',
       ARRAY[3,4,5,6,7],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Banana
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'SP',
       'CEAGESP',
       'sudeste',
       'ES',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'SP',
       'CEAGESP',
       'sudeste',
       'ES',
       ARRAY[5,6,7,8,9,10],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Carne Bovina
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Carne Bovina',
       'MS',
       'CEASA-MS',
       'sudeste',
       'SP',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('CARNE BOVINA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Carne Bovina',
       'MS',
       'CEASA-MS',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('CARNE BOVINA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'PA',
       'CEASA-PA',
       'norte',
       'AM',
       ARRAY[4,5,6,7,8,9],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Arroz
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Arroz',
       'PA',
       'CEASA-PA',
       'norte',
       'AP',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ARROZ'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Arroz',
       'PA',
       'CEASA-PA',
       'nordeste',
       'MA',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ARROZ'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Banana
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'AM',
       'CEASA-AM',
       'norte',
       'RR',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'AM',
       'CEASA-AM',
       'norte',
       'RO',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'RO',
       'CEASA-RO',
       'norte',
       'AC',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'ES',
       'CEASA-ES',
       'sudeste',
       'RJ',
       ARRAY[4,5,6,7,8,9],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Café
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Café',
       'ES',
       'CEASA-ES',
       'sudeste',
       'MG',
       ARRAY[5,6,7,8,9,10],
       'alta',
       'Alto',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = 'CAFE'
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Banana
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'RJ',
       'CEASA-RJ',
       'sudeste',
       'ES',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'RJ',
       'CEASA-RJ',
       'sudeste',
       'MG',
       ARRAY[4,5,6,7,8,9],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Arroz
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Arroz',
       'MA',
       'CEASA-MA',
       'nordeste',
       'PI',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ARROZ'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Melão
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Melão',
       'RN',
       'CEASA-RN',
       'nordeste',
       'CE',
       ARRAY[7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MELAO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Coco
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Coco',
       'AL',
       'CEASA-AL',
       'nordeste',
       'PE',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('COCO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Banana
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'PB',
       'CEASA-PB',
       'nordeste',
       'PE',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Laranja
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Laranja',
       'SE',
       'CEASA-SE',
       'nordeste',
       'BA',
       ARRAY[3,4,5,6,7,8],
       'alta',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('LARANJA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tomate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tomate',
       'DF',
       'CEASA-DF',
       'centro-oeste',
       'GO',
       ARRAY[4,5,6,7,8,9,10],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TOMATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Açaí
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Açaí',
       'AP',
       'CEASA-AP',
       'norte',
       'PA',
       ARRAY[7,8,9,10,11,12],
       'alta',
       'Alto',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ACAI'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Arroz
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Arroz',
       'PI',
       'CEASA-PI',
       'nordeste',
       'CE',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ARROZ'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Carne Bovina
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Carne Bovina',
       'PA',
       'CEASA-PA',
       'norte',
       'RR',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Alto',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('CARNE BOVINA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Castanha
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Castanha',
       'AC',
       'CEASA-AC',
       'norte',
       'RO',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Alto',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('CASTANHA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Açaí
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Açaí',
       'AC',
       'CEASA-AC',
       'norte',
       'AM',
       ARRAY[7,8,9,10,11,12],
       'alta',
       'Alto',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ACAI'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Arroz
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Arroz',
       'RR',
       'CEASA-RR',
       'norte',
       'AM',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ARROZ'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Banana
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Banana',
       'RR',
       'CEASA-RR',
       'norte',
       'PA',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BANANA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Milho
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Milho',
       'MT',
       'CEASA-MT',
       'sudeste',
       'SP',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MILHO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Milho',
       'PR',
       'CEASA-PR',
       'sul',
       'SC',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MILHO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Milho',
       'GO',
       'CEASA-GO',
       'centro-oeste',
       'DF',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MILHO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Milho',
       'MS',
       'CEASA-MS',
       'sudeste',
       'MG',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MILHO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Milho',
       'PR',
       'CEASA-PR',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MILHO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Leite de Vaca
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Leite de Vaca',
       'MG',
       'CEASA-MG',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('LEITE DE VACA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Leite de Vaca',
       'GO',
       'CEASA-GO',
       'centro-oeste',
       'DF',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('LEITE DE VACA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Leite de Vaca',
       'RS',
       'CEASA-RS',
       'sul',
       'SC',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('LEITE DE VACA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Leite de Vaca',
       'PR',
       'CEASA-PR',
       'sudeste',
       'SP',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('LEITE DE VACA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Leite de Vaca',
       'MG',
       'CEASA-MG',
       'sudeste',
       'ES',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('LEITE DE VACA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Farinha de Mandioca
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Farinha de Mandioca',
       'PA',
       'CEASA-PA',
       'nordeste',
       'MA',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('FARINHA DE MANDIOCA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Farinha de Mandioca',
       'PA',
       'CEASA-PA',
       'norte',
       'AP',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'media',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('FARINHA DE MANDIOCA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Farinha de Mandioca',
       'BA',
       'CEASA-BA',
       'nordeste',
       'SE',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('FARINHA DE MANDIOCA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Farinha de Mandioca',
       'BA',
       'CEASA-BA',
       'nordeste',
       'AL',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('FARINHA DE MANDIOCA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Farinha de Mandioca',
       'PA',
       'CEASA-PA',
       'norte',
       'AM',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'media',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('FARINHA DE MANDIOCA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Batata Doce
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata Doce',
       'SP',
       'CEASA-SP',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA DOCE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata Doce',
       'PR',
       'CEASA-PR',
       'sul',
       'SC',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA DOCE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata Doce',
       'RS',
       'CEASA-RS',
       'sul',
       'SC',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA DOCE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata Doce',
       'SP',
       'CEASA-SP',
       'centro-oeste',
       'DF',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA DOCE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Batata Doce',
       'MG',
       'CEASA-MG',
       'nordeste',
       'BA',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('BATATA DOCE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Alho
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Alho',
       'MG',
       'CEASA-MG',
       'sudeste',
       'SP',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ALHO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Alho',
       'MG',
       'CEASA-MG',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ALHO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Alho',
       'GO',
       'CEASA-GO',
       'centro-oeste',
       'DF',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ALHO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Alho',
       'RS',
       'CEASA-RS',
       'sul',
       'SC',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ALHO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Feijão Comum Preto
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Feijão Comum Preto',
       'PR',
       'CEASA-PR',
       'sudeste',
       'SP',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = 'FEIJAO COMUM PRETO'
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Feijão Comum Preto',
       'PR',
       'CEASA-PR',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = 'FEIJAO COMUM PRETO'
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Feijão Comum Preto',
       'RS',
       'CEASA-RS',
       'sul',
       'SC',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = 'FEIJAO COMUM PRETO'
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Feijão Comum Preto',
       'PR',
       'CEASA-PR',
       'sudeste',
       'MG',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = 'FEIJAO COMUM PRETO'
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Óleo de Soja
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Óleo de Soja',
       'PR',
       'CEASA-PR',
       'sul',
       'SC',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('OLEO DE SOJA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Óleo de Soja',
       'PR',
       'CEASA-PR',
       'sul',
       'RS',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('OLEO DE SOJA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Óleo de Soja',
       'SP',
       'CEASA-SP',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('OLEO DE SOJA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Óleo de Soja',
       'MT',
       'CEASA-MT',
       'centro-oeste',
       'GO',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('OLEO DE SOJA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Óleo de Soja',
       'SP',
       'CEASA-SP',
       'sudeste',
       'MG',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('OLEO DE SOJA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Farinha de Trigo
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Farinha de Trigo',
       'RS',
       'CEASA-RS',
       'sul',
       'SC',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('FARINHA DE TRIGO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Farinha de Trigo',
       'PR',
       'CEASA-PR',
       'sul',
       'SC',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('FARINHA DE TRIGO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Farinha de Trigo',
       'SP',
       'CEASA-SP',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('FARINHA DE TRIGO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Farinha de Trigo',
       'SP',
       'CEASA-SP',
       'sudeste',
       'MG',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('FARINHA DE TRIGO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Farinha de Trigo',
       'PR',
       'CEASA-PR',
       'centro-oeste',
       'DF',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('FARINHA DE TRIGO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Cenoura
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Cenoura',
       'MG',
       'CEASA-MG',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('CENOURA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Cenoura',
       'SP',
       'CEASA-SP',
       'centro-oeste',
       'DF',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('CENOURA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Cenoura',
       'PR',
       'CEASA-PR',
       'sul',
       'SC',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('CENOURA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Cenoura',
       'MG',
       'CEASA-MG',
       'nordeste',
       'BA',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('CENOURA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Mandioca
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Mandioca',
       'PA',
       'CEASA-PA',
       'nordeste',
       'MA',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANDIOCA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Mandioca',
       'PA',
       'CEASA-PA',
       'norte',
       'AP',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'media',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANDIOCA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Mandioca',
       'BA',
       'CEASA-BA',
       'nordeste',
       'SE',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANDIOCA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Mandioca',
       'BA',
       'CEASA-BA',
       'nordeste',
       'AL',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANDIOCA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Abacate
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Abacate',
       'SP',
       'CEASA-SP',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ABACATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Abacate',
       'MG',
       'CEASA-MG',
       'centro-oeste',
       'DF',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ABACATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Abacate',
       'SP',
       'CEASA-SP',
       'centro-oeste',
       'GO',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ABACATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Abacate',
       'SP',
       'CEASA-SP',
       'sul',
       'PR',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ABACATE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Tangerina
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tangerina',
       'SP',
       'CEASA-SP',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TANGERINA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tangerina',
       'SP',
       'CEASA-SP',
       'sul',
       'PR',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TANGERINA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tangerina',
       'MG',
       'CEASA-MG',
       'centro-oeste',
       'DF',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TANGERINA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Tangerina',
       'SP',
       'CEASA-SP',
       'sudeste',
       'MG',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('TANGERINA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Alface
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Alface',
       'SP',
       'CEASA-SP',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ALFACE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Alface',
       'MG',
       'CEASA-MG',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ALFACE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Alface',
       'SP',
       'CEASA-SP',
       'centro-oeste',
       'DF',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ALFACE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Alface',
       'PR',
       'CEASA-PR',
       'sul',
       'SC',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ALFACE'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Manteiga
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manteiga',
       'RS',
       'CEASA-RS',
       'sudeste',
       'SP',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANTEIGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manteiga',
       'SC',
       'CEASA-SC',
       'sudeste',
       'RJ',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANTEIGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manteiga',
       'MG',
       'CEASA-MG',
       'centro-oeste',
       'GO',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANTEIGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Manteiga',
       'MG',
       'CEASA-MG',
       'centro-oeste',
       'DF',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MANTEIGA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- ============================================================================
-- COMMIT
-- ============================================================================
COMMIT;
