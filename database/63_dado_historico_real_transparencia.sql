-- ============================================================================
-- QUERO COMPRAR — Fase 63: Dado Histórico Real + Transparência
-- PostgreSQL 16+
--
-- OBJETIVO (refatoracao-dado-historico):
--   Substituir as projeções SINTÉTICAS (Sanduíche Sazonal
--   staging.sp_project_sandwich_prices_2026 e Engine V13
--   staging.sp_calcular_forecast_2026_v13) por DADO HISTÓRICO REAL com
--   transparência temporal (ano âncora N → N-1 → N-2):
--
--     1. sp_executar_carga_completa() — DESATIVADA as chamadas sintéticas
--        (steps 5-6 viram no-op guards + RAISE NOTICE); novo step 7 =
--        REFRESH MATERIALIZED VIEW CONCURRENTLY da MV (D7).
--     2. Novas colunas de transparência em mart.sazonalidade_produto:
--        ano_referencia, tipo_dado, metadado_transparencia, idade_dado_anos,
--        preco_exibido (5 colunas NULLABLE + CHECK chk_sazonalidade_tipo_dado).
--     3. Backfill único (sem JOINs, sem CROSS JOIN): real → REAL_ATUAL /
--        HISTORICO_BASE; FLUXO_PROXY / is_forecast → FALLBACK_DIMENSAO
--        (nunca deletado — semântica de exibição apenas).
--     4. VIEW auxiliar mart.vw_anchor_sazonalidade (D1): âncora N→N-1→N-2 por
--        (produto, localidade, mes) via LATERAL — SEM CROSS JOIN (evita o
--        padrão OOM da Fase 62).
--     5. MV mart.vw_api_produtos_sazonalidade V17 (D3/D4/D5): 3 branches
--        UNION ALL (A reais, B âncora em ano atual, C fallback dimensão) +
--        7 índices (UNIQUE primeiro p/ CONCURRENTLY) + GRANT role_api_reader.
--     6. fn_br_nacional_sazonalidade recriada com + ano_referencia, tipo_dado.
--     7. REFRESH MATERIALIZED VIEW CONCURRENTLY inicial (fora de transação).
--
-- IDEMPOTÊNCIA: CREATE OR REPLACE / ADD COLUMN IF NOT EXISTS / DO guard;
-- backfill com WHERE ano_referencia IS NULL (re-executável).
--
-- OBSERVAÇÕES:
--   - As procs sintéticas (V13/sanduíche) permanecem DEFINIDAS no repositório
--     e no banco (audit trail) — apenas não são mais invocadas.
--   - As 2 UNIQUEs (uq_sazonalidade, uq_sazonalidade_data_ref) e o CHECK
--     chk_data_ref_ano_mes (YYYY-MM) são PRESERVADOS (R-ADD-07/S10).
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1 — sp_executar_carga_completa (DESATIVADA as engines sintéticas)
-- ============================================================================
-- Recreate do orchestrator a partir da cópia da Fase 62 (steps 1-4 idênticos).
--   Step 5 (V13): CALL comentado + RAISE NOTICE (D7 — no-op).
--   Step 6 (Sanduíche): guard EXISTS mantido apenas para o aviso; branch de
--     execução é no-op + RAISE NOTICE (D7).
--   Step 7 (NOVO): REFRESH MATERIALIZED VIEW CONCURRENTLY — antes executado
--     pelas engines sintéticas; agora o orchestrator é o dono do refresh (D7).
-- Satisfaz S8 (forecasts não regeneram no próximo load) / R-ADD-06.

CREATE OR REPLACE PROCEDURE staging.sp_executar_carga_completa()
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
    v_existe BOOLEAN;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Iniciando pipeline completo...';

    -- 1. Carga bruta (landing → staging) — se existir no ambiente
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'staging' AND p.proname = 'sp_carregar_landing_para_staging'
    ) INTO v_existe;
    IF v_existe THEN
        CALL staging.sp_carregar_landing_para_staging();
        RAISE NOTICE '[sp_executar_carga_completa] Landing → Staging OK';
    ELSE
        RAISE NOTICE '[sp_executar_carga_completa] Landing → Staging SKIP (proc ausente neste ambiente)';
    END IF;

    -- 2. Limpeza/normalização — se existir no ambiente
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'staging' AND p.proname = 'sp_limpar_e_normalizar_staging'
    ) INTO v_existe;
    IF v_existe THEN
        CALL staging.sp_limpar_e_normalizar_staging();
        RAISE NOTICE '[sp_executar_carga_completa] Normalização OK';
    ELSE
        RAISE NOTICE '[sp_executar_carga_completa] Normalização SKIP (proc ausente neste ambiente)';
    END IF;

    -- 3. Enriquecimento CONAB → variedades — se existir no ambiente
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'staging' AND p.proname = 'sp_sincronizar_variedades_conab'
    ) INTO v_existe;
    IF v_existe THEN
        CALL staging.sp_sincronizar_variedades_conab();
        RAISE NOTICE '[sp_executar_carga_completa] Sincronização CONAB OK';
    ELSE
        RAISE NOTICE '[sp_executar_carga_completa] Sincronização CONAB SKIP (proc ausente neste ambiente)';
    END IF;

    -- 4. Cálculo sazonalidade (dados reais)
    CALL staging.sp_calcular_sazonalidade(NULL, NULL);
    RAISE NOTICE '[sp_executar_carga_completa] Sazonalidade (reais) OK';

    -- 5. Forecast V13 — DESATIVADO (refatoracao-dado-historico). Dado exibido passa a
    --    ser o histórico real com ano âncora. Proc permanece definida (audit trail), nunca invocada.
    -- CALL staging.sp_calcular_forecast_2026_v13();   -- desativado (audit trail)
    RAISE NOTICE '[sp_executar_carga_completa] Forecast V13 DESATIVADO — dado histórico real é a fonte de exibição';

    -- 6. Sanduíche Sazonal — DESATIVADO. Guard EXISTS mantido apenas para o aviso;
    --    o branch de execução é no-op. Proc permanece definida (audit trail).
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'staging' AND p.proname = 'sp_project_sandwich_prices_2026'
    ) INTO v_existe;
    IF v_existe THEN
        RAISE NOTICE '[sp_executar_carga_completa] Sanduíche Sazonal DESATIVADO (proc presente, não invocada)';
    ELSE
        RAISE NOTICE '[sp_executar_carga_completa] Sanduíche Sazonal SKIP (proc ausente neste ambiente)';
    END IF;

    -- 7. (NOVO) Refresh explícito da MV — antes executado pelas engines sintéticas.
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
    RAISE NOTICE '[sp_executar_carga_completa] MV vw_api_produtos_sazonalidade atualizada';

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Pipeline completo em % seg',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$procedure$;

COMMENT ON PROCEDURE staging.sp_executar_carga_completa IS
    'Pipeline completo — Carga + sazonalidade REAL + refresh da MV. '
    'Engines sintéticas (V13/sanduíche) DESATIVADAS (refatoracao-dado-historico): '
    'o dado exibido é o histórico real com ano âncora (N→N-1→N-2). '
    'Deve ser chamado após cada ciclo de coleta.';

GRANT ALL ON PROCEDURE staging.sp_executar_carga_completa TO role_etl_writer;

COMMIT;
