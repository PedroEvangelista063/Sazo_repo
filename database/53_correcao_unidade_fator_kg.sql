-- ============================================================================
-- MIGRATION 53: NORMALIZAÇÃO DE UNIDADE DE MEDIDA (R$/kg VIA fator_kg)
-- ============================================================================
-- Causa raiz confirmada (auditoria de conciliação Fases 2-3:
--   docs/RELATORIO_AUDITORIA_RECONCILIACAO.md e utilities/audit_raw_vs_db.py):
--
--   1. O Sanduíche Sazonal (40) e a Engine Preditiva (30) projetam preco_atual
--      a partir de bases históricas com UNIDADE MISTURADA (CONAB "preço pago ao
--      produtor" R$/kg vs. CEASA por caixa/saca/dúzia), inflando os preços de
--      1,5x a 23,8x. Ex.: Ovo Branco TO 2026/06 → preco_atual 141,11 vs fact 5,93.
--
--   2. A coluna legada mart.preco_medio == staging.fact_precos_mensais.preco_medio
--      (44.467 linhas reais verificadas com razão 1,000 e 0 divergentes) → ela é
--      a VERDADE per-kg do registro.
--
-- CORREÇÃO (idempotente):
--   PATH A — linhas COM preco_medio (verdade per-kg): preco_atual e
--            preco_referencia passam a ser preco_medio. Cobre os 343 outliers
--            (razão > 5x) e TODAS as linhas com razão fora de [0,5; 1,5]
--            (4.929 registros — mesmo vício de unidade, em menor escala).
--   PATH B — linhas forecast SEM preco_medio: divide preco_atual/preco_referencia
--            pelo fator_kg empírico = mediana de preco_atual/preco_medio por
--            (produto, UF) com n>=5 (281 pares / 68 produtos). O valor corrigido
--            é devolvido para a coluna legada preco_medio → na re-execução a
--            linha sai do filtro (preco_medio IS NULL), garantindo idempotência
--            e atacando o problema de 34.945 linhas do mart sem preço.
--
--   LIMITAÇÕES DOCUMENTADAS:
--     • PATH B assume que preco_referencia foi inflado pelo MESMO fator do
--       preco_atual (ambos vêm da mesma base no Sanduíche; auditoria: 282/343).
--     • PATH B só corrige inflação; linhas forecast deflacionadas (< 0,5x) sem
--       preco_medio ficam de fora (PATH A cobre as que têm preco_medio).
--     • Linhas forecast com preco_medio e razão 1,5-2x viram AMARELO (atual ==
--       referência): a base per-kg é a verdade disponível, o sinal sazonal não
--       é reconstruível (Fase 2: base CONAB produtor vs. CEASA misturadas).
--
--   Persiste os fatores em mart.fator_kg_produto_uf (auditabilidade + reuso).
--   status_cor recalculado pela regra ±15% (fn_status_cor_regra_15) e o log é
--   automático em ops.audit_logs via trigger trg_audit_status_cor (migration 06).
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: Tabela persistente de fatores empíricos (fator_kg por produto+UF)
-- ============================================================================
CREATE TABLE IF NOT EXISTS mart.fator_kg_produto_uf (
    id_produto           INTEGER      NOT NULL,
    uf                   CHAR(2)      NOT NULL,
    fator_kg             NUMERIC(10,4) NOT NULL,
    n_amostras           INTEGER      NOT NULL,
    mediana_preco_medio  NUMERIC(14,4) NOT NULL,
    criado_em            TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (id_produto, uf)
);

COMMENT ON TABLE mart.fator_kg_produto_uf IS
    'Fatores empíricos de conversão para R$/kg derivados na Migration 53 '
    '(mediana de preco_atual/preco_medio por produto+UF, n>=5). '
    'Usado para normalizar a unidade dos preços projetados pelo Sanduíche Sazonal '
    'e para reuso em execuções futuras da projeção.';

GRANT SELECT ON mart.fator_kg_produto_uf TO role_etl_writer;

-- ============================================================================
-- SEÇÃO 2: Derivação do fator_kg (somente pares com unidade divergente e n>=5)
-- ============================================================================
INSERT INTO mart.fator_kg_produto_uf
    (id_produto, uf, fator_kg, n_amostras, mediana_preco_medio)
SELECT
    s.id_produto,
    l.uf,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s.preco_atual / s.preco_medio)::NUMERIC, 4) AS fator_kg,
    COUNT(*)                                                                                        AS n_amostras,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s.preco_medio)::NUMERIC, 4)                  AS mediana_preco_medio
FROM mart.sazonalidade_produto s
JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
WHERE s.preco_medio > 0
  AND s.preco_atual > 0
  AND s.preco_atual / s.preco_medio > 1.5
GROUP BY 1, 2
HAVING COUNT(*) >= 5
   AND PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s.preco_atual / s.preco_medio)::NUMERIC > 1.5
