-- ============================================================================
-- Migration 013: Schema Reconciliation — Phase 4 Drift
-- ============================================================================
--
-- OBJETIVO:
--   Capturar todo o delta entre as migrations 001-012 e o schema real do
--   banco remoto, que evoluiu via scripts database/*.sql aplicados diretamente.
--
-- ESTRATÉGIA:
--   Forward-only, idempotente (IF NOT EXISTS / CREATE OR REPLACE / ADD COLUMN IF NOT EXISTS).
--   Seguro para re-aplicação. O banco remoto NÃO sofre rollback.
--
-- SCRIPTS FONTE (database/*.sql):
--   03_ajustes_fase4, 04_reestruturacao_b2c, 05_recalibracao_baseline_2025,
--   07_refatoracao_categorias, 11_status_imagem_produto, 12_status_fonte_produto,
--   15_schema_agro_regional, 16_baseline_2025_interpolado, 17_mom_seasonality,
--   18_sazonalidade_preditiva_v2, 20_hotfix_filtro_varejo, 22_data_healing_schema,
--   22b_data_healing_hotfix, 24_predictive_schema, 25_fix_mv_missing_columns,
--   26_forecast_baseline, 28_recalibracao_baseline_24_25, 29_focus_2025_2026,
--   30_engine_preditiva_forecast_2026, 31_remove_year_filter_mv,
--   32_fn_regional_snapshot, 33_paginacao_br_regional, 34_mart_vw_categorias_municipios,
--   35_drop_fn_regional_snapshot_overload
--
-- ESCOPO POR FASE:
--   FASE 1 (esta migration): DDL + DML + objetos — schema completo
--   FASE 2 (000014): Correção do trigger trg_valida_anomalia_preco (UF-based)
--   FASE 3 (000015): Security layer — RLS em todas as tabelas
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 0: Segurança — não falhar se objetos não existirem
-- ============================================================================

SET lock_timeout = '30s';

-- ============================================================================
-- SEÇÃO 1: DDL — Colunas extras em dim_produto (db/03, db/04, db/07)
-- ============================================================================

-- Classificação semântica do produto
ALTER TABLE staging.dim_produto
    ADD COLUMN IF NOT EXISTS conab_id_produto    INTEGER,
    ADD COLUMN IF NOT EXISTS classificao_produto  TEXT,
    ADD COLUMN IF NOT EXISTS categoria_b2c        TEXT,
    ADD COLUMN IF NOT EXISTS status_fonte         TEXT,
    ADD COLUMN IF NOT EXISTS id_categoria         SMALLINT
        REFERENCES staging.dim_categoria (id_categoria)
        ON DELETE RESTRICT;

COMMENT ON COLUMN staging.dim_produto.conab_id_produto IS
    'ID interno do produto no sistema CONAB (arquivos LISTA*.txt)';
COMMENT ON COLUMN staging.dim_produto.classificao_produto IS
    'Classificação do produto. Ex: "150 16X16 JOHN DEERE", "NÃO INFORMADO"';
COMMENT ON COLUMN staging.dim_produto.categoria_b2c IS
    'Categoria semântica: ALIMENTO_VAREJO | MAQUINARIO_FERRAMENTA | INSUMO_AGRICOLA | SERVICO_LOGISTICA | MATERIA_PRIMA_B2B';
COMMENT ON COLUMN staging.dim_produto.status_fonte IS
    'Status da fonte do produto: ATIVO, INATIVO, SUSPENSO';
COMMENT ON COLUMN staging.dim_produto.id_categoria IS
    'FK para staging.dim_categoria — categoria de varejo do produto (ON DELETE RESTRICT)';

-- Índices
CREATE INDEX IF NOT EXISTS idx_dim_produto_categoria
    ON staging.dim_produto (categoria_b2c);
CREATE INDEX IF NOT EXISTS idx_dim_produto_id_categoria
    ON staging.dim_produto (id_categoria);

-- ============================================================================
-- SEÇÃO 2: DDL — Colunas extras em fact_precos_mensais (db/22)
-- ============================================================================

ALTER TABLE staging.fact_precos_mensais
    ADD COLUMN IF NOT EXISTS preco_curado    NUMERIC(14,4),
    ADD COLUMN IF NOT EXISTS is_interpolado  BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN staging.fact_precos_mensais.preco_curado IS
    'Preço curado: igual ao preco_medio para dados reais, interpolado para gaps ≤ 2 meses';
COMMENT ON COLUMN staging.fact_precos_mensais.is_interpolado IS
    'TRUE se este mês foi preenchido por interpolação linear (Layer A)';

-- ============================================================================
-- SEÇÃO 3: DDL — Colunas extras em mart.sazonalidade_produto (db/22b, db/26, db/30)
-- ============================================================================

-- Colunas de forecast e rastreabilidade
ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS is_forecast          BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS tendencia_futura      TEXT,
    ADD COLUMN IF NOT EXISTS baseline_confianca    NUMERIC(5,2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS forecast_method       TEXT;

COMMENT ON COLUMN mart.sazonalidade_produto.is_forecast IS
    'TRUE = projeção, FALSE = dado real';
COMMENT ON COLUMN mart.sazonalidade_produto.baseline_confianca IS
    'Percentual de meses (2024-2025) com dado real para este (produto,localidade,mes)';
COMMENT ON COLUMN mart.sazonalidade_produto.forecast_method IS
    'Método de geração: NULL=dado real; gamma_forecast_baseline=projetado via baseline histórico';

-- Check constraint para forecast_method
ALTER TABLE mart.sazonalidade_produto
    DROP CONSTRAINT IF EXISTS chk_forecast_method;
ALTER TABLE mart.sazonalidade_produto
    ADD CONSTRAINT chk_forecast_method
        CHECK (forecast_method IS NULL
               OR forecast_method IN ('gamma_forecast_baseline', 'alpha_baseline_25_26',
                                      'beta_media_disponivel', 'beta_weighted_25_24'));

-- Colunas de precificacao hibrida
ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS preco_referencia       NUMERIC(14,4),
    ADD COLUMN IF NOT EXISTS preco_atual            NUMERIC(14,4),
    ADD COLUMN IF NOT EXISTS data_referencia_atual  VARCHAR(7),
    ADD COLUMN IF NOT EXISTS usou_fallback_12m      BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS preco_estimado         BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS metodo_calculo         TEXT,
    ADD COLUMN IF NOT EXISTS variacao_mom_pct       NUMERIC(8,4),
    ADD COLUMN IF NOT EXISTS preco_mes_anterior     NUMERIC(14,4);

COMMENT ON COLUMN mart.sazonalidade_produto.preco_referencia IS
    'Preço âncora: COALESCE(AVG(2025), AVG(últimos 12 meses))';
COMMENT ON COLUMN mart.sazonalidade_produto.preco_atual IS
    'Último preço registrado do produto na localidade';
COMMENT ON COLUMN mart.sazonalidade_produto.data_referencia_atual IS
    'Mês/ano do preço atual, formato YYYY-MM';
COMMENT ON COLUMN mart.sazonalidade_produto.usou_fallback_12m IS
    'TRUE se a âncora veio da média dos últimos 12 meses (produto sem 2025)';
COMMENT ON COLUMN mart.sazonalidade_produto.preco_estimado IS
    'TRUE se o preco_atual foi estimado por interpolação (Layer A)';
COMMENT ON COLUMN mart.sazonalidade_produto.metodo_calculo IS
    'Método usado: alpha_sazonal, beta_media_disponivel, gamma_cold_start';
COMMENT ON COLUMN mart.sazonalidade_produto.variacao_mom_pct IS
    'Variação percentual mês sobre mês';
COMMENT ON COLUMN mart.sazonalidade_produto.preco_mes_anterior IS
    'Preço do mês anterior para cálculo de variação MoM';

-- Índices extras
CREATE INDEX IF NOT EXISTS idx_sazonalidade_forecast
    ON mart.sazonalidade_produto (is_forecast)
    WHERE is_forecast = TRUE;
CREATE INDEX IF NOT EXISTS idx_sazonalidade_confianca
    ON mart.sazonalidade_produto (baseline_confianca DESC);

-- ============================================================================
-- SEÇÃO 4: Novas tabelas — staging (db/05, db/07, db/11, db/12, db/15, db/16, db/22)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 4.1 staging.dim_categoria (db/07)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.dim_categoria (
    id_categoria     SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome_categoria   TEXT NOT NULL,
    descricao        TEXT,
    icone_url        TEXT,
    criado_em        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_dim_categoria_nome UNIQUE (nome_categoria)
);

COMMENT ON TABLE  staging.dim_categoria IS 'Tabela de categorias de varejo (modelo relacional 1:N com dim_produto)';
COMMENT ON COLUMN staging.dim_categoria.nome_categoria IS 'Nome amigável da categoria (ex: FRUTAS, LEGUMES, PESCADOS)';
COMMENT ON COLUMN staging.dim_categoria.descricao      IS 'Descrição opcional para exibição no frontend';

-- População inicial (idempotente via ON CONFLICT DO NOTHING)
INSERT INTO staging.dim_categoria (nome_categoria, descricao) VALUES
    ('FRUTAS',             'Frutas frescas in natura (banana, maçã, laranja, uva, etc.)'),
    ('LEGUMES',            'Legumes e tubérculos (batata, cenoura, tomate, abóbora, etc.)'),
    ('VERDURAS',           'Verduras e folhosas (alface, couve, espinafre, rúcula, etc.)'),
    ('FLORES',             'Flores e ornamentais (rosa, orquídea, crisântemo, etc.)'),
    ('PESCADOS',           'Pescados e frutos do mar (peixe, camarão, tilápia, etc.)'),
    ('PROTEINAS',          'Carnes, ovos e laticínios (bovina, frango, leite, queijo)'),
    ('CEREAIS_GRAOS',      'Cereais, grãos e farináceos (arroz, feijão, farinha, trigo)'),
    ('BEBIDAS',            'Bebidas em geral (suco, café, refrigerante)'),
    ('ALIMENTO_VAREJO',    'Demais alimentos de varejo não classificados acima'),
    ('OUTROS',             'Máquinas, insumos, serviços e matéria-prima B2B')
ON CONFLICT (nome_categoria) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4.2 staging.dim_conab_produto_mapping (db/11)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.dim_conab_produto_mapping (
    id_mapping          INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    produto_conab       TEXT NOT NULL,
    produto_normalizado TEXT NOT NULL,
    criado_em           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE staging.dim_conab_produto_mapping IS
    'Mapeamento de nomes de produtos CONAB para nomes normalizados do sistema';

-- ---------------------------------------------------------------------------
-- 4.3 staging.fato_cotacao_regional (db/15)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.fato_cotacao_regional (
    id           INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_produto   INTEGER NOT NULL,
    uf           CHAR(2) NOT NULL,
    ano          SMALLINT NOT NULL,
    mes          SMALLINT NOT NULL,
    preco_medio  NUMERIC(14,4),
    fonte        TEXT,
    criado_em    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE staging.fato_cotacao_regional IS
    'Cotações regionais (UF-level) para análise de preços agregados por estado';

CREATE INDEX IF NOT EXISTS idx_fato_cotacao_regional_prod_uf
    ON staging.fato_cotacao_regional (id_produto, uf, ano, mes);

-- ---------------------------------------------------------------------------
-- 4.4 staging.baseline_2025_interpolado (db/16)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.baseline_2025_interpolado (
    id_baseline      BIGSERIAL PRIMARY KEY,
    id_produto       INTEGER NOT NULL,
    id_localidade    INTEGER NOT NULL,
    media_interpolada NUMERIC(14,4),
    peso_confianca   NUMERIC(4,2) NOT NULL DEFAULT 0,
    qtd_meses_reais  SMALLINT NOT NULL DEFAULT 0,
    qtd_meses_grid   SMALLINT NOT NULL DEFAULT 0,
    calculado_em     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_baseline_2025_interpolado UNIQUE (id_produto, id_localidade)
);

COMMENT ON TABLE staging.baseline_2025_interpolado IS
    'Baseline 2025 com gaps imputados por interpolação linear (Layer A) e score de confiança C (Layer B)';
COMMENT ON COLUMN staging.baseline_2025_interpolado.media_interpolada IS
    'Média dos 12 meses após interpolação linear de gaps ≤2 meses';
COMMENT ON COLUMN staging.baseline_2025_interpolado.peso_confianca IS
    'C = qtd_meses_reais / 12. Se < 0.50, sistema usa fallback 12m (Layer B)';

CREATE INDEX IF NOT EXISTS idx_baseline2025_interp_prod_loc
    ON staging.baseline_2025_interpolado (id_produto, id_localidade);

-- ---------------------------------------------------------------------------
-- 4.5 staging.confianca_baseline (db/22)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.confianca_baseline (
    id_confianca       BIGSERIAL PRIMARY KEY,
    id_produto         INTEGER NOT NULL,
    id_localidade      INTEGER NOT NULL,
    confiavel_2025     BOOLEAN NOT NULL DEFAULT FALSE,
    score_confianca    NUMERIC(4,2) NOT NULL DEFAULT 0,
    meses_reais        SMALLINT NOT NULL DEFAULT 0,
    meses_interpolados SMALLINT NOT NULL DEFAULT 0,
    media_2025_curada  NUMERIC(14,4),
    calculado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_confianca_baseline UNIQUE (id_produto, id_localidade)
);

COMMENT ON TABLE staging.confianca_baseline IS
    'Layer B: Score de confiança do baseline 2025. confiavel_2025 = TRUE quando score >= 0.50';
COMMENT ON COLUMN staging.confianca_baseline.confiavel_2025 IS
    'Regra de Ouro: se FALSE ou NULL, a SP deve IGNORAR a média de 2025 e acionar fallback 12m';

CREATE INDEX IF NOT EXISTS idx_confianca_2025_prod_loc
    ON staging.confianca_baseline (id_produto, id_localidade);
CREATE INDEX IF NOT EXISTS idx_confianca_2025_flag
    ON staging.confianca_baseline (confiavel_2025)
    WHERE confiavel_2025 = TRUE;

-- ============================================================================
-- SEÇÃO 5: Novas tabelas — mart (db/30)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 5.1 mart.sazonalidade_baseline_24_25
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mart.sazonalidade_baseline_24_25 (
    id_produto     INTEGER NOT NULL,
    id_localidade  INTEGER NOT NULL,
    mes            INTEGER NOT NULL,
    status_cor_mode TEXT NOT NULL,
    confianca      NUMERIC(5,2),
    fonte          TEXT DEFAULT 'BASELINE_24_25',
    atualizado_em  TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (id_produto, id_localidade, mes)
);

COMMENT ON TABLE mart.sazonalidade_baseline_24_25 IS
    'Moda do status_cor por (produto, localidade, mes) calculada sobre 2024-2025 reais. Usado como fallback para projetar 2026.';

CREATE INDEX IF NOT EXISTS idx_baseline_24_25_mes
    ON mart.sazonalidade_baseline_24_25 (mes);

-- ---------------------------------------------------------------------------
-- 5.2 mart.sazonalidade_baseline_25_26
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mart.sazonalidade_baseline_25_26 (
    id_produto     INTEGER NOT NULL,
    id_localidade  INTEGER NOT NULL,
    mes            INTEGER NOT NULL,
    status_cor_mode TEXT NOT NULL,
    confianca      NUMERIC(5,2),
    fonte          TEXT DEFAULT 'BASELINE_25_26',
    atualizado_em  TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (id_produto, id_localidade, mes)
);

COMMENT ON TABLE mart.sazonalidade_baseline_25_26 IS
    'Moda do status_cor por (produto, localidade, mes) calculada sobre 2025-2026 reais. Baseline primário para projetar 2026.';

CREATE INDEX IF NOT EXISTS idx_baseline_25_26_mes
    ON mart.sazonalidade_baseline_25_26 (mes);

-- ============================================================================
-- SEÇÃO 6: Nova tabela — ops (db/12)
-- ============================================================================

CREATE TABLE IF NOT EXISTS staging.status_fonte_produto (
    id             BIGSERIAL PRIMARY KEY,
    id_produto     INTEGER NOT NULL REFERENCES staging.dim_produto(id_produto),
    status_fonte   TEXT NOT NULL,
    motivo         TEXT,
    criado_em      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE staging.status_fonte_produto IS
    'Histórico de mudanças de status_fonte dos produtos';

CREATE INDEX IF NOT EXISTS idx_status_fonte_produto
    ON staging.status_fonte_produto (id_produto);

-- ============================================================================
-- SEÇÃO 7: Views — mart (db/34)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 7.1 mart.vw_categorias
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.vw_categorias AS
SELECT
    c.id_categoria,
    c.nome_categoria,
    c.descricao,
    COUNT(DISTINCT p.id_produto) AS total_produtos
FROM staging.dim_categoria c
LEFT JOIN staging.dim_produto p
    ON p.id_categoria = c.id_categoria
   AND p.categoria_b2c = 'ALIMENTO_VAREJO'
GROUP BY c.id_categoria, c.nome_categoria, c.descricao
ORDER BY c.nome_categoria;

COMMENT ON VIEW mart.vw_categorias IS
    'Categorias com contagem de produtos B2C (ALIMENTO_VAREJO). Substitui query direta em staging.dim_categoria.';

-- ---------------------------------------------------------------------------
-- 7.2 mart.vw_municipios
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.vw_municipios AS
SELECT DISTINCT
    l.uf,
    l.municipio_nome AS municipio
FROM staging.dim_localidade l
WHERE l.municipio_nome IS NOT NULL
  AND l.municipio_nome != ''
ORDER BY l.uf, l.municipio_nome;

COMMENT ON VIEW mart.vw_municipios IS
    'Municípios disponíveis por UF. Substitui query direta em staging.dim_localidade.';

-- ============================================================================
-- SEÇÃO 8: Materialized View — V15 (db/31)
-- ============================================================================
-- Remove overloaded function first if it exists (db/35)
DROP FUNCTION IF EXISTS mart.fn_regional_snapshot(TEXT[], INTEGER, TEXT);

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
SELECT
    s.id_sazonalidade,
    s.id_localidade,
    p.id_produto,
    p.nome_produto              AS produto,
    p.classificao_produto,
    p.conab_id_produto,
    p.status_fonte,
    COALESCE(c.nome_categoria, 'ALIMENTO_VAREJO') AS categoria,
    l.uf,
    l.municipio_nome            AS municipio,
    l.municipio_id,
    CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER) AS ano,
    CAST(SPLIT_PART(s.data_referencia_atual, '-', 2) AS INTEGER) AS mes,
    s.preco_referencia,
    s.preco_atual,
    s.data_referencia_atual,
    s.usou_fallback_12m,
    s.preco_estimado,
    s.status_cor,
    s.fonte,
    s.calculado_em,
    s.metodo_calculo,
    s.variacao_mom_pct          AS variacao_pct,
    s.tendencia_futura,
    s.is_forecast,
    s.baseline_confianca,
    s.forecast_method
FROM mart.sazonalidade_produto s
JOIN staging.dim_produto    p ON p.id_produto    = s.id_produto
JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
LEFT JOIN staging.dim_categoria c ON c.id_categoria = p.id_categoria
WHERE s.status_cor IN ('VERDE', 'AMARELO', 'VERMELHO')
  AND p.categoria_b2c = 'ALIMENTO_VAREJO'
  AND (p.classificao_produto IS NULL
       OR p.classificao_produto NOT IN ('INSUMO_AGRICOLA', 'MAQUINARIO_FERRAMENTA', 'SERVICO_LOGISTICA'))
  AND (c.nome_categoria IS NULL
       OR c.nome_categoria NOT IN ('FLORES', 'OUTROS'))
ORDER BY ano, mes, s.is_forecast, s.status_cor, p.nome_produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'View B2C V15 — Sem filtro de ano. Expõe dados 2024-2026. Inclui is_forecast, baseline_confianca, forecast_method.';

-- Índices
CREATE UNIQUE INDEX IF NOT EXISTS idx_vw_sazonalidade_unico
    ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_filtro
    ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_categoria
    ON mart.vw_api_produtos_sazonalidade (categoria);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_produto
    ON mart.vw_api_produtos_sazonalidade (id_produto);

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_ano_mes
    ON mart.vw_api_produtos_sazonalidade (ano, mes)
    WHERE ano IS NOT NULL AND mes IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_forecast
    ON mart.vw_api_produtos_sazonalidade (is_forecast)
    WHERE is_forecast = TRUE;

CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_confianca
    ON mart.vw_api_produtos_sazonalidade (baseline_confianca DESC)
    WHERE is_forecast = TRUE;

-- ============================================================================
-- SEÇÃO 9: Funções — Agregação Nacional e Regional (db/31, db/33)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 9.1 mart.fn_br_nacional_sazonalidade(ano, categoria) — db/31
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mart.fn_br_nacional_sazonalidade(
    p_ano      INTEGER,
    p_categoria TEXT DEFAULT NULL
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
    total_ufs           BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_categoria_filter TEXT := COALESCE(p_categoria, '%%');
BEGIN
    RETURN QUERY
    WITH uf_por_mes AS (
        SELECT
            v.produto,
            v.classificao_produto,
            COALESCE(v.categoria, 'ALIMENTO_VAREJO') AS categoria_final,
            v.uf,
            v.mes,
            MODE() WITHIN GROUP (ORDER BY v.status_cor) AS uf_status_cor,
            BOOL_OR(v.is_forecast)       AS uf_forecast,
            MAX(v.baseline_confianca)    AS uf_confianca
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.ano = p_ano
          AND (p_categoria IS NULL OR v.categoria ILIKE v_categoria_filter)
        GROUP BY v.produto, v.classificao_produto, categoria_final, v.uf, v.mes
    )
    SELECT
        upm.produto,
        upm.classificao_produto,
        upm.categoria_final,
        upm.mes,
        (p_ano || '-' || LPAD(upm.mes::TEXT, 2, '0'))::TEXT AS data_ref,
        MODE() WITHIN GROUP (ORDER BY upm.uf_status_cor) AS status_cor_nac,
        BOOL_OR(upm.uf_forecast) AS is_forecast_nac,
        MAX(upm.uf_confianca) AS confianca_nac,
        COUNT(DISTINCT upm.uf) AS total_ufs_nac
    FROM uf_por_mes upm
    GROUP BY upm.produto, upm.classificao_produto, upm.categoria_final, upm.mes
    HAVING COUNT(DISTINCT upm.uf) >= 3
    ORDER BY upm.produto, upm.mes;
END;
$$;

COMMENT ON FUNCTION mart.fn_br_nacional_sazonalidade IS
    'Sazonalidade BR Nacional: retorna 12 meses de um ano. Moda da moda por UF, HAVING COUNT(DISTINCT uf) >= 3.';

-- ---------------------------------------------------------------------------
-- 9.2 mart.fn_br_nacional_por_mes(ano, mes, categoria, limit, offset) — db/33
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mart.fn_br_nacional_por_mes(
    p_ano       INTEGER,
    p_mes       INTEGER,
    p_categoria TEXT DEFAULT NULL,
    p_limit     INTEGER DEFAULT NULL,
    p_offset    INTEGER DEFAULT 0
)
RETURNS TABLE(
    produto             TEXT,
    classificao_produto TEXT,
    categoria           TEXT,
    uf                  TEXT,
    municipio           TEXT,
    municipio_id        TEXT,
    ano                 INTEGER,
    mes                 INTEGER,
    data_referencia_atual TEXT,
    preco_referencia    NUMERIC,
    preco_atual         NUMERIC,
    usou_fallback_12m   BOOLEAN,
    preco_estimado      BOOLEAN,
    status_cor          TEXT,
    fonte               TEXT,
    is_forecast         BOOLEAN,
    total_ufs           BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_categoria_filter TEXT := COALESCE(p_categoria, '%%');
BEGIN
    RETURN QUERY
    WITH uf_consolidado AS (
        SELECT
            v.produto,
            v.classificao_produto,
            COALESCE(v.categoria, 'ALIMENTO_VAREJO') AS categoria_final,
            v.uf,
            COUNT(*)::NUMERIC AS peso_uf,
            AVG(v.preco_referencia) AS uf_preco_ref,
            AVG(v.preco_atual)      AS uf_preco_atual,
            BOOL_OR(v.usou_fallback_12m) AS uf_fallback,
            BOOL_OR(v.preco_estimado)    AS uf_estimado,
            BOOL_OR(v.is_forecast)       AS uf_forecast,
            MODE() WITHIN GROUP (ORDER BY v.status_cor) AS uf_status_cor
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.ano = p_ano
          AND v.mes = p_mes
          AND (p_categoria IS NULL OR v.categoria ILIKE v_categoria_filter)
        GROUP BY v.produto, v.classificao_produto, v.categoria_final, v.uf
    )
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
        MODE() WITHIN GROUP (ORDER BY uf.uf_status_cor) AS status_cor_nac,
        'municipio'::TEXT        AS fonte_nac,
        BOOL_OR(uf.uf_forecast)  AS is_forecast_nac,
        COUNT(DISTINCT uf.uf)    AS total_ufs_nac
    FROM uf_consolidado uf
    GROUP BY uf.produto, uf.classificao_produto, uf.categoria_final
    HAVING COUNT(DISTINCT uf.uf) >= 5
    ORDER BY status_cor_nac, uf.produto
    LIMIT p_limit OFFSET p_offset;
END;
$$;

COMMENT ON FUNCTION mart.fn_br_nacional_por_mes IS
    'Agregação BR Nacional com paginação. Aceita p_limit/p_offset.';

-- ---------------------------------------------------------------------------
-- 9.3 mart.fn_br_nacional_snapshot(categoria, limit, offset) — db/33
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mart.fn_br_nacional_snapshot(
    p_categoria TEXT DEFAULT NULL,
    p_limit     INTEGER DEFAULT NULL,
    p_offset    INTEGER DEFAULT 0
)
RETURNS TABLE(
    produto             TEXT,
    classificao_produto TEXT,
    categoria           TEXT,
    uf                  TEXT,
    municipio           TEXT,
    municipio_id        TEXT,
    ano                 INTEGER,
    mes                 INTEGER,
    data_referencia_atual TEXT,
    preco_referencia    NUMERIC,
    preco_atual         NUMERIC,
    usou_fallback_12m   BOOLEAN,
    preco_estimado      BOOLEAN,
    status_cor          TEXT,
    fonte               TEXT,
    is_forecast         BOOLEAN,
    total_ufs           BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_ultimo_ano INTEGER;
    v_ultimo_mes INTEGER;
BEGIN
    SELECT MAX(v.ano), MAX(v.mes) FILTER (WHERE v.ano = (SELECT MAX(v2.ano) FROM mart.vw_api_produtos_sazonalidade v2))
    INTO v_ultimo_ano, v_ultimo_mes
    FROM mart.vw_api_produtos_sazonalidade v;

    IF v_ultimo_ano IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT * FROM mart.fn_br_nacional_por_mes(v_ultimo_ano, v_ultimo_mes, p_categoria, p_limit, p_offset);
END;
$$;

COMMENT ON FUNCTION mart.fn_br_nacional_snapshot IS
    'Snapshot BR Nacional com paginação. p_limit/p_offset opcionais.';

-- ---------------------------------------------------------------------------
-- 9.4 mart.fn_regional_snapshot(ufs, min_ufs, categoria, limit, offset) — db/33
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mart.fn_regional_snapshot(
    p_ufs       TEXT[],
    p_min_ufs   INTEGER DEFAULT 2,
    p_categoria TEXT DEFAULT NULL,
    p_limit     INTEGER DEFAULT NULL,
    p_offset    INTEGER DEFAULT 0
)
RETURNS TABLE(
    produto             TEXT,
    classificao_produto TEXT,
    categoria           TEXT,
    uf                  TEXT,
    municipio           TEXT,
    status_cor          TEXT,
    total_ufs           BIGINT,
    data_referencia_atual TEXT,
    is_forecast         BOOLEAN,
    fonte               TEXT,
    ano                 INTEGER,
    mes                 INTEGER
)
LANGUAGE SQL
STABLE
AS $$
    WITH latest_per_uf AS (
        SELECT DISTINCT ON (v.id_produto, v.uf)
            v.id_produto,
            v.produto,
            v.classificao_produto,
            v.categoria,
            v.uf,
            v.municipio,
            v.status_cor,
            v.ano,
            v.mes,
            v.data_referencia_atual,
            v.is_forecast,
            v.fonte
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.uf = ANY(p_ufs)
          AND (p_categoria IS NULL OR v.categoria = p_categoria)
        ORDER BY v.id_produto, v.uf, v.ano DESC, v.mes DESC
    ),
    regional_moda AS (
        SELECT
            id_produto,
            COUNT(DISTINCT uf) AS total_ufs,
            MODE() WITHIN GROUP (ORDER BY status_cor) AS moda_status
        FROM latest_per_uf
        GROUP BY id_produto
        HAVING COUNT(DISTINCT uf) >= p_min_ufs
    )
    SELECT
        lp.produto::TEXT,
        lp.classificao_produto::TEXT,
        lp.categoria::TEXT,
        p_ufs[1]::TEXT AS uf,
        'REGIÃO'::TEXT AS municipio,
        rm.moda_status::TEXT AS status_cor,
        rm.total_ufs::BIGINT,
        MAX(lp.data_referencia_atual)::TEXT AS data_referencia_atual,
        BOOL_OR(lp.is_forecast) AS is_forecast,
        'regiao'::TEXT AS fonte,
        MAX(lp.ano)::INTEGER AS ano,
        MAX(lp.mes)::INTEGER AS mes
    FROM regional_moda rm
    JOIN latest_per_uf lp ON lp.id_produto = rm.id_produto
    GROUP BY lp.produto, lp.classificao_produto, lp.categoria, rm.moda_status, rm.total_ufs
    ORDER BY rm.moda_status, lp.produto
    LIMIT p_limit OFFSET p_offset;
$$;

COMMENT ON FUNCTION mart.fn_regional_snapshot IS
    'Snapshot regional com paginação. Aceita p_limit/p_offset.';

-- ---------------------------------------------------------------------------
-- 9.5 mart.fn_regional_por_mes(ufs, min_ufs, ano, mes, categoria, limit, offset) — db/33
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mart.fn_regional_por_mes(
    p_ufs       TEXT[],
    p_min_ufs   INTEGER DEFAULT 2,
    p_ano       INTEGER DEFAULT NULL,
    p_mes       INTEGER DEFAULT NULL,
    p_categoria TEXT DEFAULT NULL,
    p_limit     INTEGER DEFAULT NULL,
    p_offset    INTEGER DEFAULT 0
)
RETURNS TABLE(
    produto             TEXT,
    classificao_produto TEXT,
    categoria           TEXT,
    uf                  TEXT,
    municipio           TEXT,
    status_cor          TEXT,
    total_ufs           BIGINT,
    data_referencia_atual TEXT,
    is_forecast         BOOLEAN,
    fonte               TEXT,
    ano                 INTEGER,
    mes                 INTEGER
)
LANGUAGE SQL
STABLE
AS $$
    WITH regional_data AS (
        SELECT DISTINCT ON (v.id_produto, v.uf)
            v.id_produto,
            v.produto,
            v.classificao_produto,
            v.categoria,
            v.uf,
            v.municipio,
            v.status_cor,
            v.ano,
            v.mes,
            v.data_referencia_atual,
            v.is_forecast,
            v.fonte
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.uf = ANY(p_ufs)
          AND (p_categoria IS NULL OR v.categoria = p_categoria)
          AND (p_ano IS NULL OR v.ano = p_ano)
          AND (p_mes IS NULL OR v.mes = p_mes)
        ORDER BY v.id_produto, v.uf, v.ano DESC, v.mes DESC
    ),
    regional_moda AS (
        SELECT
            id_produto,
            COUNT(DISTINCT uf) AS total_ufs,
            MODE() WITHIN GROUP (ORDER BY status_cor) AS moda_status
        FROM regional_data
        GROUP BY id_produto
        HAVING COUNT(DISTINCT uf) >= p_min_ufs
    )
    SELECT
        lp.produto::TEXT,
        lp.classificao_produto::TEXT,
        lp.categoria::TEXT,
        p_ufs[1]::TEXT AS uf,
        'REGIÃO'::TEXT AS municipio,
        rm.moda_status::TEXT AS status_cor,
        rm.total_ufs::BIGINT,
        MAX(lp.data_referencia_atual)::TEXT AS data_referencia_atual,
        BOOL_OR(lp.is_forecast) AS is_forecast,
        'regiao'::TEXT AS fonte,
        COALESCE(p_ano, MAX(lp.ano))::INTEGER AS ano,
        COALESCE(p_mes, MAX(lp.mes))::INTEGER AS mes
    FROM regional_moda rm
    JOIN regional_data lp ON lp.id_produto = rm.id_produto
    GROUP BY lp.produto, lp.classificao_produto, lp.categoria, rm.moda_status, rm.total_ufs
    ORDER BY rm.moda_status, lp.produto
    LIMIT p_limit OFFSET p_offset;
$$;

COMMENT ON FUNCTION mart.fn_regional_por_mes IS
    'Agregação regional por mês com paginação. Aceita p_limit/p_offset.';

-- ============================================================================
-- SEÇÃO 10: Procedures — Forecast Engine (db/30)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 10.1 staging.sp_calcular_forecast_2026()
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE staging.sp_calcular_forecast_2026()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio  TIMESTAMPTZ;
    v_fim     TIMESTAMPTZ;
    v_total   INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_calcular_forecast_2026] Iniciando Forecast 2026...';

    WITH baseline_ponderado AS (
        SELECT
            COALESCE(bl_25_26.id_produto, bl_24_25.id_produto) AS id_produto,
            COALESCE(bl_25_26.id_localidade, bl_24_25.id_localidade) AS id_localidade,
            COALESCE(bl_25_26.mes, bl_24_25.mes) AS mes,
            COALESCE(bl_25_26.status_cor_mode, bl_24_25.status_cor_mode) AS status_cor_mode,
            CASE
                WHEN bl_25_26.status_cor_mode IS NOT NULL AND bl_25_26.confianca >= 30
                    THEN bl_25_26.confianca
                WHEN bl_24_25.status_cor_mode IS NOT NULL
                    THEN bl_24_25.confianca * 0.5
                ELSE 0
            END AS confianca,
            'beta_weighted_25_24' AS forecast_method
        FROM mart.sazonalidade_baseline_25_26 bl_25_26
        FULL JOIN mart.sazonalidade_baseline_24_25 bl_24_25
            ON bl_25_26.id_produto = bl_24_25.id_produto
           AND bl_25_26.id_localidade = bl_24_25.id_localidade
           AND bl_25_26.mes = bl_24_25.mes
    ),
    dados_reais_2026 AS (
        SELECT DISTINCT
            s.id_produto,
            s.id_localidade,
            CAST(SPLIT_PART(s.data_referencia_atual, '-', 2) AS INTEGER) AS mes,
            s.preco_atual,
            s.preco_referencia,
            s.data_referencia_atual,
            s.preco_estimado,
            s.usou_fallback_12m,
            s.status_cor,
            s.fonte,
            s.calculado_em,
            s.metodo_calculo,
            s.variacao_mom_pct,
            s.preco_mes_anterior,
            FALSE AS is_forecast,
            s.tendencia_futura,
            0::NUMERIC(5,2) AS baseline_confianca,
            NULL::TEXT AS forecast_method
        FROM mart.sazonalidade_produto s
        WHERE CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER) = 2026
          AND s.is_forecast = FALSE
    ),
    meses_2026 AS (
        SELECT generate_series(1, 12) AS mes
    ),
    produtos_com_baseline AS (
        SELECT DISTINCT id_produto, id_localidade FROM baseline_ponderado
    ),
    grade_completa AS (
        SELECT p.id_produto, p.id_localidade, m.mes
        FROM produtos_com_baseline p
        CROSS JOIN meses_2026 m
    ),
    meses_com_dado_real AS (
        SELECT DISTINCT id_produto, id_localidade, mes FROM dados_reais_2026
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
            mf.mes,
            2026 AS ano,
            b.status_cor_mode       AS status_cor,
            b.confianca             AS baseline_confianca,
            'beta_weighted_25_24' AS metodo_calculo,
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
            b.confianca,
            NULL::NUMERIC(14,4) AS preco_referencia,
            NULL::NUMERIC(14,4) AS preco_atual,
            NULL::NUMERIC(14,4) AS preco_mes_anterior,
            0::NUMERIC(8,4)     AS variacao_mom_pct,
            FALSE               AS preco_estimado,
            FALSE               AS usou_fallback_12m,
            'beta_weighted_25_24' AS forecast_method
        FROM meses_faltantes mf
        JOIN baseline_ponderado b
            ON b.id_produto = mf.id_produto
           AND b.id_localidade = mf.id_localidade
           AND b.mes = mf.mes
    ),
    uniao_final AS (
        SELECT
            id_produto, id_localidade, mes,
            preco_atual, preco_referencia,
            data_referencia_atual,
            usou_fallback_12m,
            preco_estimado, status_cor, fonte,
            metodo_calculo,
            variacao_mom_pct,
            preco_mes_anterior,
            tendencia_futura,
            is_forecast,
            baseline_confianca,
            forecast_method
        FROM dados_reais_2026
        UNION ALL
        SELECT
            id_produto, id_localidade, mes,
            preco_atual, preco_referencia,
            data_referencia_atual,
            usou_fallback_12m,
            preco_estimado, status_cor, fonte,
            metodo_calculo,
            variacao_mom_pct,
            preco_mes_anterior,
            tendencia_futura,
            is_forecast,
            baseline_confianca,
            forecast_method
        FROM projecao_faltantes
    )
    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade,
        preco_referencia, preco_atual,
        data_referencia_atual, usou_fallback_12m,
        preco_estimado, status_cor, fonte, calculado_em,
        metodo_calculo, variacao_mom_pct, preco_mes_anterior,
        tendencia_futura, is_forecast,
        baseline_confianca, forecast_method
    )
    SELECT
        u.id_produto,
        u.id_localidade,
        ROUND(u.preco_referencia, 4),
        u.preco_atual,
        u.data_referencia_atual,
        u.usou_fallback_12m,
        u.preco_estimado,
        u.status_cor,
        u.fonte,
        NOW(),
        u.metodo_calculo,
        u.variacao_mom_pct,
        u.preco_mes_anterior,
        u.tendencia_futura,
        u.is_forecast,
        u.baseline_confianca,
        u.forecast_method
    FROM uniao_final u
    ON CONFLICT (id_produto, id_localidade, data_referencia_atual)
    DO UPDATE SET
        preco_referencia      = EXCLUDED.preco_referencia,
        preco_atual           = EXCLUDED.preco_atual,
        usou_fallback_12m     = EXCLUDED.usou_fallback_12m,
        preco_estimado        = EXCLUDED.preco_estimado,
        status_cor            = EXCLUDED.status_cor,
        fonte                 = EXCLUDED.fonte,
        calculado_em          = NOW(),
        metodo_calculo        = EXCLUDED.metodo_calculo,
        variacao_mom_pct      = EXCLUDED.variacao_mom_pct,
        preco_mes_anterior    = EXCLUDED.preco_mes_anterior,
        is_forecast           = CASE
                                    WHEN EXCLUDED.is_forecast = FALSE THEN FALSE
                                    WHEN mart.sazonalidade_produto.is_forecast = TRUE
                                         AND EXCLUDED.is_forecast = TRUE THEN TRUE
                                    ELSE mart.sazonalidade_produto.is_forecast
                                END,
        tendencia_futura      = EXCLUDED.tendencia_futura,
        baseline_confianca    = EXCLUDED.baseline_confianca,
        forecast_method       = EXCLUDED.forecast_method;

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_forecast_2026] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);

    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
    RAISE NOTICE '[sp_calcular_forecast_2026] MV atualizada.';
END;
$$;

COMMENT ON PROCEDURE staging.sp_calcular_forecast_2026 IS
    'Engine Preditiva 2026 — Projeta meses sem dado real usando baseline ponderado (25_26 primária + 24_25 fallback*0.5).';

-- ---------------------------------------------------------------------------
-- 10.2 staging.sp_executar_carga_completa() — pipeline completo V12
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE staging.sp_executar_carga_completa()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Iniciando pipeline completo...';

    CALL staging.sp_carregar_landing_para_staging();
    RAISE NOTICE '[sp_executar_carga_completa] Landing → Staging OK';

    CALL staging.sp_limpar_e_normalizar_staging();
    RAISE NOTICE '[sp_executar_carga_completa] Normalização OK';

    CALL staging.sp_sincronizar_variedades_conab();
    RAISE NOTICE '[sp_executar_carga_completa] Sincronização CONAB OK';

    CALL staging.sp_calcular_sazonalidade_v11();
    RAISE NOTICE '[sp_executar_carga_completa] Sazonalidade v11 OK';

    CALL staging.sp_calcular_forecast_2026();
    RAISE NOTICE '[sp_executar_carga_completa] Forecast 2026 OK';

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Pipeline completo em % seg',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

COMMENT ON PROCEDURE staging.sp_executar_carga_completa IS
    'Pipeline completo V12 — Executa carga + sazonalidade V11 + Forecast 2026.';

-- ============================================================================
-- SEÇÃO 11: Permissões
-- ============================================================================

-- Tabelas novas — mart
GRANT SELECT ON mart.sazonalidade_baseline_24_25 TO role_api_reader;
GRANT SELECT ON mart.sazonalidade_baseline_25_26 TO role_api_reader;

-- Tabelas novas — staging
GRANT ALL ON TABLE staging.dim_categoria TO role_etl_writer;
GRANT SELECT ON TABLE staging.dim_categoria TO role_api_reader;
GRANT SELECT, INSERT, UPDATE ON staging.baseline_2025_interpolado TO role_etl_writer;
GRANT USAGE ON SEQUENCE staging.baseline_2025_interpolado_id_baseline_seq TO role_etl_writer;
GRANT SELECT ON staging.baseline_2025_interpolado TO role_api_reader;
GRANT SELECT, INSERT, UPDATE ON staging.confianca_baseline TO role_etl_writer;
GRANT USAGE ON SEQUENCE staging.confianca_baseline_id_confianca_seq TO role_etl_writer;
GRANT SELECT ON staging.confianca_baseline TO role_api_reader;
GRANT ALL ON TABLE staging.fato_cotacao_regional TO role_etl_writer;
GRANT ALL ON TABLE staging.dim_conab_produto_mapping TO role_etl_writer;
GRANT ALL ON TABLE staging.status_fonte_produto TO role_etl_writer;

-- Views
GRANT SELECT ON mart.vw_categorias TO role_api_reader;
GRANT SELECT ON mart.vw_municipios TO role_api_reader;
GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;

-- Funções de agregação nacional
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT)
    TO role_api_reader;
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_por_mes(INTEGER, INTEGER, TEXT, INTEGER, INTEGER)
    TO role_api_reader;
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_snapshot(TEXT, INTEGER, INTEGER)
    TO role_api_reader;
GRANT EXECUTE ON FUNCTION mart.fn_regional_snapshot(TEXT[], INTEGER, TEXT, INTEGER, INTEGER)
    TO role_api_reader;
GRANT EXECUTE ON FUNCTION mart.fn_regional_por_mes(TEXT[], INTEGER, INTEGER, INTEGER, TEXT, INTEGER, INTEGER)
    TO role_api_reader;
-- Mantém compatibilidade com assinaturas anteriores
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_por_mes(INTEGER, INTEGER, TEXT)
    TO role_api_reader;
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_snapshot(TEXT)
    TO role_api_reader;

-- Procedures
GRANT ALL ON PROCEDURE staging.sp_calcular_forecast_2026 TO role_etl_writer;
GRANT ALL ON PROCEDURE staging.sp_executar_carga_completa TO role_etl_writer;

-- ============================================================================
-- SEÇÃO 12: Refresh inicial da MV (executar após criar)
-- ============================================================================

REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- ============================================================================
-- FIM
-- ============================================================================

COMMIT;
