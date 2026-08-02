-- ============================================================================
-- QUERO COMPRAR — Fase 62: Engine Forecast V13 — Âncora 2024 + Margem 2025
-- PostgreSQL 16+
--
-- OBJETIVO:
--   Substituir a lógica de projeção da Engine Preditiva (Fase 30/40/41/51)
--   por um motor explícito de BASELINE PONDERADA 2024→2025:
--     1. Baseline 24_25 reconstruído (moda do status_cor real 2024/2025)
--     2. Nova tabela mart.sazonalidade_baseline_ponderada com a Matriz de
--        Decisão (60% âncora 2024 + 40% margem 2025) e cadeia de fallbacks:
--        ANCHOR_2024_MARGIN_2025 → PROXY_CATEGORIA_UF → LOCF_MES_ANTERIOR
--     3. Divergência entre anos → AMARELO (margem de risco) + eh_divergencia
--     4. st_calcular_forecast_2026_v13() lê a baseline ponderada e projeta
--        os meses de 2026 sem dado real, PRESERVANDO linhas reais
--        (is_forecast = FALSE) no ON CONFLICT
--     5. fn_br_nacional_sazonalidade recriada com forecast_method + calculado_em
--
-- ARQUITETURA (seções):
--   1. Rebuild mart.sazonalidade_baseline_24_25 (idempotente, re-grant)
--   2. CREATE mart.sazonalidade_baseline_ponderada (Matriz de Decisão + fallbacks)
--   3. ALTER CHECK chk_forecast_method (+ANCHOR/PROXY_CATEGORIA/LOCF)
--   4. sp_calcular_forecast_2026_v13() — projeção de 2026 lendo a ponderada
--   5. sp_executar_carga_completa() — passo 5 aponta p/ a nova engine
--   6. fn_br_nacional_sazonalidade() — + forecast_method, calculado_em
--
-- IDEMPOTÊNCIA: arquivo re-executável sem erro (DROP IF EXISTS, CREATE
-- OR REPLACE, DROP CONSTRAINT antes de ADD).
-- ============================================================================

BEGIN;
-- Controles de memória/paralelismo: o build da grade produto×localidade×12 meses
-- estourou a RAM da instância em produção (crash/OOM). work_mem moderado + menos
-- parallel workers evitam que N workers × work_mem virem OOM. statement_timeout é
-- rede de segurança (30min) — nunca aborta um lote legítimo.
SET lock_timeout = '30s';
SET work_mem = '128MB';
SET max_parallel_workers_per_gather = 2;
SET statement_timeout = '1800s';

-- ============================================================================
-- SEÇÃO 1 — Rebuild mart.sazonalidade_baseline_24_25
-- ============================================================================
-- Reconstrução idêntica à Fase 30: moda do status_cor real (is_forecast=FALSE)
-- de 2024 e 2025 por (id_produto, id_localidade, mes), usando SPLIT_PART.
-- O DROP TABLE remove os GRANTs — por isso o re-grant é obrigatório aqui.

DROP TABLE IF EXISTS mart.sazonalidade_baseline_24_25;

CREATE TABLE mart.sazonalidade_baseline_24_25 AS
WITH dados_reais AS (
    SELECT
        s.id_produto,
        s.id_localidade,
        CAST(SPLIT_PART(s.data_referencia_atual, '-', 2) AS INTEGER) AS mes,
        s.status_cor,
        COUNT(*) AS freq
    FROM mart.sazonalidade_produto s
    WHERE CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER) IN (2024, 2025)
      AND s.is_forecast = FALSE
    GROUP BY s.id_produto, s.id_localidade,
             CAST(SPLIT_PART(s.data_referencia_atual, '-', 2) AS INTEGER),
             s.status_cor
),
moda_por_mes AS (
    SELECT DISTINCT ON (id_produto, id_localidade, mes)
        id_produto,
        id_localidade,
        mes,
        status_cor AS status_cor_mode,
        freq,
        SUM(freq) OVER (PARTITION BY id_produto, id_localidade, mes) AS total_meses
    FROM dados_reais
    ORDER BY id_produto, id_localidade, mes, freq DESC
)
SELECT
    id_produto,
    id_localidade,
    mes,
    status_cor_mode,
    ROUND((freq::NUMERIC / total_meses) * 100, 2)::NUMERIC(5,2) AS confianca,
    'BASELINE_24_25' AS fonte,
    NOW() AS atualizado_em
FROM moda_por_mes;

-- Garante o shape de colunas + defaults (CREATE TABLE AS infere tipos)
ALTER TABLE mart.sazonalidade_baseline_24_25
    ALTER COLUMN id_produto     SET NOT NULL,
    ALTER COLUMN id_localidade  SET NOT NULL,
    ALTER COLUMN mes            SET NOT NULL,
    ALTER COLUMN status_cor_mode SET NOT NULL,
    ALTER COLUMN fonte          SET DEFAULT 'BASELINE_24_25',
    ALTER COLUMN atualizado_em  SET DEFAULT NOW();

