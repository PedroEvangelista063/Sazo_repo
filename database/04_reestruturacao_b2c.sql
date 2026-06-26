-- ============================================================================
-- QUERO COMPRAR — Reestruturação B2C (Cômodo 2: A Despensa)
-- PostgreSQL 16+  |  Idêntico ao blueprint: Garagem → Despensa → Cozinha
--
-- Este script implementa as regras da **Prateleira do Meio (staging)** e da
-- **Prateleira de Cima (mart)** para isolar completamente os dados B2C
-- (ALIMENTO_VAREJO) dos dados B2B (TRATOR, ZINCO, TRANSPORTE, etc.).
--
-- SUMÁRIO:
--   1. ``dim_produto``: colunas ``categoria_b2c``, ``conab_id_produto``,
--      ``classificao_produto`` (idêntico, re-executável)
--   2. Trigger de anomalia: preço >500% da média histórica → quarentena
--   3. Stored Procedure ``sp_calcular_sazonalidade`` (rolling window 12m)
--   4. Materialized View ``vw_api_produtos_sazonalidade`` com filtro
--      ``WHERE categoria_b2c = 'ALIMENTO_VAREJO'`` — tratores não passam.
--   5. Procedure mestre ``sp_executar_carga_completa``
--   6. Permissões para as roles
--
-- Regra da Sala de Estar (Cômodo 4):
--   O FILTRO ``ALIMENTO_VAREJO`` NA MV É A ÚLTIMA BARREIRA. Se um TRATOR
--   aparecer aqui, a API B2C vai expor um trator de R$ 500.000,00 para o
--   consumidor de supermercado. Isso é uma falha arquitetural.
-- ============================================================================

BEGIN;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 1 — DIM_PRODUTO: atributos de classificação semântica
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- A coluna ``categoria_b2c`` é populada pelo Motor Semântico (Regex) durante
-- a ingestão no Cômodo 1 (Garagem). Os valores possíveis são:
--
--   ALIMENTO_VAREJO      → único que passa para o app B2C
--   MAQUINARIO_FERRAMENTA → tratores, ferramentas (B2B)
--   INSUMO_AGRICOLA       → fertilizantes, defensivos (B2B)
--   SERVICO_LOGISTICA     → transporte, serviços (B2B)
--   MATERIA_PRIMA_B2B     → borracha, celulose (fallback B2B)
--
-- A unicidade da dimensão permanece por ``nome_produto`` (combinado na carga
-- Python: ``produto + " - " + classificao_produto``), garantindo que
-- "TRATOR 150 16X16 JOHN DEERE" seja distinto de "TRATOR 100 4X4".
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

ALTER TABLE staging.dim_produto
    ADD COLUMN IF NOT EXISTS conab_id_produto    INTEGER,
    ADD COLUMN IF NOT EXISTS classificao_produto  TEXT,
    ADD COLUMN IF NOT EXISTS categoria_b2c        TEXT;

COMMENT ON COLUMN staging.dim_produto.conab_id_produto IS
    'ID interno do produto no sistema CONAB (arquivos LISTA*.txt)';

COMMENT ON COLUMN staging.dim_produto.classificao_produto IS
    'Classificação do produto. Ex: "150 16X16 JOHN DEERE", "NÃO INFORMADO"';

COMMENT ON COLUMN staging.dim_produto.categoria_b2c IS
    'Categoria semântica (preenchida pelo Motor Regex na ingestão). '
    'ALIMENTO_VAREJO é o único que chega ao app B2C.';

-- Índice para filtrar B2C na MV e em consultas
CREATE INDEX IF NOT EXISTS idx_dim_produto_categoria
    ON staging.dim_produto (categoria_b2c);

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 2 — TRIGGER DE ANOMALIA DE PREÇO (Quarentena)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Se o preço inserido exceder **500% da média histórica** do mesmo produto
-- na **mesma UF**, a linha é desviada para ``staging.precos_rejeitados``.
--
-- Por que comparar por UF e não por localidade exata:
--   - Dados CONAB chegam em dois níveis: UF (PrecosMensalUF) e município
--     (ProhortMensal). Um TRATOR de R$ 500k em SP (UF-level) deve ser
--     comparado com TRATORES de R$ 500k em SP (município-level).
--   - A janela histórica por UF garante cobertura máxima.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE FUNCTION staging.trg_valida_anomalia_preco()
RETURNS TRIGGER AS $$
DECLARE
    v_media_historica NUMERIC(14,4);
    v_dados_brutos    JSONB;
    v_uf              CHAR(2);
