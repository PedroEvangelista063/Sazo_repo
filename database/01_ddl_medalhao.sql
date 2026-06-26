-- ============================================================================
-- QUERO COMPRAR — DDL Completo (Arquitetura Medalhão)
-- PostgreSQL 16+  |  Fase 1: Backend & Database
--
-- Executar no DBeaver como superusuário (postgres).
-- Dividido em seções: schemas → tabelas → índices → funções/triggers →
-- procedures → views → roles → manutenção.
-- ============================================================================
-- SÉRIO: Nunca execute este script em produção sem revisar as configurações
-- de tablespace, encoding e permissões específicas do seu ambiente.
-- ============================================================================

BEGIN;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 0 — EXTENSÕES
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE EXTENSION IF NOT EXISTS pgcrypto;           -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pg_stat_statements; -- monitoramento de queries

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 1 — SCHEMAS (Medalhão adaptado para RDBMS)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- raw:     dados brutos "como chegam" (tabelas staging para COPY direto)
-- staging: dados limpos, tipados, normalizados (Star Schema)
-- mart:    regras de negócio, sazonalidade, visão para a API
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS mart;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 2 — TABELAS RAW (cópia fiel do CONAB, 1∶1)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE TABLE raw.precos_uf (
    id              BIGSERIAL   PRIMARY KEY,
    produto         TEXT,
    uf              CHAR(2),
    ano             SMALLINT,
    mes             SMALLINT,
    preco_medio     TEXT,       -- mantido como TEXT para evitar perda na carga
    _arquivo        TEXT        NOT NULL DEFAULT 'PrecosMensalUF',
    _loaded_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    _batch_id       UUID        NOT NULL DEFAULT gen_random_uuid()
);

CREATE TABLE raw.precos_municipio (
    id              BIGSERIAL   PRIMARY KEY,
    produto         TEXT,
    municipio_id    TEXT,
    municipio_nome  TEXT,
    uf              CHAR(2),
    ano             SMALLINT,
    mes             SMALLINT,
    preco_medio     TEXT,
    _arquivo        TEXT        NOT NULL DEFAULT 'PrecosMensalMunicipio',
    _loaded_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    _batch_id       UUID        NOT NULL DEFAULT gen_random_uuid()
);

