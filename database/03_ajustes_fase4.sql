-- ============================================================================
-- QUERO COMPRAR — Ajustes Fase 4: Ingestão de Dados Reais e Edge Cases
-- PostgreSQL 16+
--
-- 1. Dimensão Produto: novo atributo classificao_produto + conab_id_produto
-- 2. Trigger de anomalia: compara APENAS mesmo id_produto + uf (não global)
-- 3. Sazonalidade: isolamento por classificação (TRATOR ≠ TOMATE)
-- ============================================================================

BEGIN;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 1 — DIM_PRODUTO: atributos de classificação
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Os arquivos LISTA*.txt carregam produto + classificao_produto + id_produto
-- (CONAB). Armazenamos como metadados para auditoria e consultas futuras.
-- A unicidade continua sendo por nome_produto (combinado na carga Python).
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

ALTER TABLE staging.dim_produto
    ADD COLUMN IF NOT EXISTS conab_id_produto    INTEGER,
    ADD COLUMN IF NOT EXISTS classificao_produto  TEXT,
    ADD COLUMN IF NOT EXISTS categoria_b2c        TEXT;

COMMENT ON COLUMN staging.dim_produto.conab_id_produto IS
    'ID interno do produto no sistema CONAB (arquivos LISTA*.txt)';

COMMENT ON COLUMN staging.dim_produto.classificao_produto IS
    'Classificação do produto ex: "150 16X16 JOHN DEERE", "NÃO INFORMADO"';

COMMENT ON COLUMN staging.dim_produto.categoria_b2c IS
    'Categoria semântica: ALIMENTO_VAREJO | MAQUINARIO_FERRAMENTA | INSUMO_AGRICOLA | SERVICO_LOGISTICA | MATERIA_PRIMA_B2B';

-- Índice para filtrar B2C na MV
CREATE INDEX IF NOT EXISTS idx_dim_produto_categoria
    ON staging.dim_produto (categoria_b2c);

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 2 — TRIGGER DE ANOMALIA CORRIGIDA
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Problema original: a trigger comparava o preço de inserção com a média
-- histórica do mesmo id_produto E id_localidade. Isso fazia com que um
-- TRATOR de R$ 500k em SP fosse comparado com TRATORES de R$ 500k em SP
-- (correto), mas o JOIN explícito por UF agora garante que a janela
-- histórica capture TODOS os municípios da mesma UF para o mesmo produto.
--
-- Isso é relevante quando a carga vem de fontes diferentes (UF-level vs
-- municipio-level) — a média considera a UF inteira.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE FUNCTION staging.trg_valida_anomalia_preco()
RETURNS TRIGGER AS $$
DECLARE
    v_media_historica NUMERIC(14,4);
    v_dados_brutos    JSONB;
    v_uf              CHAR(2);
BEGIN
    -- Resolve a UF da localidade que está sendo inserida
    SELECT uf INTO v_uf
    FROM staging.dim_localidade
    WHERE id_localidade = NEW.id_localidade;

    -- Média histórica do MESMO produto na MESMA UF (qualquer municipio)
    SELECT AVG(f.preco_medio) INTO v_media_historica
    FROM staging.fact_precos_mensais f
    JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
    WHERE f.id_produto = NEW.id_produto
      AND l.uf         = v_uf
      AND NOT (f.ano = NEW.ano AND f.mes = NEW.mes);

    -- Sem histórico → deixa passar (primeira ocorrência)
    IF v_media_historica IS NULL THEN
        RETURN NEW;
    END IF;

    -- Preço > 500 % da média da UF → quarentena
    IF NEW.preco_medio > (v_media_historica * 5.0) THEN
        v_dados_brutos := jsonb_build_object(
            'produto_id',      NEW.id_produto,
            'localidade_id',   NEW.id_localidade,
            'uf',              v_uf,
            'ano',             NEW.ano,
            'mes',             NEW.mes,
            'preco_enviado',   NEW.preco_medio,
            'media_historica', v_media_historica
        );

        INSERT INTO staging.precos_rejeitados (
            id_produto, id_localidade, ano, mes,
            preco_medio, preco_medio_historico, razao,
            dados_brutos, batch_id
        ) VALUES (
            NEW.id_produto, NEW.id_localidade, NEW.ano, NEW.mes,
            NEW.preco_medio, v_media_historica,
            'Preço excede 500% da média histórica do mesmo produto na mesma UF',
            v_dados_brutos, NEW.batch_id
        );

        RETURN NULL;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION staging.trg_valida_anomalia_preco() IS
    'Desvia para quarentena preços >500% da média do mesmo id_produto + UF (Fase 4)';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 3 — TUNING DA MATERIALIZED VIEW (isolamento por classificação)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- A MV agora expõe classificao_produto e conab_id_produto para que a API
-- possa distinguir, por exemplo, "ZINCO AGRICHEM" de "ZINCO QUELATIZADO 10%".
-- O cálculo de sazonalidade dentro de sp_calcular_sazonalidade já agrupa
-- por id_produto (surrogate), que é único para cada (nome_produto), e o
-- load_local_file combina produto + classificao_produto no nome_produto,
-- garantindo que cada variação tenha seu próprio cálculo isolado.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
SELECT
    s.id_sazonalidade,
    p.nome_produto              AS produto,
    p.classificao_produto,
    p.conab_id_produto,
    p.categoria_b2c,
    l.uf,
    l.municipio_nome            AS municipio,
    l.municipio_id,
    s.ano,
    s.mes,
    s.preco_medio,
    s.media_movel_12m,
    s.indice_sazonalidade,
    s.status_cor,
    s.fonte,
    s.calculado_em
FROM mart.sazonalidade_produto s
JOIN staging.dim_produto    p ON p.id_produto    = s.id_produto
JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
WHERE s.status_cor != 'INSUFICIENTE'
  AND p.categoria_b2c = 'ALIMENTO_VAREJO'        -- filtra tratores do app B2C
ORDER BY s.ano DESC, s.mes DESC, p.nome_produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'Fase 4: inclui categoria_b2c e filtra ALIMENTO_VAREJO — tratores fora do app consumidor';

CREATE UNIQUE INDEX IF NOT EXISTS idx_vw_api_unique
    ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

CREATE INDEX IF NOT EXISTS idx_vw_api_filtro
    ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);

-- Refresh único (executar após criar)
REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 4 — PERMISSÕES (re-aplicar para incluir novas colunas)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;

COMMIT;
