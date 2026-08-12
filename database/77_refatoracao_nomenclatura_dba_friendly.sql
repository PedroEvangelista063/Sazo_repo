-- ============================================================
-- MIGRATION: 77_refatoracao_nomenclatura_dba_friendly
-- Executar SOMENTE após: backup completo + aprovação do time
-- Idempotente: verifica existência antes de renomear
-- Compatibilidade: views temporárias (30 dias) p/ tabelas e
--                  wrappers de função (30 dias) p/ funções
-- NÃO toca: MV vw_api_produtos_sazonalidade, roles,
--           fact_precos_mensais, sp_executar_carga_completa
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- BLOCO 1: Renomear tabelas RAW (sem dependentes)
-- ────────────────────────────────────────────────────────────
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='raw' AND tablename='precos_uf')
       AND NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='raw' AND tablename='preco_conab_uf') THEN
        ALTER TABLE raw.precos_uf RENAME TO preco_conab_uf;
        RAISE NOTICE 'RENOMEADO: raw.precos_uf → raw.preco_conab_uf';
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='raw' AND tablename='precos_municipio')
       AND NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='raw' AND tablename='preco_conab_municipio') THEN
        ALTER TABLE raw.precos_municipio RENAME TO preco_conab_municipio;
        RAISE NOTICE 'RENOMEADO: raw.precos_municipio → raw.preco_conab_municipio';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────
-- BLOCO 2: Renomear tabelas STAGING/MART sem dependentes
-- ────────────────────────────────────────────────────────────
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='staging' AND tablename='dim_conab_produto_mapping')
       AND NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='staging' AND tablename='dim_mapeamento_produto_conab') THEN
        ALTER TABLE staging.dim_conab_produto_mapping RENAME TO dim_mapeamento_produto_conab;
        RAISE NOTICE 'RENOMEADO: staging.dim_conab_produto_mapping → staging.dim_mapeamento_produto_conab';
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='mart' AND tablename='dim_produto_canonico')
       AND NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='mart' AND tablename='produto_canonico') THEN
        ALTER TABLE mart.dim_produto_canonico RENAME TO produto_canonico;
        RAISE NOTICE 'RENOMEADO: mart.dim_produto_canonico → mart.produto_canonico';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────
-- BLOCO 3: Renomear views sem dependentes (pg_depend: a MV
-- vw_api_produtos_sazonalidade NÃO depende destas views)
-- ────────────────────────────────────────────────────────────
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_views WHERE schemaname='mart' AND viewname='vw_anchor_sazonalidade')
       AND NOT EXISTS (SELECT 1 FROM pg_views WHERE schemaname='mart' AND viewname='vw_ancora_preco_referencia') THEN
        ALTER VIEW mart.vw_anchor_sazonalidade RENAME TO vw_ancora_preco_referencia;
        RAISE NOTICE 'RENOMEADO: mart.vw_anchor_sazonalidade → mart.vw_ancora_preco_referencia';
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_views WHERE schemaname='mart' AND viewname='vw_mapa_regional_completo')
       AND NOT EXISTS (SELECT 1 FROM pg_views WHERE schemaname='mart' AND viewname='vw_abastecimento_regional_completo') THEN
        ALTER VIEW mart.vw_mapa_regional_completo RENAME TO vw_abastecimento_regional_completo;
        RAISE NOTICE 'RENOMEADO: mart.vw_mapa_regional_completo → mart.vw_abastecimento_regional_completo';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────
