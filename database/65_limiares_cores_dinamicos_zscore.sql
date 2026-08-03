-- ============================================================================
-- QUERO COMPRAR — Fase 65: Limiares Dinâmicos de Cor (Z-Score por Volatilidade)
-- PostgreSQL 16+
--
-- OBJETIVO (limiares-cores-dinamicos-zscore):
--   Substituir o modelo ESTÁTICO do semáforo (±25% fixo na view/MV 63:88,
--   ±15% fixo na procedure 59) por limiares DINÂMICOS baseados no desvio
--   padrão histórico de cada (id_produto, id_localidade), calculado sobre os
--   últimos 24 meses REAIS de staging.fact_precos_mensais:
--
--     VERDE    se preco_exibido <  preco_referencia - 1.0 * desvio_padrao
--     VERMELHO se preco_exibido >  preco_referencia + 1.0 * desvio_padrao
--     AMARELO  caso contrário (incl. base insuficiente / sem estatística)
--
--   Um ±25% fixo trata Arroz (baixa volatilidade) e Tomate (alta
--   volatilidade) de forma idêntica — escondendo anomalias e superproduzindo
--   AMARELO. O modelo dinâmico adapta a faixa ao histórico de cada produto.
--   Piso de segurança (CV mínimo 10%): produtos com desvio nulo/zero ou CV
--   < 10% usam desvio_efetivo = 10% da média (banda mínima não-degenerada).
--
-- FASES:
--   FASE 1 — staging.fn_estatisticas_volatilidade_24m(): AVG/STDDEV/COUNT
--            por (id_produto, id_localidade) na janela dos últimos 24 meses
--            reais + desvio_efetivo com piso de CV 10% (mesmo STDDEV amostral
--            da Fase 10).
--   FASE 2 — staging.fn_status_cor_zscore(preco_exibido, preco_referencia,
--            desvio_padrao): semáforo dinâmico ±1σ (estilo 57 fn_regra_25).
--   FASE 3 — Propagação ao mart:
--              3.1. 3 colunas em mart.sazonalidade_produto
--                   (desvio_padrao_historico, limite_superior, limite_inferior);
--              3.2. UPDATE full da base (regra dinâmica + limites);
--              3.3. sp_calcular_sazonalidade() — CASE ±15% substituído pela
--                   regra dinâmica via LATERAL + gravação das 3 colunas;
--              3.4. mart.vw_anchor_sazonalidade — status_cor dinâmico via
--                   LATERAL + 3 novas colunas no output;
--              3.5. MV mart.vw_api_produtos_sazonalidade V18 (DROP+CREATE,
--                   WITH DATA, MESMOS 3 branches / colunas / 7 índices /
--                   GRANTs — apenas 3 colunas adicionadas).
--   FASE 4 — (proof query executada pelo orchestrator após o apply).
--
-- IDEMPOTÊNCIA: CREATE OR REPLACE / ADD COLUMN IF NOT EXISTS / DROP IF
-- EXISTS; MV recriada com DROP + CREATE (CREATE OR REPLACE não existe para
-- MV) + WITH DATA (popula no próprio apply — satisfaz o refresh).
-- Não toca em backup_schema_latest.sql (regenerado automaticamente).
-- ============================================================================

BEGIN;

-- ============================================================================
-- FASE 1 — Volatilidade por (produto, localidade): AVG/STDDEV 24m + piso CV
-- ============================================================================
-- Janela = últimos 24 meses reais relativa ao (ano,mes) mais recente da fact.
-- STDDEV amostral (igual à Fase 10). desvio_efetivo aplica o piso de CV 10%
-- para produtos com desvio nulo/zero ou quase nulo (baixa amostragem).

CREATE OR REPLACE FUNCTION staging.fn_estatisticas_volatilidade_24m()
RETURNS TABLE (
    id_produto                 INTEGER,
    id_localidade              INTEGER,
    media_historica            NUMERIC(14,4),
    desvio_padrao_historico    NUMERIC(14,4),
    n_meses                    INTEGER,
    desvio_efetivo             NUMERIC(14,4)
)
LANGUAGE sql
STABLE
AS $$
    WITH max_data AS (
        SELECT MAX(ano * 12 + mes) AS max_periodo
        FROM staging.fact_precos_mensais
    ),
    janela AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            f.preco_medio
        FROM staging.fact_precos_mensais f
        CROSS JOIN max_data m
        WHERE f.ano * 12 + f.mes > m.max_periodo - 24
          AND f.preco_medio > 0
    )
    SELECT
        j.id_produto,
        j.id_localidade,
        AVG(j.preco_medio)::NUMERIC(14,4)                  AS media_historica,
        STDDEV(j.preco_medio)::NUMERIC(14,4)               AS desvio_padrao_historico,
        COUNT(*)::INTEGER                                  AS n_meses,
        CASE
            WHEN AVG(j.preco_medio) IS NULL OR AVG(j.preco_medio) = 0
                THEN NULL
            WHEN STDDEV(j.preco_medio) IS NULL
              OR STDDEV(j.preco_medio) = 0
              OR (STDDEV(j.preco_medio) / AVG(j.preco_medio)) < 0.10
                THEN ROUND(0.10 * AVG(j.preco_medio), 4)   -- CV mínimo 10%
            ELSE STDDEV(j.preco_medio)
        END::NUMERIC(14,4)                                 AS desvio_efetivo
    FROM janela j
    GROUP BY j.id_produto, j.id_localidade;
