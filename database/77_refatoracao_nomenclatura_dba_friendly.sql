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
-- ⚠️ GUARD DE IDEMPOTÊNCIA: o BLOCO 4 usa pg_get_function_identity_arguments,
-- que INCLUI nomes de parâmetros IN. Todo wrapper DEVE replicar os nomes de
-- parâmetros do original exatamente (caso real: p_force → p_dry_run), senão
-- a 2ª execução tenta renomear o wrapper e falha com 'already exists'.
--
-- ✅ Os corpos chamadores são REEESCRITOS no BLOCO 4.6 para os nomes novos
-- (validar_anomalia_preco e consolidar_produtos_duplicados) — os wrappers
-- ficam puramente vestigiais e a Fase 3 (drop em 2026-09-30) é segura sem
-- pré-requisito futuro.
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

CREATE OR REPLACE FUNCTION staging.fn_relatorio_mapa_regional(p_uf TEXT DEFAULT NULL)
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

CREATE OR REPLACE FUNCTION staging.fn_consolidar_produtos_duplicados(p_dry_run BOOLEAN DEFAULT TRUE)
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

CREATE OR REPLACE FUNCTION staging.fn_consolidar_produtos_por_lista(p_produtos TEXT[], p_dry_run BOOLEAN DEFAULT TRUE)
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

CREATE OR REPLACE FUNCTION staging.fn_injetar_dados_ufs_carentes(p_dry_run BOOLEAN DEFAULT TRUE)
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
-- BLOCO 4.6: REESCREVER CORPOS CHAMADORES (nomes NOVOS)
-- As funções abaixo referenciam POR NOME as funções renomeadas no
-- BLOCO 4 (PL/pgSQL resolve em runtime):
--   1. validar_anomalia_preco (ex-trg_valida_anomalia_preco) chama
--      fn_classificar_preco_anomalia → agora chama classificar_preco_anomalia
--   2. consolidar_produtos_duplicados (ex-fn_consolidar_produtos_duplicados)
--      chama fn_relatorio_normalizacao → agora chama relatorio_normalizacao_produtos
-- Recriar com CREATE OR REPLACE (mantém OID + ACLs + o trigger segue via OID)
-- torna os wrappers do BLOCO 4.5 puramente vestigiais: a Fase 3 pode dropar
-- wrappers/views em 2026-09-30 sem quebrar nada em runtime.
-- ────────────────────────────────────────────────────────────

-- 4.6.1 — Trigger function (fiel ao 58_hotfix_pipeline_outliers.sql, só o nome da chamada muda)
CREATE OR REPLACE FUNCTION staging.validar_anomalia_preco()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_razao      TEXT;
    v_motivo     TEXT;
    v_dados_brutos JSONB;
    v_uf         CHAR(2);
BEGIN
    SELECT uf INTO v_uf
    FROM staging.dim_localidade
    WHERE id_localidade = NEW.id_localidade;

    v_razao := staging.classificar_preco_anomalia(
        NEW.id_produto,
        NEW.id_localidade,
        NEW.ano,
        NEW.mes,
        NEW.preco_medio
    );

    IF v_razao IS NULL THEN
        RETURN NEW;
    END IF;

    v_motivo := CASE v_razao
        WHEN 'EXCEDE_500PCT_MEDIA_UF'
            THEN 'Preço excede 500% da média histórica do mesmo produto na mesma UF'
        WHEN 'HARD_CAP_50_SEM_HISTORICO'
            THEN 'ANOMALIA_PARSING: preço > R$50 sem histórico sólido que justifique'
        ELSE 'Preço anômalo (' || v_razao || ')'
    END;

    v_dados_brutos := jsonb_build_object(
        'produto_id',      NEW.id_produto,
        'localidade_id',   NEW.id_localidade,
        'uf',              v_uf,
        'ano',             NEW.ano,
        'mes',             NEW.mes,
        'preco_enviado',   NEW.preco_medio,
        'razao_codigo',    v_razao
    );

    INSERT INTO staging.precos_rejeitados (
        id_produto, id_localidade, ano, mes,
        preco_medio, preco_medio_historico, razao,
        dados_brutos, batch_id
    ) VALUES (
        NEW.id_produto, NEW.id_localidade, NEW.ano, NEW.mes,
        NEW.preco_medio, NULL,
        v_motivo,
        v_dados_brutos, NEW.batch_id
    );

    RETURN NULL;  -- aborta esta linha, mas não a transação
