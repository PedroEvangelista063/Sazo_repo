-- ============================================================================
-- QUERO COMPRAR — Fase 63: Dado Histórico Real + Transparência
-- PostgreSQL 16+
--
-- OBJETIVO (refatoracao-dado-historico):
--   Substituir as projeções SINTÉTICAS (Sanduíche Sazonal
--   staging.sp_project_sandwich_prices_2026 e Engine V13
--   staging.sp_calcular_forecast_2026_v13) por DADO HISTÓRICO REAL com
--   transparência temporal (ano âncora N → N-1 → N-2):
--
--     1. sp_executar_carga_completa() — DESATIVADA as chamadas sintéticas
--        (steps 5-6 viram no-op guards + RAISE NOTICE); novo step 7 =
--        REFRESH MATERIALIZED VIEW CONCURRENTLY da MV (D7).
--     2. Novas colunas de transparência em mart.sazonalidade_produto:
--        ano_referencia, tipo_dado, metadado_transparencia, idade_dado_anos,
--        preco_exibido (5 colunas NULLABLE + CHECK chk_sazonalidade_tipo_dado).
--     3. Backfill único (sem JOINs, sem CROSS JOIN): real → REAL_ATUAL /
--        HISTORICO_BASE; FLUXO_PROXY / is_forecast → FALLBACK_DIMENSAO
--        (nunca deletado — semântica de exibição apenas).
--     4. VIEW auxiliar mart.vw_anchor_sazonalidade (D1): âncora N→N-1→N-2 por
--        (produto, localidade, mes) via LATERAL — SEM CROSS JOIN (evita o
--        padrão OOM da Fase 62).
--     5. MV mart.vw_api_produtos_sazonalidade V17 (D3/D4/D5): 3 branches
--        UNION ALL (A reais, B âncora em ano atual, C fallback dimensão) +
--        7 índices (UNIQUE primeiro p/ CONCURRENTLY) + GRANT role_api_reader.
--     6. fn_br_nacional_sazonalidade recriada com + ano_referencia, tipo_dado.
--     7. REFRESH MATERIALIZED VIEW CONCURRENTLY inicial (fora de transação).
--
-- IDEMPOTÊNCIA: CREATE OR REPLACE / ADD COLUMN IF NOT EXISTS / DO guard;
-- backfill com WHERE ano_referencia IS NULL (re-executável).
--
-- OBSERVAÇÕES:
--   - As procs sintéticas (V13/sanduíche) permanecem DEFINIDAS no repositório
--     e no banco (audit trail) — apenas não são mais invocadas.
--   - As 2 UNIQUEs (uq_sazonalidade, uq_sazonalidade_data_ref) e o CHECK
--     chk_data_ref_ano_mes (YYYY-MM) são PRESERVADOS (R-ADD-07/S10).
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1 — sp_executar_carga_completa (DESATIVADA as engines sintéticas)
-- ============================================================================
-- Recreate do orchestrator a partir da cópia da Fase 62 (steps 1-4 idênticos).
--   Step 5 (V13): CALL comentado + RAISE NOTICE (D7 — no-op).
--   Step 6 (Sanduíche): guard EXISTS mantido apenas para o aviso; branch de
--     execução é no-op + RAISE NOTICE (D7).
--   Step 7 (NOVO): REFRESH MATERIALIZED VIEW CONCURRENTLY — antes executado
--     pelas engines sintéticas; agora o orchestrator é o dono do refresh (D7).
-- Satisfaz S8 (forecasts não regeneram no próximo load) / R-ADD-06.

