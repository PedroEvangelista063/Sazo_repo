-- ============================================================================
-- MIGRATION 78 — DEEP FALLBACK HISTÓRICO (V22)
-- ============================================================================
-- DATA: 2026-08-11 · AUTOR: auditoria E2E + decisão de arquitetura (lead)
--
-- CONTEXTO / PROBLEMA
-- -------------------
-- A auditoria E2E apontou que meses futuros (set-dez 2026) da MV
-- mart.vw_api_produtos_sazonalidade têm linhas FALLBACK_DIMENSAO com
-- status_cor fabricado ('AMARELO') e ano_referencia NULL (hoje 2026-08-11:
-- m8-12 REAL_ATUAL = 0 linhas; m7 = 1.956 parcial; 9.055 linhas FALLBACK em
-- m9-12). A arquitetura REJEITOU 'CINZA'/null na UI — a grade deve permanecer
-- preenchida (VERDE/AMARELO/VERMELHO).
--
-- SOLUÇÃO APROVADA (DEEP FALLBACK)
-- --------------------------------
-- Para linhas FALLBACK_DIMENSAO do ano corrente com mes >= mes corrente:
--   status_cor ← (1º) status_cor do histórico real mais recente do mesmo
--                 (id_produto, id_localidade, mes) em anos anteriores
--                 (tipo_dado IN ('REAL_ATUAL','HISTORICO_BASE'),
--                  ORDER BY ano DESC LIMIT 1);
--               (2º) mart.sazonalidade_baseline.status_cor_mode;
--               (3º) 'VERDE'.
--   ano_referencia ← ano histórico usado (NULL se caiu em baseline/VERDE —
--                    não existe ano real de origem).
--   metadado_transparencia ← chaves originais preservadas + objeto
--                 'PROJECAO_HISTORICA'/'DEEP_FALLBACK'/'ano_referencia'/
--                 'mensagem_transparencia'.
--   mensagem_transparencia ← texto da projeção (NULL para linhas reais).
-- Contrato da API NÃO muda: tipo_dado continua Literal atual
-- (REAL_ATUAL/HISTORICO_BASE/FALLBACK_DIMENSAO) — a proveniência vai nos
-- metadados. QUALITY GATE da FASE 76 preservado integralmente.
--
-- Também: fn_br_nacional_sazonalidade ganha p_limit/p_offset (paginação
-- push-down no NÍVEL DE PRODUTO — grade de 12 meses), mantendo o contrato do
-- endpoint /br-sazonalidade ("Exibindo X produtos", grade por produto).
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1 — MV V22: DEEP FALLBACK (DROP + CREATE — padrão do repo)
-- ============================================================================
-- Mantém TODAS as 35 colunas da FASE 76 na MESMA ordem + nova coluna final
-- mensagem_transparencia TEXT. LATERAL de histórico e JOIN de baseline só
-- disparam para linhas candidatas (branch C, ano corrente, mes >= corrente,
-- ano_referencia NULL) via condição no ON — custo zero para linhas reais.

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
-- CTE MATERIALIZED: a view âncora (LATERAL/DISTINCT) é avaliada UMA vez;
-- sem isso, o NOT EXISTS do branch C reavaliaria a view por linha (lentidão O(N²)).
WITH anchor AS MATERIALIZED (
    SELECT * FROM mart.vw_anchor_sazonalidade
),
-- FASE 76 — QUALITY GATE DE COMPLETUDE: só entram na MV produtos com série
-- mensal COMPLETA (12/12 meses REAIS — is_interpolado = FALSE) em 2024 OU 2025
-- (staging.fact_precos_mensais). Produtos com gaps em todos os anos (grupo Z)
-- são removidos sumariamente da visão — nenhuma grade incompleta chega à API.
produtos_completos AS MATERIALIZED (
    SELECT id_produto
    FROM staging.fact_precos_mensais
    WHERE ano IN (2024, 2025)
      AND NOT COALESCE(is_interpolado, FALSE)
    GROUP BY id_produto
    HAVING COUNT(DISTINCT CASE WHEN ano = 2024 THEN mes END) = 12
        OR COUNT(DISTINCT CASE WHEN ano = 2025 THEN mes END) = 12
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
    -- FASE 78 — DEEP FALLBACK: status projetado do histórico/baseline para
    -- linhas FALLBACK_DIMENSAO futuras do ano corrente.
    CASE WHEN v.tipo_dado = 'FALLBACK_DIMENSAO'
              AND v.ano = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
              AND v.mes >= EXTRACT(MONTH FROM CURRENT_DATE)::INTEGER
              AND v.ano_referencia IS NULL
         THEN COALESCE(hh.hist_status_cor, b.status_cor_mode, 'VERDE')
         ELSE v.status_cor
    END AS status_cor,
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
    -- FASE 78 — ano histórico usado pela projeção (NULL em baseline/VERDE)
    CASE WHEN v.tipo_dado = 'FALLBACK_DIMENSAO'
              AND v.ano = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
              AND v.mes >= EXTRACT(MONTH FROM CURRENT_DATE)::INTEGER
              AND v.ano_referencia IS NULL
         THEN hh.hist_ano
         ELSE v.ano_referencia
    END AS ano_referencia,
    v.tipo_dado,
    v.idade_dado_anos,
    -- FASE 78 — chaves originais preservadas (data_referencia etc.) + objeto
    -- de projeção; 'procedencia' é sobrescrito por DEEP_FALLBACK (|| right-wins).
    CASE WHEN v.tipo_dado = 'FALLBACK_DIMENSAO'
              AND v.ano = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
              AND v.mes >= EXTRACT(MONTH FROM CURRENT_DATE)::INTEGER
              AND v.ano_referencia IS NULL
         THEN COALESCE(v.metadado_transparencia, '{}'::jsonb)
              || jsonb_build_object(
                     'fonte_dado', 'PROJECAO_HISTORICA',
                     'procedencia', 'DEEP_FALLBACK',
                     'ano_referencia', hh.hist_ano,
                     'mensagem_transparencia',
                         CASE WHEN hh.hist_ano IS NOT NULL
                              THEN 'Projecao sazonal baseada no historico de ' || hh.hist_ano::TEXT
                              ELSE 'Projecao sazonal sem historico real (baseline de dimensao)'
                         END
                 )
         ELSE v.metadado_transparencia
    END AS metadado_transparencia,
    -- Limiares dinâmicos (V18 — FASE 65)
    v.desvio_padrao_historico,
    v.limite_superior,
    v.limite_inferior,
    -- FASE 78 — texto de proveniência da projeção (NULL para linhas reais)
    CASE WHEN v.tipo_dado = 'FALLBACK_DIMENSAO'
              AND v.ano = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
              AND v.mes >= EXTRACT(MONTH FROM CURRENT_DATE)::INTEGER
              AND v.ano_referencia IS NULL
         THEN CASE WHEN hh.hist_ano IS NOT NULL
                   THEN 'Projecao sazonal baseada no historico de ' || hh.hist_ano::TEXT
                   ELSE 'Projecao sazonal sem historico real (baseline de dimensao)'
              END
         ELSE NULL
    END AS mensagem_transparencia
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
        -- (f.status_cor IN ('VERDE','AMARELO','VERMELHO')) já garante não-nulo.
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
-- FASE 76 — QUALITY GATE DE COMPLETUDE: hash join com produtos que possuem
-- série mensal COMPLETA (12/12 meses reais) em 2024 OU 2025.
JOIN produtos_completos pc ON pc.id_produto = v.id_produto
-- FASE 78 — DEEP FALLBACK: histórico real mais recente do mesmo
-- (id_produto, id_localidade, mes) em anos anteriores. O ON restringe a
-- avaliação do LATERAL às linhas candidatas (branch C futuras do ano corrente).
LEFT JOIN LATERAL (
    SELECT h.status_cor AS hist_status_cor,
           h.ano        AS hist_ano
    FROM mart.sazonalidade_produto h
    WHERE h.id_produto = v.id_produto
      AND h.id_localidade = v.id_localidade
      AND h.mes = v.mes
      AND h.ano < EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
      AND h.tipo_dado IN ('REAL_ATUAL', 'HISTORICO_BASE')
      AND h.status_cor IN ('VERDE', 'AMARELO', 'VERMELHO')
      AND NOT COALESCE(h.is_forecast, FALSE)
      AND COALESCE(h.fonte, '') <> 'FLUXO_PROXY'
    ORDER BY h.ano DESC
    LIMIT 1
) hh ON v.tipo_dado = 'FALLBACK_DIMENSAO'
    AND v.ano = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
    AND v.mes >= EXTRACT(MONTH FROM CURRENT_DATE)::INTEGER
    AND v.ano_referencia IS NULL
-- FASE 78 — baseline sazonal (moda por produto/localidade/mês) como 2º nível
-- do Deep Fallback. UNIQUE(id_produto, id_localidade, mes) garante 1 linha.
LEFT JOIN mart.sazonalidade_baseline b
    ON b.id_produto = v.id_produto
   AND b.id_localidade = v.id_localidade
   AND b.mes = v.mes
   AND v.tipo_dado = 'FALLBACK_DIMENSAO'
   AND v.ano = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
   AND v.mes >= EXTRACT(MONTH FROM CURRENT_DATE)::INTEGER
   AND v.ano_referencia IS NULL
ORDER BY v.ano, v.mes, v.is_forecast, v.status_cor, v.produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'V22 (deep-fallback-historico) — 3 branches: (A) linhas reais com âncora; '
    '(B) exibição ancorada em ano atual (id=-id, só quando ano_referencia<N); '
    '(C) FALLBACK_DIMENSAO (id=-(id)-1e9). FASE 68: âncora sem fallback AMARELO '
    '— base insuficiente/banda inválida → status_cor NULL (linha excluída). '
    'FASE 71: supressão de produtos fantasmas. FASE 76: QUALITY GATE DE '
    'COMPLETUDE (vitrine perfeita, COUNT(DISTINCT mes)=12 real em 2024 OU 2025). '
    'FASE 78: DEEP FALLBACK — linhas FALLBACK_DIMENSAO do ano corrente com '
    'mes >= mes corrente projetam status_cor do histórico real mais recente '
    'do mesmo produto+localidade+mes (tipo_dado REAL_ATUAL/HISTORICO_BASE, '
    'ORDER BY ano DESC LIMIT 1) → mart.sazonalidade_baseline.status_cor_mode '
    '→ VERDE; ano_referencia = ano histórico usado (NULL em baseline); '
    'metadado_transparencia preserva chaves originais + '
    'PROJECAO_HISTORICA/DEEP_FALLBACK/mensagem; nova coluna '
    'mensagem_transparencia TEXT (NULL para linhas reais). Qualidade: status_cor '
    'fabricado AMARELO e nulls de ano_referencia eliminados nos meses futuros.';

-- Índices (padrão 65) — UNIQUE primeiro (obrigatório p/ CONCURRENTLY).
CREATE UNIQUE INDEX idx_vw_sazonalidade_unico ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);
CREATE INDEX idx_vw_sazonalidade_filtro ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);
CREATE INDEX idx_vw_sazonalidade_categoria ON mart.vw_api_produtos_sazonalidade (categoria);
CREATE INDEX idx_vw_sazonalidade_produto ON mart.vw_api_produtos_sazonalidade (id_produto);
CREATE INDEX idx_vw_sazonalidade_ano_mes ON mart.vw_api_produtos_sazonalidade (ano, mes) WHERE (ano IS NOT NULL AND mes IS NOT NULL);
CREATE INDEX idx_vw_sazonalidade_tipo_dado ON mart.vw_api_produtos_sazonalidade (tipo_dado) WHERE (tipo_dado IS NOT NULL);
CREATE INDEX idx_vw_sazonalidade_ano_referencia ON mart.vw_api_produtos_sazonalidade (ano_referencia DESC) WHERE (ano_referencia IS NOT NULL);

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;
GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_etl_writer;