$$;

COMMENT ON FUNCTION staging.fn_estatisticas_volatilidade_24m IS
    'Estatísticas de volatilidade por (produto, localidade) sobre os últimos '
    '24 meses reais de staging.fact_precos_mensais (janela relativa ao (ano,mes) '
    'mais recente). STDDEV amostral; desvio_efetivo aplica piso de CV mínimo '
    '10%% (ROUND(0.10 * media)) quando o desvio é nulo/zero ou CV < 10%% — '
    'garante banda mínima não-degenerada. Uso: SELECT * FROM staging.fn_estatisticas_volatilidade_24m();';

GRANT EXECUTE ON FUNCTION staging.fn_estatisticas_volatilidade_24m()
    TO role_etl_writer;

-- ============================================================================
-- FASE 2 — Semáforo dinâmico Z-Score (±1σ em torno da referência)
-- ============================================================================
-- Estilo fn_status_cor_regra_25 (57:71): retorna NULL se algum argumento for
-- inválido (o chamador decide o fallback, normalmente AMARELO).

CREATE OR REPLACE FUNCTION staging.fn_status_cor_zscore(
    p_preco_exibido      NUMERIC,
    p_preco_referencia   NUMERIC,
    p_desvio_padrao      NUMERIC
)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
        WHEN p_preco_exibido IS NULL OR p_preco_exibido <= 0 THEN NULL
        WHEN p_preco_referencia IS NULL OR p_preco_referencia <= 0 THEN NULL
        WHEN p_desvio_padrao IS NULL OR p_desvio_padrao <= 0 THEN NULL
        WHEN p_preco_exibido < (p_preco_referencia - p_desvio_padrao) THEN 'VERDE'
        WHEN p_preco_exibido > (p_preco_referencia + p_desvio_padrao) THEN 'VERMELHO'
        ELSE 'AMARELO'
    END
$$;

COMMENT ON FUNCTION staging.fn_status_cor_zscore(NUMERIC, NUMERIC, NUMERIC) IS
    'Semáforo dinâmico ±1 desvio padrão: VERDE se preco_exibido < (ref - σ); '
    'VERMELHO se preco_exibido > (ref + σ); senão AMARELO. σ = desvio_efetivo '
    'de fn_estatisticas_volatilidade_24m. Retorna NULL se qualquer argumento '
    'for NULL ou <= 0 (chamador aplica fallback, normalmente AMARELO).';

GRANT EXECUTE ON FUNCTION staging.fn_status_cor_zscore(NUMERIC, NUMERIC, NUMERIC)
    TO role_etl_writer;

-- ============================================================================
-- FASE 3.1 — Colunas de limiares dinâmicos em mart.sazonalidade_produto
-- ============================================================================

ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS desvio_padrao_historico NUMERIC(14,4),
    ADD COLUMN IF NOT EXISTS limite_superior         NUMERIC(14,4),
    ADD COLUMN IF NOT EXISTS limite_inferior         NUMERIC(14,4);

COMMENT ON COLUMN mart.sazonalidade_produto.desvio_padrao_historico IS
    'Desvio padrão efetivo (últimos 24 meses reais, piso CV 10%) usado nos '
    'limiares dinâmicos do semáforo. NULL quando o (produto, localidade) não '
    'tem estatística na janela.';
COMMENT ON COLUMN mart.sazonalidade_produto.limite_superior IS
    'COALESCE(preco_referencia, media_movel_12m, preco_medio) + desvio_padrao_historico '
    '(limiar superior do AMARELO dinâmico — acima dele → VERMELHO).';
COMMENT ON COLUMN mart.sazonalidade_produto.limite_inferior IS
    'COALESCE(preco_referencia, media_movel_12m, preco_medio) - desvio_padrao_historico '
    '(limiar inferior do AMARELO dinâmico — abaixo dele → VERDE).';

