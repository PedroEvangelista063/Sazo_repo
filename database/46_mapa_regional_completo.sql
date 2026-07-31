-- ============================================================================
-- QUERO COMPRAR — Fase 46: Mapa Regional Completo (Consolidação Final)
-- PostgreSQL 16+
--
-- OBJETIVO:
--   Consolidar todos os passos anteriores em uma única view/função que
--   mostre, por UF e produto normalizado:
--     1. Produto (já normalizado pelo Passo 1)
--     2. Fluxo de abastecimento (origem → destino, Passo 3+4)
--     3. Dados de preço (real ou FLUXO_PROXY, Passo 2)
--     4. Status de sazonalidade (semáforo)
--     5. Cobertura (se tem preço, se tem sazonalidade, se tem fluxo)
--
--   Isso permite responder perguntas como:
--     - Quais produtos cada UF RECEBE de fora? (tipo='importado')
--     - Quais produtos cada UF PRODUZ/ENVIA? (tipo='exportado')
--     - Quais produtos têm preço real vs. proxy vs. nenhum?
--     - Qual o status_cor atual de cada produto na UF?
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: View Consolidada do Mapa Regional
-- ============================================================================
-- Uso: SELECT * FROM mart.vw_mapa_regional_completo WHERE uf = 'TO';
--      SELECT * FROM mart.vw_mapa_regional_completo WHERE uf IN ('AC','AM','AP');

CREATE OR REPLACE VIEW mart.vw_mapa_regional_completo AS
WITH
-- Produtos normalizados (Passo 1)
produtos_norm AS (
    SELECT
        p.id_produto,
        p.nome_produto,
        staging.fn_normalizar_nome_produto(p.nome_produto) AS nome_normalizado,
        p.categoria_b2c,
        p.status_fonte
    FROM staging.dim_produto p
),
-- Última sazonalidade por (produto, uf)
ultima_sazonalidade AS (
    SELECT DISTINCT ON (sp.id_produto, l.uf)
        sp.id_produto,
        l.uf,
        sp.status_cor,
        sp.is_forecast,
        sp.baseline_confianca,
        sp.forecast_method,
        sp.ano,
        sp.mes,
        sp.preco_atual
    FROM mart.sazonalidade_produto sp
    JOIN staging.dim_localidade l ON l.id_localidade = sp.id_localidade
    WHERE l.uf != 'BR'
      AND sp.status_cor IN ('VERDE', 'AMARELO', 'VERMELHO')
    ORDER BY sp.id_produto, l.uf, sp.ano DESC, sp.mes DESC
),
-- Preços em fact_precos_mensais (inclui FLUXO_PROXY do Passo 2)
precos_por_uf AS (
    SELECT
        staging.fn_normalizar_nome_produto(p.nome_produto) AS nome_norm,
        l.uf,
        COUNT(*) AS qtd_registros,
        COUNT(DISTINCT fp.fonte) AS qtd_fontes,
        BOOL_OR(fp.fonte = 'FLUXO_PROXY') AS tem_proxy,
        BOOL_OR(fp.fonte != 'FLUXO_PROXY') AS tem_real,
        MAX(fp.preco_medio) AS preco_max,
        AVG(fp.preco_medio) AS preco_medio,
        MIN(fp.ano || '-' || LPAD(fp.mes::TEXT, 2, '0')) AS periodo_de,
        MAX(fp.ano || '-' || LPAD(fp.mes::TEXT, 2, '0')) AS periodo_ate
    FROM staging.fact_precos_mensais fp
    JOIN staging.dim_produto p ON p.id_produto = fp.id_produto
    JOIN staging.dim_localidade l ON l.id_localidade = fp.id_localidade
    WHERE l.uf != 'BR'
    GROUP BY staging.fn_normalizar_nome_produto(p.nome_produto), l.uf
),
-- Regiões (para resolver destino_regiao_id)
regioes AS (
    SELECT * FROM (VALUES
        ('norte'::TEXT, 'Norte'::TEXT, 1::INT),
        ('nordeste', 'Nordeste', 2),
        ('centro-oeste', 'Centro-Oeste', 3),
        ('sudeste', 'Sudeste', 4),
        ('sul', 'Sul', 5)
    ) AS r(id, nome, ordem)
),
-- Fluxos consolidados por (produto, uf_destino)
fluxos_agg AS (
    SELECT
        f.id_produto,
        f.destino_uf,
        STRING_AGG(DISTINCT f.origem_uf, ', ' ORDER BY f.origem_uf) FILTER (WHERE f.tipo = 'importado') AS origens_importado,
        STRING_AGG(DISTINCT f.origem_uf, ', ' ORDER BY f.origem_uf) FILTER (WHERE f.tipo = 'exportado') AS origens_exportado,
        STRING_AGG(DISTINCT f.origem_polo, ', ' ORDER BY f.origem_polo) AS polos_origem,
        BOOL_OR(f.tipo = 'autossuficiente') AS autossuficiente,
        COUNT(*) AS qtd_fluxos
    FROM staging.dim_fluxo_abastecimento f
    GROUP BY f.id_produto, f.destino_uf
)
-- Query final
SELECT
    -- Dimensão UF
    l.uf,
    l.municipio_nome AS municipio_referencia,

    -- Produto (normalizado)
    pn.id_produto,
    pn.nome_produto AS produto_original,
    pn.nome_normalizado,
    pn.categoria_b2c,
    pn.status_fonte,

    -- Fluxos de abastecimento (Passo 3+4)
    COALESCE(fa.origens_importado, '') AS origens_fornecedoras,
    COALESCE(fa.origens_exportado, '') AS origens_compradoras,
    COALESCE(fa.polos_origem, '') AS polos_origem,
    COALESCE(fa.autossuficiente, FALSE) AS autossuficiente,
    COALESCE(fa.qtd_fluxos, 0)::INTEGER AS qtd_fluxos,

    -- Preços em fact_precos_mensais (Passo 2)
    CASE
        WHEN pc.tem_real THEN 'REAL'
        WHEN pc.tem_proxy THEN 'PROXY'
        ELSE 'AUSENTE'
    END AS tipo_preco,
    COALESCE(pc.qtd_registros, 0)::INTEGER AS qtd_registros_preco,
    COALESCE(pc.qtd_fontes, 0)::INTEGER AS qtd_fontes_preco,
    pc.periodo_de,
    pc.periodo_ate,
    pc.preco_medio,
    pc.preco_max,

    -- Sazonalidade (status_cor do mart)
    sz.status_cor,
    CASE sz.status_cor
        WHEN 'VERDE'    THEN '🟢 Safra'
        WHEN 'AMARELO'  THEN '🟡 Normal'
        WHEN 'VERMELHO' THEN '🔴 Entressafra'
        ELSE '⚪ Indisponível'
    END AS status_cor_label,
    sz.is_forecast,
    sz.baseline_confianca,
    sz.forecast_method,
    sz.ano AS ultimo_ano_sazonalidade,
    sz.mes AS ultimo_mes_sazonalidade,

    -- Indicadores de cobertura
    CASE
        WHEN pc.tem_real   THEN '🟢 Dado real'
        WHEN pc.tem_proxy  THEN '🟡 Proxy (FLUXO_PROXY)'
        WHEN fa.qtd_fluxos > 0 THEN '🔵 Tem fluxo, sem preço'
        ELSE '⚪ Sem dados'
    END AS cobertura_status,

    -- Região do destino
    r.nome AS regiao_destino

