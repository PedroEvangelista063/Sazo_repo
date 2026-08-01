-- ============================================================================
-- QUERO COMPRAR — Fase 60: Completar Fluxos (Açaí, Castanha, Melão)
-- Descricao: Expande fn_normalizar_nome_produto para colapsar variantes de
--             AÇAÍ/ACAI, CASTANHA e MELÃO/MELAO no canônico, cadastra o
--             produto canônico AÇAÍ em dim_produto (não existia) e insere
--             os 6 fluxos que a migration 48 não conseguiu casar.
-- PostgreSQL 16+
--
-- NOTA IMPORTANTE (166 vs 165):
--   config/flows.json contém 166 entradas, mas apenas 165 combinações
--   únicas (item, origem_uf, destino_uf, tipo): os fluxos id 25 e id 93
--   (Melão RN→CE, preços 'Baixo' e 'Médio') compartilham a mesma rota/tipo.
--   Como a constraint única uq_fluxo_produto_uf é
--   (id_produto, origem_uf, destino_uf, tipo) — e ambos resolvem para o
--   mesmo produto canônico MELÃO (id 10439, 133 preços) — o segundo INSERT
--   é descartado pelo ON CONFLICT DO NOTHING. Portanto o banco passa a ter
--   165 linhas (todos os fluxos únicos), o que é o máximo do modelo atual.
-- ============================================================================

BEGIN;

-- ============================================================================
-- Passo 1: Expande fn_normalizar_nome_produto
-- ----------------------------------------------------------------------------
-- Regras adicionadas (compatíveis com a filosofia da fase 43 — colapsar
-- variedades no canônico):
--   * ^MELÃO / ^MELAO( |$)  -> MELAO   (MELÃO AMARELO, MELÃO NET MELON, ...)
--   * ^CASTANHA             -> CASTANHA (CASTANHA NACIONAL, CASTANHA IMP., ...)
--   * ^AÇAÍ / ^ACAI( |$)    -> ACAI    (AÇAÍ, ACAI FRUTO, ...)
-- Boundary ( |$) evita colapsar MELANCIA em MELAO; ACAI não colide com MACA.
-- ============================================================================

CREATE OR REPLACE FUNCTION staging.fn_normalizar_nome_produto(
    p_nome TEXT
)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE STRICT
AS $$
DECLARE
    v_nome TEXT;
