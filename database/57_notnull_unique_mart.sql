-- ============================================================================
-- MIGRATION 57: HARDENING DA MART — NOT NULL + UNIQUE TEMPORAL CANÔNICO
-- ============================================================================
-- CONTEXTO (auditoria de conciliação + migrations 54/55/56):
--   A migration 54 eliminou as 60.519 linhas legadas da era snapshot (todas
--   duplicatas com ano/mes NULL). Este hardening impede que o problema
--   reapareça e padroniza a chave temporal:
--
--     1. NOT NULL em mart.sazonalidade_produto.ano e .mes — a era snapshot
--        gravava apenas data_referencia_atual (ano/mes NULL), criando
--        duplicatas invisíveis para o UNIQUE por (ano, mes). Com NOT NULL,
--        novas linhas legadas são estruturalmente impossíveis.
--
--     2. UNIQUE canônico por (id_produto, id_localidade, data_referencia_atual):
--        é a chave temporal que a migration 23 e os scripts Python
--        (backfill_2024.py, projetar_2026_br.py) usam em ON CONFLICT — que
--        estavam QUEBRADOS no live por falta de constraint correspondente
--        (auditoria: "UNIQUE divergente"). Este UNIQUE conserta essa lacuna.
--
--     3. MANTÉM o UNIQUE (id_produto, id_localidade, ano, mes): os SPs do
--        Sanduíche Sazonal (migrations 40/41/50/56) e o LOCF (39) usam
--        ON CONFLICT por (ano, mes). Dropar este constraint quebraria esses SPs.
--        → Duas constraints equivalentes, servindo ON CONFLICT distintos.
--
--     4. CHECK de coerência: garante data_referencia_atual == 'YYYY-MM'
--        derivado de (ano, mes), tornando as duas UNIQUEs logicamente
--        equivalentes (impede drift futuro entre as chaves).
--
-- VALIDAÇÃO EMPÍRICA PRÉVIA (banco live, pós-migration 54):
--   • 131.799 linhas; data_referencia_atual sempre '^\d{4}-\d{2}$' (0 NULL)
--   • 0 duplicatas por (id_produto, id_localidade, data_referencia_atual)
--   • 0 duplicatas por (id_produto, id_localidade, ano, mes)
--   → as duas UNIQUEs podem coexistir sem conflito.
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: NOT NULL em ano/mes (impede novas linhas legadas)
-- ============================================================================
ALTER TABLE mart.sazonalidade_produto
    ALTER COLUMN ano SET NOT NULL,
    ALTER COLUMN mes SET NOT NULL;

COMMENT ON COLUMN mart.sazonalidade_produto.ano IS
    'Ano do período (NOT NULL desde migration 57 — impede novas linhas legadas da era snapshot).';
COMMENT ON COLUMN mart.sazonalidade_produto.mes IS
    'Mês do período (NOT NULL desde migration 57 — impede novas linhas legadas sem mês).';

-- ============================================================================
-- SEÇÃO 2: CHECK de coerência data_referencia_atual == ano-mes
-- ============================================================================
ALTER TABLE mart.sazonalidade_produto
    DROP CONSTRAINT IF EXISTS chk_data_ref_ano_mes;

ALTER TABLE mart.sazonalidade_produto
    ADD CONSTRAINT chk_data_ref_ano_mes
    CHECK (data_referencia_atual = (ano::TEXT || '-' || LPAD(mes::TEXT, 2, '0')));

COMMENT ON CONSTRAINT chk_data_ref_ano_mes ON mart.sazonalidade_produto IS
    'Garante data_referencia_atual == ano-mes (YYYY-MM). Torna as UNIQUEs por '
    '(ano, mes) e por data_referencia_atual logicamente equivalentes. Migration 57.';

-- ============================================================================
-- SEÇÃO 3: UNIQUE canônico por (id_produto, id_localidade, data_referencia_atual)
-- ============================================================================
-- O UNIQUE existente uq_sazonalidade (id_produto, id_localidade, ano, mes) é
-- MANTIDO para não quebrar os ON CONFLICT dos SPs (sanduíche/LOCF). Este novo
-- UNIQUE por data_referencia_atual conserta o ON CONFLICT da migration 23 e
-- dos scripts Python (backfill_2024.py, projetar_2026_br.py).
ALTER TABLE mart.sazonalidade_produto
    ADD CONSTRAINT uq_sazonalidade_data_ref
    UNIQUE (id_produto, id_localidade, data_referencia_atual);

COMMENT ON CONSTRAINT uq_sazonalidade_data_ref ON mart.sazonalidade_produto IS
    'UNIQUE canônico por (id_produto, id_localidade, data_referencia_atual). '
    'Usado pelos ON CONFLICT da migration 23 e dos scripts Python. '
    'Coexiste com uq_sazonalidade (ano, mes) usado pelos SPs do sanduíche. Migration 57.';

-- Índice de apoio (b-tree DESC para série temporal)
CREATE INDEX IF NOT EXISTS idx_sazonalidade_data_ref
    ON mart.sazonalidade_produto (id_produto, id_localidade, data_referencia_atual DESC);

-- ============================================================================
-- SEÇÃO 4: Resumo observável (convenção de migrations 40/52/53)
-- ============================================================================
DO $$
DECLARE
    v_nulos_ano   INTEGER;
    v_colisoes    INTEGER;
    v_divergentes INTEGER;
BEGIN
    SELECT count(*) INTO v_nulos_ano
    FROM mart.sazonalidade_produto
    WHERE ano IS NULL OR mes IS NULL;

    SELECT count(*) INTO v_colisoes
    FROM (
        SELECT id_produto, id_localidade, data_referencia_atual
        FROM mart.sazonalidade_produto
        GROUP BY 1, 2, 3 HAVING count(*) > 1
    ) d;

    SELECT count(*) INTO v_divergentes
    FROM mart.sazonalidade_produto
    WHERE data_referencia_atual <> (ano::TEXT || '-' || LPAD(mes::TEXT, 2, '0'));

    RAISE NOTICE '[migration_57] ano/mes NULL=% | colisoes (produto,local,data_ref)=% | divergencias data_ref<>ano-mes=%',
        v_nulos_ano, v_colisoes, v_divergentes;
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
-- 1) Sem NULLs:
--    SELECT count(*) FROM mart.sazonalidade_produto WHERE ano IS NULL OR mes IS NULL;  -- 0
--
-- 2) Constraints ativas (devem existir as duas UNIQUEs):
--    SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--    WHERE conrelid = 'mart.sazonalidade_produto'::regclass AND contype IN ('u','p');
-- ============================================================================