CREATE OR REPLACE PROCEDURE staging.sp_executar_carga_completa()
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
    v_existe BOOLEAN;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Iniciando pipeline completo...';

    -- 1. Carga bruta (landing → staging) — se existir no ambiente
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'staging' AND p.proname = 'sp_carregar_landing_para_staging'
    ) INTO v_existe;
    IF v_existe THEN
        CALL staging.sp_carregar_landing_para_staging();
        RAISE NOTICE '[sp_executar_carga_completa] Landing → Staging OK';
    ELSE
        RAISE NOTICE '[sp_executar_carga_completa] Landing → Staging SKIP (proc ausente neste ambiente)';
    END IF;

    -- 2. Limpeza/normalização — se existir no ambiente
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'staging' AND p.proname = 'sp_limpar_e_normalizar_staging'
    ) INTO v_existe;
    IF v_existe THEN
        CALL staging.sp_limpar_e_normalizar_staging();
        RAISE NOTICE '[sp_executar_carga_completa] Normalização OK';
    ELSE
        RAISE NOTICE '[sp_executar_carga_completa] Normalização SKIP (proc ausente neste ambiente)';
    END IF;

    -- 3. Enriquecimento CONAB → variedades — se existir no ambiente
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'staging' AND p.proname = 'sp_sincronizar_variedades_conab'
    ) INTO v_existe;
    IF v_existe THEN
        CALL staging.sp_sincronizar_variedades_conab();
        RAISE NOTICE '[sp_executar_carga_completa] Sincronização CONAB OK';
    ELSE
        RAISE NOTICE '[sp_executar_carga_completa] Sincronização CONAB SKIP (proc ausente neste ambiente)';
    END IF;

    -- 4. Cálculo sazonalidade (dados reais)
    CALL staging.sp_calcular_sazonalidade(NULL, NULL);
    RAISE NOTICE '[sp_executar_carga_completa] Sazonalidade (reais) OK';

    -- 5. Forecast V13 — DESATIVADO (refatoracao-dado-historico). Dado exibido passa a
    --    ser o histórico real com ano âncora. Proc permanece definida (audit trail), nunca invocada.
    -- CALL staging.sp_calcular_forecast_2026_v13();   -- desativado (audit trail)
    RAISE NOTICE '[sp_executar_carga_completa] Forecast V13 DESATIVADO — dado histórico real é a fonte de exibição';

    -- 6. Sanduíche Sazonal — DESATIVADO. Guard EXISTS mantido apenas para o aviso;
    --    o branch de execução é no-op. Proc permanece definida (audit trail).
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'staging' AND p.proname = 'sp_project_sandwich_prices_2026'
    ) INTO v_existe;
    IF v_existe THEN
        RAISE NOTICE '[sp_executar_carga_completa] Sanduíche Sazonal DESATIVADO (proc presente, não invocada)';
    ELSE
        RAISE NOTICE '[sp_executar_carga_completa] Sanduíche Sazonal SKIP (proc ausente neste ambiente)';
    END IF;

    -- 7. (NOVO) Refresh explícito da MV — antes executado pelas engines sintéticas.
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
    RAISE NOTICE '[sp_executar_carga_completa] MV vw_api_produtos_sazonalidade atualizada';

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Pipeline completo em % seg',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$procedure$;

COMMENT ON PROCEDURE staging.sp_executar_carga_completa IS
    'Pipeline completo — Carga + sazonalidade REAL + refresh da MV. '
    'Engines sintéticas (V13/sanduíche) DESATIVADAS (refatoracao-dado-historico): '
    'o dado exibido é o histórico real com ano âncora (N→N-1→N-2). '
    'Deve ser chamado após cada ciclo de coleta.';

GRANT ALL ON PROCEDURE staging.sp_executar_carga_completa TO role_etl_writer;

-- ============================================================================
-- SEÇÃO 2 — Colunas de transparência em mart.sazonalidade_produto
-- ============================================================================
-- 5 colunas NULLABLE (sem DEFAULT — D6: ficam NULL até o backfill único).
-- preco_referencia já existe (05:58); apenas 5 colunas são adicionadas.
-- As 2 UNIQUEs (uq_sazonalidade, uq_sazonalidade_data_ref) e o CHECK
-- chk_data_ref_ano_mes (YYYY-MM) NÃO são tocados — additive-only (R-ADD-07/S10).

ALTER TABLE mart.sazonalidade_produto
    ADD COLUMN IF NOT EXISTS ano_referencia         INTEGER,
    ADD COLUMN IF NOT EXISTS tipo_dado              TEXT,
    ADD COLUMN IF NOT EXISTS metadado_transparencia JSONB,
    ADD COLUMN IF NOT EXISTS idade_dado_anos        INTEGER,
    ADD COLUMN IF NOT EXISTS preco_exibido          NUMERIC(14,4);

COMMENT ON COLUMN mart.sazonalidade_produto.ano_referencia IS
    'Ano âncora do dado exibido (última cotação REAL). NULL p/ FALLBACK_DIMENSAO.';
COMMENT ON COLUMN mart.sazonalidade_produto.tipo_dado IS
    'REAL_ATUAL | HISTORICO_BASE | FALLBACK_DIMENSAO (snapshot de proveniência da linha; MV é a fonte de exibição).';
COMMENT ON COLUMN mart.sazonalidade_produto.metadado_transparencia IS
    'JSONB: fonte_dado, data_referencia, procedencia (coleta_real_conab|sintetico_proxy|sintetico_engine), calculado_em.';
COMMENT ON COLUMN mart.sazonalidade_produto.idade_dado_anos IS
    'ANO_ATUAL - ano_referencia (0 = ano corrente).';
COMMENT ON COLUMN mart.sazonalidade_produto.preco_exibido IS
    'Preço real exibido (sem multiplicador sintético). NULL p/ linhas não exibíveis.';