END;
$function$;

-- 4.6.2 — Consolidador (fiel ao 43_normalizacao_produtos.sql, só o nome da chamada muda)
CREATE OR REPLACE FUNCTION staging.consolidar_produtos_duplicados(
    p_dry_run BOOLEAN DEFAULT TRUE
)
RETURNS TABLE(
    acao            TEXT,
    nome_grupo      TEXT,
    id_afetado      INTEGER,
    nome_afetado    TEXT,
    detalhe         TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count        INTEGER;
    v_total_precos INTEGER := 0;
    v_total_sfp    INTEGER := 0;
    v_canonico     INTEGER;
    v_grupo_nome   TEXT;
BEGIN
    -- ============================================================
    -- Passo 1: DRY-RUN — apenas mostra o relatório
    -- ============================================================
    IF p_dry_run THEN
        RETURN QUERY
        SELECT
            'DRY-RUN'::TEXT,
            r.grupo_normalizado,
            r.id_canonico,
            r.nome_canonico,
            format('%s duplicatas, %s registros de preço afetados',
                r.total_duplicatas, r.qtd_precos_afetados)
        FROM staging.relatorio_normalizacao_produtos() r
        ORDER BY r.qtd_precos_afetados DESC;
        RETURN;
    END IF;

    -- ============================================================
    -- Passo 2: Executa a consolidação
    -- ============================================================
    RAISE NOTICE '[normalizacao] INICIANDO consolidação de produtos duplicados...';

    -- Temp table com grupos de produtos duplicados
    CREATE TEMP TABLE IF NOT EXISTS tmp_grupos_normalizacao ON COMMIT DROP AS
    WITH normalizados AS (
        SELECT
            p.id_produto,
            p.nome_produto,
            staging.fn_normalizar_nome_produto(p.nome_produto) AS nome_normalizado,
            (SELECT COUNT(*) FROM staging.fact_precos_mensais fp WHERE fp.id_produto = p.id_produto) AS qtd_precos
        FROM staging.dim_produto p
    ),
    grupos AS (
        SELECT
            nome_normalizado,
            COUNT(*) AS qtd_produtos
        FROM normalizados
        GROUP BY nome_normalizado
        HAVING COUNT(*) > 1
    ),
    canonical AS (
        SELECT DISTINCT ON (n.nome_normalizado)
            n.nome_normalizado,
            n.id_produto AS id_canonico,
            n.nome_produto AS nome_canonico,
            n.qtd_precos
        FROM normalizados n
        JOIN grupos g ON g.nome_normalizado = n.nome_normalizado
        ORDER BY n.nome_normalizado, n.qtd_precos DESC NULLS LAST, n.id_produto ASC
    ),
    duplicatas AS (
        SELECT n.*
        FROM normalizados n
        JOIN grupos g ON g.nome_normalizado = n.nome_normalizado
    )
    SELECT
        d.id_produto,
        d.nome_produto,
        d.nome_normalizado,
        c.id_canonico,
        c.nome_canonico,
        d.qtd_precos
    FROM duplicatas d
    JOIN canonical c ON c.nome_normalizado = d.nome_normalizado;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RAISE NOTICE '[normalizacao] % linhas na temp table de grupos', v_count;

    -- Reporta grupos encontrados
    RETURN QUERY
    SELECT
        'GRUPO'::TEXT,
        tg.nome_normalizado,
        tg.id_produto,
        tg.nome_produto,
        format('canônico=%s (%s), precos=%s',
            tg.id_canonico, tg.nome_canonico, tg.qtd_precos)
    FROM tmp_grupos_normalizacao tg
    ORDER BY tg.nome_normalizado, tg.id_produto;

    -- Para cada canônico, processa suas duplicatas
    FOR v_canonico, v_grupo_nome IN
        SELECT DISTINCT id_canonico, nome_normalizado FROM tmp_grupos_normalizacao
    LOOP
        -- 3a. Atualiza fact_precos_mensais: redireciona FKs das duplicatas para o canônico
        WITH dups AS (
            SELECT id_produto FROM tmp_grupos_normalizacao
            WHERE id_canonico = v_canonico AND id_produto != v_canonico
        ),
        updated AS (
            UPDATE staging.fact_precos_mensais fp
            SET id_produto = v_canonico
            FROM dups d
            WHERE fp.id_produto = d.id_produto
            RETURNING fp.id_produto
        )
        SELECT COUNT(*) INTO v_count FROM updated;

        IF v_count > 0 THEN
            v_total_precos := v_total_precos + v_count;
            RETURN QUERY
            SELECT
                'FK-PRECOS'::TEXT,
                v_grupo_nome,
                v_canonico,
                (SELECT nome_canonico FROM tmp_grupos_normalizacao WHERE id_canonico = v_canonico LIMIT 1),
                format('%s registros em fact_precos_mensais redirecionados', v_count);
        END IF;

        -- 3b. Atualiza status_fonte_produto: redireciona FKs das duplicatas para o canônico
        WITH dups AS (
            SELECT id_produto FROM tmp_grupos_normalizacao
            WHERE id_canonico = v_canonico AND id_produto != v_canonico
        ),
        updated AS (
            UPDATE staging.status_fonte_produto sfp
            SET id_produto = v_canonico
            FROM dups d
            WHERE sfp.id_produto = d.id_produto
            RETURNING sfp.id_produto
        )
        SELECT COUNT(*) INTO v_count FROM updated;

        IF v_count > 0 THEN
            v_total_sfp := v_total_sfp + v_count;
            RETURN QUERY
            SELECT
                'FK-STATUS_FONTE'::TEXT,
                v_grupo_nome,
                v_canonico,
                (SELECT nome_canonico FROM tmp_grupos_normalizacao WHERE id_canonico = v_canonico LIMIT 1),
                format('%s registros em status_fonte_produto redirecionados', v_count);
        END IF;

        -- 4. Remove duplicatas (exceto canônico)
        WITH dups AS (
            SELECT id_produto FROM tmp_grupos_normalizacao
            WHERE id_canonico = v_canonico AND id_produto != v_canonico
        ),
        deleted AS (
            DELETE FROM staging.dim_produto dp
            USING dups d
            WHERE dp.id_produto = d.id_produto
            RETURNING dp.id_produto, dp.nome_produto
        )
        SELECT COUNT(*) INTO v_count FROM deleted;

        IF v_count > 0 THEN
            RETURN QUERY
            SELECT
                'DELETE'::TEXT,
                v_grupo_nome,
                v_canonico,
                (SELECT nome_canonico FROM tmp_grupos_normalizacao WHERE id_canonico = v_canonico LIMIT 1),
                format('%s produtos duplicados removidos', v_count);
        END IF;

        -- 5. Atualiza nome do canônico para o nome normalizado (se diferente)
        UPDATE staging.dim_produto dp
        SET nome_produto = v_grupo_nome
        WHERE dp.id_produto = v_canonico
          AND dp.nome_produto != v_grupo_nome;

        GET DIAGNOSTICS v_count = ROW_COUNT;
        IF v_count > 0 THEN
            RETURN QUERY
            SELECT
                'RENAME'::TEXT,
                v_grupo_nome,
                v_canonico,
                (SELECT nome_canonico FROM tmp_grupos_normalizacao WHERE id_canonico = v_canonico LIMIT 1),
                'nome atualizado para o normalizado';
        END IF;
    END LOOP;

    -- Limpa temp table
    DROP TABLE IF EXISTS tmp_grupos_normalizacao;

    -- Totais finais
    RETURN QUERY
    SELECT 'FIM'::TEXT,
        format('%s preços + %s status_fonte consolidados',
            v_total_precos, v_total_sfp)::TEXT,
        NULL::INTEGER,
        NULL::TEXT,
        'consolidação concluída'::TEXT;

    RAISE NOTICE '[normalizacao] CONCLUÍDO: % preços + % status_fonte_produto consolidados',
        v_total_precos, v_total_sfp;
END;
$$;

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