-- ============================================================================
-- FASE 3.2 — Reclassificação retroativa de TODA a base (regra dinâmica)
-- ============================================================================
-- UPDATE full: join à função de volatilidade por (id_produto, id_localidade).
-- COALESCE por linha garante que linhas legadas sem preco_referencia ainda
-- classifiquem (fallback media_movel_12m → preco_medio). Guarda < 6 meses na
-- janela → AMARELO (base insuficiente). Rows SEM estatística na janela viram
-- AMARELO com limites NULL (LEFT JOIN — semântica de "full UPDATE").

WITH volatilidade AS MATERIALIZED (
    SELECT * FROM staging.fn_estatisticas_volatilidade_24m()
)
UPDATE mart.sazonalidade_produto AS s
SET desvio_padrao_historico = v.desvio_efetivo,
    limite_superior = COALESCE(s.preco_referencia, s.media_movel_12m, s.preco_medio)
                      + v.desvio_efetivo,
    limite_inferior = COALESCE(s.preco_referencia, s.media_movel_12m, s.preco_medio)
                      - v.desvio_efetivo,
    status_cor = CASE
        WHEN v.n_meses < 6 THEN 'AMARELO'
        ELSE COALESCE(
            staging.fn_status_cor_zscore(
                COALESCE(s.preco_exibido, s.preco_atual, s.preco_medio),
                COALESCE(s.preco_referencia, s.media_movel_12m, s.preco_medio),
                v.desvio_efetivo
            ),
            'AMARELO'
        )
    END
FROM (
    SELECT ss.id_sazonalidade, st.desvio_efetivo, st.n_meses
    FROM mart.sazonalidade_produto ss
    LEFT JOIN volatilidade st
        ON st.id_produto = ss.id_produto
       AND st.id_localidade = ss.id_localidade
) v
WHERE s.id_sazonalidade = v.id_sazonalidade;

-- ============================================================================
-- FASE 3.3 — sp_calcular_sazonalidade() com regra dinâmica + 3 novas colunas
-- ============================================================================
-- Preserva TODO o comportamento da versão 59 (janela 12m, media_movel_12m,
-- indice_sazonalidade, preco_atual/preco_referencia = preco_medio, variacao_mom,
-- data_referencia_atual, ON CONFLICT). Apenas o CASE ±15% do status_cor vira
-- regra dinâmica (via LATERAL à função de volatilidade) e as 3 colunas de
-- limiares passam a ser gravadas no INSERT/UPDATE.

CREATE OR REPLACE PROCEDURE staging.sp_calcular_sazonalidade(IN p_ano_alvo smallint DEFAULT NULL::smallint, IN p_mes_alvo smallint DEFAULT NULL::smallint)
 LANGUAGE plpgsql
