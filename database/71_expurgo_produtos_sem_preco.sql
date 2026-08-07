-- ============================================================================
-- 71_expurgo_produtos_sem_preco.sql
-- ============================================================================
-- EXPURGO DE PRODUTOS FANTASMAS + SUPREÇÃO NA VIEW MATERIALIZADA (FASE 2)
--
-- Contexto:
--   O scraper/ETL ingeriu linhas sem preço válido, poluindo staging.dim_produto
--   com "produtos fantasmas" (sem NENHUM registro em fact_precos_mensais).
--   Resultado: mart.sazonalidade_produto gerava milhares de linhas órfãs e a
--   MV mart.vw_api_produtos_sazonalidade emitia grades 100% CINZA no frontend.
--
-- Baseline medido (pré-migração):
--   staging.dim_produto            = 2.869  (627 sem nenhum fact)
--   staging.fact_precos_mensais    = 266.773
--   mart.sazonalidade_produto      = 364.383 (10.518 órfãs de fantasmas)
--   mart.vw_api_produtos_sazonalidade = 260.487 (~10.176 linhas de fantasmas)
--
-- Esta migration (100% transacional):
--   1) Backup dos expurgados (rollback manual sem perda de dados)
--   2) DELETE dos órfãos da sazonalidade (sem FK p/ dim_produto)
--   3) DELETE dos fantasmas da dim_produto (NOT EXISTS na fact)
--   4) Recria a MV suprimindo produtos SEM NENHUMA âncora real
--      (REAL_ATUAL / HISTORICO_BASE) — o frontend nunca mais renderiza
--      um produto que é 12 meses CINZA.
-- ============================================================================

BEGIN;

-- ── 1) BACKUP — tabelas de auditoria em ops ────────────────────────────────
DROP TABLE IF EXISTS ops.dim_produto_expurgado_backup;
CREATE TABLE ops.dim_produto_expurgado_backup AS
SELECT dp.*, NOW() AS expurgado_em
FROM staging.dim_produto dp
WHERE NOT EXISTS (
    SELECT 1 FROM staging.fact_precos_mensais f WHERE f.id_produto = dp.id_produto
);

DROP TABLE IF EXISTS ops.sazonalidade_orfao_backup;
CREATE TABLE ops.sazonalidade_orfao_backup AS
SELECT s.*, NOW() AS expurgado_em
FROM mart.sazonalidade_produto s
WHERE NOT EXISTS (
    SELECT 1 FROM staging.fact_precos_mensais f WHERE f.id_produto = s.id_produto
);

-- Backup do mapeamento MDM (mart.dim_produto_canonico) dos fantasmas:
-- cada fantasma tem 1 linha canônica e (na prática) aponta para si mesmo ou
-- outro fantasma como id_produto_mestre — sem perda de mapeamento real.
DROP TABLE IF EXISTS ops.dim_produto_canonico_expurgado_backup;
CREATE TABLE ops.dim_produto_canonico_expurgado_backup AS
SELECT c.*, NOW() AS expurgado_em
FROM mart.dim_produto_canonico c
WHERE NOT EXISTS (
    SELECT 1 FROM staging.fact_precos_mensais f WHERE f.id_produto = c.id_produto_original
);

-- ── 2) DELETE dos órfãos (defensivo, antes de tocar a dim) ─────────────────
-- status_fonte_produto e dim_fluxo_abastecimento podem apontar p/ fantasmas;
-- limpa ANTES do DELETE da dim para não violar FK (NO ACTION / RESTRICT).
DELETE FROM staging.status_fonte_produto sf
WHERE NOT EXISTS (
    SELECT 1 FROM staging.fact_precos_mensais f WHERE f.id_produto = sf.id_produto
);

DELETE FROM staging.dim_fluxo_abastecimento dfa
WHERE NOT EXISTS (
    SELECT 1 FROM staging.fact_precos_mensais f WHERE f.id_produto = dfa.id_produto
);

-- Órfãos de sazonalidade: mart.sazonalidade_produto NÃO tem FK p/ dim_produto,
-- então precisa de DELETE explícito das linhas cujo produto não tem preço real.
DELETE FROM mart.sazonalidade_produto s
WHERE NOT EXISTS (
    SELECT 1 FROM staging.fact_precos_mensais f WHERE f.id_produto = s.id_produto
);

