-- ============================================================================
-- MIGRATION 54: DEDUP DE LINHAS LEGADAS SEM ano/mes (SNAPSHOT ERA)
-- ============================================================================
-- CONTEXTO (auditoria de conciliação — docs/RELATORIO_AUDITORIA_RECONCILIACAO.md):
--   A auditoria Fase 3 encontrou 60.519 linhas em mart.sazonalidade_produto
--   com ano/mes NULL (30,5% da tabela) — legadas da era snapshot, quando os
--   SPs gravavam apenas data_referencia_atual.
--
-- DIAGNÓSTICO EMPÍRICO (validado contra o banco live):
--   • 60.519/60.519 linhas sem ano/mes são DUPLICATAS: cada uma possui uma
--     "gêmea" com ano/mes preenchidos na MESMA chave (id_produto,
--     id_localidade, data_referencia_atual). A colisão existe porque o UNIQUE
--     real é (id_produto, id_localidade, ano, mes) e ano/mes NULL nunca
--     colidem — o backfill dessas linhas VIOLARIA o constraint.
--   • Perda de dados = 0: nenhuma linha legada com preço perde valor ao ser
--     removida (toda legada tem gêmea com preço OU fact match exato no mês).
--   • A MV mart.vw_api_produtos_sazonalidade expõe 59.621 duplicatas
--     (produto+uf+municipio+ano+mes duplicados) — corrigir a base corrige a API.
--
-- CORREÇÃO:
--   1. Backups das 60.519 linhas legadas em mart.sazonalidade_legado_backup
--      (arquivo auditável e rollback manual).
--   2. DELETE apenas das linhas sem ano/mes QUE TENHAM gêmea preenchida
--      (guarda EXISTS → idempotente e à prova de linhas órfãs futuras).
--
-- Idempotência: em re-execução, nenhuma linha sem ano/mes resta → 0 afetadas.
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: Backup auditável das linhas legadas
-- ============================================================================
CREATE TABLE IF NOT EXISTS mart.sazonalidade_legado_backup AS
SELECT
    id_sazonalidade,
    id_produto,
    id_localidade,
    ano,
    mes,
    preco_medio,
    media_movel_12m,
    indice_sazonalidade,
    status_cor,
    fonte,
    calculado_em,
    is_forecast,
    tendencia_futura,
    baseline_confianca,
    forecast_method,
    preco_referencia,
    preco_atual,
    data_referencia_atual,
    usou_fallback_12m,
    metodo_calculo,
    variacao_mom_pct,
    preco_mes_anterior,
    preco_estimado
FROM mart.sazonalidade_produto
WHERE (ano IS NULL OR mes IS NULL)
  AND data_referencia_atual ~ '^\\d{4}-\\d{2}$';

COMMENT ON TABLE mart.sazonalidade_legado_backup IS
    'Backup das linhas legadas da era snapshot (ano/mes NULL) removidas pela '
    'Migration 54. Duplicatas de linhas com ano/mes preenchidos na mesma chave. '
    'Mantido para auditoria e rollback manual.';

GRANT SELECT ON mart.sazonalidade_legado_backup TO role_etl_writer;

-- ============================================================================
-- SEÇÃO 2: DELETE das legadas duplicadas (apenas com gêmea preenchida)
-- ============================================================================
DELETE FROM mart.sazonalidade_produto s
WHERE (s.ano IS NULL OR s.mes IS NULL)
  AND s.data_referencia_atual ~ '^\\d{4}-\\d{2}$'
  AND EXISTS (
      SELECT 1
      FROM mart.sazonalidade_produto g
      WHERE g.id_produto    = s.id_produto
        AND g.id_localidade = s.id_localidade
        AND g.ano           = SPLIT_PART(s.data_referencia_atual, '-', 1)::SMALLINT
        AND g.mes           = SPLIT_PART(s.data_referencia_atual, '-', 2)::SMALLINT
  );

-- ============================================================================
-- SEÇÃO 3: Resumo observável (convenção de migrations 40/52/53)
-- ============================================================================
DO $$
DECLARE
    v_backup   INTEGER;
    v_restante INTEGER;
BEGIN
    SELECT count(*) INTO v_backup   FROM mart.sazonalidade_legado_backup;
    SELECT count(*) INTO v_restante FROM mart.sazonalidade_produto WHERE ano IS NULL OR mes IS NULL;
    RAISE NOTICE '[migration_54] legadas backup=% | restantes sem ano/mes=%', v_backup, v_restante;
END
$$;

COMMIT;

-- ============================================================================
-- Refresh da MV (fora da transação — REFRESH ... CONCURRENTLY)
-- ============================================================================
REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- ============================================================================
-- Verificação pós-aplicação (executar manualmente):
--
-- 1) Duplicatas na API devem cair para ~0:
--    SELECT count(*) FROM (
--      SELECT v.id_produto, v.uf, v.municipio_id, v.ano, v.mes
--      FROM mart.vw_api_produtos_sazonalidade v
--      GROUP BY 1,2,3,4,5 HAVING count(*) > 1
--    ) d;
--
-- 2) Nenhuma linha restante sem ano/mes:
--    SELECT count(*) FROM mart.sazonalidade_produto WHERE ano IS NULL OR mes IS NULL;
--
-- 3) Backup auditável:
--    SELECT count(*) FROM mart.sazonalidade_legado_backup;  -- ~60.519
-- ============================================================================
