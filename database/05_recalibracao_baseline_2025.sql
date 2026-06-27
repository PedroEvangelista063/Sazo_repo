-- ============================================================================
-- QUERO COMPRAR — Fase 6: Baseline 2025 com Fallback Híbrido
-- PostgreSQL 16+  |  Ano Âncora + Média Móvel 12m Condicional
--
-- MOTIVAÇÃO:
--   O negócio pivotou: abandonamos a média móvel contínua (12m rolling window
--   das Fases 1-4) porque ela amortece a percepção de inflação. Agora usamos
--   o Ano Âncora 2025 como baseline primário.
--
--   PORÉM: produtos novos catalogados pela CONAB apenas em 2026 não possuem
--   baseline 2025. Para estes, acionamos um Mecanismo de Fallback: a média
--   dos últimos 12 meses disponíveis vira a âncora provisória.
--
--   A regra é: COALESCE(media_2025, media_12m). Se 2025 existe, ela
--   PREVALECE. O fallback só entra se 2025 for NULL.
--
--   O campo usou_fallback_12m sinaliza para o frontend que o preço base
--   não é de 2025 (pode exibir "*Comparado aos últimos 12 meses").
--
-- SUMÁRIO:
--   1. DROP da pipeline antiga (MV → tabela → SP)
--   2. Rebuild de mart.sazonalidade_produto (schema híbrido)
--   3. SP com 4 CTEs: calc_base_2025 → calc_ultimos_precos →
--      calc_fallback_12m → master_join
--   4. MV com usou_fallback_12m + UNIQUE INDEX para CONCURRENTLY
--   5. Atualização de sp_executar_carga_completa
--   6. Índices, permissões, comentários
-- ============================================================================

BEGIN;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 1 — Limpeza da pipeline antiga
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Ordem: MV depende da tabela; tabela depende de nada.

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;
DROP TABLE IF EXISTS mart.sazonalidade_produto CASCADE;
DROP PROCEDURE IF EXISTS staging.sp_calcular_sazonalidade;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 2 — Nova tabela mart (híbrida: 2025 + fallback 12m)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--
-- ESTRUTURA:
--   preco_referencia   → COALESCE(preco_referencia_2025, preco_fallback_12m)
--   preco_atual        → último preço registrado
--   usou_fallback_12m  → TRUE se a âncora veio do fallback (não de 2025)
--   status_cor         → VERDE / AMARELO / VERMELHO / INSUFICIENTE
--
-- UQ: (id_produto, id_localidade) — um snapshot vigente por par.
-- O upsert sempre substitui o snapshot anterior.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE TABLE mart.sazonalidade_produto (
    id_sazonalidade       BIGSERIAL       PRIMARY KEY,
    id_produto            INTEGER         NOT NULL,
    id_localidade         INTEGER         NOT NULL,
    preco_referencia      NUMERIC(14,4),            -- âncora: 2025 ou fallback 12m
    preco_atual           NUMERIC(14,4),             -- último preço registrado
    data_referencia_atual VARCHAR(7)     NOT NULL,   -- 'YYYY-MM' do preço atual
    usou_fallback_12m     BOOLEAN        NOT NULL DEFAULT FALSE,
    status_cor            TEXT            NOT NULL
                          CHECK (status_cor IN ('VERDE','AMARELO','VERMELHO','INSUFICIENTE')),
    fonte                 TEXT            NOT NULL DEFAULT 'municipio'
                          CHECK (fonte IN ('municipio','uf')),
    calculado_em          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_sazonalidade UNIQUE (id_produto, id_localidade)
);

COMMENT ON TABLE mart.sazonalidade_produto IS
    'Snapshot do semáforo B2C por produto+localidade. Baseline 2025 com '
    'fallback condicional de 12 meses para produtos sem histórico em 2025.';

COMMENT ON COLUMN mart.sazonalidade_produto.preco_referencia IS
    'Preço âncora: COALESCE(AVG(2025), AVG(últimos 12 meses)). '
    'Usa baseline 2025 se disponível; fallback 12m se não.';

