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

-- ============================================================================
-- SEÇÃO 2 — Colunas de transparência em mart.sazonalidade_produto
-- ============================================================================
-- 5 colunas NULLABLE (sem DEFAULT — D6: ficam NULL até o backfill único).
-- preco_referencia já existe (05:58); apenas 5 colunas são adicionadas.
-- As 2 UNIQUEs (uq_sazonalidade, uq_sazonalidade_data_ref) e o CHECK
-- chk_data_ref_ano_mes (YYYY-MM) NÃO são tocados — additive-only (R-ADD-07/S10).

ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS ano_referencia         INTEGER,
    ADD COLUMN IF NOT EXISTS tipo_dado              TEXT,
    ADD COLUMN IF NOT EXISTS metadado_transparencia JSONB,
    ADD COLUMN IF NOT EXISTS idade_dado_anos        INTEGER,
    ADD COLUMN IF NOT EXISTS preco_exibido          NUMERIC(14,4);

COMMENT ON COLUMN mart.sazonalidade_produto.ano_referencia IS
    'Ano âncora do dado exibido (última cotação REAL). NULL p/ FALLBACK_DIMENSAO.';
COMMENT ON COLUMN mart.sazonalidade_produto.tipo_dado IS
    'REAL_ATUAL | HISTORICO_BASE | FALLBACK_DIMENSAO (snapshot de proveniência da linha; MV é a fonte de exibição).';
COMMENT ON COLUMN mart.sazonalidade_produto.metadado_transparencia IS
    'JSONB: fonte_dado, data_referencia, procedencia (coleta_real_conab|sintetico_proxy|sintetico_engine), calculado_em.';
COMMENT ON COLUMN mart.sazonalidade_produto.idade_dado_anos IS
    'ANO_ATUAL - ano_referencia (0 = ano corrente).';
COMMENT ON COLUMN mart.sazonalidade_produto.preco_exibido IS
    'Preço real exibido (sem multiplicador sintético). NULL p/ linhas não exibíveis.';

-- CHECK pós-backfill (R-ADD-01): valores restritos, NULL permitido
ALTER TABLE mart.sazonalidade_produto
    ADD CONSTRAINT chk_sazonalidade_tipo_dado
    CHECK (tipo_dado IS NULL OR tipo_dado IN ('REAL_ATUAL','HISTORICO_BASE','FALLBACK_DIMENSAO'));

-- ============================================================================
-- SEÇÃO 3 — Backfill único (single pass, sem JOINs, sem CROSS JOIN)
-- ============================================================================
-- ANO_ATUAL = EXTRACT(YEAR FROM CURRENT_DATE) em todo lugar (dinâmico — S6;
-- 2027 não exige mudança de código). Linhas FLUXO_PROXY/is_forecast são
-- marcadas FALLBACK_DIMENSAO, NUNCA deletadas (semântica de exibição apenas).
-- WHERE ano_referencia IS NULL garante idempotência (re-executável).

UPDATE mart.sazonalidade_produto AS s
SET ano_referencia = EXTRACT(YEAR FROM s.data_referencia_atual)::INTEGER,
    idade_dado_anos = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
                      - EXTRACT(YEAR FROM s.data_referencia_atual)::INTEGER,
    tipo_dado = CASE
        WHEN COALESCE(s.fonte,'') = 'FLUXO_PROXY' OR s.is_forecast THEN 'FALLBACK_DIMENSAO'
        WHEN EXTRACT(YEAR FROM s.data_referencia_atual)::INTEGER
             = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER THEN 'REAL_ATUAL'
        ELSE 'HISTORICO_BASE'
    END,
    metadado_transparencia = jsonb_build_object(
        'fonte_dado',      COALESCE(s.fonte,'desconhecida'),
        'data_referencia', s.data_referencia_atual,
        'procedencia', CASE
            WHEN COALESCE(s.fonte,'') = 'FLUXO_PROXY' THEN 'sintetico_proxy'
            WHEN s.is_forecast THEN 'sintetico_engine'
            ELSE 'coleta_real_conab'
        END,
        'calculado_em',    s.calculado_em
    ),
    preco_exibido = CASE
        WHEN COALESCE(s.fonte,'') <> 'FLUXO_PROXY' AND NOT s.is_forecast THEN s.preco_atual
        ELSE NULL
    END
WHERE ano_referencia IS NULL;

DO $$
DECLARE
    v_total    BIGINT;
    v_real     BIGINT;
    v_fallback BIGINT;
    v_sem_ano  BIGINT;
BEGIN
    SELECT count(*),
           count(*) FILTER (WHERE tipo_dado IN ('REAL_ATUAL','HISTORICO_BASE')),
           count(*) FILTER (WHERE tipo_dado = 'FALLBACK_DIMENSAO'),
           count(*) FILTER (WHERE tipo_dado IN ('REAL_ATUAL','HISTORICO_BASE') AND ano_referencia IS NULL)
    INTO v_total, v_real, v_fallback, v_sem_ano
    FROM mart.sazonalidade_produto;

    RAISE NOTICE '[63] Backfill: % linhas (REAL_ATUAL+HISTORICO_BASE=%, FALLBACK_DIMENSAO=%, reais sem ano=%)',
        v_total, v_real, v_fallback, v_sem_ano;

    IF v_sem_ano > 0 THEN
        RAISE EXCEPTION '[63] Backfill inconsistente: % linha(s) REAL sem ano_referencia', v_sem_ano;
    END IF;
END $$;

COMMIT;
