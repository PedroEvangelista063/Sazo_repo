-- ============================================================================
-- QUERO COMPRAR — database/64: ROLLBACK do Dado Histórico Real (refatoracao-dado-historico)
-- PostgreSQL 17+  |  Rollback-ONLY (desfaz database/63 + 000021)  |  Idempotente
--
-- ATENÇÃO: Este arquivo é intencionalmente rollback-ONLY. Ele NÃO roda em
-- deploy; é acionado manualmente (psql) se o dado histórico real precisar ser
-- revertido. Refaz exatamente o estado pré-refatoração:
--   SEÇÃO 1 — Restaura sp_executar_carga_completa com engines sintéticas ATIVAS
--             (steps 5-6 reativados — corpo original de database/62).
--   SEÇÃO 2 — Remove as 5 colunas de transparência + CHECK + comentários.
--   SEÇÃO 3 — Remove a view auxiliar mart.vw_anchor_sazonalidade.
--   SEÇÃO 4 — Recria a MV vw_api_produtos_sazonalidade V16 (definition de
--             database/31 + 7 índices + GRANT) e faz refresh.
--   SEÇÃO 5 — Restaura fn_br_nacional_sazonalidade (sem ano_referencia/tipo_dado).
--
-- REAPLICAR database/63 após rollback reaplica a refatoração (idempotente).
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1 — sp_executar_carga_completa: engines sintéticas REATIVADAS
-- ============================================================================
-- Corpo original de database/62 (SEÇÃO 5). Restaura os CALLs dos steps 5-6 e
-- remove o refresh explícito do step 7 (a MV volta a ser atualizada pelas
-- engines). O GRANT é redundante (o proc já existe) mas mantém idempotência.

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

    -- 5. Forecast 2026 — Engine V13 (âncora 2024 + margem 2025)
    CALL staging.sp_calcular_forecast_2026_v13();
    RAISE NOTICE '[sp_executar_carga_completa] Forecast 2026 V13 (status_cor) OK';

    -- 6. Sanduíche Sazonal (projeta PREÇO NUMÉRICO para meses faltantes)
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'staging' AND p.proname = 'sp_project_sandwich_prices_2026'
    ) INTO v_existe;
    IF v_existe THEN
        CALL staging.sp_project_sandwich_prices_2026();
        RAISE NOTICE '[sp_executar_carga_completa] Sanduíche Sazonal (preço numérico) OK';
    ELSE
        RAISE NOTICE '[sp_executar_carga_completa] Sanduíche Sazonal SKIP (proc ausente neste ambiente)';
    END IF;

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Pipeline completo em % seg',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$procedure$;

COMMENT ON PROCEDURE staging.sp_executar_carga_completa IS
    'Pipeline completo — Executa carga + sazonalidade + Forecast 2026 V13 + '
    'Sanduíche Sazonal (preço numérico). Deve ser chamado após cada ciclo de coleta. (rollback 64)';

GRANT ALL ON PROCEDURE staging.sp_executar_carga_completa TO role_etl_writer;

-- ============================================================================
-- SEÇÃO 2 — Remove colunas de transparência + CHECK + comentários
-- ============================================================================
-- Refaz o estado pré-63: remove o CHECK e as 5 colunas (em ordem inversa à
-- criação, evitando dependências). Os dados de preco_exibido/ano_referencia
-- são descartados — a MV volta a usar preco_atual/preco_estimado das engines.

ALTER TABLE mart.sazonalidade_produto
    DROP CONSTRAINT IF EXISTS chk_sazonalidade_tipo_dado;

COMMENT ON COLUMN mart.sazonalidade_produto.ano_referencia        IS NULL;
COMMENT ON COLUMN mart.sazonalidade_produto.tipo_dado             IS NULL;
COMMENT ON COLUMN mart.sazonalidade_produto.metadado_transparencia IS NULL;
COMMENT ON COLUMN mart.sazonalidade_produto.idade_dado_anos       IS NULL;
COMMENT ON COLUMN mart.sazonalidade_produto.preco_exibido         IS NULL;

ALTER TABLE mart.sazonalidade_produto
    DROP COLUMN IF EXISTS preco_exibido,
    DROP COLUMN IF EXISTS idade_dado_anos,
    DROP COLUMN IF EXISTS metadado_transparencia,
    DROP COLUMN IF EXISTS tipo_dado,
    DROP COLUMN IF EXISTS ano_referencia;