COMMENT ON TABLE mart.sazonalidade_baseline_24_25 IS
    'Moda do status_cor por (produto, localidade, mes) calculada sobre 2024-2025 reais. '
    'Âncora primária da Baseline Ponderada V13.';

ALTER TABLE mart.sazonalidade_baseline_24_25
    ADD CONSTRAINT pk_sazonalidade_baseline_24_25
    PRIMARY KEY (id_produto, id_localidade, mes);

CREATE INDEX IF NOT EXISTS idx_baseline_24_25_mes
    ON mart.sazonalidade_baseline_24_25 (mes);

-- DROP TABLE remove grants — re-grant obrigatório
-- role_etl_writer precisa de acesso de tabela (a policy etl_writer_all só
-- filtra linhas para quem JÁ possui o privilégio — sem GRANT, é inerte).
GRANT SELECT, INSERT, UPDATE, DELETE ON mart.sazonalidade_baseline_24_25
    TO role_etl_writer;

GRANT SELECT ON mart.sazonalidade_baseline_24_25 TO role_api_reader;

-- O DROP TABLE também remove o flag de RLS e as policies criadas na 000016.
-- Restaura o desenho de defesa-em-profundidade da 000016:
ALTER TABLE mart.sazonalidade_baseline_24_25 ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS etl_writer_all ON mart.sazonalidade_baseline_24_25;
CREATE POLICY etl_writer_all ON mart.sazonalidade_baseline_24_25
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS api_reader_select ON mart.sazonalidade_baseline_24_25;
CREATE POLICY api_reader_select ON mart.sazonalidade_baseline_24_25
    FOR SELECT
    TO role_api_reader
    USING (true);

DO $$
DECLARE
    v_n BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_n FROM mart.sazonalidade_baseline_24_25;
    RAISE NOTICE '[62] Baseline 24_25 reconstruída: % linhas', v_n;
END;
$$;

-- ============================================================================
-- SEÇÃO 2 — CREATE mart.sazonalidade_baseline_ponderada
-- ============================================================================
-- Nova tabela com a Matriz de Decisão V13 (FULL JOIN das duas baselines).
--
-- Regras por célula (id_produto, id_localidade, mes):
--   1. Ambos anos, MESMO status  → status = status comum;
--      confianca = LEAST(0.6*c2024 + 0.4*c2025, 100); ANCHOR_2024_MARGIN_2025
--   2. Ambos anos, status DIFERENTES → status = 'AMARELO' (margem de risco);
--      confianca = LEAST(0.6*c2024 + 0.4*c2025, 40); eh_divergencia = TRUE;
--      ANCHOR_2024_MARGIN_2025
--   3. Só 2025 → status 2025; confianca = c2025; ANCHOR_2024_MARGIN_2025
--   4. Só 2024 → status 2024; confianca = c2024 * 0.5; ANCHOR_2024_MARGIN_2025
--   5. Nenhum ano → fallback CATEGORIA/UF: moda do status_cor real de produtos
--      da MESMA categoria (id_categoria via dim_produto→dim_categoria) na
--      mesma localidade e mês; confianca <= 25; PROXY_CATEGORIA_UF
--   6. Categoria vazia → LOCF: último status_cor real conhecido daquele
--      (produto, localidade) antes do mês corrente (qualquer ano);
--      confianca <= 15; LOCF_MES_ANTERIOR
--   7. Último recurso → status 'AMARELO'; confianca = 5; LOCF_MES_ANTERIOR
--
-- A grade dirige os pares (produto, localidade) com histórico real (baselines
-- 24_25/25_26 + dados reais 2026) × 12 meses, garantindo cobertura 100% dos
-- produtos exibidos (sem células cinzas). Versão otimizada anti-OOM/disco: o
-- CROSS JOIN completo de todos os produtos × todas as localidades gerava
-- ~4,85M linhas e estourou a instância de produção.

DROP TABLE IF EXISTS mart.sazonalidade_baseline_ponderada;

CREATE TABLE mart.sazonalidade_baseline_ponderada (
    id_produto           INTEGER     NOT NULL,
    id_localidade        INTEGER     NOT NULL,
    mes                  INTEGER     NOT NULL,
    status_cor_2024      TEXT,
    status_cor_2025      TEXT,
    status_cor_ponderado TEXT        NOT NULL,
    eh_divergencia       BOOLEAN     NOT NULL DEFAULT FALSE,
    confianca            NUMERIC(5,2),
    forecast_method      TEXT        NOT NULL,
    fonte                TEXT        NOT NULL DEFAULT 'BASELINE_PONDERADA',
    atualizado_em        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_sazonalidade_baseline_ponderada
        PRIMARY KEY (id_produto, id_localidade, mes)
);

