-- =============================================================================
-- 74_quality_gate_12_meses.sql
-- Quality Gate de 12 Meses — "Completude Mensal Total"
-- -----------------------------------------------------------------------------
-- REGRA DE NEGÓCIO (nova):
--   Só permanecem visíveis no frontend os produtos que possuam dados cobrindo
--   TODOS os 12 meses do ano (Janeiro a Dezembro), usando como base o período
--   histórico 2024-2026:
--
--       COUNT(DISTINCT mes) = 12   (staging.fact_precos_mensais)
--       WHERE ano BETWEEN 2024 AND 2026
--
-- O que esta migration faz:
--   1) Identifica os produtos que NÃO atendem ao Quality Gate (meses < 12 na
--      janela 2024-2026, incluindo produtos com ZERO linhas na janela).
--   2) Expurga fisicamente esses produtos e todas as dependências
--      (fact, sazonalidade, fluxo, status fonte, MDM canônico, dimensão).
--   3) Refresca a Materialized View de exibição — a FastAPI deixa de servir
--      qualquer produto com gaps mensais (Zero CINZA por incompletude).
--
-- POLÍTICA DE BACKUP (Zero-Waste no Remoto):
--   O backup ANTES desta migration foi feito EXCLUSIVAMENTE no banco local e
--   em disco local (database/backups_locais/), via pg_dump:
--     * backup_pre_quality_gate_*.dump            (dump completo custom)
--     * backup_tabelas_afetadas_*.sql             (6 tabelas afetadas, plain)
--     * backup_schema_*.sql                       (schema completo)
--   ESTA MIGRATION NÃO CRIA NENHUMA TABELA ops.*_backup nem roda dump pesado
--   no banco remoto (Aiven) — política de preservação de storage.
--
-- Execução:
--   1) LOCAL:  psql "$DATABASE_URL_LOCAL_BACKUP" -f database/74_quality_gate_12_meses.sql
--   2) REMOTO: psql "$DATABASE_URL"             -f database/74_quality_gate_12_meses.sql
--   3) VACUUM FULL manual (instruções no final do script) para liberar espaço
--      físico em disco.
-- =============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1) Selecionar os produtos que NÃO passam no Quality Gate de 12 meses
-- ----------------------------------------------------------------------------
-- Critério: menos de 12 meses distintos na janela 2024-2026 do fact, OU
-- nenhuma linha na janela (produtos com histórico só fora do período ou
-- zero dados). LEFT JOIN garante que produtos sem linhas na janela entram.
CREATE TEMP TABLE tmp_produtos_remover AS
SELECT dp.id_produto,
       COALESCE(cov.meses, 0) AS meses_na_janela
FROM staging.dim_produto dp
LEFT JOIN (
    SELECT id_produto, COUNT(DISTINCT mes) AS meses
    FROM staging.fact_precos_mensais
    WHERE ano BETWEEN 2024 AND 2026
    GROUP BY id_produto
) cov ON cov.id_produto = dp.id_produto
WHERE COALESCE(cov.meses, 0) < 12;

-- Diagnóstico: quantos serão removidos e quantos permanecem
DO $$
DECLARE
    v_remover   bigint;
    v_permanec  bigint;
    v_janela    bigint;
BEGIN
    SELECT count(*) INTO v_remover  FROM tmp_produtos_remover;
    SELECT count(*) INTO v_permanec FROM staging.dim_produto
        WHERE id_produto NOT IN (SELECT id_produto FROM tmp_produtos_remover);
    SELECT count(*) INTO v_janela   FROM staging.dim_produto;
    RAISE NOTICE '[74_quality_gate] produtos a remover: % | permanecem: % | dim total: %',
        v_remover, v_permanec, v_janela;
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

-- 2.5 sazonalidade (sem FK p/ dim_produto -> delete manual de órfãos)
DELETE FROM mart.sazonalidade_produto
WHERE id_produto IN (SELECT id_produto FROM tmp_produtos_remover);

-- ----------------------------------------------------------------------------
-- 3) Poda da dimensão
-- ----------------------------------------------------------------------------
DELETE FROM staging.dim_produto
WHERE id_produto IN (SELECT id_produto FROM tmp_produtos_remover);

-- ----------------------------------------------------------------------------
-- 4) Prova embutida — contagens pós-expurgo (saída do psql)
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_dim     bigint;
    v_fact    bigint;
    v_saz     bigint;
    v_canon   bigint;
    v_ok_12m  bigint;
BEGIN
    SELECT count(*) INTO v_dim    FROM staging.dim_produto;
    SELECT count(*) INTO v_fact   FROM staging.fact_precos_mensais;
    SELECT count(*) INTO v_saz    FROM mart.sazonalidade_produto;
    SELECT count(*) INTO v_canon  FROM mart.dim_produto_canonico;
    SELECT count(*) INTO v_ok_12m FROM (
        SELECT id_produto FROM staging.fact_precos_mensais
        WHERE ano BETWEEN 2024 AND 2026
        GROUP BY id_produto HAVING COUNT(DISTINCT mes) = 12
    ) t;
    RAISE NOTICE '[74_quality_gate] POS-EXPURGO: dim_produto=% | fact=% | sazonalidade=% | canonico=% | produtos_com_12m_janela=%',
        v_dim, v_fact, v_saz, v_canon, v_ok_12m;
END $$;

COMMIT;

-- ----------------------------------------------------------------------------
-- 5) Atualizar a Materialized View (excluir expurgados do painel)
--    CONCURRENTLY: permite consultas durante o refresh (índice único existe)
-- ----------------------------------------------------------------------------
REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- ----------------------------------------------------------------------------
-- 6) Recuperação física de espaço (fora de transação — execução manual)
--    RODAR NO LOCAL E NO REMOTO, UMA VEZ, APÓS VALIDAÇÃO:
-- ----------------------------------------------------------------------------
-- VACUUM FULL staging.fact_precos_mensais;
-- VACUUM FULL staging.dim_produto;
-- VACUUM FULL staging.dim_fluxo_abastecimento;
-- VACUUM FULL staging.status_fonte_produto;
-- VACUUM FULL mart.dim_produto_canonico;
-- VACUUM FULL mart.sazonalidade_produto;
-- ANALYZE staging.fact_precos_mensais;
-- ANALYZE staging.dim_produto;
-- ANALYZE mart.sazonalidade_produto;
--
-- Verificação pós-poda:
--   SELECT count(*) FROM staging.dim_produto;                      -- esperado: 863
--   SELECT count(*) FROM mart.vw_api_produtos_sazonalidade;        -- deve cair p/ ~210.367
--   SELECT count(DISTINCT id_produto) FROM mart.vw_api_produtos_sazonalidade;  -- esperado: 468
--   SELECT pg_size_pretty(pg_database_size('quero_comprar'));      -- local antes: 464 MB
-- =============================================================================