BEGIN
    -- 1. UPPER + TRIM
    v_nome := UPPER(TRIM(p_nome));

    -- 2. Remove ' - NÃO INFORMADO'
    v_nome := REGEXP_REPLACE(v_nome, ' - NÃO INFORMADO$', '');

    -- 3. Remove 'NÃO INFORMADO' solto no final
    v_nome := REGEXP_REPLACE(v_nome, '\s+NÃO INFORMADO$', '');

    -- 4. Hífen entre palavras → espaço (ex: BATATA-DOCE → BATATA DOCE)
    v_nome := REPLACE(v_nome, '-', ' ');

    -- 5. Colapsa espaços múltiplos
    v_nome := REGEXP_REPLACE(v_nome, '\s+', ' ', 'g');
    v_nome := TRIM(v_nome);

    -- 6. Remove sufixos de variedade para produtos base
    --    ⚠️ Ordem CRÍTICA: subprodutos (BATATA DOCE) ANTES do pai (BATATA)
    --    A condição SEM `AND v_nome != '...'` garante que o nome exato
    --    do subproduto seja preservado (ex: BATATA DOCE não vira BATATA).
    v_nome := CASE
        -- Subprodutos (devem vir ANTES do pai genérico)
        WHEN v_nome ~ '^BATATA DOCE'             THEN 'BATATA DOCE'
        WHEN v_nome ~ '^FEIJAO COMUM PRETO'      THEN 'FEIJAO COMUM PRETO'
        WHEN v_nome ~ '^FEIJAO COMUM CORES'      THEN 'FEIJAO COMUM CORES'
        WHEN v_nome ~ '^FEIJAO CAUPI'            THEN 'FEIJAO CAUPI'
        WHEN v_nome ~ '^FARINHA DE MANDIOCA'     THEN 'FARINHA DE MANDIOCA'
        WHEN v_nome ~ '^FARINHA DE TRIGO'        THEN 'FARINHA DE TRIGO'
        WHEN v_nome ~ '^CARNE CAPRINA'           THEN 'CARNE CAPRINA'
        WHEN v_nome ~ '^CARNE BOVINA'            THEN 'CARNE BOVINA'
        WHEN v_nome ~ '^CARNE DE FRANGO'         THEN 'CARNE DE FRANGO'
        WHEN v_nome ~ '^CARNE OVINA'             THEN 'CARNE OVINA'
        WHEN v_nome ~ '^LEITE DE VACA'           THEN 'LEITE DE VACA'
        WHEN v_nome ~ '^OVOS DE GALINHA'         THEN 'OVOS DE GALINHA'
        WHEN v_nome ~ '^OLEO DE SOJA'            THEN 'OLEO DE SOJA'
        WHEN v_nome ~ '^FLOCOS DE MILHO'         THEN 'FLOCOS DE MILHO'
        WHEN v_nome ~ '^MACARRAO'                THEN 'MACARRAO'  -- boundary: MACARRAO NÃO vira MACA
        WHEN v_nome ~ '^ARROZ'                   THEN 'ARROZ'
        WHEN v_nome ~ '^FEIJAO'                  THEN 'FEIJAO'
        -- Produtos pai (genéricos) — boundary ( |$) evita colapsar MACARRAO em MACA, SALMÃO em SAL, etc.
        WHEN v_nome ~ '^BANANA'                  THEN 'BANANA'
        WHEN v_nome ~ '^TOMATE'                  THEN 'TOMATE'
        WHEN v_nome ~ '^BATATA'                  THEN 'BATATA'
        WHEN v_nome ~ '^MILHO'                   THEN 'MILHO'
        WHEN v_nome ~ '^MACA( |$)'               THEN 'MACA'
        WHEN v_nome ~ '^MAMAO'                   THEN 'MAMAO'
        WHEN v_nome ~ '^LARANJA'                 THEN 'LARANJA'
        WHEN v_nome ~ '^CEBOLA'                  THEN 'CEBOLA'
        WHEN v_nome ~ '^ALHO'                    THEN 'ALHO'
        WHEN v_nome ~ '^CAFE'                    THEN 'CAFE'
        WHEN v_nome ~ '^MANDIOCA'                THEN 'MANDIOCA'
        WHEN v_nome ~ '^ACUCAR'                  THEN 'ACUCAR'
        WHEN v_nome ~ '^PAO'                     THEN 'PAO'
        WHEN v_nome ~ '^MANTEIGA'                THEN 'MANTEIGA'
        WHEN v_nome ~ '^SAL( |$)'                THEN 'SAL'  -- boundary: SALMÃO, SALSÃO, SALSA NÃO viram SAL
        -- Fase 60: Açaí / Castanha / Melão (colapsar variantes no canônico)
        WHEN v_nome ~ '^AÇAÍ'                    THEN 'ACAI'
        WHEN v_nome ~ '^ACAI( |$)'               THEN 'ACAI'
        WHEN v_nome ~ '^CASTANHA'                THEN 'CASTANHA'
        WHEN v_nome ~ '^MELÃO'                   THEN 'MELAO'
        WHEN v_nome ~ '^MELAO( |$)'              THEN 'MELAO'  -- boundary: MELANCIA NÃO vira MELAO
        ELSE v_nome
    END;

    -- 7. Colapsa espaços novamente (pode ter sobrado do CASE)
    v_nome := REGEXP_REPLACE(v_nome, '\s+', ' ', 'g');
    v_nome := TRIM(v_nome);

    RETURN v_nome;
END;
$$;

COMMENT ON FUNCTION staging.fn_normalizar_nome_produto IS
    'Normaliza nome de produto: UPPER, remove NÃO INFORMADO, normaliza hífens, '
    'remove sufixos de variedade para bases conhecidas. IMMUTABLE para uso em índices. '
    'Fase 60: adiciona colapso de AÇAÍ/ACAI, CASTANHA e MELÃO/MELAO para o canônico.';

