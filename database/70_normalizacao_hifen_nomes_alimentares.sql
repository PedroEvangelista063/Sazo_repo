-- ============================================================================
-- QUERO COMPRAR — MIGRAÇÃO 70: Normalização de Hífen em Nomes Alimentares
-- (Resolução das duplicatas residuais da FASE 2: Batata Doce vs Batata-Doce)
--
-- PROBLEMA
--   A auditoria FASE 2 (banco vs API, cache MISS forçado) encontrou a ÚNICA
--   anomalia residual da grade BR 2026: 5 duplicatas semânticas em Tubérculos
--   e Raízes — `Batata Doce` vs `Batata-Doce` (e variantes Amarela/Branca/
--   Rosada/Roxa). Causa raiz: `mart.fn_sanitizar_nome_produto` (migration 67)
--   preserva hífens NÃO espaçados por design (para não destruir códigos como
--   `00-18-18` e tokens como `couve-flor`), o que faz `BATATA-DOCE` e
--   `BATATA DOCE` virarem chaves semânticas DISTINTAS.
--
-- SOLUÇÃO
--   1. Nova `mart.fn_sanitizar_nome_produto`: converte hífen entre DUAS LETRAS
--      maiúsculas para espaço (`([A-Z])-([A-Z])` → `\1 \2`). Hífens de códigos
--      com dígitos (NPK `00-18-18`, `02-20-20`, `08-20-18+MICRO`, `2,4-D`)
--      são PRESERVADOS (o vizinho é dígito, não letra).
--   2. Recarrega `mart.dim_produto_canonico` (TRUNCATE + INSERT idêntico à 67,
--      mesma eleição de mestre: prioridade de categoria → legibilidade → id).
--   3. Reaplica o Title Case no `nome_canonico` (padrão da migration 69 — o
--      reload recalcula `nome_canonico` a partir do nome do mestre, que pode
--      ser MAIÚSCULO, ex: 'BATATA DOCE' → 'Batata Doce').
--
-- ANÁLISE DE SEGURANÇA (pré-apply, 2026-08-06)
--   Total de staging.dim_produto: 2869 produtos · MDM atual: 2713 grupos.
--   Produtos com hífen não espaçado: 118.
--   FUSÕES NOVAS (grupos distintos que passam a compartilhar chave): 10 —
--   TODAS semanticamente corretas (variação hífen/espaço do MESMO alimento):
--     ALHO PORRO, BATATA DOCE(+AMARELA/BRANCA/ROSADA/ROXA), CANA DE ACUCAR,
--     COUVE DE BRUXELAS, COUVE FLOR, FEIJAO DE CORDA.
--   FUSÕES RUINS: 0. Códigos NPK preservados: 86. Marcas únicas (K-OTHRINE,
--   BAC-CONTROL, CROP-SET, MS-MN) viram chave com espaço, sem colisão com
--   nenhum outro produto (verificado pairwise). Edge case tratado com dupla
--   passada da regex: 'CARNE BOVINA - CHARQUE PA CRAY-O-VA' (id 890) tem
--   hífens consecutivos e exige 2 aplicações para zerar residuais.
--   Grupos após a migration: 2713 - 10 = 2703.
--
-- IDEMPOTENTE: CREATE OR REPLACE da função + TRUNCATE/INSERT (recarregável).
--
-- ROLLBACK
--   Restaurar a função original (backup em /tmp/opencode/fn_def_original_backup.sql)
--   ou reaplicar a migration 67 e re-executar o UPDATE de Title Case da 69.
-- ============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- ============================================================================
-- FASE 1 — Nova mart.fn_sanitizar_nome_produto (hífen entre letras → espaço)
-- ============================================================================
-- Regra de conversão: `([A-Z])-([A-Z])` → `\1 \2` aplicada DUAS vezes
-- (POSIX/ARE, sem lookbehind — não suportado por AREs do PostgreSQL). Como o
-- texto é colocado em CAIXA ALTA antes, apenas letras maiúsculas importam.
-- Hífens com dígito vizinho (`00-18-18`, `2,4-D`, `08-20-18+MICRO`) NÃO casam
-- → preservados. DUPLA aplicação: com regexp_replace 'g' o cursor avança após
-- cada substituição, então hífens CONSECUTIVOS ('CRAY-O-VA') deixam um
-- residual na primeira passada ('CRAY O-VA'); a segunda passada converte o
-- residual ('CRAY O VA').

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
                -- FASE 70: hífen entre DUAS LETRAS → espaço (une 'BATATA-DOCE'
                -- com 'BATATA DOCE'). Códigos NPK com dígitos preservados.
                -- Passada 1: 'BATATA-DOCE' → 'BATATA DOCE'.
                '([A-Z])-([A-Z])', '\1 \2', 'g'
            ),
            -- Passada 2: hífens consecutivos ('CRAY-O-VA' → 'CRAY O-VA' →
            -- 'CRAY O VA') — o cursor da passada 1 avança após cada match.
            '([A-Z])-([A-Z])', '\1 \2', 'g'
        ),
        '\*+', '', 'g'
    ),
    ' -'
);
$function$;

