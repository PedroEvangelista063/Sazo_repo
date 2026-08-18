-- ============================================================================
-- MIGRATION 83 — CORREÇÃO DA ÂNCORA HISTÓRICA + CASCATA TRICROMÁTICA (V24)
-- ============================================================================
-- DATA: 2026-08-18 · AUTOR: correção de Quality Gate de Transparência de Dados
--
-- CONTEXTO / PROBLEMA
-- -------------------
-- A migration 80 (V23) fixou o piso da âncora histórica do Deep Fallback em
-- Ano Atual − 3 (2023), projetando ago–dez/2026 com base em 2023 (~11.047
-- linhas com ano_referencia=2023). Isso viola a regra de âncora histórica do
-- AGENTS.md (âncora máxima = Ano Atual − 1, hoje 2025). Além disso, projeções
-- FALLBACK_DIMENSAO sem histórico e sem baseline sofriam fallback forçado para
-- 'VERDE' (~10.593 linhas VERDE artificiais), mascarando ausência de dado real.
--
-- DECISÃO DE NEGÓCIO (Quality Gate)
-- --------------------------------
-- Paleta estritamente tricromática: 'VERDE', 'AMARELO', 'VERMELHO' (sem CINZA).
-- Transparência de projeções sem dado real é informada APENAS via metadados
-- (ano_referencia, tipo_dado, mensagem_transparencia). Contrato da API
-- INALTERADO.
--
-- SOLUÇÃO (V24)
-- -------------
-- 1. Piso deslizante de ano no LATERAL hh do Deep Fallback:
--      AND h.ano >= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 1
--    (janela deslizante de 2 anos: para 2026, âncoras 2024..2025 — piso =
--    Ano Atual − 1, ou seja, 2025 hoje). Nenhuma âncora < Ano Atual − 1.
-- 2. Cascata de status tricromática no CASE do status_cor:
--      THEN COALESCE(hh.hist_status_cor, b.status_cor_mode, 'AMARELO')
--    (histórico real recente → cor dele; senão baseline mode da dimensão;
--    senão AMARELO neutro = alerta metodológico — NUNCA VERDE artificial).
-- 3. ano_referencia = ano histórico usado pela projeção, ou NULL em baseline
--    pura (sem histórico real no piso Ano Atual − 1).
--
-- LOCAIS ONDE O PISO FOI CORRIGIDO
-- -------------------------------
-- 1. LEFT JOIN LATERAL hh do Deep Fallback (80:366-383 → 83): subconsulta que
--    lê mart.sazonalidade_produto (alias h) buscando o status/ano histórico
--    real mais recente do mesmo (id_produto, id_localidade, mes) em anos
--    anteriores (tipo_dado IN ('REAL_ATUAL','HISTORICO_BASE'), ORDER BY ano
--    DESC LIMIT 1). É a ÚNICA subconsulta da MV com intenção de âncora
--    histórica de PROJEÇÃO (Deep Fallback). Troca '... - 3' por '... - 1'.
--
-- LOCAIS ONDE NÃO FOI ALTERADO (e por quê)
-- ----------------------------------------
-- 1. Branch A — linhas REAIS do período corrente (navegação + dados reais).
--    Não é projeção.
-- 2. Branch B — join apenas para campos de exibição da linha âncora; filtro
--    de ano vive no anchor (vw_anchor_sazonalidade). Re-exibição de dados
--    REAIS na grade, não projeção.
-- 3. Branch C — linhas FALLBACK_DIMENSAO do ano corrente (linhas-alvo, não
--    âncora histórica).
-- 4. Filtros 'status_cor IN ('VERDE','AMARELO','VERMELHO')' nas branches A/B/C
--    e no LATERAL hh — regras de cor de dados reais (paleta), não fallback de
--    projeção. NÃO alterados.
-- 5. CTE anchor — alimenta branches A/B com dados reais; alterar mudaria dados
--    reais (proibido pela regra de branches).
--
-- QUALITY GATE (FASE 76) preservado integralmente.
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1 — MV V24: CORREÇÃO DA ÂNCORA HISTÓRICA + CASCATA TRICROMÁTICA
-- ============================================================================
-- Idêntica à 80 (V23) exceto por: (1) piso do ano no LATERAL hh
-- (Ano Atual − 1, hoje 2025); (2) fallback final da cascata de status
-- 'VERDE' → 'AMARELO'. Mantém TODAS as 35 colunas na MESMA ordem + coluna
-- final mensagem_transparencia TEXT. LATERAL de histórico e JOIN de baseline
-- só disparam para linhas candidatas (branch C, ano corrente, mes >= corrente,
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
    -- M83 — CASCATA TRICROMÁTICA: histórico real recente → cor dele; senão
    -- baseline mode da dimensão; senão AMARELO neutro (alerta metodológico) —
    -- NUNCA 'VERDE' artificial quando não houver dado real.
    CASE WHEN v.tipo_dado = 'FALLBACK_DIMENSAO'
              AND v.ano = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
              AND v.mes >= EXTRACT(MONTH FROM CURRENT_DATE)::INTEGER
              AND v.ano_referencia IS NULL
         THEN COALESCE(hh.hist_status_cor, b.status_cor_mode, 'AMARELO')
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
    -- FASE 78 — ano histórico usado pela projeção (NULL em baseline pura)
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
-- M83 — piso da âncora CORRIGIDO: Ano Atual − 1 (hoje 2025), janela 2024..2025.
LEFT JOIN LATERAL (
    SELECT h.status_cor AS hist_status_cor,
           h.ano        AS hist_ano
    FROM mart.sazonalidade_produto h
    WHERE h.id_produto = v.id_produto
      AND h.id_localidade = v.id_localidade
      AND h.mes = v.mes
      AND h.ano < EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
      -- M83 — ÂNCORA HISTÓRICA MÁXIMA Ano Atual − 1: piso deslizante (nenhuma
      -- âncora < Ano Atual − 1). Corrige o piso − 3 da migration 80 (2023).
      AND h.ano >= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 1
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
    'V24 (correcao-ancora-janela-historica) — 3 branches: (A) linhas reais com '
    'âncora; (B) exibição ancorada em ano atual (id=-id, só quando '
    'ano_referencia<N); (C) FALLBACK_DIMENSAO (id=-(id)-1e9). FASE 68: âncora '
    'sem fallback AMARELO — base insuficiente/banda inválida → status_cor NULL '
    '(linha excluída). FASE 71: supressão de produtos fantasmas. FASE 76: '
    'QUALITY GATE DE COMPLETUDE (vitrine perfeita, COUNT(DISTINCT mes)=12 real '
    'em 2024 OU 2025). FASE 78: DEEP FALLBACK — linhas FALLBACK_DIMENSAO do ano '
    'corrente com mes >= mes corrente projetam status_cor do histórico real '
    'mais recente do mesmo produto+localidade+mes (tipo_dado '
    'REAL_ATUAL/HISTORICO_BASE, ORDER BY ano DESC LIMIT 1) → '
    'mart.sazonalidade_baseline.status_cor_mode → AMARELO (NUNCA VERDE '
    'artificial); ano_referencia = ano histórico usado pela projeção (NULL em '
    'baseline pura); metadado_transparencia preserva chaves originais + '
    'PROJECAO_HISTORICA/DEEP_FALLBACK/mensagem; coluna mensagem_transparencia '
    'TEXT (NULL para linhas reais). M83: QUALITY GATE DE ÂNCORA — piso '
    'deslizante no LATERAL hh do Deep Fallback corrigido para '
    '(h.ano >= Ano Atual − 1; hoje 2025): nenhuma âncora < Ano Atual − 1 '
    '(corrige o piso − 3 de 2023 da M80). Cascata tricromática '
    '(hist → baseline → AMARELO): projeção sem dado real nunca vira VERDE. '
    'Transparência via metadados (ano_referencia/tipo_dado/mensagem). '
    'Paleta estrita VERDE/AMARELO/VERMELHO — sem CINZA.';

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
-- SEÇÃO 2 — Prova embutida (saída do psql)
-- ============================================================================
-- QG-83: âncora histórica máxima Ano Atual − 1.
--   * projecao_janela = projeções com histórico cujo ano_referencia está
--     DENTRO da janela (>= Ano Atual − 1).
--   * ancora_velha = projeções futuras do ano corrente com ano_referencia
--     explícito ANTES de Ano Atual − 1 (deve ser 0).
--   * historico_2025 = mensagens de projeção ancoradas no ano mais recente
--     dentro do piso (hoje 2025) — confirma o texto da transparência.
-- A função fn_br_nacional_sazonalidade já foi atualizada na migration 79 —
-- não é tocada aqui (padrão 78: DDL só, refresh posterior via psql).

DO $$
DECLARE
    v_fallback        int;
    v_projetado       int;
    v_projecao_janela int;
    v_ancora_velha    int;
    v_hist_2025       int;
    v_linhas_mv       int;
BEGIN
    SELECT count(*) INTO v_fallback
      FROM mart.vw_api_produtos_sazonalidade
     WHERE tipo_dado = 'FALLBACK_DIMENSAO';
    SELECT count(*) INTO v_projetado
      FROM mart.vw_api_produtos_sazonalidade
     WHERE tipo_dado = 'FALLBACK_DIMENSAO'
       AND mensagem_transparencia IS NOT NULL;
    SELECT count(*) INTO v_projecao_janela
      FROM mart.vw_api_produtos_sazonalidade
     WHERE tipo_dado = 'FALLBACK_DIMENSAO'
       AND mensagem_transparencia IS NOT NULL
       AND COALESCE(ano_referencia, 0) >= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 1;
    SELECT count(*) INTO v_ancora_velha
      FROM mart.vw_api_produtos_sazonalidade
     WHERE tipo_dado = 'FALLBACK_DIMENSAO'
       AND ano = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
       AND ano_referencia IS NOT NULL
       AND ano_referencia < EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 1;
    SELECT count(*) INTO v_hist_2025
      FROM mart.vw_api_produtos_sazonalidade
     WHERE tipo_dado = 'FALLBACK_DIMENSAO'
       AND mensagem_transparencia =
           'Projecao sazonal baseada no historico de '
           || (EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 1)::TEXT;
    SELECT count(*) INTO v_linhas_mv FROM mart.vw_api_produtos_sazonalidade;
    RAISE NOTICE 'QG-83: MV=% FALLBACK=% projecao_janela=% ancora_velha_%_antes=% historico_2025=%',
        v_linhas_mv, v_fallback, v_projecao_janela,
        EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 1, v_ancora_velha, v_hist_2025;
END $$;

COMMIT;