COMMENT ON TABLE mart.sazonalidade_baseline_ponderada IS
    'Baseline Ponderada V13 — Matriz de Decisão âncora 2024 (60%) + margem 2025 (40%). '
    'Divergência entre anos → AMARELO + eh_divergencia. '
    'Fallbacks: PROXY_CATEGORIA_UF (mesma categoria/localidade/mês) e '
    'LOCF_MES_ANTERIOR (último status real conhecido). Cobertura 100% da grade.';

-- Índice de apoio para o fallback LOCF (último status real por produto/localidade):
-- evita seq scan no LATERAL abaixo e acelera a grade mensal.
CREATE INDEX IF NOT EXISTS idx_sazonalidade_locf_lookup
    ON mart.sazonalidade_produto (id_produto, id_localidade, data_referencia_atual DESC)
    WHERE is_forecast = FALSE AND status_cor IS NOT NULL;

-- Stats frescas antes do build pesado (evita plano ruim no CROSS JOIN da grade)
ANALYZE mart.sazonalidade_produto;
ANALYZE staging.dim_produto;

-- Build FATIADO POR MÊS (12 lotes): o CROSS JOIN completo produto×localidade×12
-- meses estourou a memória da instância em produção (crash/OOM observado). Cada
-- lote processa um único mês → pico de memória ~1/12, mantendo a atomicidade
-- (mesma transação) e o resultado final idêntico ao build original.
DO $$
DECLARE
    v_mes  INTEGER;
    v_lote INTEGER;
