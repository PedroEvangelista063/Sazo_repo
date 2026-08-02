-- ============================================================================
-- QUERO COMPRAR — verify_synthetic_off.sql  (RED/GREEN assertions — Slice 1)
-- ----------------------------------------------------------------------------
-- Change: refatoracao-dado-historico  (Slice 1 — DB, PR #1)
--
-- OBJETIVO:
--   Script de verificação (TDD) que prova que as engines sintéticas estão
--   DESATIVADAS e que a migração 63 (transparência de dado histórico real)
--   está aplicada. Serve de RED (falha contra o schema pré-migração) e de
--   GREEN (passa contra o schema pós-migração).
--
-- EXECUÇÃO:
--   psql -U postgres -h localhost -d <db> -v ON_ERROR_STOP=1 \
--        -f scripts/verify_synthetic_off.sql
--
--   Qualquer assertion violada dispara RAISE EXCEPTION → psql sai com erro
--   (exit != 0). "OK:" em NOTICE = assertion satisfeita.
--
-- ASSERTIONS (a) pg_proc / (b) pg_constraint / (c) MV V17:
--   (a) sp_executar_carga_completa NÃO contém CALL ativo para
--       sp_calcular_forecast_2026_v13 nem sp_project_sandwich_prices_2026
--       (S8 / R-ADD-06). A regex exige "CALL" no início da linha (após
--       whitespace) — um "-- CALL ..." comentado NÃO casa.
--   (b) Constraintes sobreviventes: uq_sazonalidade, uq_sazonalidade_data_ref,
--       chk_sazonalidade_tipo_dado (nova) e chk_data_ref_ano_mes (YYYY-MM)
--       (S10 / R-ADD-07).
--   (c) MV V17: branch B (id_sazonalidade < 0) só existe em ano = ANO_ATUAL
--       com ano_referencia < ANO_ATUAL; nenhuma duplicata
--       (id_produto, id_localidade, ano, mes) na MV (sem double-count entre
--       branches A/B/C); colunas de transparência presentes (R-ADD-05).
--
-- ASSERTIONS DE ARQUIVO (grep — rodar fora do psql; documentadas para o
-- verify/deploy phase). O padrão é ANCORADO (^ + whitespace): a linha de
-- audit trail "-- CALL ... (desativado)" NÃO casa (começa com "--"),
-- portanto o count esperado é 0 em ambos os arquivos:
--   1.  grep -cE '^\s*CALL staging\.sp_calcular_forecast_2026_v13' \
--         database/63_dado_historico_real_transparencia.sql  → 0
--   2.  grep -cE '^\s*CALL staging\.sp_calcular_forecast_2026_v13' \
--         supabase/migrations/000021_desativar_engines_sinteticas.sql  → 0
--   3.  grep -cE '^\s*CALL staging\.sp_project_sandwich_prices_2026' \
--         database/63_dado_historico_real_transparencia.sql  → 0
--   4.  grep -cE '^\s*CALL staging\.sp_project_sandwich_prices_2026' \
--         supabase/migrations/000021_desativar_engines_sinteticas.sql  → 0
--   5.  grep -c "sp_calcular_sazonalidade_preditiva" \
--         pipeline/run_bulk_historical_fill.py  → 0
--      (path de recálculo agora é real-only; docstring atualizada)
--   6.  deploy_v13_prod.sh: linha de "database/63" e "000021" ANTES da
--      seção "CALL staging.sp_executar_carga_completa":
--      grep -n "63_dado_historico\|000021_desativar\|sp_executar_carga_completa" \
--         scripts/deploy_v13_prod.sh
--   7.  Guard pós-CALL no deploy: grep -n "is_forecast" scripts/deploy_v13_prod.sh
-- ============================================================================

-- (a) pg_proc — engines sintéticas fora do orchestrator -----------------------
DO $$
DECLARE
    v_calls INTEGER;
    v_body  TEXT;
BEGIN
    SELECT prosrc INTO v_body
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'staging' AND p.proname = 'sp_executar_carga_completa';

    IF v_body IS NULL THEN
        RAISE EXCEPTION 'RED/GREEN falhou: staging.sp_executar_carga_completa não existe';
    END IF;

    -- CALL ativo = "CALL" no início de linha (após whitespace); comentado não casa
    SELECT count(*)
    INTO v_calls
    FROM (
        SELECT v_body AS body
    ) x
    WHERE body ~ '\n\s*CALL\s+staging\.sp_calcular_forecast_2026_v13\s*\('
       OR body ~ '\n\s*CALL\s+staging\.sp_project_sandwich_prices_2026\s*\(';

    IF v_calls > 0 THEN
        RAISE EXCEPTION 'RED/GREEN falhou: sp_executar_carga_completa contém % CALL(s) sintético(s) ativo(s) (V13/sanduíche) — engines NÃO desativadas (S8)',
            v_calls;
    END IF;
    RAISE NOTICE 'OK (a): sp_executar_carga_completa sem CALL sintético ativo';
END $$;

-- (b) pg_constraint — UNIQUEs + CHECKs sobreviventes --------------------------
DO $$
DECLARE
    v_faltando TEXT := '';
    v_achou    BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_sazonalidade'
          AND conrelid = 'mart.sazonalidade_produto'::regclass
    ) INTO v_achou;
    IF NOT v_achou THEN v_faltando := v_faltando || ' uq_sazonalidade'; END IF;

    SELECT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_sazonalidade_data_ref'
          AND conrelid = 'mart.sazonalidade_produto'::regclass
    ) INTO v_achou;
    IF NOT v_achou THEN v_faltando := v_faltando || ' uq_sazonalidade_data_ref'; END IF;

    SELECT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_sazonalidade_tipo_dado'
          AND conrelid = 'mart.sazonalidade_produto'::regclass
    ) INTO v_achou;
    IF NOT v_achou THEN v_faltando := v_faltando || ' chk_sazonalidade_tipo_dado'; END IF;

    SELECT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_data_ref_ano_mes'
          AND conrelid = 'mart.sazonalidade_produto'::regclass
    ) INTO v_achou;
    IF NOT v_achou THEN v_faltando := v_faltando || ' chk_data_ref_ano_mes'; END IF;

    IF v_faltando <> '' THEN
        RAISE EXCEPTION 'RED/GREEN falhou: constraints ausentes:% (S10/R-ADD-07)', v_faltando;
    END IF;
    RAISE NOTICE 'OK (b): uq_sazonalidade, uq_sazonalidade_data_ref, chk_sazonalidade_tipo_dado, chk_data_ref_ano_mes presentes';
