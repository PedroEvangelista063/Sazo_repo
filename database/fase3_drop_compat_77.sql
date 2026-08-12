-- ============================================================
-- FASE 3 — DROP de compatibilidade da migration 77 (nomenclatura)
-- Agendado: 2026-09-30 (janela de compatibilidade de 30 dias)
--
-- Remove:
--   • 9 WRAPPERS de função (BLOCO 4.5 da 77) — nomes antigos delegando
--     aos novos. SEGURO: os corpos chamadores foram reescritos no
--     BLOCO 4.6 da própria 77 (validar_anomalia_preco → classificar_preco_anomalia;
--     consolidar_produtos_duplicados → relatorio_normalizacao_produtos).
--   • 6 VIEWS de compatibilidade (BLOCO 5 da 77) — nomes antigos de
--     tabelas/views renomeadas.
--
-- PRÉ-REQUISITOS (validados aqui dentro):
--   1. Data >= 2026-09-30 (guard temporal — aborta antes)
--   2. rg no codebase: zero referências aos nomes antigos fora de docs
--      (executar manualmente antes; o script valida o catálogo)
--   3. Ambas as execuções da 77 aplicadas (local + Aiven) — consistência
--      validada por contagens de objetos novos
--
-- NÃO toca: objetos renomeados (nomes novos), MV, roles, triggers.
-- ============================================================

\set ON_ERROR_STOP on

BEGIN;

-- Guard temporal: só executa a partir de 2026-09-30. DENTRO da transação:
-- um RAISE EXCEPTION aborta o bloco e o ROLLBACK implícito desfaz tudo —
-- seguro mesmo se o arquivo for rodado sem -v ON_ERROR_STOP (o \set acima
-- também garante).
DO $$
BEGIN
    IF CURRENT_DATE < DATE '2026-09-30' THEN
        RAISE EXCEPTION 'FASE 3 bloqueada: janela de compatibilidade ativa até 2026-09-30 (hoje: %). Abortando sem alterar nada.', CURRENT_DATE;
    END IF;
END
$$;

-- ── Validação pré-drop: os nomes NOVOS precisam existir (nunca dropar um
--    wrapper sem o alvo) ─────────────────────────────────────────────────────
DO $$
DECLARE
    v_faltando INT;
BEGIN
    SELECT count(*) INTO v_faltando
    FROM unnest(ARRAY[
        'staging.normalizar_preco_conab', 'staging.gerar_id_lote',
        'staging.relatorio_abastecimento_por_uf', 'staging.relatorio_normalizacao_produtos',
        'staging.consolidar_produtos_duplicados', 'staging.consolidar_produtos_por_lista',
        'staging.injetar_dados_ufs_carentes', 'staging.calcular_status_cor_por_preco',
        'staging.classificar_preco_anomalia', 'staging.validar_anomalia_preco'
    ]) AS obj
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname || '.' || p.proname = obj
    );
    IF v_faltando > 0 THEN
        RAISE EXCEPTION 'FASE 3 abortada: % nomes novos ausentes — confira se a migration 77 foi aplicada.', v_faltando;
    END IF;
END
$$;

-- ── DROP dos 9 wrappers de função (assinatura exata) ────────────────────────
DROP FUNCTION IF EXISTS staging._parse_conab_price(TEXT);
DROP FUNCTION IF EXISTS staging._gerar_batch_id();
DROP FUNCTION IF EXISTS staging.fn_relatorio_mapa_regional(TEXT);
DROP FUNCTION IF EXISTS staging.fn_relatorio_normalizacao();
DROP FUNCTION IF EXISTS staging.fn_consolidar_produtos_duplicados(BOOLEAN);
DROP FUNCTION IF EXISTS staging.fn_consolidar_produtos_por_lista(TEXT[], BOOLEAN);
DROP FUNCTION IF EXISTS staging.fn_injetar_dados_ufs_carentes(BOOLEAN);
DROP FUNCTION IF EXISTS staging.fn_calcular_status_cor_por_preco(INTEGER, INTEGER, SMALLINT);
DROP FUNCTION IF EXISTS staging.fn_classificar_preco_anomalia(INTEGER, INTEGER, SMALLINT, SMALLINT, NUMERIC);

-- ── DROP das 6 views de compatibilidade ────────────────────────────────────
DROP VIEW IF EXISTS raw.precos_uf;
DROP VIEW IF EXISTS raw.precos_municipio;
DROP VIEW IF EXISTS staging.dim_conab_produto_mapping;
DROP VIEW IF EXISTS mart.dim_produto_canonico;
DROP VIEW IF EXISTS mart.vw_anchor_sazonalidade;
DROP VIEW IF EXISTS mart.vw_mapa_regional_completo;

-- ── Verificação pós-drop: nomes antigos zerados, novos intactos ────────────
DO $$
DECLARE
    v_antigos INT;
    v_views   INT;
BEGIN
    SELECT count(*) INTO v_antigos
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'staging' AND p.proname IN (
        '_parse_conab_price', '_gerar_batch_id', 'fn_relatorio_mapa_regional',
        'fn_relatorio_normalizacao', 'fn_consolidar_produtos_duplicados',
        'fn_consolidar_produtos_por_lista', 'fn_injetar_dados_ufs_carentes',
        'fn_calcular_status_cor_por_preco', 'fn_classificar_preco_anomalia'
    );
    RAISE NOTICE 'FASE 3: wrappers restantes = % (esperado 0)', v_antigos;
    IF v_antigos > 0 THEN
        RAISE EXCEPTION 'FASE 3: ainda restam % wrappers — conferir manualmente.', v_antigos;
    END IF;

    SELECT count(*) INTO v_views
    FROM pg_views
    WHERE (schemaname, viewname) IN (
        ('raw', 'precos_uf'), ('raw', 'precos_municipio'),
        ('staging', 'dim_conab_produto_mapping'),
        ('mart', 'dim_produto_canonico'), ('mart', 'vw_anchor_sazonalidade'),
        ('mart', 'vw_mapa_regional_completo')
    );
    RAISE NOTICE 'FASE 3: views de compat restantes = % (esperado 0)', v_views;
    IF v_views > 0 THEN
        RAISE EXCEPTION 'FASE 3: ainda restam % views de compatibilidade — conferir manualmente.', v_views;
    END IF;
END
$$;

COMMIT;

-- ============================================================
-- Verificação manual pós-Fase 3:
--   SELECT count(*) FROM staging.precos_rejeitados;   -- trigger segue ativo
--   SELECT tgname, tgfoid::regprocedure FROM pg_trigger WHERE tgname='trg_valida_anomalia_preco';
--   -- → deve apontar para staging.validar_anomalia_preco()
--   SELECT count(*) FROM mart.vw_api_produtos_sazonalidade;  -- MV intacta
--   rg -n '_parse_conab_price|fn_classificar_preco_anomalia|vw_anchor_sazonalidade|vw_mapa_regional_completo' --glob '!docs/**' --glob '!database/77*' --glob '!database/43*' --glob '!database/58*' --glob '!database/46*'
--   -- → zero resultados fora de docs/migrations históricas
-- ============================================================
