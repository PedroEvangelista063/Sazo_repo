-- ============================================================================
-- QUERO COMPRAR — MIGRAÇÃO 68: Recalibração Estatística da Grade BR
-- PostgreSQL 16+
--
-- OBJETIVO (recalibracao-estatistica-br):
--   Corrigir três distorções detectadas no semáforo da grade nacional:
--
--   FASE 1 — Limpeza de outliers na base de variância
--     staging.fn_estatisticas_volatilidade_24m() calcula o desvio padrão de
--     cada (id_produto, id_localidade) sobre os últimos 24 meses reais. Pontos
--     com erro de unidade/coleta (ex: 'UVA IMPORTADA' com R$2,34 numa série de
--     R$12-24; 'Mostarda' com R$0,02) inflam o STDDEV e geravam limites
--     inferiores NEGATIVOS (preco_referencia - 1σ < 0). A nova versão expurga
--     outliers por regra IQR (1.5× faixa interquartil) por grupo ANTES do
--     AVG/STDDEV, com piso absoluto de sanidade de R$0,50.
--     NOTA (IQR mascarado): em amostras pequenas com outliers AGRUPADOS
--     (ex: UVA Campinas com 3 de 7 pontos a R$2,34), o próprio Q1 é
--     contaminado e a faixa IQR engole o outlier. Por isso adiciona-se um
--     GUARD ROBUSTO complementar: ponto com preço < 25% da MEDIANA do grupo
--     é erro de unidade/coleta (escala ~10x menor), independente do IQR.
--
--   FASE 2a — Quórum de severidade nas agregações nacionais
--     mart.fn_br_nacional_sazonalidade() e mart.fn_br_nacional_por_mes()
--     decidiam a cor nacional por MODE() das cores das UFs. Uma UF VERMELHA
--     minoritária (ex: 12/27 UFs = 44%) era esmagada pela moda (AMARELO).
--     Substitui-se o MODE APENAS do status_cor nacional por quórum de
--     severidade: ≥40% das UFs VERMELHO → VERMELHO; ≥40% VERDE → VERDE;
--     senão AMARELO. O VERMELHO tem precedência (princípio da prudência).
--     Os MODE() dos demais campos (metadados uniformes por grupo canônico)
--     são preservados. O nível 1 (cor por UF = MODE de municípios) NÃO muda.
--
--   FASE 2b — Ausência de dados vira CINZA (e não AMARELO mecânico)
--     mart.vw_anchor_sazonalidade forçava 'AMARELO' quando base insuficiente
--     (n_meses_referencia < 6) ou banda inválida (COALESCE(fn_zscore, 'AMARELO')).
--     Com o expurgo de outliers, muitos pontos agora ficam sem estatística
--     válida — forçar AMARELO mascararia a ausência. A nova âncora retorna
--     NULL nesses casos → a MV exclui as linhas → o backend marca CINZA
--     (regra de transparência aprovada no Quality Gate). O COALESCE morto do
--     branch C da MV (dead code que mascarava ausência) também é removido.
--
-- IDEMPOTÊNCIA: CREATE OR REPLACE nas funções; DROP + CREATE na view/MV
-- (CREATE OR REPLACE não existe para MV). MV recriada com WITH DATA
-- (popula no próprio apply). Guard de colisão de id_sazonalidade preservado.
-- ============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- ============================================================================
-- FASE 1 — Limpeza de Outliers na base de variância (IQR por grupo)
-- ============================================================================
-- PROBLEMA: outliers de unidade/coleta (ex: UVA IMPORTADA R$2,34 numa série
-- de R$12-24; Mostarda R$0,02) inflam o STDDEV e geravam limites inferiores
-- NEGATIVOS na regra dinâmica ±1σ — qualquer queda real de preço virava
-- VERDE indevidamente.
-- SOLUÇÃO: sobre a janela de 24 meses, expurgar pontos fora da banda
--   [Q1 - 1.5*(Q3-Q1), Q3 + 1.5*(Q3-Q1)] computada por (id_produto,
--   id_localidade) (regra de Tukey, IQR). Implementada com CTEs encadeadas
--   (janela → quartis → janela_limpa) preservando o estilo da versão 65.
--   Piso absoluto de sanidade: preco_medio >= 0.50.
--   GUARD ROBUSTO: o IQR sozinho NÃO expurga outliers agrupados que
--   contaminam o próprio Q1 (ex: UVA Campinas, 3/7 pontos a R$2,34 →
--   Q1=2.34 → faixa inferior negativa → nada é removido). Para quebrar esse
--   mascaramento, um ponto também é descartado quando preco_medio < 25% da
--   MEDIANA do grupo (erro de escala ~10x, não variação de mercado).
-- AVG/STDDEV/COUNT são calculados sobre a janela LIMPA. O desvio_efetivo
-- mantém o piso de CV mínimo 10% (banda não-degenerada).

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
    -- Janela bruta: últimos 24 meses reais, com piso absoluto de sanidade
    -- (preços <= 0.50 são erro de unidade/coleta, não preço real de mercado).
    janela AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            f.preco_medio
        FROM staging.fact_precos_mensais f
        CROSS JOIN max_data m
        WHERE f.ano * 12 + f.mes > m.max_periodo - 24
          AND f.preco_medio >= 0.50
    ),
    -- Quartis e mediana por grupo (IQR de Tukey) sobre a janela bruta.
    quartis AS (
        SELECT
            j.id_produto,
            j.id_localidade,
            PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY j.preco_medio) AS q1,
            PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY j.preco_medio) AS q3,
            PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY j.preco_medio) AS mediana
        FROM janela j
        GROUP BY j.id_produto, j.id_localidade
    ),
    -- Janela limpa: mantém apenas pontos dentro da banda IQR (outliers de
    -- unidade/coleta expurgados ANTES do AVG/STDDEV). GUARD ROBUSTO: além da
    -- banda IQR, pontos com preco < 25% da mediana do grupo são descartados —
    -- quebra o mascaramento do IQR em amostras pequenas com outliers
    -- agrupados (Q1 contaminado).
    janela_limpa AS (
        SELECT
            j.id_produto,
            j.id_localidade,
            j.preco_medio
        FROM janela j
        JOIN quartis q
            ON q.id_produto = j.id_produto
           AND q.id_localidade = j.id_localidade
        WHERE q.q1 IS NOT NULL AND q.q3 IS NOT NULL
          AND j.preco_medio BETWEEN (q.q1 - 1.5 * (q.q3 - q.q1))
                               AND (q.q3 + 1.5 * (q.q3 - q.q1))
          AND (q.mediana IS NULL OR j.preco_medio >= 0.25 * q.mediana)
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
    FROM janela_limpa j
    GROUP BY j.id_produto, j.id_localidade;
$$;

COMMENT ON FUNCTION staging.fn_estatisticas_volatilidade_24m IS
    'Estatísticas de volatilidade por (produto, localidade) sobre os últimos '
    '24 meses reais de staging.fact_precos_mensais (janela relativa ao (ano,mes) '
    'mais recente). FASE 68: outliers expurgados ANTES do AVG/STDDEV por regra '
    'IQR de Tukey (banda [Q1-1.5*IQR, Q3+1.5*IQR] por grupo) com piso absoluto '
    'de sanidade preco_medio >= 0.50 e GUARD ROBUSTO (preco < 25%% da mediana '
    'do grupo é erro de unidade/coleta) — corrige STDDEV inflado por erros de '
    'unidade/coleta (ex: UVA R$2,34 numa série de R$12-24) que geravam limites '
    'inferiores NEGATIVOS. O guard robusto quebra o mascaramento do IQR em '
    'amostras pequenas com outliers agrupados (Q1 contaminado). desvio_efetivo '
    'mantém o piso de CV mínimo 10%% (ROUND(0.10 * media)) quando o desvio é '
    'nulo/zero ou CV < 10%%. Uso: SELECT * FROM staging.fn_estatisticas_volatilidade_24m();';

GRANT EXECUTE ON FUNCTION staging.fn_estatisticas_volatilidade_24m()
    TO role_etl_writer;

-- ============================================================================
-- FASE 2a — Quórum de Severidade em mart.fn_br_nacional_sazonalidade
-- ============================================================================
-- MESMA assinatura (p_ano, p_categoria DEFAULT NULL, p_min_ufs DEFAULT 1) e
-- MESMO RETURNS TABLE da versão 67 (contrato preservado). Estrutura de 3
-- níveis intacta. Única mudança: no NÍVEL 2 (decisão Brasil), o status_cor
-- nacional deixa de ser MODE() e passa a quórum de severidade:
--   >= 40% das UFs VERMELHO → VERMELHO (prudência: prevalece sobre VERDE)
--   >= 40% das UFs VERDE   → VERDE
--   senão                   → AMARELO
-- O MODE foi removido SOMENTE do status_cor (agregação categórica de risco).
-- Os demais MODE() (classificao_produto, categoria, forecast_method,
-- ano_referencia, tipo_dado) são preservados — são metadados uniformes por
-- grupo canônico. Nível 1 (cor por UF = MODE de municípios) NÃO muda.
-- Nenhum filtro foi adicionado/removido.

CREATE OR REPLACE FUNCTION mart.fn_br_nacional_sazonalidade(p_ano integer, p_categoria text DEFAULT NULL::text, p_min_ufs integer DEFAULT 1)
 RETURNS TABLE(produto text, classificao_produto text, categoria text, mes integer, data_referencia_atual text, status_cor text, is_forecast boolean, baseline_confianca numeric, total_ufs bigint, forecast_method text, calculado_em timestamp with time zone, ano_referencia integer, tipo_dado text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_categoria_filter TEXT := COALESCE(p_categoria, '%%');
    v_min_ufs INTEGER := COALESCE(p_min_ufs, 1);
BEGIN
    RETURN QUERY
    WITH produto_canonico AS (
        -- Nível 0: resolve o nome canônico e a categoria canônica (mestre) por id.
        SELECT
            v.id_produto,
            COALESCE(dc.nome_canonico, v.produto) AS produto,
            v.classificao_produto,
            COALESCE(cat_mestre.nome_categoria, v.categoria, 'ALIMENTO_VAREJO') AS categoria,
            v.uf,
            v.mes,
            v.status_cor,
            v.is_forecast,
            v.baseline_confianca,
            v.forecast_method,
            v.calculado_em,
            v.ano_referencia,
            v.tipo_dado
        FROM mart.vw_api_produtos_sazonalidade v
        LEFT JOIN mart.dim_produto_canonico dc
               ON dc.id_produto_original = v.id_produto
        LEFT JOIN staging.dim_categoria cat_mestre
               ON cat_mestre.id_categoria = dc.id_categoria_mestre
        WHERE v.ano = p_ano
          AND (p_categoria IS NULL
               OR COALESCE(cat_mestre.nome_categoria, v.categoria, 'ALIMENTO_VAREJO') ILIKE v_categoria_filter)
          AND v.tipo_dado IN ('REAL_ATUAL', 'HISTORICO_BASE')
          AND COALESCE(v.idade_dado_anos, 0) <= 1
          AND COALESCE(v.metadado_transparencia->>'procedencia', '') NOT LIKE 'sem_historico_real%'
    ),
    uf_por_mes AS (
        -- Nível 1: consolida por (produto_canonico, UF, mes) — moda dentro da UF.
        -- ids fundidos da MESMA UF são agregados aqui (MODE de status, BOOL_OR de
        -- forecast, MAX de confianca/calculado) eliminando o produto cartesiano.
        SELECT
            pc.produto,
            pc.classificao_produto,
            COALESCE(pc.categoria, 'ALIMENTO_VAREJO') AS categoria_final,
            pc.uf,
            pc.mes,
            MODE() WITHIN GROUP (ORDER BY pc.status_cor) AS uf_status_cor,
            BOOL_OR(pc.is_forecast)                     AS uf_forecast,
            MAX(pc.baseline_confianca)                  AS uf_confianca,
            MODE() WITHIN GROUP (ORDER BY pc.forecast_method) AS uf_forecast_method,
            MAX(pc.calculado_em)                        AS uf_calculado_em,
            MODE() WITHIN GROUP (ORDER BY pc.ano_referencia)  AS uf_ano_ref,
            MODE() WITHIN GROUP (ORDER BY pc.tipo_dado)       AS uf_tipo_dado
        FROM produto_canonico pc
        GROUP BY pc.produto, pc.classificao_produto, categoria_final, pc.uf, pc.mes
    )
    -- Nível 2: agrega por (nome_canonico, mes) — quórum de severidade entre UFs.
    -- Granularidade ESTRITA: GROUP BY (produto, mes); categoria e classificacao
    -- derivam por MODE (uniformes por grupo canônico — categoria vem do mestre).
    -- FASE 68: status_cor_nac = quórum de severidade (>=40% VERMELHO → VERMELHO,
    -- >=40% VERDE → VERDE, senão AMARELO). O CASE prioriza VERMELHO (prudência
    -- quando ambos os quóruns se aplicam). MODE removido SÓ do status_cor.
    SELECT
        upm.produto,
        MODE() WITHIN GROUP (ORDER BY upm.classificao_produto) AS classificao_produto,
        MODE() WITHIN GROUP (ORDER BY upm.categoria_final)     AS categoria,
        upm.mes,
        (p_ano || '-' || LPAD(upm.mes::TEXT, 2, '0'))::TEXT AS data_ref,
        CASE
            WHEN (COUNT(*) FILTER (WHERE upm.uf_status_cor = 'VERMELHO'))::numeric
                 / NULLIF(COUNT(*), 0) >= 0.40 THEN 'VERMELHO'
            WHEN (COUNT(*) FILTER (WHERE upm.uf_status_cor = 'VERDE'))::numeric
                 / NULLIF(COUNT(*), 0) >= 0.40 THEN 'VERDE'
            ELSE 'AMARELO'
        END AS status_cor_nac,
        BOOL_OR(upm.uf_forecast)                              AS is_forecast_nac,
        MAX(upm.uf_confianca)                                 AS confianca_nac,
        COUNT(DISTINCT upm.uf)                                AS total_ufs_nac,
        MODE() WITHIN GROUP (ORDER BY upm.uf_forecast_method)  AS forecast_method_nac,
        MAX(upm.uf_calculado_em)                              AS calculado_em_nac,
        MODE() WITHIN GROUP (ORDER BY upm.uf_ano_ref)          AS ano_referencia_nac,
        MODE() WITHIN GROUP (ORDER BY upm.uf_tipo_dado)        AS tipo_dado_nac
    FROM uf_por_mes upm
    GROUP BY upm.produto, upm.mes
    HAVING COUNT(DISTINCT upm.uf) >= v_min_ufs
    ORDER BY upm.produto, upm.mes;
END;
$function$;

COMMENT ON FUNCTION mart.fn_br_nacional_sazonalidade(integer, text, integer) IS
    'Grade sazonal nacional BR por (produto canônico, mês). FASE 68: status_cor '
    'nacional decidido por QUÓRUM de severidade (>=40%% das UFs VERMELHO → '
    'VERMELHO; >=40%% VERDE → VERDE; senão AMARELO) em vez de MODE — UF '
    'VERMELHA minoritária não é mais esmagada pela moda. Demais metadados '
    'seguem por MODE (uniformes por grupo canônico). Nível 1 (UF = MODE de '
    'municípios) inalterado.';

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(integer, text, integer)
    TO role_api_reader;

-- ============================================================================
-- FASE 2a (cont.) — Quórum de Severidade em mart.fn_br_nacional_por_mes
-- ============================================================================
-- MESMA assinatura (p_ano, p_mes, p_categoria DEFAULT NULL, p_limit DEFAULT
-- NULL, p_offset DEFAULT 0) e MESMO RETURNS TABLE da versão 67. Aplica o
-- MESMO quórum de severidade ao status_cor nacional (nível 2), substituindo
-- o MODE() — idem fn_br_nacional_sazonalidade. Preços mantêm a média
-- ponderada por UF (comportamento da 67) e o HAVING COUNT(DISTINCT uf) >= 5.

CREATE OR REPLACE FUNCTION mart.fn_br_nacional_por_mes(p_ano integer, p_mes integer, p_categoria text DEFAULT NULL::text, p_limit integer DEFAULT NULL::integer, p_offset integer DEFAULT 0)
 RETURNS TABLE(produto text, classificao_produto text, categoria text, uf text, municipio text, municipio_id text, ano integer, mes integer, data_referencia_atual text, preco_referencia numeric, preco_atual numeric, usou_fallback_12m boolean, preco_estimado boolean, status_cor text, fonte text, is_forecast boolean, total_ufs bigint, confianca_baseline numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_categoria_filter TEXT := COALESCE(p_categoria, '%%');
BEGIN
    RETURN QUERY
    WITH produto_canonico AS (
        SELECT
            v.id_produto,
            COALESCE(dc.nome_canonico, v.produto) AS produto,
            v.classificao_produto,
            COALESCE(cat_mestre.nome_categoria, v.categoria, 'ALIMENTO_VAREJO') AS categoria,
            v.uf,
            v.preco_referencia,
            v.preco_atual,
            v.usou_fallback_12m,
            v.preco_estimado,
            v.status_cor,
            v.is_forecast,
            v.baseline_confianca
        FROM mart.vw_api_produtos_sazonalidade v
        LEFT JOIN mart.dim_produto_canonico dc
               ON dc.id_produto_original = v.id_produto
        LEFT JOIN staging.dim_categoria cat_mestre
               ON cat_mestre.id_categoria = dc.id_categoria_mestre
        WHERE v.ano = p_ano
          AND v.mes = p_mes
          AND (p_categoria IS NULL
               OR COALESCE(cat_mestre.nome_categoria, v.categoria, 'ALIMENTO_VAREJO') ILIKE v_categoria_filter)
          AND v.tipo_dado IN ('REAL_ATUAL', 'HISTORICO_BASE')
          AND COALESCE(v.idade_dado_anos, 0) <= 1
          AND COALESCE(v.metadado_transparencia->>'procedencia', '') NOT LIKE 'sem_historico_real%'
    ),
    uf_consolidado AS (
        -- Nível 1: (produto_canonico, UF) — AVG de preço (média simples dos ids
        -- fundidos), MODE de status, BOOL_OR de flags, peso = registros da UF.
        SELECT
            pc.produto,
            pc.classificao_produto,
            COALESCE(pc.categoria, 'ALIMENTO_VAREJO') AS categoria_final,
            pc.uf,
            COUNT(*)::NUMERIC AS peso_uf,
            AVG(pc.preco_referencia) AS uf_preco_ref,
            AVG(pc.preco_atual)      AS uf_preco_atual,
            BOOL_OR(pc.usou_fallback_12m) AS uf_fallback,
            BOOL_OR(pc.preco_estimado)    AS uf_estimado,
            BOOL_OR(pc.is_forecast)       AS uf_forecast,
            MODE() WITHIN GROUP (ORDER BY pc.status_cor) AS uf_status_cor,
            MAX(pc.baseline_confianca)    AS uf_confianca
        FROM produto_canonico pc
        GROUP BY pc.produto, pc.classificao_produto, categoria_final, pc.uf
    )
    -- Nível 2: nacional por (produto_canonico, mês) — média ponderada por UF.
    -- FASE 68: status_cor_nac por QUÓRUM de severidade (idem nacional sazonalidade).
    SELECT
        uf.produto,
        uf.classificao_produto,
        uf.categoria_final,
        'BR'::TEXT                    AS uf_nacional,
        'BRASIL'::TEXT                AS municipio_nome,
        '0'::TEXT                     AS municipio_id_val,
        p_ano                         AS ano_val,
        p_mes                         AS mes_val,
        (p_ano || '-' || LPAD(p_mes::TEXT, 2, '0'))::TEXT AS data_ref,
        ROUND(SUM(uf.uf_preco_ref * uf.peso_uf) / NULLIF(SUM(uf.peso_uf), 0), 4) AS preco_ref_nac,
        ROUND(SUM(uf.uf_preco_atual * uf.peso_uf) / NULLIF(SUM(uf.peso_uf), 0), 4) AS preco_atual_nac,
        BOOL_OR(uf.uf_fallback)  AS usou_fallback_nac,
        BOOL_OR(uf.uf_estimado)  AS preco_estimado_nac,
        CASE
            WHEN (COUNT(*) FILTER (WHERE uf.uf_status_cor = 'VERMELHO'))::numeric
                 / NULLIF(COUNT(*), 0) >= 0.40 THEN 'VERMELHO'
            WHEN (COUNT(*) FILTER (WHERE uf.uf_status_cor = 'VERDE'))::numeric
                 / NULLIF(COUNT(*), 0) >= 0.40 THEN 'VERDE'
            ELSE 'AMARELO'
        END AS status_cor_nac,
        'municipio'::TEXT        AS fonte_nac,
        BOOL_OR(uf.uf_forecast)  AS is_forecast_nac,
        COUNT(DISTINCT uf.uf)    AS total_ufs_nac,
        ROUND(
            SUM(uf.uf_confianca * uf.peso_uf) / NULLIF(SUM(uf.peso_uf), 0),
            4
        ) AS confianca_baseline_nac
    FROM uf_consolidado uf
    GROUP BY uf.produto, uf.classificao_produto, uf.categoria_final
    HAVING COUNT(DISTINCT uf.uf) >= 5
    ORDER BY status_cor_nac, uf.produto
    LIMIT p_limit OFFSET p_offset;
END;
$function$;

COMMENT ON FUNCTION mart.fn_br_nacional_por_mes(integer, integer, text, integer, integer) IS
    'Nacional por (produto canônico, mês) com preços. FASE 68: status_cor '
    'nacional por QUÓRUM de severidade (>=40%% VERMELHO → VERMELHO; >=40%% '
    'VERDE → VERDE; senão AMARELO). Preços = média ponderada por UF. '
    'HAVING COUNT(DISTINCT uf) >= 5 preservado.';

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_por_mes(integer, integer, text, integer, integer)
    TO role_api_reader;

-- ============================================================================
-- FASE 2b — Ausência de dados vira CINZA (não AMARELO mecânico)
-- ============================================================================
-- Ordem de recriação (padrão 65): guard de colisão → DROP MV → DROP VIEW →
-- CREATE VIEW (âncora) → CREATE MV (WITH DATA) → índices → GRANTs.

-- Guard de colisão (idêntico à 65): ids negativos dos branches B/C não podem
-- colidir com ids positivos da tabela base.
DO $$
DECLARE
    v_max BIGINT;
BEGIN
    SELECT MAX(id_sazonalidade) INTO v_max FROM mart.sazonalidade_produto;
    IF v_max IS NOT NULL AND v_max >= 1000000000 THEN
        RAISE EXCEPTION
            '[68] Colisão de id_sazonalidade: MAX(id_sazonalidade)=% >= 1000000000. '
            'A faixa de ids negativos da MV colidiria com ids positivos. '
            'Abortando criação da MV.', v_max;
    END IF;
    RAISE NOTICE '[68] Guard de colisão OK (MAX(id_sazonalidade)=%)', v_max;
END $$;

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

-- ============================================================================
-- View âncora recriada (DROP + CREATE) — status_cor sem fallback 'AMARELO'
-- ============================================================================
-- FASE 68: base insuficiente (n_meses_referencia < 6) OU banda inválida
-- (fn_status_cor_zscore retorna NULL) agora produzem status_cor = NULL, em
-- vez de 'AMARELO' forçado. A MV exclui essas linhas e o backend marca CINZA
-- (regra de transparência aprovada), em vez de AMARELO mecânico que mascarava
-- a ausência de histórico real. Sem COALESCE e sem o 'AMARELO' do CASE.

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
       -- FASE 68: SEM COALESCE e SEM 'AMARELO' forçado. n_meses_referencia < 6
       -- (base insuficiente) ou banda inválida (fn_status_cor_zscore = NULL)
       -- agora retornam NULL → a MV exclui a linha → o backend marca CINZA,
       -- em vez de AMARELO mecânico (Quality Gate / regra aprovada).
       CASE
           WHEN a.n_meses_referencia IS NULL OR a.n_meses_referencia < 6 THEN NULL
           ELSE staging.fn_status_cor_zscore(
                    a.preco_exibido, a.preco_referencia, v.desvio_efetivo
                )
       END AS status_cor,
       jsonb_build_object(
           'fonte_dado',        a.fonte,
           'data_ultima_coleta', a.data_ultima_coleta,
           'procedencia',       'coleta_real_conab',
           'ano_referencia',    a.ano_referencia
       ) AS metadado_transparencia,
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
    'status_cor DINÂMICO ±1 desvio padrão via fn_status_cor_zscore + '
    'fn_estatisticas_volatilidade_24m (FASE 68 com outliers IQR expurgados); '
    'desvio_padrao_historico/limite_superior/limite_inferior expostos. '
    'FASE 68: n_meses_referencia < 6 ou banda inválida → status_cor NULL '
    '(MV exclui a linha → backend marca CINZA), NÃO mais AMARELO forçado. '
    'Sem CROSS JOIN (D1).';

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
        -- FASE 68: COALESCE(f.status_cor,'AMARELO') removido. O WHERE abaixo
        -- (f.status_cor IN ('VERDE','AMARELO','VERMELHO')) já garante não-nulo;
        -- o COALESCE era dead code que mascarava ausência de status real.
        f.status_cor AS status_cor,
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
    'V19 (recalibracao-estatistica-br) — 3 branches: (A) linhas reais com '
    'âncora; (B) exibição ancorada em ano atual (id=-id, só quando '
    'ano_referencia<N); (C) FALLBACK_DIMENSAO (id=-(id)-1e9). FASE 68: âncora '
    'sem fallback AMARELO — base insuficiente/banda inválida → status_cor NULL '
    '(linha excluída → CINZA no backend); branch C sem COALESCE morto. '
    'desvio_padrao_historico/limite_superior/limite_inferior de '
    'fn_estatisticas_volatilidade_24m (outliers IQR expurgados). Linhas '
    'FLUXO_PROXY/sintéticas NUNCA entram na MV (semântica de exibição).';

-- Índices (padrão 65) — UNIQUE primeiro (obrigatório p/ CONCURRENTLY).
CREATE UNIQUE INDEX idx_vw_sazonalidade_unico ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);
CREATE INDEX idx_vw_sazonalidade_filtro ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);
CREATE INDEX idx_vw_sazonalidade_categoria ON mart.vw_api_produtos_sazonalidade (categoria);
CREATE INDEX idx_vw_sazonalidade_produto ON mart.vw_api_produtos_sazonalidade (id_produto);
CREATE INDEX idx_vw_sazonalidade_ano_mes ON mart.vw_api_produtos_sazonalidade (ano, mes) WHERE (ano IS NOT NULL AND mes IS NOT NULL);
CREATE INDEX idx_vw_sazonalidade_tipo_dado ON mart.vw_api_produtos_sazonalidade (tipo_dado) WHERE (tipo_dado IS NOT NULL);
CREATE INDEX idx_vw_sazonalidade_ano_referencia ON mart.vw_api_produtos_sazonalidade (ano_referencia DESC) WHERE (ano_referencia IS NOT NULL);

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;

COMMIT;