CREATE TABLE raw.controle_carga (
    id              BIGSERIAL       PRIMARY KEY,
    batch_id        UUID            NOT NULL UNIQUE,
    arquivo         TEXT            NOT NULL,
    linhas_lidas    INTEGER         NOT NULL DEFAULT 0,
    linhas_inseridas INTEGER        NOT NULL DEFAULT 0,
    linhas_rejeitadas INTEGER       NOT NULL DEFAULT 0,
    duracao_seg     NUMERIC(10,2),
    status          TEXT            NOT NULL DEFAULT 'em_andamento'
                        CHECK (status IN ('em_andamento','sucesso','falha')),
    iniciado_em     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    concluido_em    TIMESTAMPTZ
);

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 3 — TABELAS STAGING (Star Schema — limpas e tipadas)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE TABLE staging.dim_produto (
    id_produto      SERIAL      PRIMARY KEY,
    nome_produto    TEXT        NOT NULL UNIQUE,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE staging.dim_localidade (
    id_localidade   SERIAL      PRIMARY KEY,
    uf              CHAR(2)     NOT NULL,
    municipio_id    TEXT,
    municipio_nome  TEXT,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_dim_localidade UNIQUE (uf, municipio_id)
);

CREATE TABLE staging.fact_precos_mensais (
    id_fato         BIGSERIAL       PRIMARY KEY,
    id_produto      INTEGER         NOT NULL REFERENCES staging.dim_produto(id_produto),
    id_localidade   INTEGER         NOT NULL REFERENCES staging.dim_localidade(id_localidade),
    ano             SMALLINT        NOT NULL,
    mes             SMALLINT        NOT NULL CHECK (mes BETWEEN 1 AND 12),
    preco_medio     NUMERIC(14,4)   NOT NULL CHECK (preco_medio > 0),
    batch_id        UUID            NOT NULL,
    loaded_at       TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_fact_precos_mensais UNIQUE (id_produto, id_localidade, ano, mes)
);

CREATE INDEX idx_fact_precos_busca
    ON staging.fact_precos_mensais (id_produto, id_localidade, ano, mes);

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 3.1 — TABELA DE QUARENTENA (dados rejeitados por anomalia)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE TABLE staging.precos_rejeitados (
    id_rejeitado    BIGSERIAL   PRIMARY KEY,
    id_produto      INTEGER,
    id_localidade   INTEGER,
    ano             SMALLINT,
    mes             SMALLINT,
    preco_medio     NUMERIC(14,4),
    preco_medio_historico NUMERIC(14,4),
    razao           TEXT        NOT NULL,
    dados_brutos    JSONB,
    rejeitado_em    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    batch_id        UUID
);

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 4 — TABELA MART (sazonalidade materializada)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE TABLE mart.sazonalidade_produto (
    id_sazonalidade     BIGSERIAL       PRIMARY KEY,
    id_produto          INTEGER         NOT NULL,
    id_localidade       INTEGER         NOT NULL,
    ano                 SMALLINT        NOT NULL,
    mes                 SMALLINT        NOT NULL CHECK (mes BETWEEN 1 AND 12),
    preco_medio         NUMERIC(14,4)   NOT NULL,
    media_movel_12m     NUMERIC(14,4),
    indice_sazonalidade NUMERIC(8,4),
    status_cor          TEXT            NOT NULL
                        CHECK (status_cor IN ('VERDE','AMARELO','VERMELHO','INSUFICIENTE')),
    fonte               TEXT            NOT NULL DEFAULT 'municipio'
                        CHECK (fonte IN ('municipio','uf')),
    calculado_em        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_sazonalidade UNIQUE (id_produto, id_localidade, ano, mes)
);

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 4.1 — ÍNDICES PARA PERFORMANCE DA API
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE INDEX idx_sazonalidade_api
    ON mart.sazonalidade_produto (id_localidade, id_produto, ano, mes);

CREATE INDEX idx_sazonalidade_status
    ON mart.sazonalidade_produto (status_cor)
    WHERE status_cor IN ('VERDE','VERMELHO');

CREATE INDEX idx_sazonalidade_mes
    ON mart.sazonalidade_produto (ano, mes);

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 5 — FUNÇÕES UTILITÁRIAS
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- 5.1. Parsing de preço CONAB: "2,27" → NUMERIC
CREATE OR REPLACE FUNCTION staging._parse_conab_price(p_texto TEXT)
RETURNS NUMERIC(14,4) AS $$
BEGIN
    IF p_texto IS NULL OR trim(p_texto) = '' THEN
        RETURN NULL;
    END IF;
    RETURN NULLIF(replace(trim(p_texto), ',', '.'), '')::NUMERIC(14,4);
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 5.2. Batch ID para carga
CREATE OR REPLACE FUNCTION staging._gerar_batch_id()
RETURNS UUID AS $$
    SELECT gen_random_uuid();
$$ LANGUAGE sql VOLATILE;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 6 — TRIGGER DE ANOMALIA DE PREÇO (Garbage In, Garbage Out)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Se o preço inserido exceder 500% da média histórica do mesmo produto
-- na mesma localidade, a linha é desviada para staging.precos_rejeitados
-- em vez de abortar a transação inteira.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE FUNCTION staging.trg_valida_anomalia_preco()
RETURNS TRIGGER AS $$
DECLARE
    v_media_historica NUMERIC(14,4);
    v_dados_brutos    JSONB;
BEGIN
    -- Buscar média histórica do mesmo produto+localidade (excluindo o mês atual)
    SELECT AVG(preco_medio) INTO v_media_historica
    FROM staging.fact_precos_mensais
    WHERE id_produto    = NEW.id_produto
      AND id_localidade = NEW.id_localidade
      AND NOT (ano = NEW.ano AND mes = NEW.mes);

    -- Se não há histórico, deixa passar (primeira aparição)
    IF v_media_historica IS NULL THEN
        RETURN NEW;
    END IF;

    -- Se preço > 500% da média histórica → quarentena
    IF NEW.preco_medio > (v_media_historica * 5.0) THEN
        v_dados_brutos := jsonb_build_object(
            'produto_id',   NEW.id_produto,
            'localidade_id', NEW.id_localidade,
            'ano',          NEW.ano,
            'mes',          NEW.mes,
            'preco_enviado', NEW.preco_medio,
            'media_historica', v_media_historica
        );

        INSERT INTO staging.precos_rejeitados (
            id_produto, id_localidade, ano, mes,
            preco_medio, preco_medio_historico, razao,
            dados_brutos, batch_id
        ) VALUES (
            NEW.id_produto, NEW.id_localidade, NEW.ano, NEW.mes,
            NEW.preco_medio, v_media_historica,
            'Preço excede 500% da média histórica — possível erro de digitação',
            v_dados_brutos, NEW.batch_id
        );

        -- Aborta a inserção da linha específica (não a transação)
        RETURN NULL;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION staging.trg_valida_anomalia_preco() IS
    'Desvia para quarentena preços >500% da média histórica do mesmo produto+localidade';

CREATE OR REPLACE TRIGGER trg_valida_anomalia_preco
    BEFORE INSERT ON staging.fact_precos_mensais
    FOR EACH ROW
    WHEN (NEW.preco_medio IS NOT NULL)
    EXECUTE FUNCTION staging.trg_valida_anomalia_preco();

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 7 — STORED PROCEDURE: sp_calcular_sazonalidade
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Calcula a média móvel de 12 meses para cada produto por localidade e
-- classifica o status (semáforo) conforme a regra:
--
--   VERDE     → preço do mês < média anual - 15%
--   AMARELO   → preço entre -15% e +15% da média anual
--   VERMELHO  → preço do mês > média anual + 15%
--   INSUFICIENTE → menos de 6 meses de histórico
--
-- Materializa o resultado em mart.sazonalidade_produto.
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

    -- Se não informado, calcular para o último mês disponível
    IF p_ano_alvo IS NULL OR p_mes_alvo IS NULL THEN
        SELECT MAX(ano), MAX(mes) INTO v_ano, v_mes
        FROM staging.fact_precos_mensais;
    ELSE
        v_ano := p_ano_alvo;
        v_mes := p_mes_alvo;
    END IF;

    RAISE NOTICE '[sp_calcular_sazonalidade] Alvo: %-%', v_ano, v_mes;

    -- Upsert materializado no mart
    INSERT INTO mart.sazonalidade_produto (
        id_produto, id_localidade, ano, mes,
        preco_medio, media_movel_12m, indice_sazonalidade,
        status_cor, fonte, calculado_em
    )
    WITH precos_12m AS (
        -- 12 meses anteriores (incluindo o mês alvo) para o rolling window
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
        -- Índice de Sazonalidade = preço / média móvel
        CASE
            WHEN p.media_movel_12m IS NOT NULL AND p.media_movel_12m > 0
            THEN ROUND(p.preco_medio / p.media_movel_12m, 4)
            ELSE NULL
        END AS indice_sazonalidade,
        -- Semáforo (Traffic Light)
        CASE
            WHEN p.meses_no_window < 6 THEN 'INSUFICIENTE'
            WHEN p.media_movel_12m IS NULL OR p.media_movel_12m = 0 THEN 'INSUFICIENTE'
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

    RAISE NOTICE '[sp_calcular_sazonalidade] Concluído: % linhas em % seg',
        v_total, ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

COMMENT ON PROCEDURE staging.sp_calcular_sazonalidade IS
    'Calcula média móvel 12m e classifica semáforo (VERDE/AMARELO/VERMELHO) '
    'por produto+localidade. Upsert no mart.sazonalidade_produto.';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 8 — MATERIALIZED VIEW (otimizada para API)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade AS
SELECT
    s.id_sazonalidade,
    p.nome_produto       AS produto,
    l.uf,
    l.municipio_nome     AS municipio,
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
ORDER BY s.ano DESC, s.mes DESC, p.nome_produto;

COMMENT ON MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade IS
    'View única para a API consultar — contém produto, localidade e status do semáforo';

CREATE UNIQUE INDEX idx_vw_api_unique
    ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);

CREATE INDEX idx_vw_api_filtro
    ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 9 — STORED PROCEDURE: sp_executar_carga_completa
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Orquestra o refresh completo: atualiza dimensões → fato → sazonalidade →
-- materialized view.
-- Pode ser chamado pelo script Python AO FINAL da carga.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE PROCEDURE staging.sp_executar_carga_completa()
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio TIMESTAMPTZ;
    v_fim    TIMESTAMPTZ;
    v_ultimo_ano  SMALLINT;
    v_ultimo_mes  SMALLINT;
    v_total_fato  INTEGER;
    v_total_saz   INTEGER;
BEGIN
    v_inicio := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Iniciando...';

    -- 1. Atualizar estatísticas do planner
    ANALYZE staging.fact_precos_mensais;

    -- 2. Último mês disponível
    SELECT MAX(ano), MAX(mes) INTO v_ultimo_ano, v_ultimo_mes
    FROM staging.fact_precos_mensais;

    -- 3. Calcular sazonalidade
    CALL staging.sp_calcular_sazonalidade(v_ultimo_ano, v_ultimo_mes);

    -- 4. Refresh da Materialized View
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

    -- 5. VACUUM é executado separadamente via cron (Seção 11)

    v_fim := clock_timestamp();
    RAISE NOTICE '[sp_executar_carga_completa] Concluído em % seg',
        ROUND(EXTRACT(EPOCH FROM v_fim - v_inicio)::NUMERIC, 2);
END;
$$;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 10 — ROLES E PERMISSÕES (Segurança)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

DO $$
BEGIN
    -- role_etl_writer: usado pelo script Python de ingestão
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_etl_writer') THEN
        CREATE ROLE role_etl_writer WITH LOGIN PASSWORD 'mude_essa_senha_em_producao';
    END IF;

    -- role_api_reader: usado pela aplicação FastAPI
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_api_reader') THEN
        CREATE ROLE role_api_reader WITH LOGIN PASSWORD 'mude_essa_senha_em_producao';
    END IF;
END;
$$;

-- Permissões ETL Writer
GRANT USAGE ON SCHEMA raw     TO role_etl_writer;
GRANT USAGE ON SCHEMA staging TO role_etl_writer;
GRANT USAGE ON SCHEMA mart    TO role_etl_writer;

GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA raw     TO role_etl_writer;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA staging TO role_etl_writer;
GRANT INSERT, SELECT, UPDATE, DELETE  ON ALL TABLES    IN SCHEMA mart    TO role_etl_writer;
GRANT USAGE ON ALL SEQUENCES          IN SCHEMA raw     TO role_etl_writer;
GRANT USAGE ON ALL SEQUENCES          IN SCHEMA staging TO role_etl_writer;
GRANT USAGE ON ALL SEQUENCES          IN SCHEMA mart    TO role_etl_writer;

GRANT EXECUTE ON ALL FUNCTIONS     IN SCHEMA staging TO role_etl_writer;
GRANT EXECUTE ON ALL PROCEDURES    IN SCHEMA staging TO role_etl_writer;

-- Permissões API Reader
GRANT USAGE ON SCHEMA mart TO role_api_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA mart TO role_api_reader;
GRANT SELECT ON mart.vw_api_produtos_sazonalidade TO role_api_reader;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 10.1 — ROW-LEVEL SECURITY (comentário explicativo)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Caso o app evolua para um modelo B2B (ex: produtores/feirantes
-- cadastrados que só veem dados dos seus próprios produtos):
--
--   1. Adicionar coluna "id_produtor" em dim_produto
--   2. Ativar RLS:
--        ALTER TABLE mart.sazonalidade_produto ENABLE ROW LEVEL SECURITY;
--   3. Criar política:
--        CREATE POLICY produtor_policy ON mart.sazonalidade_produto
--            FOR SELECT
--            USING (id_produto IN (
--                SELECT id_produto FROM staging.dim_produto
--                WHERE id_produtor = current_setting('app.id_produtor')::INTEGER
--            ));
--   4. O backend FastAPI define o valor via:
--        SET app.id_produtor = '42';
--   5. A role_api_reader jamais poderá fazer DROP/UPDATE/INSERT em nada.
--
-- Não ativamos agora porque o modelo B2B está fora do escopo da Fase 1.

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 11 — MANUTENÇÃO PROGRAMADA (VACUUM + ANALYZE)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Sugestão de cron (linux):
--
--   # VACUUM ANALYZE diário nas tabelas fato (03:00)
--   0 3 * * * psql -d quero_comprar -c "VACUUM ANALYZE staging.fact_precos_mensais; VACUUM ANALYZE mart.sazonalidade_produto;"
--
--   # Refresh completo semanal (domingo 04:00)
--   0 4 * * 0 psql -d quero_comprar -c "CALL staging.sp_executar_carga_completa();"
--
--   # Backup incremental (via pg_dump) — ver seção 12

-- Comando de manutenção pós-carga (executar no final do pipeline):
-- VACUUM ANALYZE staging.fact_precos_mensais;
-- VACUUM ANALYZE mart.sazonalidade_produto;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 12 — BACKUP (pg_dump)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Backup full (custom format, comprimido, paralelo):
--   pg_dump -U postgres -h localhost -d quero_comprar \
--           -Fc -j 4 -f /backups/quero_comprar_$(date +\%Y\%m\%d).dump
--
-- Restore:
--   pg_restore -U postgres -h localhost -d quero_comprar \
--              -j 4 --clean --if-exists /backups/quero_comprar_YYYYMMDD.dump
--
-- Sugestão crontab:
--   0 2 * * * pg_dump -U postgres -h localhost -d quero_comprar \
--                    -Fc -j 4 -f /backups/quero_comprar_$(date +\%\%Y\%\%m\%\%d).dump
--
-- Backup só do schema mart (para a API):
--   pg_dump -U postgres -h localhost -d quero_comprar \
--           -n mart -Fc -j 2 -f /backups/quero_comprar_mart_$(date +\%Y\%m\%d).dump

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 13 — COPY TEMPLATE (para referência no DBeaver)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Exemplo de COPY direto para raw.precos_uf:
--
--   COPY raw.precos_uf (produto, uf, ano, mes, preco_medio)
--   FROM 'C:/caminho/PrecosMensalUF.txt'
--   WITH (FORMAT CSV, DELIMITER ';', HEADER true, ENCODING 'LATIN1');
--
-- ATENÇÃO: O encoding dos arquivos CONAB é LATIN1 (ISO-8859-1).
-- No DBeaver, configure a codificação da conexão para LATIN1 antes
-- de executar COPY, ou use o script Python (preferido) que faz a
-- sanitização antes de enviar ao banco.

COMMIT;