END $$;

-- (c) MV V17 — transparência, branch B e double-count -------------------------
DO $$
DECLARE
    v_ano_atual INTEGER := EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER;
    v_colunas   TEXT    := '';
    v_dups      BIGINT;
    v_bad_b     BIGINT;
    v_neg_nao_atual BIGINT;
BEGIN
    -- (c1) colunas de transparência existem na MV.
    -- ATENÇÃO: information_schema.columns NÃO lista materialized views no PG
    -- (mesmo id_sazonalidade retorna 0) — usar pg_attribute (catálogo real).
    IF NOT EXISTS (
        SELECT 1 FROM pg_attribute a
        WHERE a.attrelid = 'mart.vw_api_produtos_sazonalidade'::regclass
          AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname = 'ano_referencia'
    ) THEN v_colunas := v_colunas || ' ano_referencia'; END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_attribute a
        WHERE a.attrelid = 'mart.vw_api_produtos_sazonalidade'::regclass
          AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname = 'tipo_dado'
    ) THEN v_colunas := v_colunas || ' tipo_dado'; END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_attribute a
        WHERE a.attrelid = 'mart.vw_api_produtos_sazonalidade'::regclass
          AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname = 'preco_exibido'
    ) THEN v_colunas := v_colunas || ' preco_exibido'; END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_attribute a
        WHERE a.attrelid = 'mart.vw_api_produtos_sazonalidade'::regclass
          AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname = 'idade_dado_anos'
    ) THEN v_colunas := v_colunas || ' idade_dado_anos'; END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_attribute a
        WHERE a.attrelid = 'mart.vw_api_produtos_sazonalidade'::regclass
          AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname = 'metadado_transparencia'
    ) THEN v_colunas := v_colunas || ' metadado_transparencia'; END IF;

    IF v_colunas <> '' THEN
        RAISE EXCEPTION 'RED/GREEN falhou: MV sem colunas de transparência:% (R-ADD-05)', v_colunas;
    END IF;

    -- (c2) branch B: id_sazonalidade < 0 ⇒ ano = ANO_ATUAL e ano_referencia < ANO_ATUAL
    SELECT count(*) INTO v_bad_b
    FROM mart.vw_api_produtos_sazonalidade
    WHERE id_sazonalidade < 0
      AND (ano <> v_ano_atual OR ano_referencia >= v_ano_atual);

    IF v_bad_b > 0 THEN
        RAISE EXCEPTION 'RED/GREEN falhou: % linha(s) branch B (id<0) fora do contrato (ano=% atual, ano_referencia < % atual)',
            v_bad_b, v_ano_atual, v_ano_atual;
    END IF;

    SELECT count(*) INTO v_neg_nao_atual
    FROM mart.vw_api_produtos_sazonalidade
    WHERE id_sazonalidade < 0 AND ano IS DISTINCT FROM v_ano_atual;
    IF v_neg_nao_atual > 0 THEN
        RAISE EXCEPTION 'RED/GREEN falhou: % linha(s) negativa(s) fora do ano de exibição %', v_neg_nao_atual, v_ano_atual;
    END IF;

    -- (c3) sem duplicata (id_produto, id_localidade, ano, mes) na MV
    SELECT count(*) INTO v_dups
    FROM (
        SELECT id_produto, id_localidade, ano, mes
        FROM mart.vw_api_produtos_sazonalidade
        GROUP BY 1, 2, 3, 4
        HAVING count(*) > 1
    ) dup;

    IF v_dups > 0 THEN
        RAISE EXCEPTION 'RED/GREEN falhou: % tupla(s) (produto,localidade,ano,mes) duplicada(s) na MV — double-count entre branches (D3)',
            v_dups;
    END IF;

    RAISE NOTICE 'OK (c): MV V17 com transparência; branch B consistente; sem duplicatas (%,% linhas)',
        (SELECT count(*) FROM mart.vw_api_produtos_sazonalidade),
        (SELECT count(*) FROM mart.vw_api_produtos_sazonalidade WHERE tipo_dado = 'FALLBACK_DIMENSAO');
END $$;