BEGIN
    -- Resolve a UF da localidade que está sendo inserida
    SELECT uf INTO v_uf
    FROM staging.dim_localidade
    WHERE id_localidade = NEW.id_localidade;

    -- Média histórica do MESMO produto na MESMA UF (qualquer município)
    SELECT AVG(f.preco_medio) INTO v_media_historica
    FROM staging.fact_precos_mensais f
    JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
    WHERE f.id_produto = NEW.id_produto
      AND l.uf         = v_uf
      AND NOT (f.ano = NEW.ano AND f.mes = NEW.mes);

    -- Sem histórico → deixa passar (primeira aparição)
    IF v_media_historica IS NULL THEN
        RETURN NEW;
    END IF;

    -- Preço > 500% da média da UF → quarentena
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
            'Preço excede 500% da média histórica do mesmo produto na mesma UF',
            v_dados_brutos, NEW.batch_id
        );

        RETURN NULL;  -- aborta esta linha, mas não a transação
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION staging.trg_valida_anomalia_preco() IS
    'Desvia para quarentena preços >500% da média do mesmo id_produto + UF';

-- Garante que o trigger existe (DROP + CREATE por segurança)
DROP TRIGGER IF EXISTS trg_valida_anomalia_preco
    ON staging.fact_precos_mensais;

CREATE OR REPLACE TRIGGER trg_valida_anomalia_preco
    BEFORE INSERT ON staging.fact_precos_mensais
    FOR EACH ROW
    WHEN (NEW.preco_medio IS NOT NULL)
    EXECUTE FUNCTION staging.trg_valida_anomalia_preco();

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 3 — STORED PROCEDURE: sp_calcular_sazonalidade
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Calcula a média móvel de 12 meses para cada produto por localidade e
-- classifica o status (semáforo) conforme a regra:
--
--   VERDE     → preço do mês < média anual - 15% (índice < 0.85)
--   AMARELO   → preço entre -15% e +15% da média (índice 0.85 a 1.15)
--   VERMELHO  → preço do mês > média anual + 15% (índice > 1.15)
--   INSUFICIENTE → menos de 6 meses de histórico
--
-- Materializa o resultado em ``mart.sazonalidade_produto``.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE PROCEDURE staging.sp_calcular_sazonalidade(
    p_ano_alvo  SMALLINT DEFAULT NULL,
    p_mes_alvo  SMALLINT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_ano   SMALLINT;
    v_mes   SMALLINT;
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
    v_total  INTEGER;
BEGIN
    v_inicio := clock_timestamp();

    IF p_ano_alvo IS NULL OR p_mes_alvo IS NULL THEN
        SELECT MAX(ano), MAX(mes) INTO v_ano, v_mes
        FROM staging.fact_precos_mensais;
    ELSE
        v_ano := p_ano_alvo;
        v_mes := p_mes_alvo;
    END IF;

    RAISE NOTICE '[sp_calcular_sazonalidade] Alvo: %-%', v_ano, v_mes;

    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade, ano, mes,
        preco_medio, media_movel_12m, indice_sazonalidade,
        status_cor, fonte, calculado_em
    )
    WITH precos_12m AS (
        SELECT
            f.id_produto,
            f.id_localidade,
            f.ano,
            f.mes,
            f.preco_medio,
            AVG(f.preco_medio) OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano, f.mes
                ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
            ) AS media_movel_12m,
            COUNT(*) OVER (
                PARTITION BY f.id_produto, f.id_localidade
                ORDER BY f.ano, f.mes
                ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
            ) AS meses_no_window
        FROM staging.fact_precos_mensais f
        WHERE (f.ano < v_ano OR (f.ano = v_ano AND f.mes <= v_mes))
    )
    SELECT
        p.id_produto,
        p.id_localidade,
        p.ano,
        p.mes,
        p.preco_medio,
        p.media_movel_12m,
        CASE
            WHEN p.media_movel_12m IS NOT NULL AND p.media_movel_12m > 0
            THEN ROUND(p.preco_medio / p.media_movel_12m, 4)
            ELSE NULL
        END AS indice_sazonalidade,
        CASE
            WHEN p.meses_no_window < 6 THEN 'INSUFICIENTE'
            WHEN p.media_movel_12m IS NULL OR p.media_movel_12m = 0
                THEN 'INSUFICIENTE'
            WHEN (p.preco_medio / p.media_movel_12m) < 0.85 THEN 'VERDE'
            WHEN (p.preco_medio / p.media_movel_12m) > 1.15 THEN 'VERMELHO'
            ELSE 'AMARELO'
        END AS status_cor,
        'municipio' AS fonte,
        NOW() AS calculado_em
    FROM precos_12m p
    WHERE p.ano = v_ano AND p.mes = v_mes
        AND p.preco_medio IS NOT NULL
    ON CONFLICT (id_produto, id_localidade, ano, mes)
    DO UPDATE SET
        preco_medio         = EXCLUDED.preco_medio,
        media_movel_12m     = EXCLUDED.media_movel_12m,
        indice_sazonalidade = EXCLUDED.indice_sazonalidade,
        status_cor          = EXCLUDED.status_cor,
        calculado_em        = NOW();

    GET DIAGNOSTICS v_total = ROW_COUNT;
    v_fim := clock_timestamp();

    RAISE NOTICE '[sp_calcular_sazonalidade] Concludo: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