-- ============================================================================
-- SEÇÃO 3 — Remove a view auxiliar mart.vw_anchor_sazonalidade
-- ============================================================================

DROP VIEW IF EXISTS mart.vw_anchor_sazonalidade CASCADE;

-- ============================================================================
-- SEÇÃO 4 — Recria a MV vw_api_produtos_sazonalidade V16 (pré-refatoração)
-- ============================================================================
-- Definition de database/31 (V15+) que era a vigente no banco vivo:
-- 3-branch NÃO existe — a MV expõe o que as engines (V13/sanduíche) gravam.
-- DROP + CREATE seguem o padrão de 31/36; 7 índices + GRANT idênticos.

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
SELECT
    s.id_sazonalidade,
    s.id_localidade,
    p.id_produto,
    p.nome_produto              AS produto,
    p.classificao_produto,
    p.conab_id_produto,
    p.status_fonte,
    COALESCE(c.nome_categoria, 'ALIMENTO_VAREJO') AS categoria,
    l.uf,
    l.municipio_nome            AS municipio,
    l.municipio_id,
    CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER) AS ano,
    CAST(SPLIT_PART(s.data_referencia_atual, '-', 2) AS INTEGER) AS mes,
    s.preco_referencia,
    s.preco_atual,
    s.data_referencia_atual,
    s.usou_fallback_12m,
    s.preco_estimado,
    s.status_cor,
    s.fonte,
    s.calculado_em,
    s.metodo_calculo,
    s.variacao_mom_pct          AS variacao_pct,
    s.tendencia_futura,
    s.is_forecast,
    s.baseline_confianca,
    s.forecast_method
FROM mart.sazonalidade_produto s
JOIN staging.dim_produto    p ON p.id_produto    = s.id_produto
JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
LEFT JOIN staging.dim_categoria c ON c.id_categoria = p.id_categoria
WHERE s.status_cor IN ('VERDE', 'AMARELO', 'VERMELHO')
  AND p.categoria_b2c = 'ALIMENTO_VAREJO'
  AND (p.classificao_produto IS NULL
       OR p.classificao_produto NOT IN ('INSUMO_AGRICOLA', 'MAQUINARIO_FERRAMENTA', 'SERVICO_LOGISTICA'))
  AND (c.nome_categoria IS NULL
       OR c.nome_categoria NOT IN ('FLORES', 'OUTROS'))
ORDER BY ano, mes, s.is_forecast, s.status_cor, p.nome_produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'View B2C V15/V16 — Sem filtro de ano. Expoe dados 2024-2026. '
    'Inclui is_forecast, baseline_confianca, forecast_method. (restaurada — rollback 64)';

DROP INDEX IF EXISTS mart.idx_vw_sazonalidade_unico;
DROP INDEX IF EXISTS mart.idx_vw_sazonalidade_filtro;
DROP INDEX IF EXISTS mart.idx_vw_sazonalidade_categoria;
DROP INDEX IF EXISTS mart.idx_vw_sazonalidade_produto;
DROP INDEX IF EXISTS mart.idx_vw_sazonalidade_ano_mes;
DROP INDEX IF EXISTS mart.idx_vw_sazonalidade_forecast;
DROP INDEX IF EXISTS mart.idx_vw_sazonalidade_confianca;

CREATE UNIQUE INDEX idx_vw_sazonalidade_unico
    ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

CREATE INDEX idx_vw_sazonalidade_filtro
    ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);

CREATE INDEX idx_vw_sazonalidade_categoria
    ON mart.vw_api_produtos_sazonalidade (categoria);

CREATE INDEX idx_vw_sazonalidade_produto
    ON mart.vw_api_produtos_sazonalidade (id_produto);

CREATE INDEX idx_vw_sazonalidade_ano_mes
    ON mart.vw_api_produtos_sazonalidade (ano, mes)
    WHERE ano IS NOT NULL AND mes IS NOT NULL;

CREATE INDEX idx_vw_sazonalidade_forecast
    ON mart.vw_api_produtos_sazonalidade (is_forecast)
    WHERE is_forecast = TRUE;

