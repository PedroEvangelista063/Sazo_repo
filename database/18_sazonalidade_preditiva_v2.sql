-- ============================================================================
-- QUERO COMPRAR - Fase 18: Heurística Preditiva com Degradação Graciosa
-- PostgreSQL 16+  |  Trindade Estrita (VERDE/AMARELO/VERMELHO)
--
-- MOTIVAÇÃO:
--   O modelo anterior (Fase 17) utilizava 4 níveis de fallback e gerava
--   o estado 'INSUFICIENTE' que feria a UX B2C. O usuário não quer saber
--   se o banco tem 12 meses de histórico — ele quer uma recomendação
--   direcional clara.
--
--   Este script implementa um motor de Média Preditiva Dinâmica com
--   Degradação Graciosa (Graceful Degradation) baseado em 3 camadas:
--
--     Alpha (Ideal):  Média histórica completa (sazonalidade anual)
--     Beta (Fallback): Média móvel do que estiver disponível (≥1 mês)
--     Gamma (Cold Start): preco_referencia = preco_atual → 0% → AMARELO
--
--   O semáforo agora é uma TRINDADE INVOLÁVEL: apenas VERDE, AMARELO, VERMELHO.
--   Nenhum produto com preco_atual inválido chega à Materialized View.
--
-- ARQUITETURA (3 CTEs):
--   1. ultimo_preco_conhecido  — ROW_NUMBER() para capturar o "agora"
--   2. base_historica_disponivel — AVG de todo o passado (qualquer profundiade)
--   3. motor_preditivo_e_classificacao — COALESCE + CASE para cor
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: DDL — Ajuste da constraint CHECK em mart.sazonalidade_produto
-- ============================================================================
-- Remove a constraint antiga (que permitia 'INSUFICIENTE') e recria
-- permitindo estritamente a TRINDADE.

DO $$
DECLARE
    v_constraint_name TEXT;
BEGIN
    -- Descobre o nome da constraint CHECK em status_cor (se existir)
    SELECT con.conname INTO v_constraint_name
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    WHERE rel.relname = 'sazonalidade_produto'
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%status_cor%';

    IF v_constraint_name IS NOT NULL THEN
        EXECUTE format('ALTER TABLE mart.sazonalidade_produto DROP CONSTRAINT %I', v_constraint_name);
        RAISE NOTICE '[DDL] Constraint antiga % removida', v_constraint_name;
    END IF;
END $$;

ALTER TABLE mart.sazonalidade_produto
    ADD CONSTRAINT ck_status_cor_trindade
    CHECK (status_cor IN ('VERDE', 'AMARELO', 'VERMELHO'));

COMMENT ON CONSTRAINT ck_status_cor_trindade ON mart.sazonalidade_produto IS
    'Trindade Estrita: apenas VERDE, AMARELO, VERMELHO. INSUFICIENTE foi extirpado.';

-- Ajusta também a constraint do metodo_calculo se existir
DO $$
DECLARE
    v_constraint_name TEXT;
BEGIN
    SELECT con.conname INTO v_constraint_name
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    WHERE rel.relname = 'sazonalidade_produto'
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%metodo_calculo%';

    IF v_constraint_name IS NOT NULL THEN
        EXECUTE format('ALTER TABLE mart.sazonalidade_produto DROP CONSTRAINT %I', v_constraint_name);
    END IF;
END $$;

ALTER TABLE mart.sazonalidade_produto
    ADD CONSTRAINT ck_metodo_calculo_v2
    CHECK (metodo_calculo IN ('alpha_sazonal', 'beta_media_disponivel', 'gamma_cold_start'));

COMMENT ON CONSTRAINT ck_metodo_calculo_v2 ON mart.sazonalidade_produto IS
    'Método usado: alpha_sazonal (média anual), beta_media_disponivel (qtd disponível), gamma_cold_start (preço atual).';

-- ============================================================================
-- SEÇÃO 2: Stored Procedure — Motor Preditivo com Degradação Graciosa
-- ============================================================================

