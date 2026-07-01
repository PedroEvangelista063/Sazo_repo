-- ============================================================================
-- QUERO COMPRAR — Fase 15: Schema Agro-Regional (CEASAs + CONAB ProHort)
-- PostgreSQL 16+  |  Cotacoes Regionalizadas por Fonte
--
-- MOTIVACAO:
--   A fonte CONAB (ProHort) fornece precos nacionais, mas a capilaridade
--   real esta nas CEASAs estaduais (PR, GO, CE, RS, SC, BA, MG, DF, etc.),
--   cada uma com sua periodicidade, unidade de medida e cobertura de
--   produtos heterogenea.
--
--   Precisamos de um schema que:
--     1. Armazene cotacoes diarias/semanais de multiplas fontes (1:N)
--     2. Suporte unidades de medida variadas (cx 20kg, sc 50kg, dz, kg)
--     3. Priorize fontes oficiais (CONAB) sobre CEASAs em caso de conflito
--     4. Habilite comparacao de precos por produto x UF x mes
--     5. Incorpore HORTIFRUTIGRANJEIROS como categoria na dim_produto
--
-- SUMARIO:
--   1. Cria staging.fato_cotacao_regional (tabela fato regionalizada)
--   2. Adiciona categoria HORTIFRUTIGRANJEIROS na dim_categoria
--   3. Atualiza classificacao de produtos na dim_produto
--   4. Rebuild da MV com LOJ para cotacao_regional
--   5. Indices, permissoes, comentarios
-- ============================================================================

BEGIN;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SECAO 1 — Tabela Fato: staging.fato_cotacao_regional
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Diferente da staging.fact_precos_mensais (que agrega por mes e fonte
-- CONAB apenas), esta tabela armazena a cotacao ORIGINAL de cada fonte
-- com a maxima granularidade disponivel:
--
--   - Uma CEASA pode publicar 2 cotacoes por semana para o mesmo produto
--   - Cada cotacao pode ter preco minimo, maximo e medio
--   - A unidade de medida e armazenada em texto + fator numerico para kg
--   - O campo status_fonte permite rastrear fontes instaveis
--
-- UNIQUE CONSTRAINT: (produto_normalizado, uf_referencia, data_cotacao, fonte)
--   - Se houver mais de uma fonte para o mesmo produto na mesma data,
--     o sistema prioriza pela ordem definida em fontes_prioridade
--     (CONAB = 1, CEAGESP = 2, CEASAs estaduais = 3+)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE TABLE IF NOT EXISTS staging.fato_cotacao_regional (
    id_cotacao              BIGSERIAL       PRIMARY KEY,
    produto_original        TEXT            NOT NULL,
    produto_normalizado     TEXT            NOT NULL DEFAULT '',
    id_produto              INTEGER         REFERENCES staging.dim_produto(id_produto)
                                            ON DELETE RESTRICT,
    uf_referencia           CHAR(2)         NOT NULL DEFAULT 'BR',
    municipio_referencia    TEXT            NOT NULL DEFAULT '',
    data_cotacao            DATE,
    ano                     SMALLINT,
    mes                     SMALLINT        CHECK (mes IS NULL OR (mes BETWEEN 1 AND 12)),
    fonte                   TEXT            NOT NULL DEFAULT '',
    prioridade_fonte        SMALLINT        NOT NULL DEFAULT 99,
    unidade_medida          TEXT            NOT NULL DEFAULT '',
    fator_kg                NUMERIC(10,4)   NOT NULL DEFAULT 1.0,
    preco_min               NUMERIC(14,4),
    preco_max               NUMERIC(14,4),
    preco_medio             NUMERIC(14,4)   CHECK (preco_medio IS NULL OR preco_medio > 0),
    preco_bruto             NUMERIC(14,4),
    volume_referencia       TEXT            NOT NULL DEFAULT '',
    status_coleta           TEXT            NOT NULL DEFAULT 'pendente'
                            CHECK (status_coleta IN (
                                'pendente', 'sucesso', 'erro', 'timeout', 'insuficiente'
                            )),
    erro                    TEXT            NOT NULL DEFAULT '',
    batch_id                UUID,
    data_coleta             TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    loaded_at               TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_cotacao_regional UNIQUE (produto_normalizado, uf_referencia, data_cotacao, fonte)
);

