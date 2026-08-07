-- =============================================================================
-- 72_poda_radical_produtos_incompletos.sql
-- Poda Radical — "Qualidade sobre Quantidade"
-- -----------------------------------------------------------------------------
-- Remove fisicamente produtos com densidade de dados insuficiente que causam
-- "buracos" no painel (meses sem dado real, dependência de FALLBACK_DIMENSAO).
--
-- Critério de "Produto Completo" (permanece na base):
--   A) >= 12 meses com dado REAL_ATUAL ou HISTORICO_BASE na MV de exibição
--      (mart.vw_api_produtos_sazonalidade), OU
--   B) >= 24 meses no fact de preços (staging.fact_precos_mensais) — dado
--      consistente mesmo que ainda não exposto na MV.
--
-- Produtos que não atendem A nem B são expurgados da dimensão e de todas as
-- dependências (fact, fluxo, status fonte, MDM).
--
-- Execução:
--   1) psql -f database/72_poda_radical_produtos_incompletos.sql
--   2) Executar VACUUM FULL manualmente (instruções no final do script) para
--      liberar espaço físico em disco.
-- =============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1) Selecionar os produtos incompletos (candidatos à remoção)
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE tmp_produtos_remover AS
WITH mv_dens AS (
    SELECT id_produto,
           COUNT(DISTINCT (ano * 100 + mes)) FILTER (
               WHERE tipo_dado IN ('REAL_ATUAL', 'HISTORICO_BASE')
           ) AS meses_reais_mv
    FROM mart.vw_api_produtos_sazonalidade
    GROUP BY id_produto
),
fact_dens AS (
    SELECT dp.id_produto,
           COUNT(DISTINCT (f.ano * 100 + f.mes)) AS meses_fact
    FROM staging.dim_produto dp
    LEFT JOIN staging.fact_precos_mensais f ON f.id_produto = dp.id_produto
    GROUP BY dp.id_produto
)
SELECT dp.id_produto
FROM staging.dim_produto dp
LEFT JOIN mv_dens mv   ON mv.id_produto = dp.id_produto
LEFT JOIN fact_dens fd ON fd.id_produto = dp.id_produto
WHERE COALESCE(mv.meses_reais_mv, 0) < 12
  AND COALESCE(fd.meses_fact, 0)     < 24;

-- Diagnóstico: quantos serão removidos e quantos permanecem
DO $$
DECLARE
    v_remover  bigint;
    v_permanec bigint;
BEGIN
    SELECT count(*) INTO v_remover  FROM tmp_produtos_remover;
    SELECT count(*) INTO v_permanec FROM staging.dim_produto
        WHERE id_produto NOT IN (SELECT id_produto FROM tmp_produtos_remover);
    RAISE NOTICE '[72_poda] produtos a remover: % | permanecem: %', v_remover, v_permanec;
END $$;

-- ----------------------------------------------------------------------------
-- 2) Limpeza das dependências (ordem respeita FKs; deletar dependentes antes)
-- ----------------------------------------------------------------------------
-- 2.1 fluxo de abastecimento (FK com ON DELETE RESTRICT -> delete manual)
DELETE FROM staging.dim_fluxo_abastecimento
WHERE id_produto IN (SELECT id_produto FROM tmp_produtos_remover);

-- 2.2 fato de preços (sem ON DELETE -> delete manual)
DELETE FROM staging.fact_precos_mensais
WHERE id_produto IN (SELECT id_produto FROM tmp_produtos_remover);

-- 2.3 status de fonte por produto (sem ON DELETE -> delete manual)
DELETE FROM staging.status_fonte_produto
WHERE id_produto IN (SELECT id_produto FROM tmp_produtos_remover);

-- 2.4 MDM / produto canônico (FK id_produto_original sem ON DELETE -> manual)
DELETE FROM mart.dim_produto_canonico
WHERE id_produto_original IN (SELECT id_produto FROM tmp_produtos_remover);

-- ----------------------------------------------------------------------------
-- 3) Poda da dimensão
-- ----------------------------------------------------------------------------
DELETE FROM staging.dim_produto
WHERE id_produto IN (SELECT id_produto FROM tmp_produtos_remover);

COMMIT;

-- ----------------------------------------------------------------------------
-- 4) Atualizar a Materialized View (excluir expurgados do painel)
--    CONCURRENTLY: permite consultas durante o refresh (índice único existe)
-- ----------------------------------------------------------------------------
REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- ----------------------------------------------------------------------------
-- 5) Recuperação física de espaço (fora de transação — execução manual)
-- ----------------------------------------------------------------------------
-- VACUUM FULL staging.fact_precos_mensais;
-- VACUUM FULL staging.dim_produto;
-- VACUUM FULL staging.dim_fluxo_abastecimento;
-- VACUUM FULL staging.status_fonte_produto;
-- VACUUM FULL mart.dim_produto_canonico;
-- ANALYZE staging.fact_precos_mensais;
-- ANALYZE staging.dim_produto;
--
-- Verificação pós-poda:
--   SELECT count(*) FROM staging.dim_produto;                          -- esperado: 969
--   SELECT count(*) FROM mart.vw_api_produtos_sazonalidade;            -- deve cair
--   SELECT pg_size_pretty(pg_database_size('quero_comprar'));          -- antes: 460 MB
-- =============================================================================
