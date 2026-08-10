-- ============================================================================
-- 76_quality_gate_completude_serie.sql
-- ============================================================================
-- QUALITY GATE DE COMPLETUDE DE SÉRIE — SUPREÇÃO NA VIEW MATERIALIZADA
-- (VITRINE PERFEITA: apenas produtos com série mensal COMPLETA)
--
-- Contexto:
--   A diretriz de produto exige que o painel seja uma "vitrine perfeita":
--   produtos com buracos no histórico mensal poluem a grade sazonal e
--   quebram a confiança do usuário. A migration 74 (quality gate 12 meses)
--   expurgou fisicamente com COUNT(DISTINCT mes) = 12 na janela 2024-2026 —
--   critério FRACO: qualquer produto com meses espalhados entre anos passa
--   (863 produtos sobrevivem, mas 0 têm 36/36 meses; por ano há buracos).
--
-- Baseline medido (pré-migração — auditoria 2026-08-10):
--   staging.dim_produto               = 863 (todos com dados na janela)
--   Produtos com 12/12 meses em 2024  = 684
--   Produtos com 12/12 meses em 2025  = 677
--   Produtos completos em >= 1 ano    = 720  (2024 OU 2025)
--   Produtos com gaps em todos os anos= 143  (drop/hide)
--   MV mart.vw_api_produtos_sazonalidade = 210.367 linhas / 468 produtos
--     - completos 12/12 em 2024 OU 2025 (série real, sem interpolado): 358
--     - produtos que nunca tiveram um ano completo:          107  (a remover)
--     - produtos com fallback em meses passados de 2026:     287  (coleta parada)
--
-- Regra de fallback (contexto — database/summary.md):
--   As janelas de referência são 2024 e 2025 (regra 6: janela temporal
--   2024-01 a 2026-12). As baselines de sazonalidade são construídas sobre
--   esses anos: mart.sazonalidade_baseline_25_26 = primária (moda 2025-2026),
--   mart.sazonalidade_baseline_24_25 = fallback (moda 2024-2025, confiança
--   reduzida à metade). Dado interpolado/LOCF/proxy é FALLBACK CONDICIONAL
--   (summary.md regra 8: dado real nunca é sobrescrito por projeção).
--   Por isso o CTE de completude conta APENAS dado real
--   (is_interpolado = FALSE): meses preenchidos por LOCF/interpolação não
--   contam como série completa (impacto pequeno: 361 -> 358 na MV).
--
-- Esta migration (100% transacional):
--   1) Backup dos produtos que sairão da MV (ops.serie_incompleta_backup)
--   2) Recria a MV adicionando o CTE produtos_completos: o produto SÓ entra
--      na visão se possui série mensal COMPLETA (12/12 meses REAIS) em 2024
--      OU 2025 (staging.fact_precos_mensais, is_interpolado = FALSE).
--      JOIN final filtra sumariamente os produtos do grupo Z (gaps em todos
--      os anos) — nenhuma linha incompleta chega à FastAPI/frontend.
--
-- Critério (decisão de produto, 2026-08-10): "Série completa em >= 1 ano".
--   Completude = COUNT(DISTINCT mes) = 12 em 2024 OU em 2025, contando
--   apenas linhas com dado real (NOT COALESCE(is_interpolado, FALSE)).
--   Produtos que só existem em 2026 (ano corrente, ainda incompleto) sem
--   série de referência completa são excluídos — não são âncora confiável.
-- ============================================================================

BEGIN;

-- ── 1) BACKUP — auditoria em ops (NÃO há DELETE físico; só supressão na MV) ─
-- Guarda o grupo Z (produtos SEM série completa em 2024/2025) para auditoria
-- e rollback manual da visão. Nada é apagado de staging/mart.
DROP TABLE IF EXISTS ops.serie_incompleta_backup;
CREATE TABLE ops.serie_incompleta_backup AS
SELECT dp.id_produto,
       dp.nome_produto,
       dp.categoria_b2c,
       COALESCE(c2024.meses, 0) AS meses_2024,
       COALESCE(c2025.meses, 0) AS meses_2025,
       NOW() AS auditado_em
