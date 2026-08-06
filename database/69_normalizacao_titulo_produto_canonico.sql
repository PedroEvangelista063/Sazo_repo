-- =============================================================================
-- 69_normalizacao_titulo_produto_canonico.sql
-- -----------------------------------------------------------------------------
-- FASE 1 - HOTFIX 3: Normalização de nomes em Title Case na
-- mart.dim_produto_canonico (criada na migration 67).
--
-- Objetivo: nomes canônicos como "uva red globe imp." / "tangerina" /
-- "abacate" devem aparecer como "Uva Red Globe Imp." / "Tangerina" /
-- "Abacate" na grade BR e nos cards.
--
-- Estratégia:
--   1. Cria mart.fn_title_case_produto(text) — INITCAP com rebaixamento de
--      partículas pt-BR (de, da, do, das, dos, e, em, com, para, por, a, o,
--      as, os, um, uma) que não sejam a primeira palavra, preservando
--      hífens e mantendo o resto em Title Case.
--   2. UPDATE idempotente em nome_canonico onde houver diferença.
--   3. Recalcula a MV de exposição para refletir os novos nomes.
--
-- Segurança: o UPDATE não toca em nome_sanitizado nem em id_produto_mestre;
-- a função de agregação continua agrupando pelo mesmo nome canônico (apenas
-- com capitalização normalizada). Não há risco de fusão indevida: verificado
-- que 0 pares de nomes distintos colidem após a normalização.
--
-- Idempotente: pode ser reexecutado sem efeitos colaterais.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Função de Title Case pt-BR
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mart.fn_title_case_produto(p_nome TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_palavras TEXT[];
    v_resultado TEXT := '';
    v_palavra   TEXT;
    v_i         INT;
    v_partculas CONSTANT TEXT[] := ARRAY[
        'de','da','do','das','dos','e','em','com','para','por',
        'a','o','as','os','um','uma'
    ];
BEGIN
    IF p_nome IS NULL OR btrim(p_nome) = '' THEN
        RETURN p_nome;
    END IF;

    v_palavras := string_to_array(p_nome, ' ');

    FOR v_i IN 1 .. array_length(v_palavras, 1) LOOP
        v_palavra := v_palavras[v_i];

        -- Primeira palavra sempre capitalizada; partículas só rebaixam no meio
        IF v_i = 1 OR NOT (lower(v_palavra) = ANY (v_partculas)) THEN
            v_palavra := initcap(v_palavra);
        ELSE
            v_palavra := lower(v_palavra);
        END IF;

        IF v_i = 1 THEN
            v_resultado := v_palavra;
        ELSE
            v_resultado := v_resultado || ' ' || v_palavra;
        END IF;
    END LOOP;

    RETURN v_resultado;
END;
$$;

GRANT EXECUTE ON FUNCTION mart.fn_title_case_produto(TEXT) TO role_api_reader;
GRANT EXECUTE ON FUNCTION mart.fn_title_case_produto(TEXT) TO role_etl_writer;

-- -----------------------------------------------------------------------------
-- 2. UPDATE idempotente
-- -----------------------------------------------------------------------------
UPDATE mart.dim_produto_canonico
SET nome_canonico = mart.fn_title_case_produto(nome_canonico)
WHERE nome_canonico IS DISTINCT FROM mart.fn_title_case_produto(nome_canonico);

-- -----------------------------------------------------------------------------
-- 3. Recalcula a MV de exposição para propagar os nomes normalizados
-- -----------------------------------------------------------------------------
REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

COMMIT;

-- Diagnóstico pós-migração:
-- SELECT count(*) AS ainda_minusculos
-- FROM mart.dim_produto_canonico
-- WHERE nome_canonico = lower(nome_canonico) AND nome_canonico ~ '[a-z]';