COMMENT ON COLUMN mart.sazonalidade_produto.preco_atual IS
    'Último preço registrado do produto na localidade';

COMMENT ON COLUMN mart.sazonalidade_produto.data_referencia_atual IS
    'Mês/ano do preço atual, formato YYYY-MM';

COMMENT ON COLUMN mart.sazonalidade_produto.usou_fallback_12m IS
    'TRUE se a âncora veio da média dos últimos 12 meses (produto sem 2025). '
    'O frontend pode exibir: "*Comparado aos últimos 12 meses"';

COMMENT ON COLUMN mart.sazonalidade_produto.status_cor IS
    'VERDE (≥15% abaixo da âncora), AMARELO (dentro de ±15%), '
    'VERMELHO (>15% acima da âncora), INSUFICIENTE (sem âncora ou sem preço)';

CREATE INDEX idx_sazonalidade_api
    ON mart.sazonalidade_produto (id_localidade, id_produto);

CREATE INDEX idx_sazonalidade_status
    ON mart.sazonalidade_produto (status_cor)
    WHERE status_cor IN ('VERDE','VERMELHO');

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 3 — Stored Procedure: sp_calcular_sazonalidade_baseline
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- 4 CTEs encadeadas (set-based, zero cursores):
--
--   CTE 1 calc_base_2025:
--     GROUP BY (id_produto, id_localidade) WHERE ano = 2025 → AVG(preco_medio)
--
--   CTE 2 calc_ultimos_precos:
--     ROW_NUMBER() OVER(PARTITION BY id_produto, id_localidade
--                       ORDER BY ano DESC, mes DESC) → isola o registro mais recente
--
--   CTE 3 calc_fallback_12m:
--     Para cada produto+localidade, calcula a média dos últimos 12 meses
--     contando retroativamente a partir da última data disponível.
--     Requer ≥3 meses de dados (HAVING COUNT(*) >= 3) para ser estatístico.
--
--   CTE 4 master_join:
--     LEFT JOIN de calc_ultimos_precos ← calc_base_2025 ← calc_fallback_12m.
--     COALESCE entre as duas âncoras. Se ambas NULL → INSUFICIENTE.
--
-- UPSERT: INSERT ... ON CONFLICT DO UPDATE.
-- Tempo esperado: < 1.5s para centenas de milhares de registros.
--
-- REGRA DO SEMÁFORO:
--   🟢 VERDE:     preco_atual < (preco_referencia * 0.85)  → queda ≥ 15%
--   🟡 AMARELO:   preco_atual entre ±15% da âncora
--   🔴 VERMELHO:  preco_atual > (preco_referencia * 1.15)  → alta > 15%
--   ⚪ INSUFICIENTE: sem baseline 2025 E sem fallback 12m
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE PROCEDURE staging.sp_calcular_sazonalidade_baseline()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio  TIMESTAMPTZ;
    v_fim     TIMESTAMPTZ;
    v_total   INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_calcular_sazonalidade_baseline] Iniciando...';

    WITH calc_base_2025 AS (
        -- ================================================================
        -- CTE 1: Preço Âncora Primário (Baseline 2025)
        -- AVG de todos os meses de 2025 por produto + localidade.
        -- O Brasil é continental: SP não contamina TO.
        -- ================================================================
        SELECT
            f.id_produto,
            f.id_localidade,
            AVG(f.preco_medio) AS preco_referencia_2025
        FROM staging.fact_precos_mensais f
        WHERE f.ano = 2025
          AND f.preco_medio IS NOT NULL
        GROUP BY f.id_produto, f.id_localidade
    ),
    calc_ultimos_precos AS (
        -- ================================================================
        -- CTE 2: Último preço registrado de cada produto+localidade
        -- ROW_NUMBER() particionado, ordenado do mais recente.
        -- rn=1 → o preço "atual".
        -- ================================================================
        SELECT
            f.id_produto,
            f.id_localidade,
            f.preco_medio   AS preco_atual,
            f.ano,
            f.mes,
            f.ano::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0')
                            AS data_referencia_atual,
            ROW_NUMBER() OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano DESC, f.mes DESC
            ) AS rn
        FROM staging.fact_precos_mensais f
        WHERE f.preco_medio IS NOT NULL
    ),
    calc_fallback_12m AS (
        -- ================================================================
        -- CTE 3: Preço Âncora Secundário (Fallback 12 Meses)
        --
        -- Para cada produto+localidade, isola o último período disponível
        -- (ano*12+mes) e calcula a média dos 12 meses anteriores.
        --
        -- HAVING COUNT(*) >= 3: mínimo estatístico. Produtos com 1-2 meses
        -- de dados não geram fallback (serão INSUFICIENTE).
        --
        -- Produtos COM baseline 2025 também passam por esta CTE, mas o
        -- COALESCE no master_join ignora o fallback quando 2025 existe.
        -- ================================================================
        SELECT
            f.id_produto,
            f.id_localidade,
            AVG(f.preco_medio) AS preco_fallback_12m
        FROM staging.fact_precos_mensais f
        JOIN (
            SELECT
                id_produto,
                id_localidade,
                MAX(ano * 12 + mes) AS ultimo_periodo
            FROM staging.fact_precos_mensais
            WHERE preco_medio IS NOT NULL
            GROUP BY id_produto, id_localidade
        ) p ON p.id_produto      = f.id_produto
           AND p.id_localidade   = f.id_localidade
        WHERE f.preco_medio IS NOT NULL
          -- Janela de 12 meses retroativos a partir do último período
          AND (f.ano * 12 + f.mes) > (p.ultimo_periodo - 12)
          AND (f.ano * 12 + f.mes) <= p.ultimo_periodo
        GROUP BY f.id_produto, f.id_localidade
        HAVING COUNT(*) >= 3  -- mínimo estatístico
    ),
    master_join AS (
        -- ================================================================
        -- CTE 4: O Motor Lógico (Junção + COALESCE + Semáforo)
        --
        -- LEFT JOIN a partir de calc_ultimos_precos (rn=1) porque TODO
        -- produto com preço deve gerar uma linha no snapshot.
        --
        -- preco_referencia = COALESCE(media_2025, fallback_12m)
        --
        --   - Produtos com 2025: media_2025 existe → usou_fallback = FALSE
        --   - Produtos só em 2026: media_2025 NULL, fallback existe → usou_fallback = TRUE
        --   - Produtos órfãos: ambos NULL → INSUFICIENTE
        --
        -- Proteção contra divisão por zero: NULLIF(preco_referencia, 0).
        -- ================================================================
        SELECT
            u.id_produto,
            u.id_localidade,
            u.preco_atual,
            u.data_referencia_atual,
            COALESCE(
                NULLIF(b.preco_referencia_2025, 0),
                f.preco_fallback_12m
            ) AS preco_referencia,
            -- Flag para o frontend: "este preço base NÃO é de 2025"
            (b.preco_referencia_2025 IS NULL
             AND f.preco_fallback_12m IS NOT NULL) AS usou_fallback_12m,
            CASE
                -- Âncora inexistente ou zerada → insuficiente
                WHEN COALESCE(b.preco_referencia_2025, f.preco_fallback_12m) IS NULL
                    THEN 'INSUFICIENTE'
                WHEN COALESCE(b.preco_referencia_2025, f.preco_fallback_12m) = 0
                    THEN 'INSUFICIENTE'
                -- Preço atual inexistente (não deveria ocorrer pois viemos
                -- de calc_ultimos_precos, mas segurança)
                WHEN u.preco_atual IS NULL
                    THEN 'INSUFICIENTE'
                -- Safra/Barato: ≥ 15% abaixo da âncora
                WHEN u.preco_atual < (
                        COALESCE(NULLIF(b.preco_referencia_2025, 0),
                                 f.preco_fallback_12m) * 0.85)
                    THEN 'VERDE'
                -- Entressafra/Caro: > 15% acima da âncora
                WHEN u.preco_atual > (
                        COALESCE(NULLIF(b.preco_referencia_2025, 0),
                                 f.preco_fallback_12m) * 1.15)
                    THEN 'VERMELHO'
                -- Faixa normal: oscilação de até ±15%
                ELSE 'AMARELO'
            END AS status_cor
        FROM calc_ultimos_precos u
        LEFT JOIN calc_base_2025 b
            ON b.id_produto    = u.id_produto
           AND b.id_localidade = u.id_localidade
           AND u.rn = 1
        LEFT JOIN calc_fallback_12m f
            ON f.id_produto    = u.id_produto
           AND f.id_localidade = u.id_localidade
    )
    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade,
        preco_referencia, preco_atual,
        data_referencia_atual, usou_fallback_12m,
        status_cor, fonte, calculado_em
    )
    SELECT
        mj.id_produto,
        mj.id_localidade,
        ROUND(mj.preco_referencia, 4),
        mj.preco_atual,
        mj.data_referencia_atual,
        mj.usou_fallback_12m,
        mj.status_cor,
        'municipio' AS fonte,
        NOW() AS calculado_em
    FROM master_join mj
    ON CONFLICT (id_produto, id_localidade)
    DO UPDATE SET
        preco_referencia      = EXCLUDED.preco_referencia,
        preco_atual           = EXCLUDED.preco_atual,
        data_referencia_atual = EXCLUDED.data_referencia_atual,
        usou_fallback_12m     = EXCLUDED.usou_fallback_12m,
        status_cor            = EXCLUDED.status_cor,
        fonte                 = EXCLUDED.fonte,
        calculado_em          = NOW();

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade_baseline] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