BEGIN
    FOR v_mes IN 1..12 LOOP
        INSERT INTO mart.sazonalidade_baseline_ponderada (
            id_produto, id_localidade, mes,
            status_cor_2024, status_cor_2025, status_cor_ponderado,
            eh_divergencia, confianca, forecast_method,
            fonte, atualizado_em
        )
        WITH
        -- Grade = pares (produto, localidade) com histórico REAL (baselines 24/25 e
        -- 25/26 + dados reais 2026) × 12 meses, SOMADO aos produtos novos/raros sem
        -- NENHUM histórico (criados em 2026) × 1 localidade representativa da
        -- categoria por UF (a com mais linhas reais da categoria naquele UF).
        -- ANTI-CAUSA-RAIZ do OOM/disco: o CROSS JOIN completo (todos os produtos ×
        -- todas as localidades) gerava ~404k pares/mês (~4,85M linhas) e estourou
        -- memória e disco em produção. A grade nacional agrega por UF; os fallbacks
        -- abaixo cobrem os meses faltantes de todos os pares (critério do plano:
        -- 100% dos produtos exibidos com 12 meses — inclui os novos via Open
        -- Question #1: moda da categoria na mesma UF).
        produtos_varejo AS (
            SELECT p.id_produto, p.id_categoria
            FROM staging.dim_produto p
            WHERE p.categoria_b2c = 'ALIMENTO_VAREJO'
        ),
        pares_historicos AS (
            SELECT id_produto, id_localidade FROM mart.sazonalidade_baseline_24_25
            UNION
            SELECT id_produto, id_localidade FROM mart.sazonalidade_baseline_25_26
            UNION
            SELECT DISTINCT id_produto, id_localidade
            FROM mart.sazonalidade_produto
            WHERE CAST(SPLIT_PART(data_referencia_atual, '-', 1) AS INTEGER) = 2026
              AND is_forecast = FALSE
        ),
        -- Produtos ALIMENTO_VAREJO sem NENHUM histórico real (novos/raros de 2026):
        -- cobertos via moda da categoria na mesma UF (Open Question #1 do plano).
        novos_produtos AS (
            SELECT p.id_produto, p.id_categoria
            FROM produtos_varejo p
            WHERE NOT EXISTS (
                SELECT 1 FROM pares_historicos ph WHERE ph.id_produto = p.id_produto
            )
        ),
        -- Localidade representativa por (categoria, UF): a com mais linhas reais da
        -- categoria naquele UF (desempate: menor id_localidade). Filtros alinhados ao
        -- categoria_status (ALIMENTO_VAREJO + status_cor NOT NULL) para a localidade
        -- escolhida ter dados válidos da categoria. Volume resultante:
        -- ~74 produtos × ~27 UFs × 12 meses ≈ 24k linhas (vs 4,85M do CROSS JOIN).
        localidade_categoria_uf AS (
            SELECT DISTINCT ON (p2.id_categoria, l.uf)
                p2.id_categoria,
                l.uf,
                s2.id_localidade
            FROM mart.sazonalidade_produto s2
            JOIN staging.dim_produto p2 ON p2.id_produto = s2.id_produto
            JOIN staging.dim_localidade l ON l.id_localidade = s2.id_localidade
            WHERE s2.is_forecast = FALSE
              AND s2.status_cor IS NOT NULL
              AND p2.categoria_b2c = 'ALIMENTO_VAREJO'
              AND p2.id_categoria IS NOT NULL
            GROUP BY p2.id_categoria, l.uf, s2.id_localidade
            ORDER BY p2.id_categoria, l.uf, COUNT(*) DESC, s2.id_localidade
        ),
        grade_novos AS (
            SELECT
                np.id_produto,
                np.id_categoria,
                lc.id_localidade,
                v_mes AS mes
            FROM novos_produtos np
            JOIN localidade_categoria_uf lc ON lc.id_categoria = np.id_categoria
        ),
        grade AS (
            SELECT
                pv.id_produto,
                pv.id_categoria,
                ph.id_localidade,
                v_mes AS mes
            FROM pares_historicos ph
            JOIN produtos_varejo pv ON pv.id_produto = ph.id_produto
            UNION ALL
            SELECT id_produto, id_categoria, id_localidade, mes FROM grade_novos
        ),
        -- Fallback por CATEGORIA/UF: moda do status_cor real de produtos da mesma
        -- categoria na mesma localidade e mês (restrito ao mês corrente do lote)
        categoria_status AS (
            SELECT
                s2.id_localidade,
                p2.id_categoria,
                MODE() WITHIN GROUP (ORDER BY s2.status_cor) AS status_categoria,
                LEAST(25.0, COUNT(DISTINCT s2.id_produto) * 5.0) AS confianca_categoria
            FROM mart.sazonalidade_produto s2
            JOIN staging.dim_produto p2 ON p2.id_produto = s2.id_produto
            WHERE s2.is_forecast = FALSE
              AND s2.status_cor IS NOT NULL
              AND p2.categoria_b2c = 'ALIMENTO_VAREJO'
              AND p2.id_categoria IS NOT NULL
              AND CAST(SPLIT_PART(s2.data_referencia_atual, '-', 2) AS INTEGER) = v_mes
            GROUP BY s2.id_localidade, p2.id_categoria
        ),
        resolvido AS (
            SELECT
                g.id_produto,
                g.id_localidade,
                g.mes,
                g.id_categoria,
                b24.status_cor_mode AS status_2024,
                b24.confianca       AS conf_2024,
                b25.status_cor_mode AS status_2025,
                b25.confianca       AS conf_2025,
                cs.status_categoria,
                cs.confianca_categoria,
                (b24.status_cor_mode IS NOT NULL AND b25.status_cor_mode IS NOT NULL
                 AND b24.status_cor_mode <> b25.status_cor_mode) AS eh_divergencia,
                -- status resolvido pelas baselines (NULL = sem nenhuma baseline)
                CASE
                    WHEN b24.status_cor_mode IS NOT NULL AND b25.status_cor_mode IS NOT NULL
                         AND b24.status_cor_mode = b25.status_cor_mode
                        THEN b24.status_cor_mode
                    WHEN b24.status_cor_mode IS NOT NULL AND b25.status_cor_mode IS NOT NULL
                         AND b24.status_cor_mode <> b25.status_cor_mode
                        THEN 'AMARELO'
                    WHEN b25.status_cor_mode IS NOT NULL THEN b25.status_cor_mode
                    WHEN b24.status_cor_mode IS NOT NULL THEN b24.status_cor_mode
                    ELSE NULL
                END AS status_baseline,
                -- confiança resolvida pelas baselines (60/40, caps divergência)
                CASE
                    WHEN b24.status_cor_mode IS NOT NULL AND b25.status_cor_mode IS NOT NULL
                        THEN LEAST(
                                 0.6 * COALESCE(b24.confianca, 0) + 0.4 * COALESCE(b25.confianca, 0),
                                 CASE WHEN b24.status_cor_mode = b25.status_cor_mode THEN 100 ELSE 40 END
                             )
                    WHEN b25.status_cor_mode IS NOT NULL THEN b25.confianca
                    WHEN b24.status_cor_mode IS NOT NULL THEN b24.confianca * 0.5
                    ELSE NULL
                END AS confianca_baseline
            FROM grade g
            LEFT JOIN mart.sazonalidade_baseline_24_25 b24
                ON b24.id_produto = g.id_produto
               AND b24.id_localidade = g.id_localidade
               AND b24.mes = g.mes
            LEFT JOIN mart.sazonalidade_baseline_25_26 b25
                ON b25.id_produto = g.id_produto
               AND b25.id_localidade = g.id_localidade
               AND b25.mes = g.mes
            LEFT JOIN categoria_status cs
                ON cs.id_localidade = g.id_localidade
               AND cs.id_categoria  = g.id_categoria
        ),
        sem_base AS (
            SELECT * FROM resolvido WHERE status_baseline IS NULL
        )
        -- (1)-(4) Baselines: âncora 2024 + margem 2025
        SELECT
            r.id_produto, r.id_localidade, r.mes,
            r.status_2024, r.status_2025, r.status_baseline,
            r.eh_divergencia, r.confianca_baseline,
            'ANCHOR_2024_MARGIN_2025', 'BASELINE_PONDERADA', NOW()
        FROM resolvido r
        WHERE r.status_baseline IS NOT NULL
        -- (5) Fallback categoria/UF
        UNION ALL
        SELECT
            s.id_produto, s.id_localidade, s.mes,
            NULL, NULL, s.status_categoria,
            FALSE, s.confianca_categoria,
            'PROXY_CATEGORIA_UF', 'BASELINE_PONDERADA', NOW()
        FROM sem_base s
        WHERE s.status_categoria IS NOT NULL
        -- (6)/(7) LOCF do último status real conhecido antes do mês, senão último recurso
        UNION ALL
        SELECT
            s.id_produto, s.id_localidade, s.mes,
            NULL, NULL,
            COALESCE(l.locf_status, 'AMARELO'),
            FALSE,
            CASE WHEN l.locf_status IS NOT NULL THEN 15.0 ELSE 5.0 END,
            'LOCF_MES_ANTERIOR', 'BASELINE_PONDERADA', NOW()
        FROM (
            SELECT * FROM sem_base WHERE status_categoria IS NULL
        ) s
        LEFT JOIN LATERAL (
            SELECT s2.status_cor AS locf_status
            FROM mart.sazonalidade_produto s2
            WHERE s2.id_produto = s.id_produto
              AND s2.id_localidade = s.id_localidade
              AND s2.is_forecast = FALSE
              AND s2.status_cor IS NOT NULL
              AND s2.data_referencia_atual < '2026-' || LPAD(v_mes::TEXT, 2, '0')
            ORDER BY s2.data_referencia_atual DESC
            LIMIT 1
        ) l ON TRUE;

        GET DIAGNOSTICS v_lote = ROW_COUNT;
        RAISE NOTICE '[62] Lote mês %: % linhas', v_mes, v_lote;
    END LOOP;
END;
$$;

-- Índices auxiliares
CREATE INDEX IF NOT EXISTS idx_baseline_ponderada_mes
    ON mart.sazonalidade_baseline_ponderada (mes);

CREATE INDEX IF NOT EXISTS idx_baseline_ponderada_prod
    ON mart.sazonalidade_baseline_ponderada (id_produto);

-- A engine v13 (sp_calcular_forecast_2026_v13) lê esta tabela em runtime:
-- role_etl_writer precisa de acesso (INSERT/UPDATE do rebuild + SELECT na leitura).
GRANT SELECT, INSERT, UPDATE, DELETE ON mart.sazonalidade_baseline_ponderada
    TO role_etl_writer;

GRANT SELECT ON mart.sazonalidade_baseline_ponderada TO role_api_reader;

-- RLS consistente com o padrão 000016 (defesa-em-profundidade)
ALTER TABLE mart.sazonalidade_baseline_ponderada ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS etl_writer_all ON mart.sazonalidade_baseline_ponderada;
CREATE POLICY etl_writer_all ON mart.sazonalidade_baseline_ponderada
    FOR ALL
    TO role_etl_writer
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS api_reader_select ON mart.sazonalidade_baseline_ponderada;
CREATE POLICY api_reader_select ON mart.sazonalidade_baseline_ponderada
    FOR SELECT
    TO role_api_reader
    USING (true);

DO $$
DECLARE
    v_total BIGINT;
    v_gray  BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_total FROM mart.sazonalidade_baseline_ponderada;
    SELECT COUNT(*) INTO v_gray FROM mart.sazonalidade_baseline_ponderada
    WHERE status_cor_ponderado IS NULL OR forecast_method IS NULL;
    RAISE NOTICE '[62] Baseline ponderada: % linhas (cinzas: %)', v_total, v_gray;
END;
$$;

-- ============================================================================
-- SEÇÃO 3 — ALTER CHECK chk_forecast_method
-- ============================================================================
-- Mantém o conjunto atual EXATAMENTE (migration 40) + os 3 novos métodos V13.
-- A constraint preserva a permissão de NULL (NULL = dado real).

ALTER TABLE mart.sazonalidade_produto
    DROP CONSTRAINT IF EXISTS chk_forecast_method;

-- Supabase pode ter constraint com nome auto-gerado
ALTER TABLE mart.sazonalidade_produto
    DROP CONSTRAINT IF EXISTS sazonalidade_produto_forecast_method_check;

ALTER TABLE mart.sazonalidade_produto
    ADD CONSTRAINT chk_forecast_method
    CHECK (forecast_method IS NULL
           OR forecast_method IN (
               'gamma_forecast_baseline',
               'alpha_baseline_25_26',
               'beta_media_disponivel',
               'beta_weighted_25_24',
               'SANDUICHE_MEDIA_24_25',
               'SANDUICHE_FATOR_SAZONAL',
               'PROXY_HIERARQUICO',
               'LOCF_SINGLE_MONTH',         -- ← preservado da 000018 (28 linhas no banco)
               'ANCHOR_2024_MARGIN_2025',   -- ← NOVO V13: âncora 2024 + margem 2025
               'PROXY_CATEGORIA_UF',        -- ← NOVO V13: fallback por categoria/UF
               'LOCF_MES_ANTERIOR'          -- ← NOVO V13: last-known carry-forward
            ));

COMMENT ON COLUMN mart.sazonalidade_produto.forecast_method IS
    'Método de geração: NULL=dado real; LOCF_SINGLE_MONTH=LOCF de gap de 1 mês; '
    'SANDUICHE_MEDIA_24_25=média histórica; PROXY_HIERARQUICO=herança de produto pai; '
    'ANCHOR_2024_MARGIN_2025=âncora 2024 + margem 2025 (60/40); '
    'PROXY_CATEGORIA_UF=fallback mesma categoria/UF; LOCF_MES_ANTERIOR=último status real conhecido.';

-- ============================================================================
-- SEÇÃO 3b — ALTER CHECK de fonte (permitir 'BASELINE_HISTORICO')
-- ============================================================================
-- A 000005 criou sazonalidade_produto com CHECK (fonte IN ('municipio','uf')).
-- A engine de forecast (000013 e a V13) insere linhas projetadas com
-- fonte='BASELINE_HISTORICO' em runtime — sem relaxar o check, o INSERT da
-- procedure V13 falharia. O banco vivo já tem esse check relaxado via
-- scripts/restore/fix_supabase_schema.sql; esta seção garante o mesmo em
-- qualquer ambiente (idempotente: lookup genérico + DROP + ADD, padrão
-- da migration 19).

DO $$
DECLARE
    v_conname TEXT;
BEGIN
    -- Lookup por NOME da constraint (mais preciso que pg_get_constraintdef):
    -- o nome auto-gerado do CHECK de fonte é sazonalidade_produto_fonte_check.
    SELECT conname INTO v_conname
    FROM pg_constraint
    WHERE conrelid = 'mart.sazonalidade_produto'::regclass
      AND contype = 'c'
      AND conname ILIKE '%fonte%';
    IF v_conname IS NOT NULL THEN
        EXECUTE format('ALTER TABLE mart.sazonalidade_produto DROP CONSTRAINT %I', v_conname);
    END IF;
END;
$$;

ALTER TABLE mart.sazonalidade_produto
    ADD CONSTRAINT sazonalidade_produto_fonte_check
    CHECK (fonte = ANY (ARRAY['municipio'::text, 'uf'::text, 'BASELINE_HISTORICO'::text]));

COMMENT ON CONSTRAINT sazonalidade_produto_fonte_check ON mart.sazonalidade_produto IS
    'Fonte permitida: municipio/uf (dados reais do scraper) ou BASELINE_HISTORICO (projeção de forecast).';

-- ============================================================================
-- SEÇÃO 4 — Stored Procedure — Motor de Forecast 2026 V13
-- ============================================================================
-- Lê mart.sazonalidade_baseline_ponderada (não reconstrói baselines — a
-- migration top-level faz isso). Projeta meses de 2026 sem dado real.
--
-- ON CONFLICT CRÍTICO: quando a linha existente é REAL (is_forecast = FALSE),
-- preserva status_cor/fonte/forecast_method/tendencia_futura etc. da linha
-- real (espelhando o padrão do Sanduíche). Só sobrescreve projeções.

CREATE OR REPLACE PROCEDURE staging.sp_calcular_forecast_2026_v13()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio  TIMESTAMPTZ;
    v_fim     TIMESTAMPTZ;
    v_total   INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_calcular_forecast_2026_v13] Iniciando Forecast 2026 (âncora 2024 + margem 2025)...';

    WITH baseline_ponderada AS (
        SELECT
            id_produto,
            id_localidade,
            mes,
            status_cor_ponderado AS status_cor_mode,
            confianca,
            forecast_method
        FROM mart.sazonalidade_baseline_ponderada
    ),
    -- Meses de 2026 que já têm dado real (is_forecast = FALSE)
    dados_reais_2026 AS (
        SELECT DISTINCT
            s.id_produto,
            s.id_localidade,
            CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER) AS ano,
            CAST(SPLIT_PART(s.data_referencia_atual, '-', 2) AS INTEGER) AS mes
        FROM mart.sazonalidade_produto s
        WHERE CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER) = 2026
          AND s.is_forecast = FALSE
    ),
    meses_2026 AS (
        SELECT generate_series(1, 12) AS mes
    ),
    produtos_com_baseline AS (
        SELECT DISTINCT id_produto, id_localidade
        FROM baseline_ponderada
    ),
    grade_completa AS (
        SELECT
            p.id_produto,
            p.id_localidade,
            m.mes
        FROM produtos_com_baseline p
        CROSS JOIN meses_2026 m
    ),
    meses_com_dado_real AS (
        SELECT DISTINCT id_produto, id_localidade, mes
        FROM dados_reais_2026
    ),
    meses_faltantes AS (
        SELECT g.id_produto, g.id_localidade, g.mes
        FROM grade_completa g
        LEFT JOIN meses_com_dado_real r
            ON r.id_produto = g.id_produto
           AND r.id_localidade = g.id_localidade
           AND r.mes = g.mes
        WHERE r.id_produto IS NULL
    ),
    projecao_faltantes AS (
        SELECT
            mf.id_produto,
            mf.id_localidade,
            2026 AS ano,
            mf.mes,
            b.status_cor_mode       AS status_cor,
            b.confianca             AS baseline_confianca,
            b.forecast_method       AS forecast_method,
            TRUE                    AS is_forecast,
            'BASELINE_HISTORICO'::TEXT AS fonte,
            NOW()                   AS calculado_em,
            CASE
                WHEN LAG(b.status_cor_mode) OVER (PARTITION BY b.id_produto, b.id_localidade ORDER BY b.mes) IS NULL
                    THEN 'ESTAVEL'
                WHEN LAG(b.status_cor_mode) OVER (PARTITION BY b.id_produto, b.id_localidade ORDER BY b.mes) = b.status_cor_mode
                    THEN 'ESTAVEL'
                WHEN LAG(b.status_cor_mode) OVER (PARTITION BY b.id_produto, b.id_localidade ORDER BY b.mes) = 'VERDE'
                     AND b.status_cor_mode = 'AMARELO'
                    THEN 'ALTA'
                WHEN LAG(b.status_cor_mode) OVER (PARTITION BY b.id_produto, b.id_localidade ORDER BY b.mes) = 'AMARELO'
                     AND b.status_cor_mode = 'VERDE'
                    THEN 'QUEDA'
                WHEN LAG(b.status_cor_mode) OVER (PARTITION BY b.id_produto, b.id_localidade ORDER BY b.mes) = 'VERMELHO'
                     AND b.status_cor_mode = 'AMARELO'
                    THEN 'QUEDA'
                WHEN LAG(b.status_cor_mode) OVER (PARTITION BY b.id_produto, b.id_localidade ORDER BY b.mes) = 'AMARELO'
                     AND b.status_cor_mode = 'VERMELHO'
                    THEN 'ALTA'
                ELSE 'ESTAVEL'
            END AS tendencia_futura,
            2026::TEXT || '-' || LPAD(mf.mes::TEXT, 2, '0') AS data_referencia_atual,
            NULL::NUMERIC(14,4)     AS preco_referencia,
            NULL::NUMERIC(14,4)     AS preco_atual,
            NULL::NUMERIC(14,4)     AS preco_mes_anterior,
            0::NUMERIC(8,4)         AS variacao_mom_pct,
            FALSE                   AS preco_estimado,
            FALSE                   AS usou_fallback_12m
        FROM meses_faltantes mf
        JOIN baseline_ponderada b
            ON b.id_produto = mf.id_produto
           AND b.id_localidade = mf.id_localidade
           AND b.mes = mf.mes
    )
    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade, ano, mes,
        preco_referencia, preco_atual, preco_mes_anterior, variacao_mom_pct,
        data_referencia_atual, status_cor, fonte, calculado_em,
        metodo_calculo, tendencia_futura, is_forecast,
        baseline_confianca, forecast_method,
        preco_estimado, usou_fallback_12m
    )
    SELECT DISTINCT ON (u.id_produto, u.id_localidade, u.ano, u.mes)
        u.id_produto,
        u.id_localidade,
        u.ano,
        u.mes,
        u.preco_referencia,
        u.preco_atual,
        u.preco_mes_anterior,
        u.variacao_mom_pct,
        u.data_referencia_atual,
        u.status_cor,
        u.fonte,
        u.calculado_em,
        u.forecast_method,          -- metodo_calculo espelha o método V13
        u.tendencia_futura,
        u.is_forecast,
        u.baseline_confianca,
        u.forecast_method,
        u.preco_estimado,
        u.usou_fallback_12m
    FROM projecao_faltantes u
    ORDER BY u.id_produto, u.id_localidade, u.ano, u.mes, u.is_forecast ASC
    ON CONFLICT (id_produto, id_localidade, ano, mes)
    DO UPDATE SET
        preco_referencia      = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.preco_referencia
                                    ELSE EXCLUDED.preco_referencia
                                 END,
        preco_atual           = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.preco_atual
                                    ELSE EXCLUDED.preco_atual
                                 END,
        preco_mes_anterior    = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.preco_mes_anterior
                                    ELSE EXCLUDED.preco_mes_anterior
                                 END,
        variacao_mom_pct      = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.variacao_mom_pct
                                    ELSE EXCLUDED.variacao_mom_pct
                                 END,
        data_referencia_atual = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.data_referencia_atual
                                    ELSE EXCLUDED.data_referencia_atual
                                 END,
        status_cor            = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.status_cor
                                    ELSE EXCLUDED.status_cor
                                 END,
        fonte                 = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.fonte
                                    ELSE EXCLUDED.fonte
                                 END,
        metodo_calculo        = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.metodo_calculo
                                    ELSE EXCLUDED.metodo_calculo
                                 END,
        tendencia_futura      = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.tendencia_futura
                                    ELSE EXCLUDED.tendencia_futura
                                 END,
        forecast_method       = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.forecast_method
                                    ELSE EXCLUDED.forecast_method
                                 END,
        baseline_confianca    = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.baseline_confianca
                                    ELSE EXCLUDED.baseline_confianca
                                 END,
        preco_estimado        = CASE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE
                                    THEN mart.sazonalidade_produto.preco_estimado
                                    ELSE EXCLUDED.preco_estimado
                                 END,
        usou_fallback_12m     = COALESCE(mart.sazonalidade_produto.usou_fallback_12m, FALSE),
        is_forecast           = CASE
                                    WHEN EXCLUDED.is_forecast = FALSE THEN FALSE
                                    WHEN mart.sazonalidade_produto.is_forecast = FALSE THEN FALSE
                                    WHEN mart.sazonalidade_produto.is_forecast = TRUE
                                         AND EXCLUDED.is_forecast = TRUE THEN TRUE
                                    ELSE mart.sazonalidade_produto.is_forecast
                                END,
        calculado_em          = NOW();

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_forecast_2026_v13] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);

    -- Refresh da MV
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
    RAISE NOTICE '[sp_calcular_forecast_2026_v13] MV atualizada.';