ON CONFLICT (id_produto, uf) DO UPDATE
SET fator_kg            = EXCLUDED.fator_kg,
    n_amostras          = EXCLUDED.n_amostras,
    mediana_preco_medio = EXCLUDED.mediana_preco_medio,
    criado_em           = NOW();

-- ============================================================================
-- SEÇÃO 3: PATH A — linhas COM preco_medio (verdade per-kg == fact)
--          Idempotente: após a correção a razão volta para ~1,0 e a linha
--          deixa de satisfazer o filtro.
-- ============================================================================
WITH correcao AS (
    SELECT
        id_sazonalidade,
        ROUND(preco_medio, 4) AS novo_preco
    FROM mart.sazonalidade_produto
    WHERE preco_medio > 0
      AND preco_atual  > 0
      AND (preco_atual / preco_medio > 1.5 OR preco_atual / preco_medio < 0.5)
)
UPDATE mart.sazonalidade_produto s
SET preco_atual      = c.novo_preco,
    preco_referencia = c.novo_preco,
    status_cor       = COALESCE(
        staging.fn_status_cor_regra_15(c.novo_preco, c.novo_preco),
        'AMARELO'
    ),
    calculado_em     = NOW()
FROM correcao c
WHERE s.id_sazonalidade = c.id_sazonalidade;

-- ============================================================================
-- SEÇÃO 4: PATH B — linhas forecast SEM preco_medio → divide pelo fator_kg--   Idempotência: o valor corrigido é devolvido a preco_medio; na
--   re-execução a linha deixa de casar com (preco_medio IS NULL) e não
--   é dividida de novo. A guarda de preço (preco_atual > 1,5x a mediana
--   per-kg do par) protege linhas já próximas do valor correto — mesmo em
--   pares com fator < 2 (onde a razão pós-correção ainda seria > 0,5x).
-- ============================================================================
WITH correcao AS (
    SELECT
        s.id_sazonalidade,
        ROUND(s.preco_atual / f.fator_kg, 4) AS novo_atual,
        CASE
            WHEN s.preco_referencia IS NOT NULL AND s.preco_referencia > 0
            THEN ROUND(s.preco_referencia / f.fator_kg, 4)
            ELSE NULL
        END AS novo_ref
    FROM mart.sazonalidade_produto s
    JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
    JOIN mart.fator_kg_produto_uf f
         ON f.id_produto = s.id_produto AND f.uf = l.uf
    WHERE s.is_forecast = TRUE
      AND (s.preco_medio IS NULL OR s.preco_medio <= 0)
      AND s.preco_atual > 0
      AND s.preco_atual > f.mediana_preco_medio * 1.5
)
UPDATE mart.sazonalidade_produto s
SET preco_atual      = c.novo_atual,
    preco_referencia = c.novo_ref,
    preco_medio      = c.novo_atual,
    status_cor       = COALESCE(
        staging.fn_status_cor_regra_15(c.novo_atual, c.novo_ref),
        'AMARELO'
    ),
    calculado_em     = NOW()
FROM correcao c
WHERE s.id_sazonalidade = c.id_sazonalidade;

-- ============================================================================
-- SEÇÃO 5: Resumo observável (convenção de migrations 40/52)
-- ============================================================================
DO $$
DECLARE
    v_fatores  INTEGER;
    v_path_a   INTEGER;
    v_path_b   INTEGER;
BEGIN
    SELECT count(*) INTO v_fatores FROM mart.fator_kg_produto_uf;
    SELECT count(*) INTO v_path_a
    FROM mart.sazonalidade_produto
    WHERE preco_medio > 0 AND preco_atual > 0
      AND (preco_atual / preco_medio > 1.5 OR preco_atual / preco_medio < 0.5);
    SELECT count(*) INTO v_path_b
    FROM mart.sazonalidade_produto s
    JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
    JOIN mart.fator_kg_produto_uf f
         ON f.id_produto = s.id_produto AND f.uf = l.uf
    WHERE s.is_forecast = TRUE
      AND (s.preco_medio IS NULL OR s.preco_medio <= 0)
      AND s.preco_atual > 0
      AND s.preco_atual > f.mediana_preco_medio * 1.5;
    RAISE NOTICE '[migration_53] fator_kg pares=% | PATH A (com medio) pendentes=% | PATH B (forecast) pendentes=%',
        v_fatores, v_path_a, v_path_b;
END
$$;

COMMIT;

-- ============================================================================
-- Refresh da MV (fora da transação — REFRESH ... CONCURRENTLY)
-- ============================================================================
REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- ============================================================================
-- Verificação pós-aplicação (executar manualmente):
--
-- 1) Sobra de outliers > 5x com preco_medio (deve ser ~0):
--    SELECT count(*) FROM mart.sazonalidade_produto s
--    WHERE s.preco_medio > 0 AND s.preco_atual > 0
--      AND (s.preco_atual / s.preco_medio > 5 OR s.preco_atual / s.preco_medio < 0.2);
--
-- 2) Fatores derivados:
--    SELECT * FROM mart.fator_kg_produto_uf ORDER BY n_amostras DESC LIMIT 20;
-- ============================================================================
