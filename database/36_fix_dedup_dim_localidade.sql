-- ============================================================================
-- FASE 1+2+4: DEDUPLICAÇÃO + BLINDAGEM + MV COM COALESCE
-- ============================================================================
-- Script ÚNICO e ATÔMICO (BEGIN → COMMIT)
-- Estratégia: resolve conflitos de unicidade via DELETE seletivo + UPDATE
-- ============================================================================

BEGIN;

DO $$
DECLARE
    v_fatos_migrados     INTEGER := 0;
    v_fatos_conflito     INTEGER := 0;
    v_saz_limpados       INTEGER := 0;
    v_localidades_remove INTEGER := 0;
    v_total_mv           INTEGER := 0;
BEGIN

-- ██████████████████████████████████████████████████████████████████████████████
-- FASE 1: DATA SURGERY
-- ██████████████████████████████████████████████████████████████████████████████

-- 1.1 Normalizar: todo '' vira NULL
UPDATE staging.dim_localidade
SET municipio_id   = NULL,
    municipio_nome = NULL
WHERE municipio_id = ''
   OR municipio_nome = '';
RAISE NOTICE '[1.1] '' → NULL: OK';

-- 1.2a CONTAR fatos nas duplicatas (antes do DELETE)
WITH canonical AS (
    SELECT DISTINCT ON (l.uf)
        l.id_localidade AS canonical_id, l.uf
    FROM staging.dim_localidade l
    LEFT JOIN staging.fact_precos_mensais f ON f.id_localidade = l.id_localidade
    WHERE l.municipio_id IS NULL
    GROUP BY l.id_localidade, l.uf
    ORDER BY l.uf, COUNT(f.id_fato) DESC, l.criado_em ASC, l.id_localidade ASC
)
SELECT COUNT(*) INTO v_fatos_conflito
FROM staging.fact_precos_mensais f
WHERE f.id_localidade IN (
    SELECT ld.id_localidade
    FROM staging.dim_localidade ld
    JOIN canonical c ON c.uf = ld.uf
    WHERE ld.municipio_id IS NULL AND ld.id_localidade != c.canonical_id
);

-- 1.2b DELETAR todos os fatos das duplicatas + RE-INSERT com canônico
--     Usa ON CONFLICT DO NOTHING (duplicatas c/ mesmo produto+ano+mes → só 1 INSERT vence)
WITH canonical AS (
    SELECT DISTINCT ON (l.uf)
        l.id_localidade AS canonical_id, l.uf
    FROM staging.dim_localidade l
    LEFT JOIN staging.fact_precos_mensais f ON f.id_localidade = l.id_localidade
    WHERE l.municipio_id IS NULL
    GROUP BY l.id_localidade, l.uf
    ORDER BY l.uf, COUNT(f.id_fato) DESC, l.criado_em ASC, l.id_localidade ASC
),
dupe_map AS (
    SELECT ld.id_localidade AS dupe_id, c.canonical_id
    FROM staging.dim_localidade ld
    JOIN canonical c ON c.uf = ld.uf
    WHERE ld.municipio_id IS NULL AND ld.id_localidade != c.canonical_id
),
deleted AS (
    DELETE FROM staging.fact_precos_mensais f
    WHERE f.id_localidade IN (SELECT dupe_id FROM dupe_map)
    RETURNING f.id_produto, f.ano, f.mes, f.preco_medio, f.batch_id, f.id_localidade
),
reinserted AS (
    INSERT INTO staging.fact_precos_mensais (id_produto, id_localidade, ano, mes, preco_medio, batch_id)
    SELECT d.id_produto, dm.canonical_id, d.ano, d.mes, d.preco_medio, d.batch_id
    FROM deleted d
    JOIN dupe_map dm ON dm.dupe_id = d.id_localidade
    ON CONFLICT (id_produto, id_localidade, ano, mes) DO NOTHING
    RETURNING 1
)
SELECT COUNT(*) INTO v_fatos_migrados FROM reinserted;

