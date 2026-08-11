-- ============================================================================
-- MIGRATION 80 — DEEP FALLBACK JANELA HISTÓRICA 2023+ (V23)
-- ============================================================================
-- DATA: 2026-08-11 · AUTOR: decisão do usuário
--
-- CONTEXTO / PROBLEMA
-- -------------------
-- A migration 78 (V22) implementou o DEEP FALLBACK projetando status_cor de
-- linhas FALLBACK_DIMENSAO futuras do ano corrente a partir do histórico real
-- mais recente do mesmo (id_produto, id_localidade, mes) em anos anteriores.
-- Sem piso de ano, o LATERAL hh (78:338-352) podia usar âncoras de 2021/2022
-- (defasagem elevada + inflação acumulada), comprometendo a qualidade da
-- projeção sazonal exibida na grade.
--
-- DECISÃO DE NEGÓCIO (usuário)
-- ----------------------------
-- Janela histórica de projeção LIMITADA a 2023–2026: NENHUMA âncora anterior a
-- 2023 (defasagem + inflação). Usar dados de 2023 a 2026 para completar todos
-- os meses e quadros de sazonalidade.
--
-- SOLUÇÃO (V23)
-- -------------
-- Piso deslizante de ano em TODA subconsulta da MV que lê histórico de
-- mart.sazonalidade_produto com intenção de âncora de projeção/fallback:
--   AND ano >= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 3
-- (janela deslizante de 4 anos: para 2026, âncoras 2023..2025 — piso = Ano
--  Atual − 3, ou seja, 2023 hoje). Contrato da API e branches A/B/C
-- INALTERADOS. NÃO inclui REFRESH (padrão 78: DDL só, refresh posterior via
-- psql). A função fn_br_nacional_sazonalidade já foi alterada na migration 79
-- — NÃO é tocada aqui.
--
-- LOCAIS ONDE O PISO FOI APLICADO
-- -------------------------------
-- 1. LEFT JOIN LATERAL hh do Deep Fallback (78:338-352 → 80:340-355):
--    subconsulta que lê mart.sazonalidade_produto (alias h) buscando o
--    status/ano histórico real mais recente do mesmo (id_produto, id_localidade,
--    mes) em anos anteriores (tipo_dado IN ('REAL_ATUAL','HISTORICO_BASE'),
--    ORDER BY ano DESC LIMIT 1). É a ÚNICA subconsulta da MV com intenção de
--    âncora histórica de PROJEÇÃO (Deep Fallback). Adicionado
--    'AND h.ano >= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 3' logo após o
--    'AND h.ano < EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER' (78:345).
--
-- LOCAIS ONDE O PISO NÃO FOI APLICADO (e por quê)
-- ------------------------------------------------
-- 1. Branch A (78:190 'FROM mart.sazonalidade_produto s') — linhas REAIS do
--    período corrente (navegação + dados reais do ano). Não é projeção.
-- 2. Branch B (78:249 'JOIN mart.sazonalidade_produto s') — join apenas para
--    buscar campos de exibição da linha âncora; o filtro de ano vive no anchor
--    (vw_anchor_sazonalidade). Branch protegida pela regra 'não alterar
--    branches A/B/C' — re-exibição de dados REAIS na grade, não projeção.
-- 3. Branch C (78:311 'FROM mart.sazonalidade_produto f') — linhas
--    FALLBACK_DIMENSAO do ano corrente (são as linhas-alvo, não âncora
--    histórica). Não é âncora de projeção.
-- 4. CTE anchor (78:54-56 'SELECT * FROM mart.vw_anchor_sazonalidade') —
--    alimenta branches A/B com dados reais; alterar mudaria dados reais
--    (proibido pela regra de branches). Nenhuma subconsulta da MV lê
--    sazonalidade_produto como âncora de projeção além do LATERAL hh.
-- 5. Filtro 'a.ano_referencia < EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER'
--    (78:253, Branch B) — representa dados REAIS de anos anteriores
--    re-exibidos na grade do ano corrente, NÃO projeção de fallback.
--
-- QUALITY GATE (FASE 76) preservado integralmente.
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1 — MV V23: DEEP FALLBACK JANELA HISTÓRICA 2023+ (DROP + CREATE)
-- ============================================================================
-- Idêntica à 78 (V22) exceto pelo piso de ano no LATERAL hh do Deep Fallback
-- (ver header, 'LOCAIS ONDE O PISO FOI APLICADO'). Mantém TODAS as 35 colunas
-- da FASE 76 na MESMA ordem + nova coluna final mensagem_transparencia TEXT.
-- LATERAL de histórico e JOIN de baseline só disparam para linhas candidatas
-- (branch C, ano corrente, mes >= corrente, ano_referencia NULL) via condição
-- no ON — custo zero para linhas reais.

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
-- M80 — piso de ano adicionado: janela histórica 2023+ (Ano Atual − 3).
LEFT JOIN LATERAL (
    SELECT h.status_cor AS hist_status_cor,
           h.ano        AS hist_ano
    FROM mart.sazonalidade_produto h
    WHERE h.id_produto = v.id_produto
      AND h.id_localidade = v.id_localidade
      AND h.mes = v.mes
      AND h.ano < EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
      -- M80 — JANELA HISTÓRICA 2023+: piso deslizante (nenhuma âncora < Ano Atual − 3)
      AND h.ano >= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 3
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
    'V23 (deep-fallback-janela-2023) — 3 branches: (A) linhas reais com âncora; '
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
    'fabricado AMARELO e nulls de ano_referencia eliminados nos meses futuros. '
    'M80: JANELA HISTÓRICA 2023+ — piso deslizante no LATERAL hh do Deep '
    'Fallback (h.ano >= Ano Atual − 3; hoje 2023): nenhuma âncora < 2023 nas '
    'projeções (defasagem + inflação).';

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
-- QG-80: janela histórica 2023+ — projecao_janela_2023 conta apenas projeções
-- cujo ano_referencia está DENTRO da janela (>= Ano Atual − 3). Com o piso no
-- LATERAL hh, espera-se projecao_janela_2023 = projeções com histórico.
-- A função fn_br_nacional_sazonalidade já foi atualizada na migration 79 —
-- não é tocada aqui (padrão 78: DDL só, refresh posterior via psql).

DO $$
DECLARE
    v_fallback         int;
    v_projetado        int;
    v_projecao_janela  int;
    v_linhas_mv        int;
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
       AND COALESCE(ano_referencia, 0) >= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 3;
    SELECT count(*) INTO v_linhas_mv FROM mart.vw_api_produtos_sazonalidade;
    RAISE NOTICE 'QG-80: MV=% FALLBACK=% projecao_janela_2023=%',
        v_linhas_mv, v_fallback, v_projecao_janela;
END $$;

COMMIT;