-- ============================================================================
-- Passo 2: Cadastra o canônico AÇAÍ em dim_produto (não existia)
-- ----------------------------------------------------------------------------
-- Segue o padrão dos canônicos simples (TANGERINA/MELANCIA/ALFACE):
-- categoria_b2c='ALIMENTO_VAREJO', id_categoria=9, status_fonte='SEM_FONTE_MAPEDADA'.
-- Guard contra duplicatas (nome exato ou já normalizado para ACAI).
-- ============================================================================

INSERT INTO staging.dim_produto (
    nome_produto, categoria_b2c, id_categoria,
    status_imagem, status_fonte
)
SELECT
    'AÇAÍ',
    'ALIMENTO_VAREJO',
    9,
    'PENDENTE',
    'SEM_FONTE_MAPEDADA'
WHERE NOT EXISTS (
    SELECT 1
    FROM staging.dim_produto dp
    WHERE staging.fn_normalizar_nome_produto(dp.nome_produto) = 'ACAI'
);

-- ============================================================================
-- Passo 3: Insere os 6 fluxos que a migration 48 não casou
-- ----------------------------------------------------------------------------
-- Blocos idênticos aos da migration 48 (linhas 617-664, 2299-2322,
-- 2424-2447, 2499-2547). ON CONFLICT DO NOTHING garante idempotência.
-- Obs.: o fluxo Melão RN→CE 'Médio' colide com o 'Baixo' (mesma rota/tipo e
-- mesmo produto canônico) e será descartado — comportamento esperado (165).
-- ============================================================================

-- Melão (RN → CE, preço Baixo) [migration 48 linhas 617-640]
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Melão',
       'RN',
       'CEASA-RN',
       'nordeste',
       'CE',
       ARRAY[7,8,9,10,11,12],
       'alta',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MELAO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Melão (CE → RN, preço Baixo) [migration 48 linhas 642-664]
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Melão',
       'CE',
       'CEASA-CE',
       'nordeste',
       'RN',
       ARRAY[7,8,9,10],
       'alta',
       'Baixo',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MELAO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Melão (RN → CE, preço Médio) [migration 48 linhas 2299-2322]
-- ⚠️ Esperado NO-OP: mesma chave única do fluxo 'Baixo' acima.
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Melão',
       'RN',
       'CEASA-RN',
       'nordeste',
       'CE',
       ARRAY[7,8,9,10,11,12],
       'alta',
       'Médio',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('MELAO'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Castanha (AC → RO) [migration 48 linhas 2499-2522]
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Castanha',
       'AC',
       'CEASA-AC',
       'norte',
       'RO',
       ARRAY[1,2,3,4,5,6,7,8,9,10,11,12],
       'nenhuma',
       'Alto',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('CASTANHA'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Açaí (AP → PA) [migration 48 linhas 2424-2447]
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Açaí',
       'AP',
       'CEASA-AP',
       'norte',
       'PA',
       ARRAY[7,8,9,10,11,12],
       'alta',
       'Alto',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ACAI'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

-- Açaí (AC → AM) [migration 48 linhas 2524-2547]
INSERT INTO staging.dim_fluxo_abastecimento (
    id_produto, produto_nome, origem_uf, origem_polo,
    destino_regiao_id, destino_uf, meses, sazonalidade,
    preco_referencial, tipo, ano_referencia
)
SELECT dp.id_produto,
       'Açaí',
       'AC',
       'CEASA-AC',
       'norte',
       'AM',
       ARRAY[7,8,9,10,11,12],
       'alta',
       'Alto',
       'exportado',
       2026
FROM staging.dim_produto dp
WHERE staging.fn_normalizar_nome_produto(dp.nome_produto)
    = staging.fn_normalizar_nome_produto(UPPER('ACAI'))
ORDER BY (SELECT COUNT(*) FROM staging.fact_precos_mensais fp
          WHERE fp.id_produto = dp.id_produto) DESC
LIMIT 1
ON CONFLICT (id_produto, origem_uf, destino_uf, tipo) DO NOTHING;

COMMIT;