FROM (
    -- Uma linha por UF (pega a localidade agregada, evitando duplicatas no CROSS JOIN)
    SELECT DISTINCT ON (dl.uf) dl.id_localidade, dl.uf, dl.municipio_nome
    FROM staging.dim_localidade dl
    WHERE dl.uf != 'BR'
    ORDER BY dl.uf, dl.municipio_id NULLS FIRST
) l
-- Produtos normalizados (cross join com UF para mostrar TODOS os produtos)
CROSS JOIN (SELECT DISTINCT nome_normalizado, id_produto, nome_produto, categoria_b2c, status_fonte FROM produtos_norm) pn
-- Left joins preenchem com NULL onde não há dados
LEFT JOIN precos_por_uf pc ON pc.uf = l.uf AND pc.nome_norm = pn.nome_normalizado
LEFT JOIN ultima_sazonalidade sz ON sz.id_produto = pn.id_produto AND sz.uf = l.uf
LEFT JOIN fluxos_agg fa ON fa.id_produto = pn.id_produto AND fa.destino_uf = l.uf
LEFT JOIN regioes r ON r.id = (SELECT f2.destino_regiao_id FROM staging.dim_fluxo_abastecimento f2 WHERE f2.id_produto = pn.id_produto AND f2.destino_uf = l.uf LIMIT 1)
WHERE pn.nome_normalizado IN (
        'TOMATE','BATATA','CEBOLA','CENOURA','ALFACE','BANANA',
        'MELANCIA','MANGA','MACA','LARANJA','FEIJAO','FEIJAO COMUM CORES',
        'FEIJAO COMUM PRETO','FEIJAO CAUPI','ARROZ','MANDIOCA','MILHO',
        'ALHO','BATATA DOCE','MORANGO','GOIABA','PEPINO','REPOLHO',
        'BETERRABA','VAGEM','COUVE','ABACATE','ABACAXI','BERINJELA',
        'CHUCHU','INHAME','COUVE-FLOR','QUIABO','TANGERINA','MAMAO',
        'UVA','CAFE','LEITE DE VACA','CARNE BOVINA','CARNE CAPRINA',
        'CARNE DE FRANGO','CARNE OVINA','OVOS DE GALINHA','OLEO DE SOJA',
        'ACUCAR','PAO','MANTEIGA','MACARRAO','SAL','COCO'
  )
