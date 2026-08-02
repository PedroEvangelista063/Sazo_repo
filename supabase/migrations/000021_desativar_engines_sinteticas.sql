-- ============================================================================
-- QUERO COMPRAR — Migration 000021: Desativação das Engines Sintéticas (D2)
-- PostgreSQL 17+  |  Forward-only  |  Idempotent (CREATE OR REPLACE)
--
-- OBJETIVO (refatoracao-dado-historico):
--   Impedir que a cadeia de migrations Supabase REATIVE as engines sintéticas
--   (V13 / Sanduíche) no próximo deploy. A migration 000019 carrega uma CÓPIA
--   do sp_executar_carga_completa (000019:821/834) que chama
--   sp_calcular_forecast_2026_v13() e sp_project_sandwich_prices_2026() — e o
--   scripts/deploy_v13_prod.sh reaplica 000019/000020 em todo deploy.
--
--   Esta migration sobrescreve SOMENTE o orchestrator com o corpo DESATIVADO
--   idêntico ao database/63 (SEÇÃO 1 — A.1 do design): steps 5-6 viram no-op
--   guards + RAISE NOTICE; novo step 7 = REFRESH MATERIALIZED VIEW CONCURRENTLY.
--   Assim o CALL do pipeline nunca regenera forecast sintético (S8/R-ADD-06).
--
-- POLÍTICA DE DRIFT (database/ = source of truth):
--   - `database/` é a fonte de verdade para DDL do mart (colunas de
--     transparência, backfill), view mart.vw_anchor_sazonalidade, MV V17
--     (mart.vw_api_produtos_sazonalidade) e fn_br_nacional_sazonalidade.
--   - 000020 (sanduíche v7) NÃO é portada: foi superseded pela desativação
--     (database/57 já carrega a sandwich v7 no banco vivo; aqui ela não roda).
--   - O CHECK de `fonte` do mart pode divergir entre os tracks (banco vivo
--     admite FLUXO_PROXY; o replica local admite municipio/uf/BASELINE_HISTORICO)
--     — o backfill trata ambos via COALESCE(fonte,'') = 'FLUXO_PROXY'.
--   - Esta migration NÃO altera colunas do mart: elas vêm de database/63.
-- ============================================================================

BEGIN;

-- ============================================================================
-- sp_executar_carga_completa — override DESATIVADO (idêntico a database/63 SEÇÃO 1)
-- ============================================================================
-- Neutraliza a cópia de 000019 (L769-850) — CREATE OR REPLACE substitui o corpo.
-- As procs sintéticas permanecem definidas (audit trail), nunca invocadas.

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
    'Deve ser chamado após cada ciclo de coleta. (000021)';

GRANT ALL ON PROCEDURE staging.sp_executar_carga_completa TO role_etl_writer;

COMMIT;