-- CHECK pós-backfill (R-ADD-01): valores restritos, NULL permitido.
-- DO guard p/ idempotência: ALTER TABLE ADD CONSTRAINT não tem IF NOT EXISTS.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_sazonalidade_tipo_dado'
          AND conrelid = 'mart.sazonalidade_produto'::regclass
    ) THEN
        ALTER TABLE mart.sazonalidade_produto
            ADD CONSTRAINT chk_sazonalidade_tipo_dado
            CHECK (tipo_dado IS NULL OR tipo_dado IN ('REAL_ATUAL','HISTORICO_BASE','FALLBACK_DIMENSAO'));
    END IF;
END $$;

-- ============================================================================
-- SEÇÃO 3 — Backfill único (single pass, sem JOINs, sem CROSS JOIN)
-- ============================================================================
-- ANO_ATUAL = EXTRACT(YEAR FROM CURRENT_DATE) em todo lugar (dinâmico — S6;
-- 2027 não exige mudança de código). Linhas FLUXO_PROXY/is_forecast são
-- marcadas FALLBACK_DIMENSAO, NUNCA deletadas (semântica de exibição apenas).
-- WHERE ano_referencia IS NULL garante idempotência (re-executável).

UPDATE mart.sazonalidade_produto AS s
SET ano_referencia = CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER),
    idade_dado_anos = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
                      - CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER),
    tipo_dado = CASE
        WHEN COALESCE(s.fonte,'') = 'FLUXO_PROXY' OR s.is_forecast THEN 'FALLBACK_DIMENSAO'
        WHEN CAST(SPLIT_PART(s.data_referencia_atual, '-', 1) AS INTEGER)
             = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER THEN 'REAL_ATUAL'
        ELSE 'HISTORICO_BASE'
    END,
    metadado_transparencia = jsonb_build_object(
        'fonte_dado',      COALESCE(s.fonte,'desconhecida'),
        'data_referencia', s.data_referencia_atual,
        'procedencia', CASE
            WHEN COALESCE(s.fonte,'') = 'FLUXO_PROXY' THEN 'sintetico_proxy'
            WHEN s.is_forecast THEN 'sintetico_engine'
            ELSE 'coleta_real_conab'
        END,
        'calculado_em',    s.calculado_em
    ),
    preco_exibido = CASE
        WHEN COALESCE(s.fonte,'') <> 'FLUXO_PROXY' AND NOT s.is_forecast THEN s.preco_atual
        ELSE NULL
    END
WHERE ano_referencia IS NULL;

DO $$
DECLARE
    v_total    BIGINT;
    v_real     BIGINT;
    v_fallback BIGINT;
    v_sem_ano  BIGINT;
BEGIN
    SELECT count(*),
           count(*) FILTER (WHERE tipo_dado IN ('REAL_ATUAL','HISTORICO_BASE')),
           count(*) FILTER (WHERE tipo_dado = 'FALLBACK_DIMENSAO'),
           count(*) FILTER (WHERE tipo_dado IN ('REAL_ATUAL','HISTORICO_BASE') AND ano_referencia IS NULL)
    INTO v_total, v_real, v_fallback, v_sem_ano
    FROM mart.sazonalidade_produto;

    RAISE NOTICE '[63] Backfill: % linhas (REAL_ATUAL+HISTORICO_BASE=%, FALLBACK_DIMENSAO=%, reais sem ano=%)',
        v_total, v_real, v_fallback, v_sem_ano;

    IF v_sem_ano > 0 THEN
        RAISE EXCEPTION '[63] Backfill inconsistente: % linha(s) REAL sem ano_referencia', v_sem_ano;
    END IF;
END $$;

COMMIT;

BEGIN;

-- ============================================================================
-- SEÇÃO 4 — VIEW auxiliar mart.vw_anchor_sazonalidade (D1)
-- ============================================================================
-- Âncora N → N-1 → N-2 por (id_produto, id_localidade, mes) sobre linhas REAIS
-- (CTE `real` exclui FLUXO_PROXY e is_forecast). SEM CROSS JOIN: os lookups
-- LATERAL filtram ≤3 anos candidatos por tupla via índice
-- uq_sazonalidade(id_produto,id_localidade,ano,mes); a referência varre no
-- máximo 12 linhas indexadas — evita o padrão OOM da Fase 62 (4.85M CROSS).
--
-- - preco_exibido     = preço real da linha âncora (SEM multiplicador — D5)
-- - preco_referencia  = AVG dos preços REAIS dos 12 meses anteriores ao mês
--                       âncora (mesmo produto/localidade) — base real p/ ±25%
-- - n_meses_referencia= nº de meses reais no período de referência
-- - status_cor        = semáforo ±25% inline, idêntico à fórmula 57:88:
--                       VERDE < ref*0.75, VERMELHO > ref*1.25, senão AMARELO;
--                       n_meses_referencia < 6 → AMARELO (base insuficiente)
-- - metadado_transparencia = JSONB de proveniência (fonte, data da coleta,
--                       procedencia 'coleta_real_conab', ano_referencia)
--
-- Tuplas SEM âncora real em N..N-2 ficam de fora (WHERE preco_exibido IS NOT
-- NULL) — o fallback de dimensão é tratado na MV (branch C).