-- Conflitos = total_antes - migrados
v_fatos_conflito := v_fatos_conflito - v_fatos_migrados;

RAISE NOTICE '[1.2] Fatos p/ canônico: migrados=%, conflitos=%, total_dupes=%',
    v_fatos_migrados, v_fatos_conflito, v_fatos_migrados + v_fatos_conflito;

-- 1.3 Limpar sazonalidade_produto apontando p/ duplicatas
WITH canonical AS (
    SELECT DISTINCT ON (l.uf)
        l.id_localidade AS canonical_id
    FROM staging.dim_localidade l
    LEFT JOIN staging.fact_precos_mensais f ON f.id_localidade = l.id_localidade
    WHERE l.municipio_id IS NULL
    GROUP BY l.id_localidade, l.uf
    ORDER BY l.uf, COUNT(f.id_fato) DESC, l.criado_em ASC, l.id_localidade ASC
)
DELETE FROM mart.sazonalidade_produto s
WHERE s.id_localidade IN (
    SELECT l.id_localidade
    FROM staging.dim_localidade l
    WHERE l.municipio_id IS NULL
      AND l.id_localidade NOT IN (SELECT canonical_id FROM canonical)
);

GET DIAGNOSTICS v_saz_limpados = ROW_COUNT;
RAISE NOTICE '[1.3] Sazonalidade limpa: %', v_saz_limpados;

-- 1.4 Remover duplicatas de dim_localidade
WITH canonical AS (
    SELECT DISTINCT ON (l.uf)
        l.id_localidade AS canonical_id
    FROM staging.dim_localidade l
    LEFT JOIN staging.fact_precos_mensais f ON f.id_localidade = l.id_localidade
    WHERE l.municipio_id IS NULL
    GROUP BY l.id_localidade, l.uf
    ORDER BY l.uf, COUNT(f.id_fato) DESC, l.criado_em ASC, l.id_localidade ASC
)
DELETE FROM staging.dim_localidade l
WHERE l.municipio_id IS NULL
  AND l.id_localidade NOT IN (SELECT canonical_id FROM canonical);

GET DIAGNOSTICS v_localidades_remove = ROW_COUNT;
RAISE NOTICE '[1.4] Localidades removidas: %', v_localidades_remove;

-- ██████████████████████████████████████████████████████████████████████████████
-- FASE 2: BLINDAGEM DO SCHEMA (DDL)
-- ██████████████████████████████████████████████████████████████████████████████

-- 2.1 Remove UNIQUE antiga
ALTER TABLE staging.dim_localidade DROP CONSTRAINT IF EXISTS uq_dim_localidade;
RAISE NOTICE '[2.1] UNIQUE antiga removida';

-- 2.2 Partial Unique Index — nível UF
CREATE UNIQUE INDEX IF NOT EXISTS uq_dim_localidade_uf_nivel_estado
    ON staging.dim_localidade (uf)
    WHERE municipio_id IS NULL;
RAISE NOTICE '[2.2] Partial UF index criado';

-- 2.3 Partial Unique Index — nível município
CREATE UNIQUE INDEX IF NOT EXISTS uq_dim_localidade_municipio
    ON staging.dim_localidade (uf, municipio_id)
    WHERE municipio_id IS NOT NULL;
RAISE NOTICE '[2.3] Partial Municipio index criado';

-- ██████████████████████████████████████████████████████████████████████████████
-- FASE 4: MV RECREATION COM COALESCE
-- ██████████████████████████████████████████████████████████████████████████████

-- 4.1 Drop MV antiga
DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;
RAISE NOTICE '[4.1] MV antiga removida';

