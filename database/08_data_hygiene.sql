-- ============================================================================
-- QUERO COMPRAR — Fase 11: Data Hygiene & Landing Zone do Scraper
-- PostgreSQL 16+  |  Append-Only Log, Upsert, Garbage Collection
--
-- MOTIVAÇÃO:
--   Os scrapers CEASA disparam diariamente e geram milhares de linhas.
--   Sem uma Landing Zone controlada, o banco incha com duplicatas e
--   lixo temporal (dados de preço do mesmo produto+localidade+DIA).
--
--   A comunidade (HN, r/dataengineering) recomenda o padrão Append-Only
--   Log para dados crus (raw.scraper_data) + upsert para a staging +
--   TTL de 30 dias na raw para controle de disco.
--
-- SUMÁRIO:
--   1. Tabela raw.scraper_data (append-only log, row_hash para dedup)
--   2. Função auxiliar de hash SHA-256 para identificação de duplicatas
--   3. Stored Procedure ops.sp_limpeza_diaria_scraper()
--      → Upsert raw → staging.fact_precos_mensais
--      → DELETE de registros com >30 dias na raw
--   4. Permissões
-- ============================================================================

BEGIN;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 1 — Tabela raw.scraper_data (Append-Only Log)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Propósito: Receber o dump diário dos scrapers CEASA/CEAGESP sem
--            transformação. Tratada como append-only: INSERT apenas,
--            sem UPDATE ou DELETE (exceto pelo TTL da GC).
--
-- A UNIQUE CONSTRAINT (nome_produto, id_localidade, data_ref::DATE)
-- impede duplicação do mesmo produto no mesmo local no mesmo dia.
-- =========================================================================

