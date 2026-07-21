-- ============================================================================
-- Migration 35: Drop obsolete 3-param overload of fn_regional_snapshot
-- ============================================================================
--
-- Problema:
--   Migration 32 criou fn_regional_snapshot(TEXT[], INTEGER, TEXT)
--   Migration 33 criou fn_regional_snapshot(TEXT[], INTEGER, TEXT, INTEGER, INTEGER)
--   usando CREATE OR REPLACE FUNCTION com assinatura diferente, criando uma
--   nova sobrecarga em vez de substituir a original.
--
--   Ao chamar fn_regional_snapshot com 3 argumentos, o PostgreSQL não consegue
--   decidir entre:
--     1. A função de 3 parâmetros (match exato)
--     2. A função de 5 parâmetros (com defaults para p_limit e p_offset)
--   Resultado: AmbiguousFunctionError.
--
-- Solução:
--   A função de 5 parâmetros já tem DEFAULT NULL para p_categoria e DEFAULT 2
--   para p_min_ufs, cobrindo todos os casos da função de 3 parâmetros.
--   Removemos a sobrecarga de 3 parâmetros.
--
-- Impacto:
--   Nenhuma chamada existente precisa ser alterada — a 5-param cobre tudo.
-- ============================================================================

DROP FUNCTION mart.fn_regional_snapshot(TEXT[], INTEGER, TEXT);

COMMIT;