END;
$$;

COMMENT ON PROCEDURE staging.sp_calcular_forecast_2026_v13 IS
    'Engine Preditiva V13 — Projeta meses de 2026 sem dado real usando a '
    'Baseline Ponderada (âncora 2024 60% + margem 2025 40%; divergência → AMARELO; '
    'fallback PROXY_CATEGORIA_UF / LOCF_MES_ANTERIOR). '
    'ON CONFLICT preserva linhas reais (is_forecast=FALSE). '
    'forecast_method registra o método V13 por linha.';

GRANT ALL ON PROCEDURE staging.sp_calcular_forecast_2026_v13 TO role_etl_writer;

-- ============================================================================
-- SEÇÃO 5 — sp_executar_carga_completa (passo 5 → nova engine V13)
-- ============================================================================
-- Cópia fiel da migration 58 (6 passos + EXISTS guards nos passos 1-3),
-- trocando apenas a chamada do passo 5 para sp_calcular_forecast_2026_v13().

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

    -- 5. Forecast 2026 — NOVO: Engine V13 (âncora 2024 + margem 2025)
    CALL staging.sp_calcular_forecast_2026_v13();
    RAISE NOTICE '[sp_executar_carga_completa] Forecast 2026 V13 (status_cor) OK';

    -- 6. Sanduíche Sazonal (projeta PREÇO NUMÉRICO para meses faltantes)
    --    Guard EXISTS: a proc é aplicada via database/40/51 no banco vivo, mas
    --    pode não existir em outros ambientes — espelha o padrão das etapas 1-3
    --    (e o da migration 000019).
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
    'Sanduíche Sazonal (preço numérico). Deve ser chamado após cada ciclo de coleta.';

