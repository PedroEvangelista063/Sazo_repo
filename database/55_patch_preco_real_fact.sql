-- ============================================================================
-- MIGRATION 55: PATCH DE PREÇO PARA LINHAS REAIS (is_forecast=FALSE)
-- ============================================================================
-- CONTEXTO (auditoria de conciliação — docs/RELATORIO_AUDITORIA_RECONCILIACAO.md):
--   A auditoria Fase 3 encontrou 14.270 linhas reais (is_forecast=FALSE) em
--   mart.sazonalidade_produto com preco_atual NULL/<=0 enquanto
--   staging.fact_precos_mensais possui preço para o MESMO mês exato
--   (produto+localidade+data_referencia_atual).
--
-- DIAGNÓSTICO EMPÍRICO (validado contra o banco live):
--   • 14.270/14.270 têm match exato na fact pelo data_referencia_atual.
--   • mart.preco_medio == fact.preco_medio para as 14.270 (0 divergências)
--     → o preço per-kg da fact é a verdade do registro (mesma base usada na
--     migration 53, validada em 44.467 linhas com razão 1,000).
--   • preco_curado cobre 2.225 das 14.270 (apenas 82 divergem do preco_medio).
--
-- CORREÇÃO (idempotente):
--   preco_atual = fact.preco_medio (verdade per-kg)
--   preco_referencia = existente ou preco_medio
--   status_cor = regra ±15% (fn_status_cor_regra_15); sem referência → AMARELO
--   preco_medio = COALESCE(existente, fact.preco_medio)
--
-- Idempotência: após o patch preco_atual > 0 → a linha sai do filtro
-- (preco_atual IS NULL OR <= 0) em re-execuções.
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: Patch de preço — linhas reais sem preço com fact no mês exato
-- ============================================================================
WITH patch AS (
    SELECT DISTINCT
        s.id_sazonalidade,
        f.preco_medio AS preco_fact
    FROM mart.sazonalidade_produto s
    JOIN staging.fact_precos_mensais f
        ON f.id_produto    = s.id_produto
       AND f.id_localidade = s.id_localidade
       AND f.ano::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0') = s.data_referencia_atual
    WHERE s.is_forecast = FALSE
      AND (s.preco_atual IS NULL OR s.preco_atual <= 0)
)
UPDATE mart.sazonalidade_produto s
SET
    preco_atual        = p.preco_fact,
    preco_referencia   = COALESCE(s.preco_referencia, p.preco_fact),
    preco_medio        = COALESCE(s.preco_medio, p.preco_fact),
    status_cor         = COALESCE(
        staging.fn_status_cor_regra_15(
            p.preco_fact,
            COALESCE(s.preco_referencia, p.preco_fact)
        ),
        s.status_cor
    ),
    calculado_em       = NOW()
FROM patch p
WHERE s.id_sazonalidade = p.id_sazonalidade;

-- ============================================================================
-- SEÇÃO 2: Resumo observável (convenção de migrations 40/52/53)
-- ============================================================================
DO $$
DECLARE
    v_patch    INTEGER;
    v_restante INTEGER;
BEGIN
    SELECT count(*) INTO v_patch
    FROM mart.sazonalidade_produto s
    WHERE s.is_forecast = FALSE
      AND (s.preco_atual IS NULL OR s.preco_atual <= 0)
      AND EXISTS (
          SELECT 1 FROM staging.fact_precos_mensais f
          WHERE f.id_produto = s.id_produto
            AND f.id_localidade = s.id_localidade
            AND f.ano::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0') = s.data_referencia_atual
      );

    SELECT count(*) INTO v_restante
    FROM mart.sazonalidade_produto
    WHERE is_forecast = FALSE
      AND (preco_atual IS NULL OR preco_atual <= 0);

    RAISE NOTICE '[migration_55] reais sem preco com fact pendentes=% | reais sem preco total=%',
        v_patch, v_restante;
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
-- 1) Nenhuma linha real sem preço com fact disponível:
--    SELECT count(*) FROM mart.sazonalidade_produto s
--    WHERE s.is_forecast = FALSE AND (s.preco_atual IS NULL OR s.preco_atual <= 0)
--      AND EXISTS (SELECT 1 FROM staging.fact_precos_mensais f
--                  WHERE f.id_produto = s.id_produto AND f.id_localidade = s.id_localidade
--                    AND f.ano::TEXT || '-' || LPAD(f.mes::TEXT,2,'0') = s.data_referencia_atual);
--
-- 2) Linhas reais sem preço (apenas órfãs, sem fact):
--    SELECT count(*) FROM mart.sazonalidade_produto
--    WHERE is_forecast = FALSE AND (preco_atual IS NULL OR preco_atual <= 0);
-- ============================================================================
