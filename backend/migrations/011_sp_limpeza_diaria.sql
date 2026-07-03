CREATE OR REPLACE PROCEDURE ops.sp_limpeza_diaria()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio TIMESTAMPTZ;
    v_removidos_rejeitados INT := 0;
    v_removidos_audit INT := 0;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[ops.sp_limpeza_diaria] Iniciando...';

    DELETE FROM staging.precos_rejeitados
    WHERE rejeitado_em < NOW() - INTERVAL '90 days';
    GET DIAGNOSTICS v_removidos_rejeitados = ROW_COUNT;

    DELETE FROM ops.audit_llm_queries
    WHERE executado_em < NOW() - INTERVAL '30 days';
    GET DIAGNOSTICS v_removidos_audit = ROW_COUNT;

    DELETE FROM raw.controle_carga
    WHERE iniciado_em < NOW() - INTERVAL '1 year';

    ANALYZE staging.fact_precos_mensais;
    ANALYZE staging.precos_rejeitados;
    ANALYZE staging.dim_produto;
    ANALYZE staging.dim_localidade;

    RAISE NOTICE '[ops.sp_limpeza_diaria] Concluido: rejeitados=% audit=% em % seg',
        v_removidos_rejeitados, v_removidos_audit,
        ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_inicio)::NUMERIC, 2);
END;
$$;