COMMENT ON FUNCTION mart.fn_sanitizar_nome_produto(text) IS
'Normaliza nome de produto para chave semântica MDM: CAIXA ALTA, sem acentos, '
'espaços colapsados, hífen espaçado convertido em espaço, hífen entre letras '
'convertido em espaço em DUAS passadas (FASE 70 — une "BATATA-DOCE" e "BATATA '
'DOCE", inclusive hífens consecutivos tipo "CRAY-O-VA"; códigos com dígitos '
'como NPK 00-18-18 preservados), asteriscos removidos, bordas sem pontuação. '
'Determinística e IMMUTABLE.';

GRANT EXECUTE ON FUNCTION mart.fn_sanitizar_nome_produto(text) TO role_etl_writer;

-- ============================================================================
-- FASE 2 — Recarga de mart.dim_produto_canonico (mesma eleição de mestre da 67)
-- ============================================================================

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

-- ============================================================================
-- FASE 3 — Reaplica Title Case no nome_canonico (padrão da migration 69)
-- ============================================================================
-- O reload recalcula nome_canonico a partir do NOME DO MESTRE (pode ser
-- MAIÚSCULO, ex: 'BATATA DOCE' → 'Batata Doce'). Rebaixa partículas pt-BR
-- (de/da/do/e/em/com/...) no meio do nome.

UPDATE mart.dim_produto_canonico
SET nome_canonico = mart.fn_title_case_produto(nome_canonico)
WHERE nome_canonico IS DISTINCT FROM mart.fn_title_case_produto(nome_canonico);

-- ============================================================================
-- FASE 4 — Guard de verificação (aborta se o resultado fugir do esperado)
-- ============================================================================
DO $$
DECLARE
    v_grupos       INTEGER;
    v_hifen_letras INTEGER;
    v_batata       TEXT;
BEGIN
    SELECT count(DISTINCT nome_sanitizado) INTO v_grupos
    FROM mart.dim_produto_canonico;

    -- Nenhuma chave pode manter hífen entre letras (regra da FASE 70)
    SELECT count(*) INTO v_hifen_letras
    FROM mart.dim_produto_canonico
    WHERE nome_sanitizado ~ '([A-Z])-([A-Z])';

    -- Grupo BATATA DOCE deve ter nome canônico Title Case
    SELECT nome_canonico INTO v_batata
    FROM mart.dim_produto_canonico
    WHERE nome_sanitizado = 'BATATA DOCE'
    LIMIT 1;

    RAISE NOTICE '[70] Grupos após normalização: % (esperado 2703)', v_grupos;
    RAISE NOTICE '[70] Chaves com hífen entre letras: % (esperado 0)', v_hifen_letras;
    RAISE NOTICE '[70] nome_canonico de BATATA DOCE: %', v_batata;

    IF v_grupos <> 2703 THEN
        RAISE EXCEPTION '[70] Contagem de grupos inesperada: % (esperado 2703). Abortando.', v_grupos;
    END IF;
    IF v_hifen_letras <> 0 THEN
        RAISE EXCEPTION '[70] % chaves ainda com hífen entre letras. Abortando.', v_hifen_letras;
    END IF;
    IF v_batata IS NULL THEN
        RAISE EXCEPTION '[70] Grupo BATATA DOCE não encontrado após normalização. Abortando.';
    END IF;
END $$;

COMMIT;

-- ============================================================================
-- Diagnóstico pós-migration (opcional):
--   SELECT nome_sanitizado, count(*) AS n, min(nome_canonico) AS canonico
--   FROM mart.dim_produto_canonico
--   GROUP BY 1 HAVING count(*) > 1
--   ORDER BY 2 DESC, 1
--   LIMIT 20;
-- ============================================================================