COMMENT ON TABLE staging.fato_cotacao_regional IS
    'Cotacoes regionalizadas de hortifrutigranjeiros por fonte (CEASAs + CONAB ProHort). '
    'Cada linha = 1 cotacao original de 1 fonte para 1 produto em 1 data.';

COMMENT ON COLUMN staging.fato_cotacao_regional.prioridade_fonte IS
    'Prioridade numerica da fonte (1=CONAB oficial, 2=CEAGESP, 3+=CEASAs estaduais). '
    'Usada para resolver conflitos quando ha multiplas fontes p/ mesmo produto/data.';

COMMENT ON COLUMN staging.fato_cotacao_regional.fator_kg IS
    'Fator de conversao para kg. Ex: cx 20kg = 20.0, dz = 1.0, sc 50kg = 50.0';

COMMENT ON COLUMN staging.fato_cotacao_regional.status_coleta IS
    'Status da coleta: pendente, sucesso, erro, timeout, insuficiente. '
    'Usado para monitoramento de saude das fontes.';

-- Indices de consulta
CREATE INDEX IF NOT EXISTS idx_cotacao_regional_busca
    ON staging.fato_cotacao_regional (produto_normalizado, uf_referencia, ano, mes);

CREATE INDEX IF NOT EXISTS idx_cotacao_regional_fonte
    ON staging.fato_cotacao_regional (fonte, status_coleta);

CREATE INDEX IF NOT EXISTS idx_cotacao_regional_data
    ON staging.fato_cotacao_regional (data_cotacao DESC);

CREATE INDEX IF NOT EXISTS idx_cotacao_regional_id_produto
    ON staging.fato_cotacao_regional (id_produto);

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SECAO 2 — VIEW de resolucao de conflitos (prioridade de fontes)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Quando o mesmo produto tem cotacao de multiplas fontes na mesma data,
-- esta view retorna APENAS a linha de maior prioridade (menor numero).
--
-- Ordem de prioridade das fontes (definida em sources_map.json):
--   1  = CONAB-ProHort (oficial federal)
--   2  = CEAGESP (maior CEASA da America Latina)
--   3  = CEASA-PR (historico bem estruturado)
--   4  = CEASA-GO
--   5  = CEASA-RS
--   6  = CEASA-SC
--   7  = CEASA-CE
--   8  = CEASA-BA
--   9  = CEASA-MG
--   10 = CEASA-DF
--   99 = fonte desconhecida/nao mapeada
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE VIEW staging.vw_cotacao_regional_dedup AS
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY produto_normalizado, uf_referencia, data_cotacao
            ORDER BY prioridade_fonte ASC, loaded_at DESC
        ) AS rn
    FROM staging.fato_cotacao_regional
    WHERE status_coleta = 'sucesso'
      AND preco_medio IS NOT NULL
)
SELECT
    id_cotacao,
    produto_original,
    produto_normalizado,
    id_produto,
    uf_referencia,
    municipio_referencia,
    data_cotacao,
    ano,
    mes,
    fonte                  AS fonte_vencedora,
    prioridade_fonte,
    unidade_medida,
    fator_kg,
    preco_min,
    preco_max,
    preco_medio,
    ROUND(preco_medio / NULLIF(fator_kg, 0), 4) AS preco_por_kg,
    volume_referencia,
    batch_id,
    data_coleta,
    loaded_at
FROM ranked
WHERE rn = 1;

COMMENT ON VIEW staging.vw_cotacao_regional_dedup IS
    'View deduplicada: para cada produto + UF + data, retorna apenas a fonte '
    'de maior prioridade (CONAB > CEAGESP > CEASA estadual).';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SECAO 3 — Categoria HORTIFRUTIGRANJEIROS
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Adiciona HORTIFRUTIGRANJEIROS como categoria guarda-chuva (id=11)
-- que engloba FRUTAS + LEGUMES + VERDURAS + parte de ALIMENTO_VAREJO.
-- Produtos nestas categorias recebem status_fonte = 'MAPEADA'.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