-- BLOCO 4: Renomear funções (robusto a sobrecarga — resolve
-- a assinatura real pelo catálogo; trigger referencia por OID,
-- então renomear a função do trigger NÃO quebra o trigger)
--
-- Guard de idempotência: só renomeia se o NOVO nome NÃO existir
-- com a mesma identidade de argumentos. Isso impede que uma 2ª
-- execução tente renomear um WRAPPER de compatibilidade (que tem
-- o nome antigo) para cima de um objeto já renomeado.
-- ────────────────────────────────────────────────────────────
DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT p.oid, p.proname, n.nspname
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE (n.nspname, p.proname) IN (
            ('staging', '_parse_conab_price'),
            ('staging', '_gerar_batch_id'),
            ('staging', 'fn_relatorio_mapa_regional'),
            ('staging', 'fn_relatorio_normalizacao'),
            ('staging', 'fn_consolidar_produtos_duplicados'),
            ('staging', 'fn_consolidar_produtos_por_lista'),
            ('staging', 'fn_injetar_dados_ufs_carentes'),
            ('staging', 'fn_calcular_status_cor_por_preco'),
            ('staging', 'fn_classificar_preco_anomalia'),
            ('staging', 'trg_valida_anomalia_preco')
        )
        AND p.proname NOT LIKE 'pg_%'
        AND NOT EXISTS (
            SELECT 1
            FROM pg_proc p2 JOIN pg_namespace n2 ON n2.oid = p2.pronamespace
            WHERE n2.nspname = n.nspname
              AND p2.proname = CASE p.proname
                    WHEN '_parse_conab_price'                  THEN 'normalizar_preco_conab'
                    WHEN '_gerar_batch_id'                     THEN 'gerar_id_lote'
                    WHEN 'fn_relatorio_mapa_regional'          THEN 'relatorio_abastecimento_por_uf'
                    WHEN 'fn_relatorio_normalizacao'           THEN 'relatorio_normalizacao_produtos'
                    WHEN 'fn_consolidar_produtos_duplicados'   THEN 'consolidar_produtos_duplicados'
                    WHEN 'fn_consolidar_produtos_por_lista'    THEN 'consolidar_produtos_por_lista'
                    WHEN 'fn_injetar_dados_ufs_carentes'       THEN 'injetar_dados_ufs_carentes'
                    WHEN 'fn_calcular_status_cor_por_preco'    THEN 'calcular_status_cor_por_preco'
                    WHEN 'fn_classificar_preco_anomalia'       THEN 'classificar_preco_anomalia'
                    WHEN 'trg_valida_anomalia_preco'           THEN 'validar_anomalia_preco'
                END
              AND pg_get_function_identity_arguments(p2.oid) = pg_get_function_identity_arguments(p.oid)
        )
    LOOP
        EXECUTE format('ALTER FUNCTION %I.%I(%s) RENAME TO %I',
            r.nspname, r.proname,
            pg_get_function_identity_arguments(r.oid),
            CASE r.proname
                WHEN '_parse_conab_price'                  THEN 'normalizar_preco_conab'
                WHEN '_gerar_batch_id'                     THEN 'gerar_id_lote'
                WHEN 'fn_relatorio_mapa_regional'          THEN 'relatorio_abastecimento_por_uf'
                WHEN 'fn_relatorio_normalizacao'           THEN 'relatorio_normalizacao_produtos'
                WHEN 'fn_consolidar_produtos_duplicados'   THEN 'consolidar_produtos_duplicados'
                WHEN 'fn_consolidar_produtos_por_lista'    THEN 'consolidar_produtos_por_lista'
                WHEN 'fn_injetar_dados_ufs_carentes'       THEN 'injetar_dados_ufs_carentes'
                WHEN 'fn_calcular_status_cor_por_preco'    THEN 'calcular_status_cor_por_preco'
                WHEN 'fn_classificar_preco_anomalia'       THEN 'classificar_preco_anomalia'
                WHEN 'trg_valida_anomalia_preco'           THEN 'validar_anomalia_preco'
            END
        );
        RAISE NOTICE 'RENOMEADO: %.% → %', r.nspname, r.proname,
            CASE r.proname
                WHEN '_parse_conab_price' THEN 'normalizar_preco_conab' WHEN '_gerar_batch_id' THEN 'gerar_id_lote'
                WHEN 'fn_relatorio_mapa_regional' THEN 'relatorio_abastecimento_por_uf'
                WHEN 'fn_relatorio_normalizacao' THEN 'relatorio_normalizacao_produtos'
                WHEN 'fn_consolidar_produtos_duplicados' THEN 'consolidar_produtos_duplicados'
                WHEN 'fn_consolidar_produtos_por_lista' THEN 'consolidar_produtos_por_lista'
                WHEN 'fn_injetar_dados_ufs_carentes' THEN 'injetar_dados_ufs_carentes'
                WHEN 'fn_calcular_status_cor_por_preco' THEN 'calcular_status_cor_por_preco'
                WHEN 'fn_classificar_preco_anomalia' THEN 'classificar_preco_anomalia'
                WHEN 'trg_valida_anomalia_preco' THEN 'validar_anomalia_preco'
            END;
    END LOOP;
END $$;