COMMENT ON PROCEDURE staging.sp_calcular_sazonalidade IS
    'Calcula média móvel 12m e classifica semáforo (VERDE/AMARELO/VERMELHO) '
    'por produto+localidade. Upsert no mart.sazonalidade_produto.';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 4 — MATERIALIZED VIEW (O OURO DA PRATELEIRA DE CIMA)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- ESTA VIEW TEM UM FILTRO RÍGIDO: ``WHERE categoria_b2c = 'ALIMENTO_VAREJO'``.
--
-- Regra da Sala de Estar:
--   TRATORES, SERVIÇOS E INSUMOS AGRÍCOLAS FORAM ISOLADOS VIA REGEX NA
--   INGESTÃO (CÔMODO 1) E SÃO SUMARIAMENTE PROIBIDOS DE CHEGAR AO BANCO
--   DE DADOS DO APLICATIVO B2C FINAL. Este filtro é a última barreira.
--   Se um "TRATOR 150 16X16 JOHN DEERE" (R$ 500.000,00) aparecer aqui,
--   o consumidor de supermercado vai ver um trator no lugar do tomate.
--   Isso é uma falha arquitetural e deve ser tratada como bug crítico.
--
-- Colunas expostas para a API:
--   - ``produto``, ``uf``, ``municipio`` — identificação
--   - ``status_cor`` — VERDE/AMARELO/VERMELHO (único dado para o frontend)
--   - ``preco_medio`` — **disponível apenas para auditoria interna**
--     (o frontend B2C NUNCA exibe preços em R$)
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
  AND p.categoria_b2c = 'ALIMENTO_VAREJO'   -- ← barreira antifraude B2B
ORDER BY s.ano DESC, s.mes DESC, p.nome_produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'View otimizada para a API B2C. Filtra APENAS ALIMENTO_VAREJO. '
    'Tratores, insumos e serviços são excluídos na MV (barreira final).';

CREATE UNIQUE INDEX IF NOT EXISTS idx_vw_api_unique
    ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

CREATE INDEX IF NOT EXISTS idx_vw_api_filtro
    ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);

-- Refresh inicial da MV
REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 5 — STORED PROCEDURE: sp_executar_carga_completa (Mestre)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Orquestra o ciclo completo: cálculo de sazonalidade → refresh da MV.
-- Chamado pelo script Python ao final de cada carga.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE PROCEDURE staging.sp_executar_carga_completa()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio      TIMESTAMPTZ;
    v_fim         TIMESTAMPTZ;
    v_ultimo_ano  SMALLINT;
    v_ultimo_mes  SMALLINT;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Iniciando...';

    ANALYZE staging.fact_precos_mensais;

    SELECT MAX(ano), MAX(mes) INTO v_ultimo_ano, v_ultimo_mes
    FROM staging.fact_precos_mensais;

    CALL staging.sp_calcular_sazonalidade(v_ultimo_ano, v_ultimo_mes);

    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Concludo em % seg',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 6 — PERMISSÕES
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;

COMMIT;
