-- ============================================================================
-- ops.sp_limpeza_diaria() — manutenção de retenção de dados operacionais
-- ----------------------------------------------------------------------------
-- Protege o plano free do banco (Aiven free-1-1gb) contra estouro de disco.
--
-- O que limpa:
--   1. ops.audit_logs           → retenção de 3 dias (causa #1 de estouro:
--      a trigger trg_audit_status_cor grava TODA mudança de status_cor —
--      recálculos em lote geram 300k+ linhas em horas);
--   2. staging.precos_rejeitados → retenção de 90 dias (quarentena de anomalias);
--   3. ops.audit_llm_queries     → retenção de 30 dias;
--   4. raw.controle_carga        → retenção de 1 ano.
--   + ANALYZE nas tabelas quentes após as remoções.
--
-- Agendamento: cron diário (workflow GitHub ou Render cron) chama
--   CALL ops.sp_limpeza_diaria();
-- ============================================================================
CREATE OR REPLACE PROCEDURE ops.sp_limpeza_diaria()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio TIMESTAMPTZ;
    v_removidos_audit INT := 0;
    v_removidos_rejeitados INT := 0;
    v_removidos_llm INT := 0;
    v_removidos_controle INT := 0;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[ops.sp_limpeza_diaria] Iniciando...';

    -- 1. audit_logs — retenção de 3 DIAS (coluna data_mudanca)
    DELETE FROM ops.audit_logs
    WHERE data_mudanca < NOW() - INTERVAL '3 days';
    GET DIAGNOSTICS v_removidos_audit = ROW_COUNT;

    -- 2. precos_rejeitados — retenção de 90 dias (coluna rejeitado_em)
    DELETE FROM staging.precos_rejeitados
    WHERE rejeitado_em < NOW() - INTERVAL '90 days';
    GET DIAGNOSTICS v_removidos_rejeitados = ROW_COUNT;

    -- 3. audit_llm_queries — retenção de 30 dias (coluna criado_em)
    DELETE FROM ops.audit_llm_queries
    WHERE criado_em < NOW() - INTERVAL '30 days';
    GET DIAGNOSTICS v_removidos_llm = ROW_COUNT;

    -- 4. controle_carga — retenção de 1 ano (coluna criado_em)
    DELETE FROM raw.controle_carga
    WHERE criado_em < NOW() - INTERVAL '1 year';
    GET DIAGNOSTICS v_removidos_controle = ROW_COUNT;

    ANALYZE staging.fact_precos_mensais;
    ANALYZE staging.precos_rejeitados;
    ANALYZE staging.dim_produto;
    ANALYZE staging.dim_localidade;
    ANALYZE ops.audit_logs;

    RAISE NOTICE '[ops.sp_limpeza_diaria] Concluido: audit=% rejeitados=% llm=% controle=% em % seg',
        v_removidos_audit, v_removidos_rejeitados, v_removidos_llm,
        v_removidos_controle,
        ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_inicio)::NUMERIC, 2);
END;
$$;