FROM staging.dim_produto dp
LEFT JOIN (
    SELECT id_produto, COUNT(DISTINCT mes) AS meses
    FROM staging.fact_precos_mensais
    WHERE ano = 2024 AND NOT COALESCE(is_interpolado, FALSE)
    GROUP BY id_produto
) c2024 ON c2024.id_produto = dp.id_produto
LEFT JOIN (
    SELECT id_produto, COUNT(DISTINCT mes) AS meses
    FROM staging.fact_precos_mensais
    WHERE ano = 2025 AND NOT COALESCE(is_interpolado, FALSE)
    GROUP BY id_produto
) c2025 ON c2025.id_produto = dp.id_produto
WHERE COALESCE(c2024.meses, 0) < 12
  AND COALESCE(c2025.meses, 0) < 12;

CREATE INDEX IF NOT EXISTS idx_serie_incompleta_backup_produto
    ON ops.serie_incompleta_backup (id_produto);

-- ── 2) Recria a MV com supressão de séries incompletas ──────────────────────
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
-- FASE 76 — QUALITY GATE DE COMPLETUDE: hash join com produtos que possuem
-- série mensal COMPLETA (12/12 meses reais) em 2024 OU 2025.
JOIN produtos_completos pc ON pc.id_produto = v.id_produto
ORDER BY v.ano, v.mes, v.is_forecast, v.status_cor, v.produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'V21 (quality-gate-completude-serie) — 3 branches: (A) linhas reais com '
    'âncora; (B) exibição ancorada em ano atual (id=-id, só quando '
    'ano_referencia<N); (C) FALLBACK_DIMENSAO (id=-(id)-1e9). FASE 68: âncora '
    'sem fallback AMARELO — base insuficiente/banda inválida → status_cor NULL '
    '(linha excluída → CINZA no backend); branch C sem COALESCE morto. '
    'FASE 71: supressão de produtos fantasmas — só produtos com PELO MENOS '
    'UMA âncora real (REAL_ATUAL/HISTORICO_BASE) entram na MV; produtos 12 '
    'meses CINZA (sem nenhum dado real) são completamente removidos. '
    'FASE 76: QUALITY GATE DE COMPLETUDE (vitrine perfeita) — só entram '
    'produtos com série mensal COMPLETA (COUNT(DISTINCT mes)=12, dado REAL '
    'is_interpolado=FALSE) em 2024 OU 2025 (staging.fact_precos_mensais); '
    'produtos com gaps em todos os anos (grupo Z) são suprimidos da visão — '
    'nada de grade incompleta chega à FastAPI/frontend. '
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

-- ── 5) PROVA EMBUTIDA — contagens pós-supressão (saída do psql) ─────────────
DO $$
DECLARE
    v_serie_incompleta int;
    v_mv              int;
    v_mv_produtos     int;
    v_mv_fallback     int;
BEGIN
    SELECT count(*) INTO v_serie_incompleta FROM ops.serie_incompleta_backup;
    SELECT count(*) INTO v_mv             FROM mart.vw_api_produtos_sazonalidade;
    SELECT count(DISTINCT id_produto) INTO v_mv_produtos
        FROM mart.vw_api_produtos_sazonalidade;
    SELECT count(*) INTO v_mv_fallback    FROM mart.vw_api_produtos_sazonalidade
                                           WHERE tipo_dado = 'FALLBACK_DIMENSAO';
    RAISE NOTICE 'QG-76: serie_incompleta_backup=% (grupo Z suprimido) | MV=% linhas | MV produtos=% | MV linhas FALLBACK=%',
        v_serie_incompleta, v_mv, v_mv_produtos, v_mv_fallback;
END $$;

COMMIT;