CREATE INDEX idx_vw_sazonalidade_confianca
    ON mart.vw_api_produtos_sazonalidade (baseline_confianca DESC)
    WHERE is_forecast = TRUE;

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;

-- ============================================================================
-- SEÇÃO 5 — Restaura fn_br_nacional_sazonalidade (sem ano_referencia/tipo_dado)
-- ============================================================================
-- Definition original de database/62 (SEÇÃO 6). DROP das assinaturas criadas
-- pela 63 (INTEGER, TEXT, INTEGER — a mesma assinatura de 62; a 63 substituiu
-- por CREATE OR REPLACE, então basta o DROP + CREATE abaixo) e recria sem os
-- 2 outputs extras.

DROP FUNCTION IF EXISTS mart.fn_br_nacional_sazonalidade(INTEGER, TEXT);
DROP FUNCTION IF EXISTS mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER);

CREATE FUNCTION mart.fn_br_nacional_sazonalidade(
    p_ano       INTEGER,
    p_categoria TEXT DEFAULT NULL,
    p_min_ufs   INTEGER DEFAULT 1
)
RETURNS TABLE(
    produto             TEXT,
    classificao_produto TEXT,
    categoria           TEXT,
    mes                 INTEGER,
    data_referencia_atual TEXT,
    status_cor          TEXT,
    is_forecast         BOOLEAN,
    baseline_confianca  NUMERIC,
    total_ufs           BIGINT,
    forecast_method     TEXT,
    calculado_em        TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_categoria_filter TEXT := COALESCE(p_categoria, '%%');
    v_min_ufs INTEGER := COALESCE(p_min_ufs, 1);
BEGIN
    RETURN QUERY
    WITH uf_por_mes AS (
        SELECT
            v.produto,
            v.classificao_produto,
            COALESCE(v.categoria, 'ALIMENTO_VAREJO') AS categoria_final,
            v.uf,
            v.mes,
            MODE() WITHIN GROUP (ORDER BY v.status_cor) AS uf_status_cor,
            BOOL_OR(v.is_forecast)       AS uf_forecast,
            MAX(v.baseline_confianca)    AS uf_confianca,
            MODE() WITHIN GROUP (ORDER BY v.forecast_method) AS uf_forecast_method,
            MAX(v.calculado_em)          AS uf_calculado_em
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.ano = p_ano
          AND (p_categoria IS NULL OR v.categoria ILIKE v_categoria_filter)
        GROUP BY v.produto, v.classificao_produto, categoria_final, v.uf, v.mes
    )
    SELECT
        upm.produto,
        upm.classificao_produto,
        upm.categoria_final,
        upm.mes,
        (p_ano || '-' || LPAD(upm.mes::TEXT, 2, '0'))::TEXT AS data_ref,
        MODE() WITHIN GROUP (ORDER BY upm.uf_status_cor) AS status_cor_nac,
        BOOL_OR(upm.uf_forecast) AS is_forecast_nac,
        MAX(upm.uf_confianca) AS confianca_nac,
        COUNT(DISTINCT upm.uf) AS total_ufs_nac,
        MODE() WITHIN GROUP (ORDER BY upm.uf_forecast_method) AS forecast_method_nac,
        MAX(upm.uf_calculado_em) AS calculado_em_nac
    FROM uf_por_mes upm
    GROUP BY upm.produto, upm.classificao_produto, upm.categoria_final, upm.mes
    HAVING COUNT(DISTINCT upm.uf) >= v_min_ufs
    ORDER BY upm.produto, upm.mes;
END;
$$;

COMMENT ON FUNCTION mart.fn_br_nacional_sazonalidade IS
    'Sazonalidade BR Nacional — retorna 12 meses de um ano. '
    'Moda da moda por UF, HAVING COUNT(DISTINCT uf) >= p_min_ufs (default 1). (restaurada — rollback 64)';

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER) TO role_api_reader;

-- ============================================================================
-- SEÇÃO 6 — Refresh da MV restaurada (fora de transação — CONCURRENTLY)
-- ============================================================================
-- O COMMIT acima finaliza a transação (SEÇÃO 1-5, um único BEGIN/COMMIT).
-- O refresh roda fora da transação, como em 63.

COMMIT;

REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

RAISE NOTICE '[64] Rollback concluído — engines reativadas, colunas removidas, MV V16 restaurada';