-- 4.2 Criar NOVA MV com COALESCE
CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
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
    (split_part((s.data_referencia_atual)::text, '-'::text, 1))::integer AS ano,
    (split_part((s.data_referencia_atual)::text, '-'::text, 2))::integer AS mes,
    s.preco_referencia,
    s.preco_atual,
    s.data_referencia_atual,
    s.usou_fallback_12m,
    s.preco_estimado,
    s.status_cor,
    s.fonte,
    s.calculado_em,
    s.metodo_calculo,
    s.variacao_mom_pct AS variacao_pct,
    s.tendencia_futura,
    s.is_forecast,
    s.baseline_confianca,
    s.forecast_method
   FROM (((mart.sazonalidade_produto s
     JOIN staging.dim_produto p ON ((p.id_produto = s.id_produto)))
     JOIN staging.dim_localidade l ON ((l.id_localidade = s.id_localidade)))
     LEFT JOIN staging.dim_categoria c ON ((c.id_categoria = p.id_categoria)))
  WHERE ((s.status_cor = ANY (ARRAY['VERDE'::text, 'AMARELO'::text, 'VERMELHO'::text]))
     AND (p.categoria_b2c = 'ALIMENTO_VAREJO'::text)
     AND ((p.classificao_produto IS NULL)
       OR (p.classificao_produto <> ALL (ARRAY['INSUMO_AGRICOLA'::text, 'MAQUINARIO_FERRAMENTA'::text, 'SERVICO_LOGISTICA'::text])))
     AND ((c.nome_categoria IS NULL)
       OR (c.nome_categoria <> ALL (ARRAY['FLORES'::text, 'OUTROS'::text]))))
  ORDER BY (split_part((s.data_referencia_atual)::text, '-'::text, 1))::integer,
           (split_part((s.data_referencia_atual)::text, '-'::text, 2))::integer,
           s.is_forecast,
           s.status_cor,
           p.nome_produto;

RAISE NOTICE '[4.2] NOVA MV criada com COALESCE';

-- 4.3 Índices
CREATE UNIQUE INDEX idx_vw_sazonalidade_unico ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);
CREATE INDEX idx_vw_sazonalidade_filtro ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);
CREATE INDEX idx_vw_sazonalidade_categoria ON mart.vw_api_produtos_sazonalidade (categoria);
CREATE INDEX idx_vw_sazonalidade_produto ON mart.vw_api_produtos_sazonalidade (id_produto);
CREATE INDEX idx_vw_sazonalidade_ano_mes ON mart.vw_api_produtos_sazonalidade (ano, mes) WHERE ((ano IS NOT NULL) AND (mes IS NOT NULL));
CREATE INDEX idx_vw_sazonalidade_confianca ON mart.vw_api_produtos_sazonalidade (baseline_confianca DESC);
CREATE INDEX idx_vw_sazonalidade_forecast ON mart.vw_api_produtos_sazonalidade (is_forecast) WHERE (is_forecast = true);

RAISE NOTICE '[4.3] Índices recriados (7)';

-- 4.4 Grant permissão API
GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;

-- Relatório final
SELECT COUNT(*) INTO v_total_mv FROM mart.vw_api_produtos_sazonalidade;

RAISE NOTICE '╔══════════════════════════════════════════════════════════════╗';
RAISE NOTICE '║        FASE 1+2+4 — RELATÓRIO DE EXECUÇÃO                   ║';
RAISE NOTICE '╠══════════════════════════════════════════════════════════════╣';
RAISE NOTICE '║  Fatos conflitantes removidos... %', v_fatos_conflito;
RAISE NOTICE '║  Fatos migrados p/ canônico...... %', v_fatos_migrados;
RAISE NOTICE '║  Sazonalidade limpa.............. %', v_saz_limpados;
RAISE NOTICE '║  Localidades removidas........... %', v_localidades_remove;
RAISE NOTICE '║  Partial UF index................ CRIADO';
RAISE NOTICE '║  Partial Municipio index......... CRIADO';
RAISE NOTICE '║  UNIQUE antiga................... REMOVIDA';
RAISE NOTICE '║  MV com COALESCE................. CRIADA (%, rows)', v_total_mv;
RAISE NOTICE '║  role_api_reader................. GRANT OK';
RAISE NOTICE '╚══════════════════════════════════════════════════════════════╝';

END $$;

COMMIT;