CREATE OR REPLACE VIEW mart.vw_anchor_sazonalidade AS
WITH real AS (
    SELECT id_sazonalidade, id_produto, id_localidade, ano, mes,
           data_referencia_atual, preco_atual, fonte, calculado_em
    FROM mart.sazonalidade_produto
    WHERE COALESCE(fonte,'') <> 'FLUXO_PROXY' AND NOT is_forecast
      AND preco_atual IS NOT NULL AND preco_atual > 0
),
tuples AS (
    SELECT DISTINCT id_produto, id_localidade, mes FROM real
),
anchored AS (
    SELECT t.id_produto, t.id_localidade, t.mes,
           a.id_sazonalidade, a.ano AS ano_referencia, a.preco_atual AS preco_exibido,
           a.data_referencia_atual, a.calculado_em AS data_ultima_coleta, a.fonte,
           EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - a.ano AS idade_dado_anos,
           CASE WHEN a.ano = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
                THEN 'REAL_ATUAL' ELSE 'HISTORICO_BASE' END AS tipo_dado,
           r.preco_ref_real AS preco_referencia, r.n_meses AS n_meses_referencia
    FROM tuples t
    LEFT JOIN LATERAL (   -- âncora: linha real mais recente em N..N-2 p/ a tupla de mês
        SELECT r.id_sazonalidade, r.ano, r.preco_atual, r.data_referencia_atual,
               r.calculado_em, r.fonte
        FROM real r
        WHERE r.id_produto = t.id_produto
          AND r.id_localidade = t.id_localidade
          AND r.mes = t.mes
          AND r.ano BETWEEN EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - 2
                        AND EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
        ORDER BY r.ano DESC, r.mes DESC
        LIMIT 1
    ) a ON TRUE
    LEFT JOIN LATERAL (   -- referência REAL: 12 meses anteriores ao mês âncora
        SELECT AVG(r2.preco_atual)::NUMERIC(14,4) AS preco_ref_real, COUNT(*) AS n_meses
        FROM real r2
        WHERE r2.id_produto = t.id_produto
          AND r2.id_localidade = t.id_localidade
          AND (r2.ano * 12 + r2.mes) BETWEEN (a.ano * 12 + t.mes - 12)
                                        AND (a.ano * 12 + t.mes - 1)
    ) r ON TRUE
)
SELECT *,
       CASE
           WHEN n_meses_referencia IS NULL OR n_meses_referencia < 6 THEN 'AMARELO'
           WHEN preco_exibido IS NULL THEN NULL
           WHEN preco_exibido < preco_referencia * 0.75 THEN 'VERDE'
           WHEN preco_exibido > preco_referencia * 1.25 THEN 'VERMELHO'
           ELSE 'AMARELO'
       END AS status_cor,
       jsonb_build_object(
           'fonte_dado',        fonte,
           'data_ultima_coleta', data_ultima_coleta,
           'procedencia',       'coleta_real_conab',
           'ano_referencia',    ano_referencia
       ) AS metadado_transparencia
FROM anchored
WHERE preco_exibido IS NOT NULL;   -- só tuplas com âncora real (fallback → MV branch C)

COMMENT ON VIEW mart.vw_anchor_sazonalidade IS
    'Âncora N→N-1→N-2 por (produto, localidade, mes) sobre linhas REAIS '
    '(FLUXO_PROXY/is_forecast excluídos). preco_exibido = preço real da âncora '
    '(sem multiplicador); preco_referencia = AVG real 12m anteriores; '
    'status_cor ±25%% inline (57:88). Sem CROSS JOIN (D1).';

GRANT SELECT ON mart.vw_anchor_sazonalidade TO role_api_reader;