AS $procedure$
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
        status_cor, fonte, calculado_em,
        preco_atual, preco_referencia,
        desvio_padrao_historico, limite_superior, limite_inferior,
        preco_mes_anterior, variacao_mom_pct,
        data_referencia_atual
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
            ) AS meses_no_window,
            LAG(f.preco_medio) OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano, f.mes
            ) AS preco_mes_anterior
        FROM staging.fact_precos_mensais f
        WHERE (f.ano < v_ano OR (f.ano = v_ano AND f.mes <= v_mes))
          AND f.preco_medio IS NOT NULL
    ),
    -- Volatilidade avaliada UMA vez (MATERIALIZED) — as linhas LATERAL apenas
    -- fazem lookup por (id_produto, id_localidade), sem re-executar a função.
    volatilidade AS MATERIALIZED (
        SELECT * FROM staging.fn_estatisticas_volatilidade_24m()
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
            WHEN p.meses_no_window < 6 THEN 'AMARELO'
            WHEN v.desvio_efetivo IS NULL THEN 'AMARELO'
            ELSE COALESCE(
                staging.fn_status_cor_zscore(
                    p.preco_medio, p.media_movel_12m, v.desvio_efetivo
                ),
                'AMARELO'
            )
        END AS status_cor,
        'municipio' AS fonte,
        NOW() AS calculado_em,
        p.preco_medio AS preco_atual,
        p.preco_medio AS preco_referencia,
        v.desvio_efetivo AS desvio_padrao_historico,
        p.media_movel_12m + v.desvio_efetivo AS limite_superior,
        p.media_movel_12m - v.desvio_efetivo AS limite_inferior,
        p.preco_mes_anterior,
        CASE
            WHEN p.preco_mes_anterior IS NULL OR p.preco_mes_anterior <= 0
                 OR p.preco_medio IS NULL OR p.preco_medio <= 0
            THEN NULL
            ELSE ROUND(((p.preco_medio / p.preco_mes_anterior) - 1) * 100, 4)
        END AS variacao_mom_pct,
        p.ano::TEXT || '-' || LPAD(p.mes::TEXT, 2, '0') AS data_referencia_atual
    FROM precos_12m p
    LEFT JOIN LATERAL (
        SELECT st.desvio_efetivo
        FROM volatilidade st
        WHERE st.id_produto = p.id_produto
          AND st.id_localidade = p.id_localidade
    ) v ON TRUE
    WHERE p.ano = v_ano AND p.mes = v_mes
    ON CONFLICT (id_produto, id_localidade, ano, mes)
    DO UPDATE SET
        preco_medio         = EXCLUDED.preco_medio,
        media_movel_12m     = EXCLUDED.media_movel_12m,
        indice_sazonalidade = EXCLUDED.indice_sazonalidade,
        status_cor          = EXCLUDED.status_cor,
        calculado_em        = NOW(),
        preco_atual         = EXCLUDED.preco_atual,
        preco_referencia    = EXCLUDED.preco_referencia,
        desvio_padrao_historico = EXCLUDED.desvio_padrao_historico,
        limite_superior     = EXCLUDED.limite_superior,
        limite_inferior     = EXCLUDED.limite_inferior,
        preco_mes_anterior  = EXCLUDED.preco_mes_anterior,
        variacao_mom_pct    = EXCLUDED.variacao_mom_pct,
        data_referencia_atual = EXCLUDED.data_referencia_atual;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$procedure$;

COMMENT ON PROCEDURE staging.sp_calcular_sazonalidade IS
    'Pipeline real de sazonalidade por (produto, localidade, mês). '
    'FASE 65: status_cor agora usa limiares DINÂMICOS ±1 desvio padrão '
    '(fn_status_cor_zscore vs media_movel_12m) via fn_estatisticas_volatilidade_24m; '
    'grava desvio_padrao_historico/limite_superior/limite_inferior. '
    'meses_no_window < 6 ou desvio NULL → AMARELO.';

-- ============================================================================
-- FASE 3.4 — mart.vw_anchor_sazonalidade com status_cor dinâmico
-- ============================================================================
-- (RECRIADA na FASE 3.5 — ver bloco após o DROP da MV antiga.)
--
-- MOTIVO (fix do erro de aplicação): CREATE OR REPLACE VIEW não pode
-- reordenar/renomear colunas em uma view EXISTENTE enquanto outro objeto
-- (a MV V17) dela depende — "cannot change name of view column". Como esta
-- view ganha 3 colunas novas (a ordenação muda), ela é recriada via
-- DROP VIEW + CREATE VIEW, posicionada SEMPRE DEPOIS do DROP da MV antiga
-- (seu único dependente) e ANTES do CREATE da MV V18, que a referencia no
-- CTE MATERIALIZED. A ordem de dependência no arquivo é:
--   DROP MV → DROP VIEW → CREATE VIEW (âncora) → CREATE MV (V18).

-- ============================================================================
-- FASE 3.5 — MV mart.vw_api_produtos_sazonalidade V18 (3 branches + 3 colunas)
-- ============================================================================
-- Padrão da Fase 36 (DROP + CREATE + 7 índices + GRANT), 3 branches UNION ALL
-- preservados da V17 (63:357-590): A reais, B exibição ano atual, C fallback.
-- Única mudança: 3 novas colunas (desvio_padrao_historico, limite_superior,
-- limite_inferior) projetadas da âncora (branch C → NULL). status_cor continua
-- vindo da âncora (COALESCE) — agora dinâmico. WITH DATA popula no apply.

-- Guard de colisão (idêntico à 63): ids negativos dos branches B/C não podem
-- colidir com ids positivos da tabela base.
DO $$
DECLARE
    v_max BIGINT;
BEGIN
    SELECT MAX(id_sazonalidade) INTO v_max FROM mart.sazonalidade_produto;
    IF v_max IS NOT NULL AND v_max >= 1000000000 THEN
        RAISE EXCEPTION
            '[65] Colisão de id_sazonalidade: MAX(id_sazonalidade)=% >= 1000000000. '
            'A faixa de ids negativos da MV V18 colidiria com ids positivos. '
            'Abortando criação da MV.', v_max;
    END IF;
    RAISE NOTICE '[65] Guard de colisão OK (MAX(id_sazonalidade)=%)', v_max;
END $$;

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

-- ============================================================================
-- FASE 3.4 (aqui) — View âncora recriada: DROP + CREATE
-- ============================================================================
-- A MV antiga acabou de ser dropada (único dependente da âncora), então a
-- view pode ser recriada com DROP VIEW IF EXISTS (sem CASCADE) + CREATE VIEW.
-- Corpo idêntico à versão 63 (real/tuples/anchored, SEM CROSS JOIN — lookups
-- LATERAL via índice uq_sazonalidade), com:
--   - status_cor: CASE estático ±25% substituído por
--     staging.fn_status_cor_zscore(preco_exibido, preco_referencia,
--     v.desvio_efetivo) via LATERAL à função de volatilidade;
--   - guarda < 6 meses (n_meses_referencia) → AMARELO mantida;
--   - 3 novas colunas de saída (desvio_padrao_historico, limite_superior,
--     limite_inferior — limites em torno de preco_referencia) APENDADAS ao
--     final (a ordem das colunas existentes é preservada).
-- A MV V18 abaixo referencia esta view no CTE MATERIALIZED: por isso ela já
-- precisa existir neste ponto.

DROP VIEW IF EXISTS mart.vw_anchor_sazonalidade;

CREATE VIEW mart.vw_anchor_sazonalidade AS
WITH real AS (
    SELECT id_sazonalidade, id_produto, id_localidade, ano, mes,
           data_referencia_atual, preco_atual, fonte, calculado_em
    FROM mart.sazonalidade_produto
    WHERE COALESCE(fonte,'') <> 'FLUXO_PROXY' AND NOT is_forecast
      AND preco_atual IS NOT NULL AND preco_atual > 0
),
tuples AS (
    SELECT DISTINCT id_produto, id_localidade, mes FROM real
),
anchored AS (
    SELECT t.id_produto, t.id_localidade, t.mes,
           a.id_sazonalidade, a.ano AS ano_referencia, a.preco_atual AS preco_exibido,
           a.data_referencia_atual, a.calculado_em AS data_ultima_coleta, a.fonte,
           EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - a.ano AS idade_dado_anos,
           CASE WHEN a.ano = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
                THEN 'REAL_ATUAL' ELSE 'HISTORICO_BASE' END AS tipo_dado,
           r.preco_ref_real AS preco_referencia, r.n_meses AS n_meses_referencia
    FROM tuples t
    LEFT JOIN LATERAL (   -- âncora: linha real mais recente em N..N-2 p/ a tupla de mês
        -- Lê a BASE diretamente (não a CTE `real`) p/ o planner usar o índice
        -- uq_sazonalidade(id_produto, id_localidade, ano, mes) por tupla em
        -- vez de escanear a CTE materializada inteira a cada linha (evita O(N²)).
        SELECT r.id_sazonalidade, r.ano, r.preco_atual, r.data_referencia_atual,
               r.calculado_em, r.fonte
        FROM mart.sazonalidade_produto r
        WHERE r.id_produto = t.id_produto
          AND r.id_localidade = t.id_localidade
          AND r.mes = t.mes
          AND COALESCE(r.fonte,'') <> 'FLUXO_PROXY' AND NOT r.is_forecast
          AND r.preco_atual IS NOT NULL AND r.preco_atual > 0
          AND r.ano BETWEEN EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 2
                        AND EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
        ORDER BY r.ano DESC, r.mes DESC
        LIMIT 1
    ) a ON TRUE
    LEFT JOIN LATERAL (   -- referência REAL: 12 meses anteriores ao mês âncora
        -- Lê a BASE diretamente (não a CTE `real`) p/ usar uq_sazonalidade por
        -- tupla (evita o scan O(N²) da CTE materializada no loop aninhado).
        SELECT AVG(r2.preco_atual)::NUMERIC(14,4) AS preco_ref_real, COUNT(*) AS n_meses
        FROM mart.sazonalidade_produto r2
        WHERE r2.id_produto = t.id_produto
          AND r2.id_localidade = t.id_localidade
          AND COALESCE(r2.fonte,'') <> 'FLUXO_PROXY' AND NOT r2.is_forecast
          AND r2.preco_atual IS NOT NULL AND r2.preco_atual > 0
          AND (r2.ano * 12 + r2.mes) BETWEEN (a.ano * 12 + t.mes - 12)
                                        AND (a.ano * 12 + t.mes - 1)
    ) r ON TRUE
),
-- Volatilidade avaliada UMA vez (MATERIALIZED) — os lookups LATERAL não
-- re-executam a função; apenas resolvem por (id_produto, id_localidade).
volatilidade AS MATERIALIZED (
    SELECT * FROM staging.fn_estatisticas_volatilidade_24m()
)
SELECT a.*,
       CASE
           WHEN a.n_meses_referencia IS NULL OR a.n_meses_referencia < 6 THEN 'AMARELO'
           ELSE COALESCE(
               staging.fn_status_cor_zscore(
                   a.preco_exibido, a.preco_referencia, v.desvio_efetivo
               ),
               'AMARELO'
           )
       END AS status_cor,
       jsonb_build_object(
           'fonte_dado',        a.fonte,
           'data_ultima_coleta', a.data_ultima_coleta,
           'procedencia',       'coleta_real_conab',
           'ano_referencia',    a.ano_referencia
       ) AS metadado_transparencia,
       -- FASE 65 — limiares dinâmicos (apendados ao final)
       v.desvio_efetivo AS desvio_padrao_historico,
       a.preco_referencia + v.desvio_efetivo AS limite_superior,
       a.preco_referencia - v.desvio_efetivo AS limite_inferior
FROM anchored a
LEFT JOIN LATERAL (
    SELECT st.desvio_efetivo
    FROM volatilidade st
    WHERE st.id_produto = a.id_produto
      AND st.id_localidade = a.id_localidade
) v ON TRUE
WHERE a.preco_exibido IS NOT NULL;   -- só tuplas com âncora real (fallback → MV branch C)

COMMENT ON VIEW mart.vw_anchor_sazonalidade IS
    'Âncora N→N-1→N-2 por (produto, localidade, mes) sobre linhas REAIS '
    '(FLUXO_PROXY/is_forecast excluídos). preco_exibido = preço real da âncora '
    '(sem multiplicador); preco_referencia = AVG real 12m anteriores; '
    'status_cor DINÂMICO ±1 desvio padrão (FASE 65) via '
    'fn_status_cor_zscore + fn_estatisticas_volatilidade_24m; '
    'desvio_padrao_historico/limite_superior/limite_inferior expostos. '
    'n_meses_referencia < 6 → AMARELO. Sem CROSS JOIN (D1).';

GRANT SELECT ON mart.vw_anchor_sazonalidade TO role_api_reader;

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
-- CTE MATERIALIZED: a view âncora (LATERAL/DISTINCT) é avaliada UMA vez;
-- sem isso, o NOT EXISTS do branch C reavaliaria a view por linha (lentidão O(N²)).
WITH anchor AS MATERIALIZED (
    SELECT * FROM mart.vw_anchor_sazonalidade
)
SELECT
    v.id_sazonalidade,
    v.id_localidade,
    v.id_produto,
    v.produto,
    v.classificao_produto,
    v.conab_id_produto,
    v.status_fonte,
    v.categoria,
    v.uf,
    v.municipio,
    v.municipio_id,
    v.ano,
    v.mes,
    v.preco_referencia,
    v.preco_atual,
    v.data_referencia_atual,
    v.usou_fallback_12m,
    v.preco_estimado,
    v.status_cor,
    v.fonte,
    v.calculado_em,
    v.metodo_calculo,
    v.variacao_pct,
    v.tendencia_futura,
    v.is_forecast,
    v.baseline_confianca,
    v.forecast_method,
    -- Colunas de transparência (V17 — R-ADD-05)
    v.preco_exibido,
    v.ano_referencia,
    v.tipo_dado,
    v.idade_dado_anos,
    v.metadado_transparencia,
    -- Limiares dinâmicos (V18 — FASE 65)
    v.desvio_padrao_historico,
    v.limite_superior,
    v.limite_inferior
FROM (
    -- ── BRANCH A — linhas reais com campos de âncora (navegação histórica) ──
    SELECT
        s.id_sazonalidade,
        s.id_localidade,
        p.id_produto,
        p.nome_produto AS produto,
        p.classificao_produto,
        p.conab_id_produto,
        p.status_fonte,
        COALESCE(c.nome_categoria, 'ALIMENTO_VAREJO'::text) AS categoria,
        l.uf,
        COALESCE(l.municipio_nome, l.uf || ' (UF)') AS municipio,
        l.municipio_id,
        (split_part(s.data_referencia_atual, '-', 1))::integer AS ano,
        (split_part(s.data_referencia_atual, '-', 2))::integer AS mes,
        COALESCE(a.preco_referencia, s.preco_referencia) AS preco_referencia,
        COALESCE(a.preco_exibido, s.preco_atual) AS preco_atual,
        s.data_referencia_atual,
        s.usou_fallback_12m,
        s.preco_estimado,
        COALESCE(a.status_cor, s.status_cor) AS status_cor,
        s.fonte,
        s.calculado_em,
        s.metodo_calculo,
        s.variacao_mom_pct AS variacao_pct,
        s.tendencia_futura,
        s.is_forecast,
        s.baseline_confianca,
        s.forecast_method,
        COALESCE(a.preco_exibido, s.preco_atual) AS preco_exibido,
        COALESCE(a.ano_referencia, s.ano_referencia) AS ano_referencia,
        COALESCE(a.tipo_dado, s.tipo_dado) AS tipo_dado,
        COALESCE(a.idade_dado_anos, s.idade_dado_anos) AS idade_dado_anos,
        COALESCE(a.metadado_transparencia, s.metadado_transparencia) AS metadado_transparencia,
        -- V18 — limiares dinâmicos (da âncora quando presente, senão da base)
        COALESCE(a.desvio_padrao_historico, s.desvio_padrao_historico) AS desvio_padrao_historico,
        COALESCE(a.limite_superior, s.limite_superior) AS limite_superior,
        COALESCE(a.limite_inferior, s.limite_inferior) AS limite_inferior
    FROM mart.sazonalidade_produto s
    JOIN staging.dim_produto p ON p.id_produto = s.id_produto
    JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
    LEFT JOIN staging.dim_categoria c ON c.id_categoria = p.id_categoria
    LEFT JOIN anchor a
        ON a.id_produto = s.id_produto
       AND a.id_localidade = s.id_localidade
       AND a.mes = s.mes
    WHERE COALESCE(s.fonte, '') <> 'FLUXO_PROXY'
      AND NOT s.is_forecast
      AND s.status_cor IN ('VERDE','AMARELO','VERMELHO')
      AND p.categoria_b2c = 'ALIMENTO_VAREJO'
      AND (p.classificao_produto IS NULL
           OR p.classificao_produto NOT IN ('INSUMO_AGRICOLA','MAQUINARIO_FERRAMENTA','SERVICO_LOGISTICA'))
      AND (c.nome_categoria IS NULL
           OR c.nome_categoria NOT IN ('FLORES','OUTROS'))
      AND (COALESCE(a.status_cor, s.status_cor) IS NOT NULL
           OR COALESCE(a.tipo_dado, s.tipo_dado) = 'FALLBACK_DIMENSAO')

    UNION ALL

    -- ── BRANCH B — exibição ancorada em ano = ANO_ATUAL (grade do ano corrente) ──
    SELECT
        -a.id_sazonalidade AS id_sazonalidade,
        s.id_localidade,
        a.id_produto,
        p.nome_produto AS produto,
        p.classificao_produto,
        p.conab_id_produto,
        p.status_fonte,
        COALESCE(c.nome_categoria, 'ALIMENTO_VAREJO'::text) AS categoria,
        l.uf,
        COALESCE(l.municipio_nome, l.uf || ' (UF)') AS municipio,
        l.municipio_id,
        EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER AS ano,
        a.mes AS mes,
        a.preco_referencia AS preco_referencia,
        a.preco_exibido AS preco_atual,
        (EXTRACT(YEAR FROM CURRENT_DATE)::TEXT || '-' || LPAD(a.mes::TEXT, 2, '0')) AS data_referencia_atual,
        s.usou_fallback_12m,
        s.preco_estimado,
        a.status_cor AS status_cor,
        a.fonte AS fonte,
        a.data_ultima_coleta AS calculado_em,
        s.metodo_calculo,
        NULL::numeric AS variacao_pct,
        s.tendencia_futura,
        FALSE AS is_forecast,
        s.baseline_confianca,
        s.forecast_method,
        a.preco_exibido AS preco_exibido,
        a.ano_referencia AS ano_referencia,
        a.tipo_dado AS tipo_dado,
        a.idade_dado_anos AS idade_dado_anos,
        a.metadado_transparencia AS metadado_transparencia,
        -- V18 — limiares dinâmicos (da âncora)
        a.desvio_padrao_historico AS desvio_padrao_historico,
        a.limite_superior AS limite_superior,
        a.limite_inferior AS limite_inferior
    FROM anchor a
    JOIN mart.sazonalidade_produto s ON s.id_sazonalidade = a.id_sazonalidade
    JOIN staging.dim_produto p ON p.id_produto = a.id_produto
    JOIN staging.dim_localidade l ON l.id_localidade = a.id_localidade
    LEFT JOIN staging.dim_categoria c ON c.id_categoria = p.id_categoria
    WHERE a.ano_referencia < EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
      AND a.status_cor IS NOT NULL
      AND s.status_cor IN ('VERDE','AMARELO','VERMELHO')
      AND p.categoria_b2c = 'ALIMENTO_VAREJO'
      AND (p.classificao_produto IS NULL
           OR p.classificao_produto NOT IN ('INSUMO_AGRICOLA','MAQUINARIO_FERRAMENTA','SERVICO_LOGISTICA'))
      AND (c.nome_categoria IS NULL
           OR c.nome_categoria NOT IN ('FLORES','OUTROS'))

    UNION ALL

    -- ── BRANCH C — FALLBACK_DIMENSAO (sem histórico real em N..N-2) ──
    -- Parênteses obrigatórios: o ORDER BY do DISTINCT ON é do branch, não do UNION.
    (
    SELECT DISTINCT ON (f.id_produto, f.id_localidade, f.mes)
        -(f.id_sazonalidade) - 1000000000 AS id_sazonalidade,
        f.id_localidade,
        f.id_produto,
        p.nome_produto AS produto,
        p.classificao_produto,
        p.conab_id_produto,
        p.status_fonte,
        COALESCE(c.nome_categoria, 'ALIMENTO_VAREJO'::text) AS categoria,
        l.uf,
        COALESCE(l.municipio_nome, l.uf || ' (UF)') AS municipio,
        l.municipio_id,
        EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER AS ano,
        f.mes AS mes,
        NULL::numeric AS preco_referencia,
        NULLIF(f.preco_atual, 0) AS preco_atual,
        (EXTRACT(YEAR FROM CURRENT_DATE)::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0')) AS data_referencia_atual,
        f.usou_fallback_12m,
        f.preco_estimado,
        COALESCE(f.status_cor, 'AMARELO') AS status_cor,
        f.fonte AS fonte,
        f.calculado_em,
        f.metodo_calculo,
        NULL::numeric AS variacao_pct,
        f.tendencia_futura,
        FALSE AS is_forecast,
        NULL::numeric AS baseline_confianca,
        NULL::text AS forecast_method,
        NULLIF(f.preco_atual, 0) AS preco_exibido,
        NULL::integer AS ano_referencia,
        'FALLBACK_DIMENSAO'::text AS tipo_dado,
        NULL::integer AS idade_dado_anos,
        jsonb_build_object(
            'fonte_dado',    f.fonte,
            'procedencia',   CASE WHEN COALESCE(f.fonte,'') = 'FLUXO_PROXY'
                                  THEN 'sem_historico_real_uso_proxy'
                                  ELSE 'sem_historico_real' END,
            'data_referencia', f.data_referencia_atual
        ) AS metadado_transparencia,
        -- V18 — limiares dinâmicos (fallback sem histórico → NULL)
        NULL::numeric AS desvio_padrao_historico,
        NULL::numeric AS limite_superior,
        NULL::numeric AS limite_inferior
    FROM mart.sazonalidade_produto f
    JOIN staging.dim_produto p ON p.id_produto = f.id_produto
    JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
    LEFT JOIN staging.dim_categoria c ON c.id_categoria = p.id_categoria
    WHERE NOT EXISTS (
            SELECT 1 FROM anchor a2
            WHERE a2.id_produto = f.id_produto
              AND a2.id_localidade = f.id_localidade
              AND a2.mes = f.mes
        )
      AND f.status_cor IN ('VERDE','AMARELO','VERMELHO')
      AND p.categoria_b2c = 'ALIMENTO_VAREJO'
      AND (p.classificao_produto IS NULL
           OR p.classificao_produto NOT IN ('INSUMO_AGRICOLA','MAQUINARIO_FERRAMENTA','SERVICO_LOGISTICA'))
      AND (c.nome_categoria IS NULL
           OR c.nome_categoria NOT IN ('FLORES','OUTROS'))
    ORDER BY f.id_produto, f.id_localidade, f.mes,
             CASE WHEN COALESCE(f.fonte,'') = 'FLUXO_PROXY' THEN 1 ELSE 0 END,  -- prefere não-proxy
             f.data_referencia_atual DESC
    )
) v
ORDER BY v.ano, v.mes, v.is_forecast, v.status_cor, v.produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'V18 (limiares-cores-dinamicos-zscore) — 3 branches: (A) linhas reais com '
    'âncora; (B) exibição ancorada em ano atual (id=-id, só quando '
    'ano_referencia<N); (C) FALLBACK_DIMENSAO (id=-(id)-1e9). preco_exibido = '
    'preço real sem multiplicador; status_cor DINÂMICO ±1 desvio padrão '
    '(FASE 65) vs referência real; novas colunas desvio_padrao_historico/'
    'limite_superior/limite_inferior. Linhas FLUXO_PROXY/sintéticas NUNCA '
    'entram na MV (semântica de exibição).';

-- Índices (padrão 36:202-214) — UNIQUE primeiro (obrigatório p/ CONCURRENTLY).
-- Reutiliza os MESMOS nomes da V17 (o DROP acima remove os antigos com a MV).
CREATE UNIQUE INDEX idx_vw_sazonalidade_unico ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);
CREATE INDEX idx_vw_sazonalidade_filtro ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);
CREATE INDEX idx_vw_sazonalidade_categoria ON mart.vw_api_produtos_sazonalidade (categoria);
CREATE INDEX idx_vw_sazonalidade_produto ON mart.vw_api_produtos_sazonalidade (id_produto);
CREATE INDEX idx_vw_sazonalidade_ano_mes ON mart.vw_api_produtos_sazonalidade (ano, mes) WHERE (ano IS NOT NULL AND mes IS NOT NULL);
CREATE INDEX idx_vw_sazonalidade_tipo_dado ON mart.vw_api_produtos_sazonalidade (tipo_dado) WHERE (tipo_dado IS NOT NULL);
CREATE INDEX idx_vw_sazonalidade_ano_referencia ON mart.vw_api_produtos_sazonalidade (ano_referencia DESC) WHERE (ano_referencia IS NOT NULL);

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;

COMMIT;