-- ────────────────────────────────────────────────────────────
-- BLOCO 4.5: WRAPPERS DE COMPATIBILIDADE PARA FUNÇÕES (30 dias)
-- Remover em 2026-09-30 (junto com as views do BLOCO 5).
--
-- POR QUE: funções PL/pgSQL resolvem chamadas por NOME em
-- runtime. Após o rename, qualquer função que ainda referencie o
-- nome antigo (ex.: trg_valida_anomalia_preco → chama
-- fn_classificar_preco_anomalia; fn_consolidar_produtos_duplicados
-- → chama fn_relatorio_normalizacao) quebraria em runtime.
-- Wrappers preservam a assinatura EXATA + volatility do original
-- e delegam ao novo nome. Função trigger NÃO tem wrapper (o
-- trigger referencia por OID — o rename é transparente).
--
-- Idempotência: CREATE OR REPLACE — reexecução é segura.
--
-- ⚠️ LIMITAÇÃO/PRÉ-REQUISITO DO DROP (2026-09-30): os wrappers NÃO
-- reescrevem o corpo dos chamadores — validar_anomalia_preco (ex-trigger)
-- continua chamando fn_classificar_preco_anomalia por nome, e
-- fn_consolidar_produtos_duplicados continua chamando fn_relatorio_normalizacao.
-- ANTES de dropar os wrappers na Fase 3, atualizar os corpos chamadores para
-- os nomes novos (CREATE OR REPLACE) — senão o trigger volta a quebrar.
--
-- ⚠️ GUARD DE IDEMPOTÊNCIA: o BLOCO 4 usa pg_get_function_identity_arguments,
-- que INCLUI nomes de parâmetros IN. Todo wrapper DEVE replicar os nomes de
-- parâmetros do original exatamente (caso real: p_force → p_dry_run), senão
-- a 2ª execução tenta renomear o wrapper e falha com 'already exists'.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION staging._parse_conab_price(p_texto TEXT)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT staging.normalizar_preco_conab(p_texto);
$$;
COMMENT ON FUNCTION staging._parse_conab_price(TEXT) IS
    'DEPRECATED 2026-08: use staging.normalizar_preco_conab(TEXT). Removida em 2026-09-30.';

CREATE OR REPLACE FUNCTION staging._gerar_batch_id()
RETURNS UUID
LANGUAGE sql
VOLATILE
AS $$
    SELECT staging.gerar_id_lote();
$$;
COMMENT ON FUNCTION staging._gerar_batch_id() IS
    'DEPRECATED 2026-08: use staging.gerar_id_lote(). Removida em 2026-09-30.';

CREATE OR REPLACE FUNCTION staging.fn_relatorio_mapa_regional(p_uf TEXT)
RETURNS TABLE(
    uf text, produtos_total bigint, com_preco_real bigint, com_preco_proxy bigint,
    sem_preco bigint, com_fluxo bigint, com_sazonalidade bigint, status_verde bigint,
    status_amarelo bigint, status_vermelho bigint, cobertura_pct numeric
)
LANGUAGE sql
STABLE
AS $$
    SELECT * FROM staging.relatorio_abastecimento_por_uf(p_uf);
$$;
COMMENT ON FUNCTION staging.fn_relatorio_mapa_regional(TEXT) IS
    'DEPRECATED 2026-08: use staging.relatorio_abastecimento_por_uf(TEXT). Removida em 2026-09-30.';

CREATE OR REPLACE FUNCTION staging.fn_relatorio_normalizacao()
RETURNS TABLE(
    grupo_normalizado text, produtos_originais text, id_canonico integer,
    nome_canonico text, total_duplicatas bigint, qtd_precos_afetados bigint
)
LANGUAGE sql
STABLE
AS $$
    SELECT * FROM staging.relatorio_normalizacao_produtos();
$$;
COMMENT ON FUNCTION staging.fn_relatorio_normalizacao() IS
    'DEPRECATED 2026-08: use staging.relatorio_normalizacao_produtos(). Removida em 2026-09-30.';

CREATE OR REPLACE FUNCTION staging.fn_consolidar_produtos_duplicados(p_dry_run BOOLEAN)
RETURNS TABLE(
    acao text, nome_grupo text, id_afetado integer, nome_afetado text, detalhe text
)
LANGUAGE sql
VOLATILE
AS $$
    SELECT * FROM staging.consolidar_produtos_duplicados(p_dry_run);
$$;
COMMENT ON FUNCTION staging.fn_consolidar_produtos_duplicados(BOOLEAN) IS
    'DEPRECATED 2026-08: use staging.consolidar_produtos_duplicados(BOOLEAN). Removida em 2026-09-30.';