-- ============================================================================
-- SEÇÃO 5 — MV mart.vw_api_produtos_sazonalidade V17 (D3/D4/D5)
-- ============================================================================
-- Padrão da Fase 36 (DROP + CREATE + 7 índices + GRANT), 3 branches UNION ALL:
--   A) Linhas REAIS (navegação histórica ?ano=) com campos de âncora
--      (COALESCE(a.*, s.*)) — ano/mes próprios da linha real.
--   B) Linhas de EXIBIÇÃO ancoradas em ano = ANO_ATUAL (grade do ano corrente
--      completa — mata células cinza sem tocar na semântica da fn): id = -id,
--      somente quando ano_referencia < ANO_ATUAL (sem double-count com A).
--   C) FALLBACK_DIMENSAO (DISTINCT ON por tupla, prefere linha não-proxy):
--      id = -(id) - 1000000000, sem status_cor, proveniência no metadado.
-- Guard de colisão: DO block aborta se MAX(id_sazonalidade) >= 1000000000
-- (faixa dos ids negativos do branch C colidiria com ids positivos).
-- status_cor inline ±25% (igual 57:88); preco_exibido = preço real da âncora
-- (sem multiplicador — D5).

DO $$
DECLARE
    v_max BIGINT;
BEGIN
    SELECT MAX(id_sazonalidade) INTO v_max FROM mart.sazonalidade_produto;
    IF v_max IS NOT NULL AND v_max >= 1000000000 THEN
        RAISE EXCEPTION
            '[63] Colisão de id_sazonalidade: MAX(id_sazonalidade)=% >= 1000000000. '
            'A faixa de ids negativos do V17 (branch B: -id; branch C: -(id)-1e9) '
            'colidiria com ids positivos. Abortando criação da MV.', v_max;
    END IF;
    RAISE NOTICE '[63] Guard de colisão OK (MAX(id_sazonalidade)=%)', v_max;
END $$;

DROP MATERIALIZED VIEW IF EXISTS mart.vw_api_produtos_sazonalidade CASCADE;

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
-- CTE MATERIALIZED: a view âncora (LATERAL/DISTINCT) é avaliada UMA vez;
-- sem isso, o NOT EXISTS do branch C reavaliaria a view por linha (lentidão O(N²)).
WITH anchor AS MATERIALIZED (
    SELECT * FROM mart.vw_anchor_sazonalidade
)
SELECT
    v.id_sazonalidade,
    v.id_localidade,
    v.id_produto,
    v.produto,
    v.classificao_produto,
    v.conab_id_produto,
    v.status_fonte,
    v.categoria,
    v.uf,
    v.municipio,
    v.municipio_id,
    v.ano,
    v.mes,
    v.preco_referencia,
    v.preco_atual,
    v.data_referencia_atual,
    v.usou_fallback_12m,
    v.preco_estimado,
    v.status_cor,
    v.fonte,
    v.calculado_em,
    v.metodo_calculo,
    v.variacao_pct,
    v.tendencia_futura,
    v.is_forecast,
    v.baseline_confianca,
    v.forecast_method,
    -- Colunas de transparência (V17 — R-ADD-05)
    v.preco_exibido,
    v.ano_referencia,
    v.tipo_dado,
    v.idade_dado_anos,
    v.metadado_transparencia