-- ============================================================================
-- SEÇÃO 2 — fn_br_nacional_sazonalidade: paginação push-down
-- ============================================================================
-- Mesma lógica canônica da 67 (CTEs produto_canonico/uf_por_mes/nacional) +
-- CTE 'pagina' com LIMIT/OFFSET APÓS ORDER BY sobre o conjunto DISTINTO de
-- produtos (grade de 12 meses). p_limit NULL = sem limite (usado pelo count).
-- OBS: CREATE OR REPLACE não muda aridade → DROP das assinaturas antigas
-- primeiro (padrão 63:600-601), preservando o contrato (3 args continuam OK
-- via DEFAULTs).

DROP FUNCTION IF EXISTS mart.fn_br_nacional_sazonalidade(INTEGER, TEXT);
DROP FUNCTION IF EXISTS mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER);

CREATE FUNCTION mart.fn_br_nacional_sazonalidade(
    p_ano       INTEGER,
    p_categoria TEXT DEFAULT NULL,
    p_min_ufs   INTEGER DEFAULT 1,
    p_limit     INTEGER DEFAULT NULL,
    p_offset    INTEGER DEFAULT 0
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
    calculado_em        TIMESTAMPTZ,
    ano_referencia      INTEGER,
    tipo_dado           TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_categoria_filter TEXT := COALESCE(p_categoria, '%%');
    v_min_ufs INTEGER := COALESCE(p_min_ufs, 1);
BEGIN
    RETURN QUERY
    WITH produto_canonico AS (
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
    ),
    nacional AS (
        SELECT
            upm.produto,
            MODE() WITHIN GROUP (ORDER BY upm.classificao_produto) AS classificao_produto,
            MODE() WITHIN GROUP (ORDER BY upm.categoria_final)     AS categoria,
            upm.mes,
            (p_ano || '-' || LPAD(upm.mes::TEXT, 2, '0'))::TEXT AS data_ref,
            MODE() WITHIN GROUP (ORDER BY upm.uf_status_cor)       AS status_cor_nac,
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
    ),
    -- FASE 78 — paginação push-down NO NÍVEL DE PRODUTO (grade de 12 meses):
    -- LIMIT/OFFSET após o ORDER BY do conjunto DISTINTO de produtos — MESMA
    -- semântica do fatiamento em memória removido do backend (produtos.py
    -- all_items[offset:offset+por_pagina]). p_limit NULL = sem limite.
    pagina AS (
        SELECT n.produto
        FROM nacional n
        GROUP BY n.produto
        ORDER BY n.produto
        LIMIT p_limit OFFSET p_offset
    )
    SELECT
        n.produto,
        n.classificao_produto,
        n.categoria,
        n.mes,
        n.data_ref                AS data_referencia_atual,
        n.status_cor_nac          AS status_cor,
        n.is_forecast_nac         AS is_forecast,
        n.confianca_nac           AS baseline_confianca,
        n.total_ufs_nac           AS total_ufs,
        n.forecast_method_nac     AS forecast_method,
        n.calculado_em_nac        AS calculado_em,
        n.ano_referencia_nac      AS ano_referencia,
        n.tipo_dado_nac           AS tipo_dado
    FROM nacional n
    JOIN pagina pg ON pg.produto = n.produto
    ORDER BY n.produto, n.mes;
END;
$$;

COMMENT ON FUNCTION mart.fn_br_nacional_sazonalidade IS
    'Sazonalidade BR Nacional — retorna os 12 meses de um ano por produto '
    'canônico. Moda da moda por UF, HAVING COUNT(DISTINCT uf) >= p_min_ufs '
    '(default 1). FASE 78: paginação push-down por PRODUTO (p_limit/p_offset '
    'sobre o DISTINCT de produtos, ORDER BY produto; p_limit NULL = sem '
    'limite). Inclui forecast_method (moda), calculado_em (máximo), '
    'ano_referencia (moda) e tipo_dado (moda). '
    'Uso: SELECT * FROM mart.fn_br_nacional_sazonalidade(2026); '
    'SELECT * FROM mart.fn_br_nacional_sazonalidade(2026, NULL, 1, 100, 0);';

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER, INTEGER, INTEGER)
    TO role_api_reader;

-- ============================================================================
-- SEÇÃO 3 — Prova embutida (saída do psql)
-- ============================================================================
DO $$
DECLARE
    v_fallback      int;
    v_projetado     int;
    v_linhas_mv     int;
    v_produtos_br   int;
BEGIN
    SELECT count(*) INTO v_fallback
      FROM mart.vw_api_produtos_sazonalidade
     WHERE tipo_dado = 'FALLBACK_DIMENSAO';
    SELECT count(*) INTO v_projetado
      FROM mart.vw_api_produtos_sazonalidade
     WHERE tipo_dado = 'FALLBACK_DIMENSAO'
       AND mensagem_transparencia IS NOT NULL;
    SELECT count(*) INTO v_linhas_mv FROM mart.vw_api_produtos_sazonalidade;
    SELECT count(*) INTO v_produtos_br
      FROM mart.fn_br_nacional_sazonalidade(EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);
    RAISE NOTICE 'QG-78: MV=% linhas | FALLBACK=% | deep_fallback_projetado=% | fn_br_nacional_sem_limit=%',
        v_linhas_mv, v_fallback, v_projetado, v_produtos_br;
END $$;

COMMIT;