CREATE OR REPLACE FUNCTION staging.fn_consolidar_produtos_por_lista(p_produtos TEXT[], p_dry_run BOOLEAN)
RETURNS TABLE(
    acao text, nome_grupo text, id_afetado integer, nome_afetado text, detalhe text
)
LANGUAGE sql
VOLATILE
AS $$
    SELECT * FROM staging.consolidar_produtos_por_lista(p_produtos, p_dry_run);
$$;
COMMENT ON FUNCTION staging.fn_consolidar_produtos_por_lista(TEXT[], BOOLEAN) IS
    'DEPRECATED 2026-08: use staging.consolidar_produtos_por_lista(TEXT[], BOOLEAN). Removida em 2026-09-30.';

CREATE OR REPLACE FUNCTION staging.fn_injetar_dados_ufs_carentes(p_dry_run BOOLEAN)
RETURNS TABLE(
    acao text, uf_destino text, produto text, fornecedor text, qtd_meses integer, detalhe text
)
LANGUAGE sql
VOLATILE
AS $$
    SELECT * FROM staging.injetar_dados_ufs_carentes(p_dry_run);
$$;
COMMENT ON FUNCTION staging.fn_injetar_dados_ufs_carentes(BOOLEAN) IS
    'DEPRECATED 2026-08: use staging.injetar_dados_ufs_carentes(BOOLEAN). Removida em 2026-09-30.';

CREATE OR REPLACE FUNCTION staging.fn_calcular_status_cor_por_preco(
    p_id_produto INTEGER, p_id_localidade INTEGER, p_mes SMALLINT
)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT staging.calcular_status_cor_por_preco(p_id_produto, p_id_localidade, p_mes);
$$;
COMMENT ON FUNCTION staging.fn_calcular_status_cor_por_preco(INTEGER, INTEGER, SMALLINT) IS
    'DEPRECATED 2026-08: use staging.calcular_status_cor_por_preco(INTEGER, INTEGER, SMALLINT). Removida em 2026-09-30.';

CREATE OR REPLACE FUNCTION staging.fn_classificar_preco_anomalia(
    p_id_produto INTEGER, p_id_localidade INTEGER, p_ano SMALLINT, p_mes SMALLINT, p_preco NUMERIC
)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT staging.classificar_preco_anomalia(p_id_produto, p_id_localidade, p_ano, p_mes, p_preco);
$$;
COMMENT ON FUNCTION staging.fn_classificar_preco_anomalia(INTEGER, INTEGER, SMALLINT, SMALLINT, NUMERIC) IS
    'DEPRECATED 2026-08: use staging.classificar_preco_anomalia(INTEGER, INTEGER, SMALLINT, SMALLINT, NUMERIC). Removida em 2026-09-30.';

-- ────────────────────────────────────────────────────────────
-- BLOCO 5: Views de compatibilidade (30 dias — remover em 2026-09-30)
-- ATENÇÃO: views são read-only; processos que INSERTAM nestes
-- nomes antigos devem migrar antes da remoção (não há INSERTs
-- vivos nestes objetos na Fase 1)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW raw.precos_uf AS SELECT * FROM raw.preco_conab_uf;
COMMENT ON VIEW raw.precos_uf IS 'DEPRECATED 2026-08: use raw.preco_conab_uf. Removida em 2026-09-30.';

CREATE OR REPLACE VIEW raw.precos_municipio AS SELECT * FROM raw.preco_conab_municipio;
COMMENT ON VIEW raw.precos_municipio IS 'DEPRECATED 2026-08: use raw.preco_conab_municipio. Removida em 2026-09-30.';

CREATE OR REPLACE VIEW staging.dim_conab_produto_mapping AS SELECT * FROM staging.dim_mapeamento_produto_conab;
COMMENT ON VIEW staging.dim_conab_produto_mapping IS 'DEPRECATED 2026-08: use staging.dim_mapeamento_produto_conab. Removida em 2026-09-30.';

CREATE OR REPLACE VIEW mart.dim_produto_canonico AS SELECT * FROM mart.produto_canonico;
COMMENT ON VIEW mart.dim_produto_canonico IS 'DEPRECATED 2026-08: use mart.produto_canonico. Removida em 2026-09-30.';

CREATE OR REPLACE VIEW mart.vw_anchor_sazonalidade AS SELECT * FROM mart.vw_ancora_preco_referencia;
COMMENT ON VIEW mart.vw_anchor_sazonalidade IS 'DEPRECATED 2026-08: use mart.vw_ancora_preco_referencia. Removida em 2026-09-30.';