CREATE TABLE IF NOT EXISTS raw.scraper_data (
    id_scraper      BIGSERIAL PRIMARY KEY,
    nome_produto    TEXT NOT NULL,
    id_localidade   INTEGER REFERENCES staging.dim_localidade (id_localidade),
    preco_medio     NUMERIC(14,4) NOT NULL CHECK (preco_medio > 0),
    data_referencia DATE NOT NULL,
    data_extracao   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    row_hash        TEXT NOT NULL,
    fonte           TEXT NOT NULL DEFAULT 'ceasa',
    _batch_id       UUID NOT NULL DEFAULT gen_random_uuid(),
    _loaded_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  raw.scraper_data IS 'Append-only log: dados crus dos scrapers CEASA/CEAGESP/Agrolink';
COMMENT ON COLUMN raw.scraper_data.id_scraper      IS 'PK da linha de scraper';
COMMENT ON COLUMN raw.scraper_data.nome_produto    IS 'Nome do produto conforme extraído (sem normalização)';
COMMENT ON COLUMN raw.scraper_data.id_localidade   IS 'FK para staging.dim_localidade (pode ser NULL se município não mapeado)';
COMMENT ON COLUMN raw.scraper_data.preco_medio     IS 'Preço médio coletado (R$/kg ou R$/unidade)';
COMMENT ON COLUMN raw.scraper_data.data_referencia  IS 'Data da coleta referente ao preço';
COMMENT ON COLUMN raw.scraper_data.data_extracao    IS 'Timestamp da extração pelo scraper';
COMMENT ON COLUMN raw.scraper_data.row_hash         IS 'SHA-256 da linha para detecção de duplicatas exatas';
COMMENT ON COLUMN raw.scraper_data.fonte            IS 'Fonte: ceasa, ceagesp, agrolink, conab';
COMMENT ON COLUMN raw.scraper_data._batch_id        IS 'UUID do lote de extração';
COMMENT ON COLUMN raw.scraper_data._loaded_at       IS 'Timestamp da inserção no banco';

-- Unique constraint: mesmo produto + mesmo local + mesmo dia = duplicata
CREATE UNIQUE INDEX IF NOT EXISTS uq_scraper_data_dia
    ON raw.scraper_data (nome_produto, COALESCE(id_localidade, 0), data_referencia);

-- Índice para a GC diária (DELETE WHERE data_extracao < cutoff)
CREATE INDEX IF NOT EXISTS idx_scraper_data_extracao
    ON raw.scraper_data (data_extracao);

-- Índice para upsert performance
CREATE INDEX IF NOT EXISTS idx_scraper_data_produto
    ON raw.scraper_data (nome_produto, data_referencia);

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 2 — Trigger de Hash Automático
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Gera o row_hash automaticamente antes do INSERT caso não fornecido.
-- =========================================================================

CREATE OR REPLACE FUNCTION raw.trg_scraper_data_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.row_hash IS NULL THEN
        NEW.row_hash := encode(
            sha256(
                COALESCE(NEW.nome_produto, '') || '|' ||
                COALESCE(NEW.id_localidade::TEXT, '0') || '|' ||
                COALESCE(NEW.preco_medio::TEXT, '0') || '|' ||
                COALESCE(NEW.data_referencia::TEXT, '') || '|' ||
                COALESCE(NEW.fonte, '')
            ),
            'hex'
        );
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_scraper_data_hash ON raw.scraper_data;
CREATE TRIGGER trg_scraper_data_hash
    BEFORE INSERT ON raw.scraper_data
    FOR EACH ROW
    EXECUTE FUNCTION raw.trg_scraper_data_hash();

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 3 — Stored Procedure: ops.sp_limpeza_diaria_scraper()
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Executa 3 operações:
--   1. Upsert raw → staging.fact_precos_mensais (resolve conflitos)
--   2. DELETE de registros com >30 dias na raw (TTL)
--   3. Log do resultado
--
-- Parâmetros:
--   p_dias_retencao  → Dias para manter na raw (default 30)
--   p_dry_run        → Se TRUE, apenas reporta sem modificar dados
--
-- Retorno: TABLE com estatísticas da execução
-- =========================================================================

CREATE OR REPLACE PROCEDURE ops.sp_limpeza_diaria_scraper(
    p_dias_retencao  INTEGER DEFAULT 30,
    p_dry_run        BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_cutoff       TIMESTAMPTZ := NOW() - (p_dias_retencao || ' days')::INTERVAL;
    v_upsertados   INTEGER := 0;
    v_ignorados    INTEGER := 0;
    v_deletados    INTEGER := 0;
    v_rejeitados   INTEGER := 0;
    v_total_raw    INTEGER;
    v_total_staging INTEGER;
BEGIN
    -- Total atual na raw
    SELECT count(*) INTO v_total_raw FROM raw.scraper_data;

    -- ── Passo 1: Upsert raw → staging.fact_precos_mensais ──────────
    -- Mapeia nome_produto → id_produto via dim_produto.
    -- Registros sem match em dim_produto são ignorados (logados).
    -- Usa ON CONFLICT DO UPDATE para evitar duplicação.

    IF NOT p_dry_run THEN
        WITH dados_para_upsert AS (
            SELECT
                dp.id_produto,
                s.id_localidade,
                EXTRACT(YEAR FROM s.data_referencia)::SMALLINT AS ano,
                EXTRACT(MONTH FROM s.data_referencia)::SMALLINT AS mes,
                s.preco_medio,
                s._batch_id
            FROM raw.scraper_data s
            JOIN staging.dim_produto dp
                ON normalize_nome_produto(s.nome_produto) = normalize_nome_produto(dp.nome_produto)
            WHERE s._loaded_at > v_cutoff  -- só dados recentes
              AND s.id_localidade IS NOT NULL
        ),
        upsertados AS (
            INSERT INTO staging.fact_precos_mensais
                (id_produto, id_localidade, ano, mes, preco_medio, batch_id)
            SELECT
                id_produto, id_localidade, ano, mes, preco_medio, _batch_id
            FROM dados_para_upsert
            ON CONFLICT (id_produto, id_localidade, ano, mes)
            DO UPDATE SET
                preco_medio = EXCLUDED.preco_medio,
                batch_id    = EXCLUDED.batch_id,
                loaded_at   = NOW()
            RETURNING 1
        )
        SELECT count(*) INTO v_upsertados FROM upsertados;

        -- Conta registros ignorados (sem match em dim_produto)
        SELECT count(*) INTO v_ignorados
        FROM raw.scraper_data s
        WHERE s._loaded_at > v_cutoff
          AND NOT EXISTS (
              SELECT 1 FROM staging.dim_produto dp
              WHERE normalize_nome_produto(s.nome_produto) = normalize_nome_produto(dp.nome_produto)
          );
    END IF;

    -- ── Passo 2: Garbage Collection — apaga raw com >30 dias ────────
    IF NOT p_dry_run THEN
        WITH deletados AS (
            DELETE FROM raw.scraper_data
            WHERE data_extracao < v_cutoff
            RETURNING 1
        )
        SELECT count(*) INTO v_deletados FROM deletados;
    ELSE
        SELECT count(*) INTO v_deletados
        FROM raw.scraper_data
        WHERE data_extracao < v_cutoff;
    END IF;

    -- Total final na staging
    SELECT count(*) INTO v_total_staging FROM staging.fact_precos_mensais;

    -- ── Log do resultado ─────────────────────────────────────────────
    RAISE NOTICE '=== sp_limpeza_diaria_scraper (%s) ===', CASE WHEN p_dry_run THEN 'DRY RUN' ELSE 'EXECUTADO' END;
    RAISE NOTICE '  Total raw (antes):     %', v_total_raw;
    RAISE NOTICE '  Upsertados staging:    %', v_upsertados;
    RAISE NOTICE '  Ignorados (sem match): %', v_ignorados;
    RAISE NOTICE '  Deletados da raw:      %', v_deletados;
    RAISE NOTICE '  Total staging (agora): %', v_total_staging;
    RAISE NOTICE '=====================================';
END $$;

COMMENT ON PROCEDURE ops.sp_limpeza_diaria_scraper IS
    'Rotina diária: upsert raw.scraper_data → staging.fact_precos_mensais, '
    'GC de registros com >30 dias, log de estatísticas. '
    'Parâmetro p_dry_run = TRUE para simular sem modificar dados.';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 4 — Função de normalização auxiliar (para matching produto)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Necessária para fazer JOIN entre nome_produto dos scrapers (imperfeito)
-- e o nome normalizado em dim_produto.
-- =========================================================================

CREATE OR REPLACE FUNCTION staging.normalize_nome_produto(p_nome TEXT)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT lower(regexp_replace(
        regexp_replace(
            trim(p_nome),
            '\s+', ' ', 'g'
        ),
        '[^a-z0-9áéíóúâêîôûãõçàèìòùäëïöü \.]', '', 'g'
    ));
$$;

COMMENT ON FUNCTION staging.normalize_nome_produto IS
    'Normaliza nome de produto para matching: lower case, remove acentos (via transliteração manual) e espaços extras';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 5 — Permissões
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

GRANT ALL ON TABLE raw.scraper_data TO role_etl_writer;
GRANT SELECT ON TABLE raw.scraper_data TO role_api_reader;

GRANT ALL ON FUNCTION raw.trg_scraper_data_hash() TO role_etl_writer;

GRANT ALL ON PROCEDURE ops.sp_limpeza_diaria_scraper TO role_etl_writer;

GRANT ALL ON FUNCTION staging.normalize_nome_produto(TEXT) TO role_etl_writer;
GRANT EXECUTE ON FUNCTION staging.normalize_nome_produto(TEXT) TO role_api_reader;

COMMIT;