FROM (
    -- ── BRANCH A — linhas reais com campos de âncora (navegação histórica) ──
    SELECT
        s.id_sazonalidade,
        s.id_localidade,
        p.id_produto,
        p.nome_produto AS produto,
        p.classificao_produto,
        p.conab_id_produto,
        p.status_fonte,
        COALESCE(c.nome_categoria, 'ALIMENTO_VAREJO'::text) AS categoria,
        l.uf,
        COALESCE(l.municipio_nome, l.uf || ' (UF)') AS municipio,
        l.municipio_id,
        (split_part(s.data_referencia_atual, '-', 1))::integer AS ano,
        (split_part(s.data_referencia_atual, '-', 2))::integer AS mes,
        COALESCE(a.preco_referencia, s.preco_referencia) AS preco_referencia,
        COALESCE(a.preco_exibido, s.preco_atual) AS preco_atual,
        s.data_referencia_atual,
        s.usou_fallback_12m,
        s.preco_estimado,
        COALESCE(a.status_cor, s.status_cor) AS status_cor,
        s.fonte,
        s.calculado_em,
        s.metodo_calculo,
        s.variacao_mom_pct AS variacao_pct,
        s.tendencia_futura,
        s.is_forecast,
        s.baseline_confianca,
        s.forecast_method,
        COALESCE(a.preco_exibido, s.preco_atual) AS preco_exibido,
        COALESCE(a.ano_referencia, s.ano_referencia) AS ano_referencia,
        COALESCE(a.tipo_dado, s.tipo_dado) AS tipo_dado,
        COALESCE(a.idade_dado_anos, s.idade_dado_anos) AS idade_dado_anos,
        COALESCE(a.metadado_transparencia, s.metadado_transparencia) AS metadado_transparencia
    FROM mart.sazonalidade_produto s
    JOIN staging.dim_produto p ON p.id_produto = s.id_produto
    JOIN staging.dim_localidade l ON l.id_localidade = s.id_localidade
    LEFT JOIN staging.dim_categoria c ON c.id_categoria = p.id_categoria
    LEFT JOIN anchor a
        ON a.id_produto = s.id_produto
       AND a.id_localidade = s.id_localidade
       AND a.mes = s.mes
    WHERE COALESCE(s.fonte, '') <> 'FLUXO_PROXY'
      AND NOT s.is_forecast
      AND s.status_cor IN ('VERDE','AMARELO','VERMELHO')
      AND p.categoria_b2c = 'ALIMENTO_VAREJO'
      AND (p.classificao_produto IS NULL
           OR p.classificao_produto NOT IN ('INSUMO_AGRICOLA','MAQUINARIO_FERRAMENTA','SERVICO_LOGISTICA'))
      AND (c.nome_categoria IS NULL
           OR c.nome_categoria NOT IN ('FLORES','OUTROS'))
      AND (COALESCE(a.status_cor, s.status_cor) IS NOT NULL
           OR COALESCE(a.tipo_dado, s.tipo_dado) = 'FALLBACK_DIMENSAO')

    UNION ALL

    -- ── BRANCH B — exibição ancorada em ano = ANO_ATUAL (grade do ano corrente) ──
    SELECT
        -a.id_sazonalidade AS id_sazonalidade,
        s.id_localidade,
        a.id_produto,
        p.nome_produto AS produto,
        p.classificao_produto,
        p.conab_id_produto,
        p.status_fonte,
        COALESCE(c.nome_categoria, 'ALIMENTO_VAREJO'::text) AS categoria,
        l.uf,
        COALESCE(l.municipio_nome, l.uf || ' (UF)') AS municipio,
        l.municipio_id,
        EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER AS ano,
        a.mes AS mes,
        a.preco_referencia AS preco_referencia,
        a.preco_exibido AS preco_atual,
        (EXTRACT(YEAR FROM CURRENT_DATE)::TEXT || '-' || LPAD(a.mes::TEXT, 2, '0')) AS data_referencia_atual,
        s.usou_fallback_12m,
        s.preco_estimado,
        a.status_cor AS status_cor,
        a.fonte AS fonte,
        a.data_ultima_coleta AS calculado_em,
        s.metodo_calculo,
        NULL::numeric AS variacao_pct,
        s.tendencia_futura,
        FALSE AS is_forecast,
        s.baseline_confianca,
        s.forecast_method,
        a.preco_exibido AS preco_exibido,
        a.ano_referencia AS ano_referencia,
        a.tipo_dado AS tipo_dado,
        a.idade_dado_anos AS idade_dado_anos,
        a.metadado_transparencia AS metadado_transparencia
    FROM anchor a
    JOIN mart.sazonalidade_produto s ON s.id_sazonalidade = a.id_sazonalidade
    JOIN staging.dim_produto p ON p.id_produto = a.id_produto
    JOIN staging.dim_localidade l ON l.id_localidade = a.id_localidade
    LEFT JOIN staging.dim_categoria c ON c.id_categoria = p.id_categoria
    WHERE a.ano_referencia < EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
      AND a.status_cor IS NOT NULL
      AND s.status_cor IN ('VERDE','AMARELO','VERMELHO')
      AND p.categoria_b2c = 'ALIMENTO_VAREJO'
      AND (p.classificao_produto IS NULL
           OR p.classificao_produto NOT IN ('INSUMO_AGRICOLA','MAQUINARIO_FERRAMENTA','SERVICO_LOGISTICA'))
      AND (c.nome_categoria IS NULL
           OR c.nome_categoria NOT IN ('FLORES','OUTROS'))

    UNION ALL

    -- ── BRANCH C — FALLBACK_DIMENSAO (sem histórico real em N..N-2) ──
    -- Parênteses obrigatórios: o ORDER BY do DISTINCT ON é do branch, não do UNION.
    (
    SELECT DISTINCT ON (f.id_produto, f.id_localidade, f.mes)
        -(f.id_sazonalidade) - 1000000000 AS id_sazonalidade,
        f.id_localidade,
        f.id_produto,
        p.nome_produto AS produto,
        p.classificao_produto,
        p.conab_id_produto,
        p.status_fonte,
        COALESCE(c.nome_categoria, 'ALIMENTO_VAREJO'::text) AS categoria,
        l.uf,
        COALESCE(l.municipio_nome, l.uf || ' (UF)') AS municipio,
        l.municipio_id,
        EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER AS ano,
        f.mes AS mes,
        NULL::numeric AS preco_referencia,
        NULLIF(f.preco_atual, 0) AS preco_atual,
        (EXTRACT(YEAR FROM CURRENT_DATE)::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0')) AS data_referencia_atual,
        f.usou_fallback_12m,
        f.preco_estimado,
        COALESCE(f.status_cor, 'AMARELO') AS status_cor,
        f.fonte AS fonte,
        f.calculado_em,
        f.metodo_calculo,
        NULL::numeric AS variacao_pct,
        f.tendencia_futura,
        FALSE AS is_forecast,
        NULL::numeric AS baseline_confianca,
        NULL::text AS forecast_method,
        NULLIF(f.preco_atual, 0) AS preco_exibido,
        NULL::integer AS ano_referencia,
        'FALLBACK_DIMENSAO'::text AS tipo_dado,
        NULL::integer AS idade_dado_anos,
        jsonb_build_object(
            'fonte_dado',    f.fonte,
            'procedencia',   CASE WHEN COALESCE(f.fonte,'') = 'FLUXO_PROXY'
                                  THEN 'sem_historico_real_uso_proxy'
                                  ELSE 'sem_historico_real' END,
            'data_referencia', f.data_referencia_atual
        ) AS metadado_transparencia
    FROM mart.sazonalidade_produto f
    JOIN staging.dim_produto p ON p.id_produto = f.id_produto
    JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
    LEFT JOIN staging.dim_categoria c ON c.id_categoria = p.id_categoria
    WHERE NOT EXISTS (
            SELECT 1 FROM anchor a2
            WHERE a2.id_produto = f.id_produto
              AND a2.id_localidade = f.id_localidade
              AND a2.mes = f.mes
        )
      AND f.status_cor IN ('VERDE','AMARELO','VERMELHO')
      AND p.categoria_b2c = 'ALIMENTO_VAREJO'
      AND (p.classificao_produto IS NULL
           OR p.classificao_produto NOT IN ('INSUMO_AGRICOLA','MAQUINARIO_FERRAMENTA','SERVICO_LOGISTICA'))
      AND (c.nome_categoria IS NULL
           OR c.nome_categoria NOT IN ('FLORES','OUTROS'))
    ORDER BY f.id_produto, f.id_localidade, f.mes,
             CASE WHEN COALESCE(f.fonte,'') = 'FLUXO_PROXY' THEN 1 ELSE 0 END,  -- prefere não-proxy
             f.data_referencia_atual DESC
    )
) v
ORDER BY v.ano, v.mes, v.is_forecast, v.status_cor, v.produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'V17 (refatoracao-dado-historico) — 3 branches: (A) linhas reais com âncora; '
    '(B) exibição ancorada em ano atual (id=-id, só quando ano_referencia<N); '
    '(C) FALLBACK_DIMENSAO (id=-(id)-1e9). preco_exibido = preço real sem '
    'multiplicador; status_cor ±25%% vs referência real (57:88); '
    'colunas de transparência ano_referencia/tipo_dado/idade_dado_anos/metadado. '
    'Linhas FLUXO_PROXY/sintéticas NUNCA entram na MV (semântica de exibição).';

-- Índices (padrão 36:202-214) — UNIQUE primeiro (obrigatório p/ CONCURRENTLY)
CREATE UNIQUE INDEX idx_vw_sazonalidade_unico ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);
CREATE INDEX idx_vw_sazonalidade_filtro ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);
CREATE INDEX idx_vw_sazonalidade_categoria ON mart.vw_api_produtos_sazonalidade (categoria);
CREATE INDEX idx_vw_sazonalidade_produto ON mart.vw_api_produtos_sazonalidade (id_produto);
CREATE INDEX idx_vw_sazonalidade_ano_mes ON mart.vw_api_produtos_sazonalidade (ano, mes) WHERE (ano IS NOT NULL AND mes IS NOT NULL);
CREATE INDEX idx_vw_sazonalidade_tipo_dado ON mart.vw_api_produtos_sazonalidade (tipo_dado) WHERE (tipo_dado IS NOT NULL);
CREATE INDEX idx_vw_sazonalidade_ano_referencia ON mart.vw_api_produtos_sazonalidade (ano_referencia DESC) WHERE (ano_referencia IS NOT NULL);