CREATE OR REPLACE VIEW mart.vw_mapa_regional_completo AS SELECT * FROM mart.vw_abastecimento_regional_completo;
COMMENT ON VIEW mart.vw_mapa_regional_completo IS 'DEPRECATED 2026-08: use mart.vw_abastecimento_regional_completo. Removida em 2026-09-30.';

-- ────────────────────────────────────────────────────────────
-- BLOCO 6: COMMENT ON (objetos renomeados + lacunas mart.*/staging.*)
-- ────────────────────────────────────────────────────────────
COMMENT ON TABLE raw.preco_conab_uf IS
    'Preços mensais por UF (arquivo CONAB). Alimenta staging.fact_precos_mensais via pipeline ETL.';
COMMENT ON TABLE raw.preco_conab_municipio IS
    'Preços mensais por município (arquivo CONAB). Alimenta staging.fact_precos_mensais via pipeline ETL.';
COMMENT ON TABLE staging.dim_mapeamento_produto_conab IS
    'Mapeamento nome CONAB → produto canônico local (fator de proporção).';
COMMENT ON TABLE mart.produto_canonico IS
    'Produto canônico MDM (deduplicação de variedades CONAB).';
COMMENT ON VIEW mart.vw_ancora_preco_referencia IS
    'Âncora temporal N → N-1 → N-2 usada para comparação de preço de referência.';
COMMENT ON VIEW mart.vw_abastecimento_regional_completo IS
    'Mapa logístico por UF: origem → destino por produto (join fluxos + dims).';
COMMENT ON FUNCTION staging.normalizar_preco_conab(TEXT) IS
    'Converte preço textual CONAB ("2,27") em NUMERIC.';
COMMENT ON FUNCTION staging.gerar_id_lote() IS
    'Gera UUID para batch de ingestão.';
COMMENT ON FUNCTION staging.relatorio_abastecimento_por_uf(TEXT) IS
    'Relatório do mapa de abastecimento/logística por UF.';
COMMENT ON FUNCTION staging.validar_anomalia_preco() IS
    'Trigger: quarentena de preços >500% da média histórica (insere em staging.precos_rejeitados).';

-- Lacunas de documentação nas tabelas centrais (Fase 1 opcional)
COMMENT ON TABLE mart.sazonalidade_produto IS
    'Tabela central de sazonalidade calculada por produto/localidade/mês. '
    'Preenche a MV mart.vw_api_produtos_sazonalidade (hot path da API B2C).';
COMMENT ON TABLE mart.sazonalidade_baseline IS
    'Baseline sazonal (status_cor predominante por produto/localidade/mês). '
    'Usada como fallback em LEFT JOIN pelo backend (produtos.py).';
COMMENT ON TABLE mart.sazonalidade_baseline_ponderada IS
    'Comparação de status entre ciclos (anterior vs recente) e divergências.';
COMMENT ON TABLE mart.fator_kg_produto_uf IS
    'Fator de conversão de unidade (kg) por produto/UF, usado no sanduíche de preços projetados.';
COMMENT ON TABLE staging.confianca_baseline IS
    'Qualidade/cobertura do baseline sazonal por produto/localidade.';
COMMENT ON TABLE staging.baseline_2025_interpolado IS
    'Baseline sazonal com lacunas interpoladas (série 2024-2026).';
COMMENT ON TABLE ops.quarentena_coleta IS
    'Payloads de coleta em quarentena (validação/limpeza antes de staging).';
COMMENT ON TABLE ops.audit_logs IS
    'Log de auditoria de mudanças (triggers em staging/mart).';
COMMENT ON TABLE staging.fato_cotacao_regional IS
    'DEPRECATED: sem uso em produção (só migração 15 e script de auditoria).';

COMMIT;

-- ============================================================
-- Verificação pós-migração (rodar manualmente antes do commit):
--   \dt raw.* mart.* staging.*
--   SELECT * FROM mart.vw_ancora_preco_referencia LIMIT 5;   -- vs. SELECT antigo
--   \df staging.*  -- conferir que funções antigas viraram wrappers
--   SELECT count(*) FROM raw.precos_uf;  -- view de compat ainda responde
--   SELECT staging.fn_classificar_preco_anomalia(1,1,2026,1,100::numeric);
--       -- wrapper DEPRECATED ainda responde (delega ao novo nome)
--   INSERT teste no fact → trigger validar_anomalia_preco segue ativo
--       (INSERT INTO staging.fact_precos_mensais ... com preço anômalo
--        → deve ir para staging.precos_rejeitados sem erro)
-- ============================================================
