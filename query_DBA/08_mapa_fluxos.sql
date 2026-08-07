-- =============================================================================
-- 08_mapa_fluxos.sql — 🗺️ Mapa regional e fluxos de abastecimento
-- =============================================================================
-- Kit do DBA — Quero Comprar VG
-- Origem: database/46_mapa_regional_completo.sql, 44_dim_fluxo_abastecimento.sql,
--         48_adicionar_novos_fluxos.sql, 60_completar_fluxos_acai_castanha_melao.sql
-- Validado em 2026-08-06 contra o banco local.
--
-- ⚠️ PERFORMANCE: as queries 8.1-8.4 (fluxos) rodam em <1s.
-- As queries da view mart.vw_mapa_regional_completo (8.5-8.7) são OPCIONAIS:
-- a view NÃO é materializada e avalia fn_normalizar_nome_produto() na ordenação
-- → ~75s por query com cache frio. Descomente apenas quando precisar.
--
-- Uso: ./conectar_dba.sh -f 08_mapa_fluxos.sql
-- =============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 8.1  FLUXOS DE ABASTECIMENTO — visão amigável (165-166 fluxos)
--      descricao_tipo: 🟢 Envia para fora / 🔴 Recebe de fora / 🟡 Produção local
-- ────────────────────────────────────────────────────────────────────────────
SELECT id_fluxo,
       produto,
       item_fluxo,
       origem_uf,
       origem_polo,
       destino_uf,
       destino_regiao_id,
       regiao_destino_nome,
       tipo,
       descricao_tipo,
       periodicidade,
       sazonalidade,
       preco_referencial
FROM staging.vw_fluxos_regionais
ORDER BY origem_uf, destino_uf
LIMIT 80;

-- ────────────────────────────────────────────────────────────────────────────
-- 8.2  FLUXOS POR TIPO — exportado / importado / autossuficiente
-- ────────────────────────────────────────────────────────────────────────────
SELECT tipo,
       descricao_tipo,
       COUNT(*)               AS qtd_fluxos,
       COUNT(DISTINCT produto) AS produtos_distintos
FROM staging.vw_fluxos_regionais
GROUP BY tipo, descricao_tipo
ORDER BY qtd_fluxos DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 8.3  FLUXOS ÓRFÃOS — produto do fluxo não existe mais em dim_produto
-- ────────────────────────────────────────────────────────────────────────────
SELECT f.id_fluxo, f.produto_nome, f.origem_uf, f.destino_uf
FROM staging.dim_fluxo_abastecimento f
LEFT JOIN staging.dim_produto p ON p.id_produto = f.id_produto
WHERE p.id_produto IS NULL
ORDER BY f.id_fluxo;

-- ────────────────────────────────────────────────────────────────────────────
-- 8.4  PRODUTOS SEM FLUXO — B2C sem fluxo de abastecimento cadastrado
-- ────────────────────────────────────────────────────────────────────────────
SELECT p.id_produto, p.nome_produto
FROM staging.dim_produto p
LEFT JOIN staging.dim_fluxo_abastecimento f ON f.id_produto = p.id_produto
WHERE f.id_fluxo IS NULL
  AND p.categoria_b2c = 'ALIMENTO_VAREJO'
ORDER BY p.nome_produto
LIMIT 50;

-- ────────────────────────────────────────────────────────────────────────────
-- 8.5  DIMENSÃO CRUA DE FLUXOS — registros com meses (array) e ano_referencia
-- ────────────────────────────────────────────────────────────────────────────
SELECT id_fluxo,
       produto_nome,
       origem_uf,
       destino_uf,
       destino_regiao_id,
       meses,
       tipo,
       ano_referencia,
       criado_em::timestamp
FROM staging.dim_fluxo_abastecimento
ORDER BY id_fluxo
LIMIT 50;

-- ═══════════════════════════════════════════════════════════════════════════
-- OPCIONAL — MAPA REGIONAL (view pesada, ~75s por query com cache frio)
-- Descomente apenas quando precisar do mapa consolidado por UF.
-- ═══════════════════════════════════════════════════════════════════════════

-- -- 8.6  RESUMO POR UF — produtos × tipo de preço × autossuficiente
-- SELECT uf,
--        COUNT(*)                                           AS linhas,
--        COUNT(*) FILTER (WHERE tipo_preco = 'real')        AS com_preco_real,
--        COUNT(*) FILTER (WHERE tipo_preco = 'proxy')       AS com_preco_proxy,
--        COUNT(*) FILTER (WHERE tipo_preco = 'ausente')     AS sem_preco,
--        COUNT(*) FILTER (WHERE autossuficiente)            AS autossuficientes
-- FROM mart.vw_mapa_regional_completo
-- GROUP BY uf
-- ORDER BY uf;

-- -- 8.7  MAPA DE UMA UF — detalhe de produtos (troque 'SP' pela UF desejada)
-- SELECT uf,
--        nome_normalizado,
--        categoria_b2c,
--        status_fonte,
--        autossuficiente,
--        qtd_fluxos,
--        tipo_preco,
--        qtd_registros_preco,
--        qtd_fontes_preco
-- FROM mart.vw_mapa_regional_completo
-- WHERE uf = 'SP'
-- ORDER BY nome_normalizado
-- LIMIT 30;

-- -- 8.8  RELATÓRIO OFICIAL POR UF (função) — MUITO PESADO (>100s)
-- --      Chama fn_normalizar_nome_produto linha a linha sobre o banco inteiro.
-- -- SELECT * FROM staging.fn_relatorio_mapa_regional('AC');  -- p_uf = NULL → nacional