ORDER BY l.uf, pn.nome_normalizado;

COMMENT ON VIEW mart.vw_mapa_regional_completo IS
    'Mapa regional completo: para cada UF + produto normalizado, mostra fluxos '
    'de abastecimento (origem/destino), tipo de preço (real/proxy/ausente), '
    'status_cor da sazonalidade e indicadores de cobertura. '
    'Consolida Passos 1, 2, 3+4 do projeto.';


-- ============================================================================
-- SEÇÃO 2: Função de Relatório Textual por UF
-- ============================================================================
-- Uso: SELECT * FROM staging.fn_relatorio_mapa_regional('AC');
--      SELECT * FROM staging.fn_relatorio_mapa_regional(NULL) → todas UFs

CREATE OR REPLACE FUNCTION staging.fn_relatorio_mapa_regional(
    p_uf TEXT DEFAULT NULL
)
RETURNS TABLE(
    uf              TEXT,
    produtos_total  BIGINT,
    com_preco_real  BIGINT,
    com_preco_proxy BIGINT,
    sem_preco       BIGINT,
    com_fluxo       BIGINT,
    com_sazonalidade BIGINT,
    status_verde    BIGINT,
    status_amarelo  BIGINT,
    status_vermelho BIGINT,
    cobertura_pct   NUMERIC(5,1)
)
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.uf::TEXT,
        COUNT(*)::BIGINT AS produtos_total,
        COUNT(*) FILTER (WHERE m.tipo_preco = 'REAL')::BIGINT AS com_preco_real,
        COUNT(*) FILTER (WHERE m.tipo_preco = 'PROXY')::BIGINT AS com_preco_proxy,
        COUNT(*) FILTER (WHERE m.tipo_preco = 'AUSENTE')::BIGINT AS sem_preco,
        COUNT(*) FILTER (WHERE m.qtd_fluxos > 0)::BIGINT AS com_fluxo,
        COUNT(*) FILTER (WHERE m.status_cor IS NOT NULL)::BIGINT AS com_sazonalidade,
        COUNT(*) FILTER (WHERE m.status_cor = 'VERDE')::BIGINT AS status_verde,
        COUNT(*) FILTER (WHERE m.status_cor = 'AMARELO')::BIGINT AS status_amarelo,
        COUNT(*) FILTER (WHERE m.status_cor = 'VERMELHO')::BIGINT AS status_vermelho,
        ROUND(
            COUNT(*) FILTER (WHERE m.tipo_preco IN ('REAL', 'PROXY'))::NUMERIC
            / NULLIF(COUNT(*), 0) * 100, 1
        ) AS cobertura_pct
    FROM mart.vw_mapa_regional_completo m
    WHERE (p_uf IS NULL OR m.uf = p_uf)
    GROUP BY m.uf
    ORDER BY m.uf;

    -- Se nenhum resultado, avisa
    IF NOT FOUND THEN
        RETURN QUERY
        SELECT
            COALESCE(p_uf, 'TODAS'),
            0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT,
            0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT,
            0.0::NUMERIC(5,1);
    END IF;
END;
$$;

COMMENT ON FUNCTION staging.fn_relatorio_mapa_regional IS
    'Relatório consolidado do mapa regional por UF. Se p_uf=NULL, retorna '
    'todas as UFs. Mostra: total de produtos, quantos com preço real/proxy, '
    'quantos sem preço, quantos com fluxo, quantos com sazonalidade, '
    'distribuição do status_cor e % de cobertura.';


-- ============================================================================
-- SEÇÃO 3: Permissões
-- ============================================================================

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_api_reader') THEN
        GRANT SELECT ON mart.vw_mapa_regional_completo TO role_api_reader;
        GRANT EXECUTE ON FUNCTION staging.fn_relatorio_mapa_regional(TEXT) TO role_api_reader;
    END IF;

    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_etl_writer') THEN
        GRANT SELECT ON mart.vw_mapa_regional_completo TO role_etl_writer;
        GRANT EXECUTE ON FUNCTION staging.fn_relatorio_mapa_regional(TEXT) TO role_etl_writer;
    END IF;
END
$$;

COMMIT;
