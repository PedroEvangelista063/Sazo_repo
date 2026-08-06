-- ============================================================================
-- QUERO COMPRAR — MIGRAÇÃO 67: Deduplicação Semântica + MDM de Produtos
-- (Grade Sazonal Nacional BR)
--
-- PROBLEMA
--   staging.dim_produto tem UNIQUE em nome_produto → a duplicidade é SEMÂNTICA:
--   variações textuais do MESMO produto ('Cenoura'/'cenoura'/'CENOURA',
--   'TOMATE - NÃO INFORMADO'/'tomate - não informado', 'TOMATE - ITALIANO' /
--   'Tomate Italiano - Pizzadoro'...) têm id_produto diferentes. Ao agrupar a
--   Materialized View por nome na mart.fn_br_nacional_sazonalidade, cada
--   variação vira uma linha distinta por (produto, mês) → explosão cartesiana
--   e grade sazonal poluída.
--
-- SOLUÇÃO
--   1. mart.fn_sanitizar_nome_produto(): normaliza o nome (CAIXA ALTA + sem
--      acentos + colapso de espaços + hífen espaçado ' - '→' ' + asteriscos
--      removidos) para servir de CHAVE SEMÂNTICA.
--   2. mart.dim_produto_canonico: tabela MDM (Master Data Management) que mapeia
--      cada id_produto_original → nome_sanitizado → nome_canonico (nome do
--      MESTRE) + id_produto_mestre + id_categoria_mestre. Mestre eleito por:
--        1º prioridade de categoria (HORTIFRUTIGRANJEIROS=11 > PESCADOS=5 >
--           PROTEINAS=6 > CEREAIS_GRAOS=7 > FRUTAS=1 > LEGUMES=2 > VERDURAS=3 >
--           BEBIDAS=8 > ALIMENTO_VAREJO=9 > OUTROS=10 > FLORES=4),
--        2º legibilidade do nome (Title Case/acentuado > minúsculo > MAIÚSCULO),
--        3º id_produto ASC (mestre = id mais antigo entre empates).
--      A auditoria Fase 1 confirmou: 113/128 grupos têm conflito de categoria e
--      TODOS são o par {9=ALIMENTO_VAREJO, 11=HORTIFRUTIGRANJEIROS} → a
--      prioridade HORTIFRUTIGRANJEIROS resolve 100% dos conflitos.
--   3. Reescrita de mart.fn_br_nacional_sazonalidade (MESMA assinatura e MESMO
--      RETURNS TABLE da original — contrato preservado) e de
--      mart.fn_br_nacional_por_mes: agregação final por (nome_canonico, mes),
--      categoria = categoria do MESTRE, sem SELECT DISTINCT.
--
-- ESCOPO
--   A canonicalização vive SÓ em mart (imutabilidade de raw/staging garantida:
--   nenhum UPDATE/DELETE em raw/staging). A MV física vw_api_produtos_sazonalidade
--   NÃO é tocada (o backend faz REFRESH em background).
--
-- ROLLBACK
--   Restaurar as funções originais (backup em /tmp/opencode/fn_def_original_backup.sql):
--     \i /tmp/opencode/fn_def_original_backup.sql   -- fn_br_nacional_sazonalidade
--   fn_br_nacional_por_mes original está documentada no git (arquivo 66_hotfix_br_quality_gate.sql
--   / migration 66). A tabela dim_produto_canonico e a fn_sanitizar_nome_produto
--   podem ser descartadas com:
--     DROP TABLE IF EXISTS mart.dim_produto_canonico;
--     DROP FUNCTION IF EXISTS mart.fn_sanitizar_nome_produto(text);
-- ============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- ============================================================================
-- FASE 1 — mart.fn_sanitizar_nome_produto(text)
-- Chave semântica determinística e imutável.
--   upper(trim(btrim(...))) → CAIXA ALTA;
--   translate() remove acentos (Á→A, À→A, Â→A, Ã→A, Ä→A, É→E, È→E, Ê→E, Ë→E,
--     Í→I, Ì→I, Î→I, Ï→I, Ó→O, Ò→O, Ô→O, Õ→O, Ö→O, Ú→U, Ù→U, Û→U, Ü→U, Ç→C —
--     como fazemos upper() antes, só o conjunto maiúsculo é necessário);
--   regexp_replace '\s+'→' ' colapsa espaços múltiplos;
--   regexp_replace '\s+-\s+'→' ' converte hífen espaçado CONAB ('TOMATE - NÃO
--     INFORMADO'→'TOMATE NAO INFORMADO') preservando tokens ('NAO INFORMADO');
--   regexp_replace '\*+' remove asteriscos;
--   btrim(...,' -') remove pontuação solta nas bordas ('-ALFACE'→'ALFACE').
--   Hífens NÃO espaçados ('00-18-18', 'couve-flor') são preservados — não são
--   padrão CONAB e não devem destruir tokens.
-- ============================================================================

CREATE OR REPLACE FUNCTION mart.fn_sanitizar_nome_produto(p_nome text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $function$
SELECT btrim(
    regexp_replace(
        regexp_replace(
            regexp_replace(
                translate(
                    upper(btrim(p_nome)),
                    'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ',
                    'AAAAAEEEEIIIIOOOOOUUUUC'
                ),
                '\s+', ' ', 'g'
            ),
            '\s+-\s+', ' ', 'g'
        ),
        '\*+', '', 'g'
    ),
    ' -'
);
$function$;

COMMENT ON FUNCTION mart.fn_sanitizar_nome_produto(text) IS
'Normaliza nome de produto para chave semântica MDM: CAIXA ALTA, sem acentos, '
'espaços colapsados, hífen espaçado convertido em espaço, asteriscos removidos, '
'bordas sem pontuação. Determinística e IMMUTABLE.';

-- ============================================================================
-- FASE 2 — mart.dim_produto_canonico (MDM)
-- Cada id_produto_original aparece EXATAMENTE uma vez. Grupos singulares também
-- entram (id_produto_mestre = ele mesmo) para o JOIN valer para TODOS os
-- produtos. nome_canonico = nome_produto_original do MESTRE eleito.
-- ============================================================================

CREATE TABLE IF NOT EXISTS mart.dim_produto_canonico (
    id_produto_original   integer      PRIMARY KEY
                            REFERENCES staging.dim_produto (id_produto),
    nome_produto_original text         NOT NULL,
    nome_sanitizado       text         NOT NULL,
    nome_canonico         text         NOT NULL,
    id_produto_mestre     integer      NOT NULL,
    id_categoria_mestre   smallint,
    criado_em             timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE mart.dim_produto_canonico IS
'MDM semântico de produtos: mapeia cada id de staging para o nome canônico e o '
'mestre do grupo de variações textuais. Categoria do mestre = categoria canônica.';

-- Recarregamento idempotente (migration reaplicável sem duplicar).
TRUNCATE TABLE mart.dim_produto_canonico;

INSERT INTO mart.dim_produto_canonico (
    id_produto_original,
    nome_produto_original,
    nome_sanitizado,
    nome_canonico,
    id_produto_mestre,
    id_categoria_mestre
)
WITH produtos_normalizados AS (
    SELECT
        dp.id_produto,
        dp.nome_produto,
        dp.id_categoria,
        mart.fn_sanitizar_nome_produto(dp.nome_produto) AS nome_sanitizado,
        -- 1º critério: prioridade de categoria (HORTIFRUTIGRANJEIROS resolve 100%
        -- dos conflitos {ALIMENTO_VAREJO, HORTIFRUTIGRANJEIROS} da auditoria).
        CASE dp.id_categoria
            WHEN 11 THEN  1 -- HORTIFRUTIGRANJEIROS
            WHEN  5 THEN  2 -- PESCADOS
            WHEN  6 THEN  3 -- PROTEINAS
            WHEN  7 THEN  4 -- CEREAIS_GRAOS
            WHEN  1 THEN  5 -- FRUTAS
            WHEN  2 THEN  6 -- LEGUMES
            WHEN  3 THEN  7 -- VERDURAS
            WHEN  8 THEN  8 -- BEBIDAS
            WHEN  9 THEN  9 -- ALIMENTO_VAREJO
            WHEN 10 THEN 10 -- OUTROS
            WHEN  4 THEN 11 -- FLORES
            ELSE 12
        END AS prio_categoria,
        -- 2º critério: legibilidade do nome (Title Case/acentuado > minúsculo >
        -- TODO MAIÚSCULO).
        CASE
            WHEN dp.nome_produto = upper(dp.nome_produto) THEN 3
            WHEN dp.nome_produto = lower(dp.nome_produto) THEN 2
            ELSE 1
        END AS prio_legibilidade
    FROM staging.dim_produto dp
),
com_ranking AS (
    SELECT
        pn.*,
        ROW_NUMBER() OVER (
            PARTITION BY pn.nome_sanitizado
            ORDER BY pn.prio_categoria, pn.prio_legibilidade, pn.id_produto
        ) AS rn_mestre
    FROM produtos_normalizados pn
),
mestres AS (
    SELECT
        nome_sanitizado,
        id_produto          AS id_produto_mestre,
        nome_produto        AS nome_canonico,
        id_categoria        AS id_categoria_mestre
    FROM com_ranking
    WHERE rn_mestre = 1
)
SELECT
    cr.id_produto,
    cr.nome_produto,
    cr.nome_sanitizado,
    m.nome_canonico,
    m.id_produto_mestre,
    m.id_categoria_mestre
FROM com_ranking cr
JOIN mestres m ON m.nome_sanitizado = cr.nome_sanitizado
ORDER BY cr.id_produto;

-- Índices (idempotentes): PK já garante UNIQUE(id_produto_original); índice
-- extra para aceleração do JOIN por nome_sanitizado.
CREATE INDEX IF NOT EXISTS idx_dim_produto_canonico_sanitizado
    ON mart.dim_produto_canonico (nome_sanitizado);

-- ============================================================================
-- FASE 3 — Reescrita de mart.fn_br_nacional_sazonalidade
-- MESMA assinatura (p_ano, p_categoria DEFAULT NULL, p_min_ufs DEFAULT 1) e MESMO
-- RETURNS TABLE da função original (contrato idêntico, preservando ordem e tipos).
-- Mudanças:
--   (a) LEFT JOIN mart.dim_produto_canonico dc ON dc.id_produto_original = v.id_produto
--       e LEFT JOIN staging.dim_categoria cat_mestre (categoria do mestre);
--   (b) produto = COALESCE(dc.nome_canonico, v.produto); categoria =
--       COALESCE(cat_mestre.nome_categoria, v.categoria, 'ALIMENTO_VAREJO');
--   (c) agregação final estrita por (nome_canonico, mes) — sem SELECT DISTINCT;
--   (d) ids fundidos: status_cor/ano_referencia/tipo_dado/forecast_method =
--       MODE() WITHIN GROUP (mesmo padrão da agregação UF→nacional já existente);
--       baseline_confianca/calculado_em = MAX. Como o RETURNS TABLE original NÃO
--       projeta preços (preco_referencia/preco_atual/preco_exibido são calculados
--       na MV/âncora, que NÃO é alterada), não há agregação de preço aqui.
--   Todos os filtros originais preservados (fonte/status via MV, is_forecast,
--   tipo_dado REAL_ATUAL/HISTORICO_BASE, idade <= 1, procedencia != sem_historico_real,
--   p_categoria sobre a categoria canônica, p_min_ufs). LEFT JOIN garante que um
--   id eventualmente fora da tabela MDM continua aparecendo com o próprio nome.
-- ============================================================================

CREATE OR REPLACE FUNCTION mart.fn_br_nacional_sazonalidade(p_ano integer, p_categoria text DEFAULT NULL::text, p_min_ufs integer DEFAULT 1)
 RETURNS TABLE(produto text, classificao_produto text, categoria text, mes integer, data_referencia_atual text, status_cor text, is_forecast boolean, baseline_confianca numeric, total_ufs bigint, forecast_method text, calculado_em timestamp with time zone, ano_referencia integer, tipo_dado text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_categoria_filter TEXT := COALESCE(p_categoria, '%%');
    v_min_ufs INTEGER := COALESCE(p_min_ufs, 1);
BEGIN
    RETURN QUERY
    WITH produto_canonico AS (
        -- Nível 0: resolve o nome canônico e a categoria canônica (mestre) por id.
        SELECT
            v.id_produto,
            COALESCE(dc.nome_canonico, v.produto) AS produto,
            v.classificao_produto,
            COALESCE(cat_mestre.nome_categoria, v.categoria, 'ALIMENTO_VAREJO') AS categoria,
            v.uf,
            v.mes,
            v.status_cor,
            v.is_forecast,
            v.baseline_confianca,
            v.forecast_method,
            v.calculado_em,
            v.ano_referencia,
            v.tipo_dado
        FROM mart.vw_api_produtos_sazonalidade v
        LEFT JOIN mart.dim_produto_canonico dc
               ON dc.id_produto_original = v.id_produto
        LEFT JOIN staging.dim_categoria cat_mestre
               ON cat_mestre.id_categoria = dc.id_categoria_mestre
        WHERE v.ano = p_ano
          AND (p_categoria IS NULL
               OR COALESCE(cat_mestre.nome_categoria, v.categoria, 'ALIMENTO_VAREJO') ILIKE v_categoria_filter)
          AND v.tipo_dado IN ('REAL_ATUAL', 'HISTORICO_BASE')
          AND COALESCE(v.idade_dado_anos, 0) <= 1
          AND COALESCE(v.metadado_transparencia->>'procedencia', '') NOT LIKE 'sem_historico_real%'
    ),
    uf_por_mes AS (
        -- Nível 1: consolida por (produto_canonico, UF, mes) — moda dentro da UF.
        -- ids fundidos da MESMA UF são agregados aqui (MODE de status, BOOL_OR de
        -- forecast, MAX de confianca/calculado) eliminando o produto cartesiano.
        SELECT
            pc.produto,
            pc.classificao_produto,
            COALESCE(pc.categoria, 'ALIMENTO_VAREJO') AS categoria_final,
            pc.uf,
            pc.mes,
            MODE() WITHIN GROUP (ORDER BY pc.status_cor) AS uf_status_cor,
            BOOL_OR(pc.is_forecast)                     AS uf_forecast,
            MAX(pc.baseline_confianca)                  AS uf_confianca,
            MODE() WITHIN GROUP (ORDER BY pc.forecast_method) AS uf_forecast_method,
            MAX(pc.calculado_em)                        AS uf_calculado_em,
            MODE() WITHIN GROUP (ORDER BY pc.ano_referencia)  AS uf_ano_ref,
            MODE() WITHIN GROUP (ORDER BY pc.tipo_dado)       AS uf_tipo_dado
        FROM produto_canonico pc
        GROUP BY pc.produto, pc.classificao_produto, categoria_final, pc.uf, pc.mes
    )
    -- Nível 2: agrega por (nome_canonico, mes) — moda da moda entre UFs.
    -- Granularidade ESTRITA: GROUP BY (produto, mes); categoria e classificacao
    -- derivam por MODE (uniformes por grupo canônico — categoria vem do mestre).
    SELECT
        upm.produto,
        MODE() WITHIN GROUP (ORDER BY upm.classificao_produto) AS classificao_produto,
        MODE() WITHIN GROUP (ORDER BY upm.categoria_final)     AS categoria,
        upm.mes,
        (p_ano || '-' || LPAD(upm.mes::TEXT, 2, '0'))::TEXT AS data_ref,
        MODE() WITHIN GROUP (ORDER BY upm.uf_status_cor)       AS status_cor_nac,
        BOOL_OR(upm.uf_forecast)                              AS is_forecast_nac,
        MAX(upm.uf_confianca)                                 AS confianca_nac,
        COUNT(DISTINCT upm.uf)                                AS total_ufs_nac,
        MODE() WITHIN GROUP (ORDER BY upm.uf_forecast_method)  AS forecast_method_nac,
        MAX(upm.uf_calculado_em)                              AS calculado_em_nac,
        MODE() WITHIN GROUP (ORDER BY upm.uf_ano_ref)          AS ano_referencia_nac,
        MODE() WITHIN GROUP (ORDER BY upm.uf_tipo_dado)        AS tipo_dado_nac
    FROM uf_por_mes upm
    GROUP BY upm.produto, upm.mes
    HAVING COUNT(DISTINCT upm.uf) >= v_min_ufs
    ORDER BY upm.produto, upm.mes;
END;
$function$;

-- ============================================================================
-- FASE 4 — Reescrita de mart.fn_br_nacional_por_mes (mesma fonte/MV, mesma API)
-- MESMA assinatura e MESMO RETURNS TABLE da versão 66. Aplica o MESMO padrão de
-- canonicalização: JOIN na MDM, categoria do mestre, agregação por nome canônico.
-- Preços de ids fundidos = média simples (AVG) no nível (canônico, UF) — escolha
-- documentada: o RETURNS TABLE desta função projeta preço, e a média simples é o
-- comportamento determinístico e estável exigido pela auditoria.
-- ============================================================================

CREATE OR REPLACE FUNCTION mart.fn_br_nacional_por_mes(p_ano integer, p_mes integer, p_categoria text DEFAULT NULL::text, p_limit integer DEFAULT NULL::integer, p_offset integer DEFAULT 0)
 RETURNS TABLE(produto text, classificao_produto text, categoria text, uf text, municipio text, municipio_id text, ano integer, mes integer, data_referencia_atual text, preco_referencia numeric, preco_atual numeric, usou_fallback_12m boolean, preco_estimado boolean, status_cor text, fonte text, is_forecast boolean, total_ufs bigint, confianca_baseline numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_categoria_filter TEXT := COALESCE(p_categoria, '%%');
BEGIN
    RETURN QUERY
    WITH produto_canonico AS (
        SELECT
            v.id_produto,
            COALESCE(dc.nome_canonico, v.produto) AS produto,
            v.classificao_produto,
            COALESCE(cat_mestre.nome_categoria, v.categoria, 'ALIMENTO_VAREJO') AS categoria,
            v.uf,
            v.preco_referencia,
            v.preco_atual,
            v.usou_fallback_12m,
            v.preco_estimado,
            v.status_cor,
            v.is_forecast,
            v.baseline_confianca
        FROM mart.vw_api_produtos_sazonalidade v
        LEFT JOIN mart.dim_produto_canonico dc
               ON dc.id_produto_original = v.id_produto
        LEFT JOIN staging.dim_categoria cat_mestre
               ON cat_mestre.id_categoria = dc.id_categoria_mestre
        WHERE v.ano = p_ano
          AND v.mes = p_mes
          AND (p_categoria IS NULL
               OR COALESCE(cat_mestre.nome_categoria, v.categoria, 'ALIMENTO_VAREJO') ILIKE v_categoria_filter)
          AND v.tipo_dado IN ('REAL_ATUAL', 'HISTORICO_BASE')
          AND COALESCE(v.idade_dado_anos, 0) <= 1
          AND COALESCE(v.metadado_transparencia->>'procedencia', '') NOT LIKE 'sem_historico_real%'
    ),
    uf_consolidado AS (
        -- Nível 1: (produto_canonico, UF) — AVG de preço (média simples dos ids
        -- fundidos), MODE de status, BOOL_OR de flags, peso = registros da UF.
        SELECT
            pc.produto,
            pc.classificao_produto,
            COALESCE(pc.categoria, 'ALIMENTO_VAREJO') AS categoria_final,
            pc.uf,
            COUNT(*)::NUMERIC AS peso_uf,
            AVG(pc.preco_referencia) AS uf_preco_ref,
            AVG(pc.preco_atual)      AS uf_preco_atual,
            BOOL_OR(pc.usou_fallback_12m) AS uf_fallback,
            BOOL_OR(pc.preco_estimado)    AS uf_estimado,
            BOOL_OR(pc.is_forecast)       AS uf_forecast,
            MODE() WITHIN GROUP (ORDER BY pc.status_cor) AS uf_status_cor,
            MAX(pc.baseline_confianca)    AS uf_confianca
        FROM produto_canonico pc
        GROUP BY pc.produto, pc.classificao_produto, categoria_final, pc.uf
    )
    -- Nível 2: nacional por (produto_canonico, mês) — média ponderada por UF.
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
        COUNT(DISTINCT uf.uf)    AS total_ufs_nac,
        ROUND(
            SUM(uf.uf_confianca * uf.peso_uf) / NULLIF(SUM(uf.peso_uf), 0),
            4
        ) AS confianca_baseline_nac
    FROM uf_consolidado uf
    GROUP BY uf.produto, uf.classificao_produto, uf.categoria_final
    HAVING COUNT(DISTINCT uf.uf) >= 5
    ORDER BY status_cor_nac, uf.produto
    LIMIT p_limit OFFSET p_offset;
END;
$function$;

COMMIT;

-- ============================================================================
-- ROLLBACK
--   Funções originais: backup em /tmp/opencode/fn_def_original_backup.sql
--     \i /tmp/opencode/fn_def_original_backup.sql
--   fn_br_nacional_por_mes original: migration 66 (66_hotfix_br_quality_gate.sql).
--   Objetos novos descartáveis:
--     DROP TABLE  IF EXISTS mart.dim_produto_canonico;
--     DROP FUNCTION IF EXISTS mart.fn_sanitizar_nome_produto(text);
-- ============================================================================