CREATE OR REPLACE PROCEDURE staging.sp_calcular_sazonalidade_preditiva()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio  TIMESTAMPTZ;
    v_fim     TIMESTAMPTZ;
    v_total   INTEGER;
    v_insert  INTEGER;
    v_update  INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_calcular_sazonalidade_preditiva] Iniciando...';

    -- ================================================================
    -- CTE 1: ultimo_preco_conhecido
    --   Fotografia do "agora": o preço mais recente de cada produto
    --   em cada localidade. Usa ROW_NUMBER() com partição por
    --   produto+localidade ordenado por data descendente.
    --
    --   Regra de segurança: WHERE preco > 0. Preços zerados ou nulos
    --   são ignorados sumariamente — o produto não entra na MV.
    -- ================================================================
    WITH ultimo_preco_conhecido AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            f.preco_medio       AS preco_atual,
            f.ano,
            f.mes,
            f.ano::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0')
                                AS data_referencia_atual,
            ROW_NUMBER() OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano DESC, f.mes DESC
            ) AS rn
        FROM staging.fact_precos_mensais f
        WHERE f.preco_medio > 0
    ),
    -- ================================================================
    -- CTE 2: base_historica_disponivel
    --   Agregação de TODO o passado (exceto a linha do "agora").
    --   Calcula AVG(preco) independente de ano ou continuidade.
    --
    --   Genialidade da "Média Móvel Mais Próxima":
    --     - 12 meses → média ultra precisa
    --     - 2 meses  → média dos 2 meses
    --     - 1 mês    → o valor daquele único mês
    --     - 0 meses  → NULL (aciona Gamma)
    -- ================================================================
    base_historica_disponivel AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            AVG(f.preco_medio)  AS media_historica,
            COUNT(*)            AS qtd_meses_historico
        FROM staging.fact_precos_mensais f
        WHERE f.preco_medio > 0
        GROUP BY f.id_produto, f.id_localidade
    ),
    -- ================================================================
    -- CTE 3: motor_preditivo_e_classificacao
    --   Aplica a Mágica da Coalescência e a Trindade das Cores.
    --
    --   Regra de Âncora (preco_referencia):
    --     COALESCE(base_historica.media, ultimo_preco.preco)
    --
    --     Alpha: Se existe média histórica → usa a média
    --     Beta:  A média JÁ É a média do que está disponível (CTE 2)
    --     Gamma: Se count(historico) == 0 → preco_referencia = preco_atual
    --            Variação = 0% → cai em AMARELO automaticamente
    --
    --   Thresholds de 15% (definidos na Fase 8.1):
    --     preco_atual < preco_referencia * 0.85  → VERDE  (safra/barato)
    --     preco_atual > preco_referencia * 1.15  → VERMELHO (entressafra/caro)
    --     else → AMARELO (estabilizado)
    -- ================================================================
    motor_preditivo_e_classificacao AS (
        SELECT
            u.id_produto,
            u.id_localidade,
            u.preco_atual,
            u.data_referencia_atual,
            -- Âncora: coalescência inteligente
            COALESCE(b.media_historica, u.preco_atual) AS preco_referencia_calc,
            -- Metadados do método
            CASE
                WHEN b.media_historica IS NOT NULL AND b.qtd_meses_historico > 1
                    THEN 'alpha_sazonal'
                WHEN b.media_historica IS NOT NULL
                    THEN 'beta_media_disponivel'
                ELSE 'gamma_cold_start'
            END AS metodo_calculo,
            b.qtd_meses_historico,
            -- Flag de fallback (compatibilidade com schema existente)
            (b.media_historica IS NULL) AS usou_fallback_12m,
            -- Classificação: Trindade Estrita
            CASE
                WHEN u.preco_atual < (COALESCE(b.media_historica, u.preco_atual) * 0.85)
                    THEN 'VERDE'
                WHEN u.preco_atual > (COALESCE(b.media_historica, u.preco_atual) * 1.15)
                    THEN 'VERMELHO'
                ELSE 'AMARELO'
            END AS status_cor,
            -- Gamma: 0% de variação, o COALESCE garante preco_referencia = preco_atual
            --         Isso resulta em AMARELO automaticamente
            CASE
                WHEN u.preco_atual IS NOT NULL
                 AND COALESCE(b.media_historica, u.preco_atual) > 0
                    THEN ROUND(
                        ((u.preco_atual / COALESCE(b.media_historica, u.preco_atual)) - 1) * 100,
                        2
                    )
                ELSE 0
            END AS variacao_pct
        FROM ultimo_preco_conhecido u
        LEFT JOIN base_historica_disponivel b
            ON b.id_produto    = u.id_produto
           AND b.id_localidade = u.id_localidade
        WHERE u.rn = 1
    )
    -- ================================================================
    -- UPSERT em mart.sazonalidade_produto
    -- ================================================================
    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade,
        preco_referencia, preco_atual,
        data_referencia_atual, usou_fallback_12m,
        status_cor, fonte, calculado_em,
        metodo_calculo, variacao_mom_pct, preco_mes_anterior
    )
    SELECT
        m.id_produto,
        m.id_localidade,
        ROUND(m.preco_referencia_calc, 4),
        m.preco_atual,
        m.data_referencia_atual,
        m.usou_fallback_12m,
        m.status_cor,
        'municipio'::TEXT AS fonte,
        NOW() AS calculado_em,
        m.metodo_calculo,
        m.variacao_pct,          -- reusa coluna variacao_mom_pct
        NULL::NUMERIC(14,4)      -- preco_mes_anterior fica NULL
    FROM motor_preditivo_e_classificacao m
    ON CONFLICT (id_produto, id_localidade)
    DO UPDATE SET
        preco_referencia      = EXCLUDED.preco_referencia,
        preco_atual           = EXCLUDED.preco_atual,
        data_referencia_atual = EXCLUDED.data_referencia_atual,
        usou_fallback_12m     = EXCLUDED.usou_fallback_12m,
        status_cor            = EXCLUDED.status_cor,
        fonte                 = EXCLUDED.fonte,
        calculado_em          = NOW(),
        metodo_calculo        = EXCLUDED.metodo_calculo,
        variacao_mom_pct      = EXCLUDED.variacao_mom_pct;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade_preditiva] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);

    -- ================================================================
    -- Persistência: REFRESH CONCURRENTLY na Materialized View
    --   A API de leitura não pode sofrer locks durante a recalibragem.
    -- ================================================================
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
    RAISE NOTICE '[sp_calcular_sazonalidade_preditiva] MV atualizada.';