-- (RAISE NOTICE removido: inválido em SQL top-level — psql não aceita fora de
--  bloco PL/pgSQL; a criação dos índices é a evidência visível no log.)

GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;

-- ============================================================================
-- SEÇÃO 6 — fn_br_nacional_sazonalidade (+ ano_referencia, tipo_dado)
-- ============================================================================
-- Recreate a partir da 62:855-922 (DROP das duas assinaturas + CREATE) com 2
-- colunas de saída adicionais: ano_referencia INTEGER, tipo_dado TEXT
-- (MODE() em nível-1 e nível-2 — A.7). Sem mudança de fonte: branch B em
-- ano=ANO_ATUAL completa a grade do ano corrente; anos históricos seguem.

DROP FUNCTION IF EXISTS mart.fn_br_nacional_sazonalidade(INTEGER, TEXT);
DROP FUNCTION IF EXISTS mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER);

CREATE FUNCTION mart.fn_br_nacional_sazonalidade(
    p_ano       INTEGER,
    p_categoria TEXT DEFAULT NULL,
    p_min_ufs   INTEGER DEFAULT 1
)
RETURNS TABLE(
    produto             TEXT,
    classificao_produto TEXT,
    categoria           TEXT,
    mes                 INTEGER,
    data_referencia_atual TEXT,
    status_cor          TEXT,
    is_forecast         BOOLEAN,
    baseline_confianca  NUMERIC,
    total_ufs           BIGINT,
    forecast_method     TEXT,
    calculado_em        TIMESTAMPTZ,
    ano_referencia      INTEGER,
    tipo_dado           TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_categoria_filter TEXT := COALESCE(p_categoria, '%%');
    v_min_ufs INTEGER := COALESCE(p_min_ufs, 1);
BEGIN
    RETURN QUERY
    WITH uf_por_mes AS (
        -- Nível 1: consolida por (produto, UF, mes) — moda dentro da UF
        SELECT
            v.produto,
            v.classificao_produto,
            COALESCE(v.categoria, 'ALIMENTO_VAREJO') AS categoria_final,
            v.uf,
            v.mes,
            MODE() WITHIN GROUP (ORDER BY v.status_cor) AS uf_status_cor,
            BOOL_OR(v.is_forecast)       AS uf_forecast,
            MAX(v.baseline_confianca)    AS uf_confianca,
            MODE() WITHIN GROUP (ORDER BY v.forecast_method) AS uf_forecast_method,
            MAX(v.calculado_em)          AS uf_calculado_em,
            MODE() WITHIN GROUP (ORDER BY v.ano_referencia) AS uf_ano_ref,
            MODE() WITHIN GROUP (ORDER BY v.tipo_dado) AS uf_tipo_dado
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.ano = p_ano
          AND (p_categoria IS NULL OR v.categoria ILIKE v_categoria_filter)
        GROUP BY v.produto, v.classificao_produto, categoria_final, v.uf, v.mes
    )
    -- Nível 2: agrega por (produto, mes) — moda da moda entre UFs
    SELECT
        upm.produto,
        upm.classificao_produto,
        upm.categoria_final,
        upm.mes,
        (p_ano || '-' || LPAD(upm.mes::TEXT, 2, '0'))::TEXT AS data_ref,
        MODE() WITHIN GROUP (ORDER BY upm.uf_status_cor) AS status_cor_nac,
        BOOL_OR(upm.uf_forecast) AS is_forecast_nac,
        MAX(upm.uf_confianca) AS confianca_nac,
        COUNT(DISTINCT upm.uf) AS total_ufs_nac,
        MODE() WITHIN GROUP (ORDER BY upm.uf_forecast_method) AS forecast_method_nac,
        MAX(upm.uf_calculado_em) AS calculado_em_nac,
        MODE() WITHIN GROUP (ORDER BY upm.uf_ano_ref) AS ano_referencia_nac,
        MODE() WITHIN GROUP (ORDER BY upm.uf_tipo_dado) AS tipo_dado_nac
    FROM uf_por_mes upm
    GROUP BY upm.produto, upm.classificao_produto, upm.categoria_final, upm.mes
    HAVING COUNT(DISTINCT upm.uf) >= v_min_ufs
    ORDER BY upm.produto, upm.mes;
END;
$$;

COMMENT ON FUNCTION mart.fn_br_nacional_sazonalidade IS
    'Sazonalidade BR Nacional — retorna 12 meses de um ano. '
    'Moda da moda por UF, HAVING COUNT(DISTINCT uf) >= p_min_ufs (default 1). '
    'Inclui forecast_method (moda), calculado_em (máximo), ano_referencia (moda) '
    'e tipo_dado (moda). Uso: SELECT * FROM mart.fn_br_nacional_sazonalidade(2026);';

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_sazonalidade(INTEGER, TEXT, INTEGER)
    TO role_api_reader;

COMMIT;

-- ============================================================================
-- SEÇÃO 7 — Refresh inicial da MV V17 (fora de transação — CONCURRENTLY)
-- ============================================================================
-- REFRESH MATERIALIZED VIEW CONCURRENTLY não pode rodar dentro de bloco de
-- transação. A MV recém-criada já traz os dados (CREATE MATERIALIZED VIEW
-- popula); este refresh garante consistência pós-commit do restante do
-- arquivo e valida o índice UNIQUE (obrigatório para CONCURRENTLY).

REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;