COMMENT ON PROCEDURE staging.sp_calcular_sazonalidade_baseline IS
    'Motor híbrido: Ano Âncora 2025 com fallback condicional de 12m. '
    '4 CTEs set-based: base_2025 → ultimos_precos → fallback_12m → master_join. '
    'COALESCE entre as âncoras. usou_fallback_12m sinaliza a origem. '
    'Upsert no mart.sazonalidade_produto.';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 4 — Materialized View (híbrida, com usou_fallback_12m)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--
--
-- Expõe para a API:
--   - preco_referencia: âncora (2025 ou fallback)
--   - preco_atual: último preço
--   - usou_fallback_12m: flag para o frontend
--   - data_referencia_atual, ano, mes: quando o preço atual foi registrado
--
-- FILTRO: WHERE categoria_b2c = 'ALIMENTO_VAREJO' — barreira antifraude B2B.
-- UNIQUE INDEX em id_sazonalidade para REFRESH CONCURRENTLY.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
SELECT
    s.id_sazonalidade,
    p.nome_produto              AS produto,
    p.classificao_produto,
    p.conab_id_produto,
    p.categoria_b2c,
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
    s.calculado_em
FROM mart.sazonalidade_produto s
JOIN staging.dim_produto    p ON p.id_produto    = s.id_produto
JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
WHERE s.status_cor != 'INSUFICIENTE'
  AND p.categoria_b2c = 'ALIMENTO_VAREJO'
ORDER BY s.status_cor, p.nome_produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'View híbrida B2C (Baseline 2025 + Fallback 12m). '
    'Expõe usou_fallback_12m para o frontend. '
    'Filtra ALIMENTO_VAREJO. UNIQUE INDEX para CONCURRENTLY.';

-- Índice UNIQUE obrigatório para REFRESH CONCURRENTLY
CREATE UNIQUE INDEX IF NOT EXISTS idx_vw_api_unique
    ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

-- Índice de filtro para a API (UF + município + status)
CREATE INDEX IF NOT EXISTS idx_vw_api_filtro
    ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);

REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 5 — Stored Procedure Mestre (atualizada)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE PROCEDURE staging.sp_executar_carga_completa()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Iniciando...';

    ANALYZE staging.fact_precos_mensais;
    CALL staging.sp_calcular_sazonalidade_baseline();
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Concluído em % seg',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

COMMENT ON PROCEDURE staging.sp_executar_carga_completa IS
    'Orquestrador mestre: ANALYZE → baseline híbrido → REFRESH MV CONCURRENTLY';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 6 — Permissões
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;

COMMIT;