END;
$$;

COMMENT ON PROCEDURE staging.sp_calcular_sazonalidade_preditiva IS
    'Motor V6 - Heurística Preditiva com Degradação Graciosa. '
    '3 camadas: Alpha (sazonalidade anual) → Beta (média disponível) → Gamma (cold start = AMARELO). '
    'Trindade Estrita: apenas VERDE/AMARELO/VERMELHO. Zero-NULL Tolerance.';

-- ============================================================================
-- SEÇÃO 3: Materialized View — Filtro Impiedoso (Zero-NULL Tolerance)
-- ============================================================================
-- A MV antiga filtava 'INSUFICIENTE' com WHERE status_cor != 'INSUFICIENTE'.
-- A nova MV vai além: suprime produtos onde preco_atual é NULL, zero, ou
-- onde status_cor não está na Trindade.

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
SELECT
    s.id_sazonalidade,
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
    s.status_cor,
    s.fonte,
    s.calculado_em,
    s.metodo_calculo,
    s.variacao_mom_pct          AS variacao_pct
FROM mart.sazonalidade_produto s
JOIN staging.dim_produto    p ON p.id_produto    = s.id_produto
JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
LEFT JOIN staging.dim_categoria c ON c.id_categoria = p.id_categoria
WHERE s.preco_atual IS NOT NULL
  AND s.preco_atual > 0
  AND s.status_cor IN ('VERDE', 'AMARELO', 'VERMELHO')
ORDER BY s.status_cor, p.nome_produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'View B2C V6 - Trindade Estrita. Filtra produtos com preco_atual NULL/zero '
    'e status fora da Trindade. Semáforo: VERDE/AMARELO/VERMELHO.';

CREATE UNIQUE INDEX IF NOT EXISTS idx_vw_api_unique
    ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

CREATE INDEX IF NOT EXISTS idx_vw_api_filtro
    ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);

CREATE INDEX IF NOT EXISTS idx_vw_api_categoria
    ON mart.vw_api_produtos_sazonalidade (categoria);

CREATE INDEX IF NOT EXISTS idx_vw_api_id_produto
    ON mart.vw_api_produtos_sazonalidade (id_produto);

REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- ============================================================================
-- SEÇÃO 4: Alias de compatibilidade (opcional)
-- ============================================================================
-- Mantém o nome antigo como alias para scripts que chamam a SP antiga
CREATE OR REPLACE PROCEDURE staging.sp_calcular_sazonalidade_baseline()
LANGUAGE plpgsql
AS $$
BEGIN
    CALL staging.sp_calcular_sazonalidade_preditiva();
END;
$$;

COMMENT ON PROCEDURE staging.sp_calcular_sazonalidade_baseline IS
    'Alias para sp_calcular_sazonalidade_preditiva (V6). Mantido para compatibilidade.';

-- ============================================================================
-- SEÇÃO 5: Permissões
-- ============================================================================

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;
GRANT ALL ON PROCEDURE staging.sp_calcular_sazonalidade_preditiva TO role_etl_writer;
GRANT ALL ON PROCEDURE staging.sp_calcular_sazonalidade_baseline TO role_etl_writer;

COMMIT;