-- Mapeamento MDM dos fantasmas: mart.dim_produto_canonico tem FK
-- (id_produto_original -> staging.dim_produto) e bloqueia o DELETE da dim.
-- Produto sem preço real não precisa de mapeamento canônico — remove junto.
DELETE FROM mart.dim_produto_canonico c
WHERE NOT EXISTS (
    SELECT 1 FROM staging.fact_precos_mensais f WHERE f.id_produto = c.id_produto_original
);

-- ── 3) DELETE dos fantasmas da dimensão ────────────────────────────────────
-- Produto sem NENHUM registro de preço na fato = fantasma. Sai da dim.
DELETE FROM staging.dim_produto dp
WHERE NOT EXISTS (
    SELECT 1 FROM staging.fact_precos_mensais f WHERE f.id_produto = dp.id_produto
);

-- ── 4) Recria a MV com supressão de fantasmas ──────────────────────────────
DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
-- CTE MATERIALIZED: a view âncora (LATERAL/DISTINCT) é avaliada UMA vez;
-- sem isso, o NOT EXISTS do branch C reavaliaria a view por linha (lentidão O(N²)).
WITH anchor AS MATERIALIZED (
    SELECT * FROM mart.vw_anchor_sazonalidade
),
-- FASE 71 — SUPREÇÃO DE FANTASMAS: produtos que NÃO possuem sequer UMA linha
-- com dado real (a âncora só contém REAL_ATUAL/HISTORICO_BASE — fonte <> proxy,
-- não-forecast, preco_atual > 0) são completamente removidos da MV. Nenhuma
-- grade de 12 meses CINZA chega ao frontend.
produtos_com_ancora AS MATERIALIZED (
    SELECT DISTINCT id_produto FROM anchor
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
-- FASE 71 — SUPREÇÃO: hash join com produtos que têm PELO MENOS uma âncora real.
JOIN produtos_com_ancora pa ON pa.id_produto = v.id_produto
ORDER BY v.ano, v.mes, v.is_forecast, v.status_cor, v.produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'V20 (expurgo-produtos-sem-preco) — 3 branches: (A) linhas reais com '
    'âncora; (B) exibição ancorada em ano atual (id=-id, só quando '
    'ano_referencia<N); (C) FALLBACK_DIMENSAO (id=-(id)-1e9). FASE 68: âncora '
    'sem fallback AMARELO — base insuficiente/banda inválida → status_cor NULL '
    '(linha excluída → CINZA no backend); branch C sem COALESCE morto. '
    'FASE 71: supressão de produtos fantasmas — só produtos com PELO MENOS '
    'UMA âncora real (REAL_ATUAL/HISTORICO_BASE) entram na MV; produtos 12 '
    'meses CINZA (sem nenhum dado real) são completamente removidos. '
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

-- ── 5) PROVA EMBUTIDA — contagens pós-expurgo (saída do psql) ──────────────
DO $$
DECLARE
    v_dim_atual       int;
    v_dim_expurgados  int;
    v_saz_atual       int;
    v_saz_expurgados  int;
    v_fact            int;
    v_mv              int;
    v_mv_fantasmas    int;
    v_canon_expurg    int;
BEGIN
    SELECT count(*) INTO v_dim_atual      FROM staging.dim_produto;
    SELECT count(*) INTO v_dim_expurgados FROM ops.dim_produto_expurgado_backup;
    SELECT count(*) INTO v_saz_atual      FROM mart.sazonalidade_produto;
    SELECT count(*) INTO v_saz_expurgados FROM ops.sazonalidade_orfao_backup;
    SELECT count(*) INTO v_fact           FROM staging.fact_precos_mensais;
    SELECT count(*) INTO v_mv             FROM mart.vw_api_produtos_sazonalidade;
    SELECT count(*) INTO v_mv_fantasmas   FROM mart.vw_api_produtos_sazonalidade
                                           WHERE tipo_dado = 'FALLBACK_DIMENSAO';
    SELECT count(*) INTO v_canon_expurg   FROM ops.dim_produto_canonico_expurgado_backup;
    RAISE NOTICE 'EXPURGO-71: dim_produto=% (expurgados=% ) | sazonalidade=% (expurgados=%) | canonico_expurg=% | fact=% | MV=% (linhas FALLBACK=%)',
        v_dim_atual, v_dim_expurgados, v_saz_atual, v_saz_expurgados, v_canon_expurg, v_fact, v_mv, v_mv_fantasmas;
END $$;

COMMIT;
