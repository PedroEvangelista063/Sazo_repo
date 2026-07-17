-- ============================================================================
-- Migration 006: Functions & Procedures
-- Utilitários, triggers, stored procedures
-- ============================================================================

-- 5.1. Parsing de preço CONAB: "2,27" → NUMERIC
CREATE OR REPLACE FUNCTION staging._parse_conab_price(p_texto TEXT)
RETURNS NUMERIC(14,4) AS $$
BEGIN
    IF p_texto IS NULL OR trim(p_texto) = '' THEN
        RETURN NULL;
    END IF;
    RETURN NULLIF(replace(trim(p_texto), ',', '.'), '')::NUMERIC(14,4);
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 5.2. Batch ID para carga
CREATE OR REPLACE FUNCTION staging._gerar_batch_id()
RETURNS UUID AS $$
    SELECT gen_random_uuid();
$$ LANGUAGE sql VOLATILE;

-- Trigger de anomalia de preço
CREATE OR REPLACE FUNCTION staging.trg_valida_anomalia_preco()
RETURNS TRIGGER AS $$
DECLARE
    v_media_historica NUMERIC(14,4);
    v_dados_brutos    JSONB;
BEGIN
    SELECT AVG(preco_medio) INTO v_media_historica
    FROM staging.fact_precos_mensais
    WHERE id_produto    = NEW.id_produto
      AND id_localidade = NEW.id_localidade
      AND NOT (ano = NEW.ano AND mes = NEW.mes);

    IF v_media_historica IS NULL THEN
        RETURN NEW;
    END IF;

    IF NEW.preco_medio > (v_media_historica * 5.0) THEN
        v_dados_brutos := jsonb_build_object(
            'produto_id',   NEW.id_produto,
            'localidade_id', NEW.id_localidade,
            'ano',          NEW.ano,
            'mes',          NEW.mes,
            'preco_enviado', NEW.preco_medio,
            'media_historica', v_media_historica
        );

        INSERT INTO staging.precos_rejeitados (
            id_produto, id_localidade, ano, mes,
            preco_medio, preco_medio_historico, razao,
            dados_brutos, batch_id
        ) VALUES (
            NEW.id_produto, NEW.id_localidade, NEW.ano, NEW.mes,
            NEW.preco_medio, v_media_historica,
            'Preço excede 500% da média histórica — possível erro de digitação',
            v_dados_brutos, NEW.batch_id
        );

        RETURN NULL;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION staging.trg_valida_anomalia_preco() IS
    'Desvia para quarentena preços >500% da média histórica do mesmo produto+localidade';

CREATE OR REPLACE TRIGGER trg_valida_anomalia_preco
    BEFORE INSERT ON staging.fact_precos_mensais
    FOR EACH ROW
    WHEN (NEW.preco_medio IS NOT NULL)
    EXECUTE FUNCTION staging.trg_valida_anomalia_preco();

-- SP: sp_calcular_sazonalidade
CREATE OR REPLACE PROCEDURE staging.sp_calcular_sazonalidade(
    p_ano_alvo  SMALLINT DEFAULT NULL,
    p_mes_alvo  SMALLINT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_ano   SMALLINT;
    v_mes   SMALLINT;
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
    v_total  INTEGER;
BEGIN
    v_inicio := clock_timestamp();

    IF p_ano_alvo IS NULL OR p_mes_alvo IS NULL THEN
        SELECT MAX(ano), MAX(mes) INTO v_ano, v_mes
        FROM staging.fact_precos_mensais;
    ELSE
        v_ano := p_ano_alvo;
        v_mes := p_mes_alvo;
    END IF;

    RAISE NOTICE '[sp_calcular_sazonalidade] Alvo: %-%', v_ano, v_mes;

    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade, ano, mes,
        preco_medio, media_movel_12m, indice_sazonalidade,
        status_cor, fonte, calculado_em
    )
    WITH precos_12m AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            f.ano,
            f.mes,
            f.preco_medio,
            AVG(f.preco_medio) OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano, f.mes
                ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
            ) AS media_movel_12m,
            COUNT(*) OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano, f.mes
                ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
            ) AS meses_no_window
        FROM staging.fact_precos_mensais f
        WHERE (f.ano < v_ano OR (f.ano = v_ano AND f.mes <= v_mes))
    )
    SELECT
        p.id_produto,
        p.id_localidade,
        p.ano,
        p.mes,
        p.preco_medio,
        p.media_movel_12m,
        CASE
            WHEN p.media_movel_12m IS NOT NULL AND p.media_movel_12m > 0
            THEN ROUND(p.preco_medio / p.media_movel_12m, 4)
            ELSE NULL
        END AS indice_sazonalidade,
        CASE
            WHEN p.meses_no_window < 6 THEN 'INSUFICIENTE'
            WHEN p.media_movel_12m IS NULL OR p.media_movel_12m = 0 THEN 'INSUFICIENTE'
            WHEN (p.preco_medio / p.media_movel_12m) < 0.85 THEN 'VERDE'
            WHEN (p.preco_medio / p.media_movel_12m) > 1.15 THEN 'VERMELHO'
            ELSE 'AMARELO'
        END AS status_cor,
        'municipio' AS fonte,
        NOW() AS calculado_em
    FROM precos_12m p
    WHERE p.ano = v_ano AND p.mes = v_mes
        AND p.preco_medio IS NOT NULL
    ON CONFLICT (id_produto, id_localidade, ano, mes)
    DO UPDATE SET
        preco_medio         = EXCLUDED.preco_medio,
        media_movel_12m     = EXCLUDED.media_movel_12m,
        indice_sazonalidade = EXCLUDED.indice_sazonalidade,
        status_cor          = EXCLUDED.status_cor,
        calculado_em        = NOW();

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

COMMENT ON PROCEDURE staging.sp_calcular_sazonalidade IS
    'Calcula média móvel 12m e classifica semáforo por produto+localidade';

-- SP: sp_executar_carga_completa
CREATE OR REPLACE PROCEDURE staging.sp_executar_carga_completa()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
    v_ultimo_ano  SMALLINT;
    v_ultimo_mes  SMALLINT;
    v_total_fato  INTEGER;
    v_total_saz   INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Iniciando...';

    ANALYZE staging.fact_precos_mensais;

    SELECT MAX(ano), MAX(mes) INTO v_ultimo_ano, v_ultimo_mes
    FROM staging.fact_precos_mensais;

    CALL staging.sp_calcular_sazonalidade(v_ultimo_ano, v_ultimo_mes);

    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Concluído em % seg',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;