INSERT INTO staging.dim_categoria (nome_categoria, descricao)
VALUES (
    'HORTIFRUTIGRANJEIROS',
    'Produtos horticulas de varejo (frutas, legumes, verduras, flores) '
    'comercializados em CEASAS e acompanhados pela CONAB/ProHort. '
    'Categoria guarda-chuva que agrupa FRUTAS + LEGUMES + VERDURAS + FLORES.'
)
ON CONFLICT (nome_categoria) DO NOTHING;

DO $$
DECLARE
    v_cat_hortifruti SMALLINT;
    v_cat_frutas     SMALLINT;
    v_cat_legumes    SMALLINT;
    v_cat_verduras   SMALLINT;
    v_cat_flores     SMALLINT;
    v_atualizados    INTEGER;
BEGIN
    v_cat_hortifruti := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'HORTIFRUTIGRANJEIROS');
    v_cat_frutas     := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'FRUTAS');
    v_cat_legumes    := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'LEGUMES');
    v_cat_verduras   := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'VERDURAS');
    v_cat_flores     := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'FLORES');

    -- Atualiza produtos de FRUTAS e LEGUMES e VERDURAS e FLORES
    UPDATE staging.dim_produto
    SET id_categoria = v_cat_hortifruti
    WHERE id_categoria IN (v_cat_frutas, v_cat_legumes, v_cat_verduras, v_cat_flores);

    GET DIAGNOSTICS v_atualizados = ROW_COUNT;
    RAISE NOTICE '[HORTIFRUTIGRANJEIROS] % produtos reclassificados', v_atualizados;
END $$;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SECAO 4 — Atualiza status_fonte para produtos hortifruti
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

DO $$
DECLARE
    v_cat_hortifruti SMALLINT;
    v_atualizados    INTEGER;
BEGIN
    v_cat_hortifruti := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'HORTIFRUTIGRANJEIROS');

    UPDATE staging.dim_produto
    SET status_fonte = 'MAPEADA'
    WHERE id_categoria = v_cat_hortifruti
      AND status_fonte != 'MAPEADA';

    GET DIAGNOSTICS v_atualizados = ROW_COUNT;
    RAISE NOTICE '[STATUS_FONTE] % produtos hortifruti mapeados como MAPEADA', v_atualizados;
END $$;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SECAO 5 — Atualiza Materialized View da API com id_produto e categoria
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
SELECT
    s.id_sazonalidade,
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
    s.status_cor,
    s.fonte,
    s.calculado_em
FROM mart.sazonalidade_produto s
JOIN staging.dim_produto    p ON p.id_produto    = s.id_produto
JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
LEFT JOIN staging.dim_categoria c ON c.id_categoria = p.id_categoria
WHERE s.status_cor != 'INSUFICIENTE'
ORDER BY s.status_cor, p.nome_produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'View B2C com id_produto, status_fonte e categoria hortifruti. '
    'Filtra INSUFICIENTE. Inclui join com dim_categoria para frontend.';

CREATE UNIQUE INDEX IF NOT EXISTS idx_vw_api_unique
    ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

CREATE INDEX IF NOT EXISTS idx_vw_api_filtro
    ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);

CREATE INDEX IF NOT EXISTS idx_vw_api_categoria
    ON mart.vw_api_produtos_sazonalidade (categoria);

CREATE INDEX IF NOT EXISTS idx_vw_api_id_produto
    ON mart.vw_api_produtos_sazonalidade (id_produto);

REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SECAO 6 — Permissoes
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

GRANT ALL PRIVILEGES ON TABLE staging.fato_cotacao_regional TO role_etl_writer;
GRANT SELECT ON TABLE staging.fato_cotacao_regional TO role_api_reader;
GRANT SELECT ON staging.vw_cotacao_regional_dedup TO role_api_reader;
GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;

COMMIT;
