-- ============================================================================
-- CLEANUP 2020-2023 — Remove dados anteriores a 2024
-- Motivo: manter apenas 2024-2026 no projeto
-- Impacto: staging.fact_precos_mensais → 1.680 linhas (420/ano)
--          Nenhuma outra tabela tem dados pré-2024
-- ============================================================================

BEGIN;

-- Verificação de segurança: quantas linhas serão deletadas
SELECT 'DELETE COUNT' AS operacao, COUNT(*) AS linhas_afetadas
FROM staging.fact_precos_mensais WHERE ano <= 2023;

-- DELETE real
DELETE FROM staging.fact_precos_mensais WHERE ano <= 2023;

-- Verificação pós-delete
SELECT 'REMANESCENTE' AS operacao, ano, COUNT(*)
FROM staging.fact_precos_mensais
GROUP BY ano
ORDER BY ano;

COMMIT;
-- Se algo der errado, troque COMMIT por ROLLBACK