GRANT ALL ON PROCEDURE staging.sp_executar_carga_completa TO role_etl_writer;

-- ============================================================================
-- SEÇÃO 6 — fn_br_nacional_sazonalidade (+ forecast_method, calculado_em)
-- ============================================================================
-- Mantém a agregação atual (moda da moda por UF, BOOL_OR is_forecast,
-- MAX baseline_confianca, COUNT(DISTINCT uf) com HAVING >= v_min_ufs) e
-- ADICIONA forecast_method (MODE) e calculado_em (MAX).
-- DROP + CREATE porque PostgreSQL não permite CREATE OR REPLACE com
-- RETURNS TABLE diferente (mesmo padrão da migration 37).

DROP FUNCTION IF EXISTS mart.fn_br_nacional_sazonalidade(INTEGER, TEXT);
-- Overload vigente no banco vivo (aplicada via psql — p_min_ufs). DROP obrigatório:
-- CREATE FUNCTION sem OR REPLACE falharia com "already exists" na assinatura (INTEGER, TEXT, INTEGER).
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
        -- Nível 1: consolida por (produto, UF, mes) — moda dentro da UF
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
    -- Nível 2: agrega por (produto, mes) — moda da moda entre UFs
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
    'Moda da moda por UF, HAVING COUNT(DISTINCT uf) >= p_min_ufs (default 1). '
    'Inclui forecast_method (moda) e calculado_em (máximo). '
    'Uso: SELECT * FROM mart.fn_br_nacional_sazonalidade(2026);';

-- Grants espelhando a função atual (somente role_api_reader, como na 31)
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER)
    TO role_api_reader;

COMMIT;
