-- ============================================================================
-- MIGRATION 75 — RESTAURAÇÃO DE mart.sazonalidade_baseline
-- ============================================================================
-- DATA: 2026-08-08
-- AUTOR: auditoria/operação (Quality Gate 12 meses + incidente de produção)
--
-- CONTEXTO / INCIDENTE
-- --------------------
-- Na limpeza de resíduos aprovada (DROP de tabelas de backup/legado após o
-- incidente de disco no Aiven free), a tabela mart.sazonalidade_baseline foi
-- DROPADA junto com os resíduos. Porém ela é uma tabela ATIVA: o endpoint
-- /api/v1/sazonalidade* (backend/app/api/v1/endpoints/produtos.py, linhas
-- 323, 529 e 1012) faz LEFT JOIN mart.sazonalidade_baseline b para expor o
-- campo `confianca_baseline`. A ausência da tabela causava HTTP 500 nos
-- endpoints de sazonalidade em produção (Render + Aiven).
--
-- A checagem pré-DROP (pg_rewrite/pg_constraint) não cobria dependências de
-- código Python — lição registrada.
--
-- RECUPERAÇÃO
-- -----------
-- Os DADOS foram restaurados do backup EXCLUSIVAMENTE LOCAL
-- (database/backups_locais/backup_pre_quality_gate_20260808_113130.dump),
-- política Zero-Waste: nenhum dump/backup foi criado no Aiven.
--
--   pg_restore --no-owner --no-privileges -d "$DATABASE_URL" \
--     -t 'sazonalidade_baseline' \
--     database/backups_locais/backup_pre_quality_gate_20260808_113130.dump
--
-- (Nota: usar -t sem prefixo de schema; com prefixo mart. não restaura.)
--
-- Este arquivo documenta a recuperação e garante o DDL + RLS + políticas
-- reprodutíveis. Em ambiente novo, aplicar esta migration e então restaurar
-- os dados a partir do backup local.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) DDL idempotente (sequence + tabela)
-- ---------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS mart.sazonalidade_baseline_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

CREATE TABLE IF NOT EXISTS mart.sazonalidade_baseline (
    id integer DEFAULT nextval('mart.sazonalidade_baseline_id_seq'::regclass) NOT NULL,
    id_produto integer NOT NULL,
    id_localidade integer NOT NULL,
    mes integer NOT NULL,
    status_cor_mode text NOT NULL,
    confianca numeric(5,2) DEFAULT 0 NOT NULL,
    fonte text DEFAULT 'BASELINE_HISTORICO'::text NOT NULL,
    atualizado_em timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sazonalidade_baseline_mes_check CHECK (((mes >= 1) AND (mes <= 12))),
    CONSTRAINT sazonalidade_baseline_status_cor_mode_check CHECK ((status_cor_mode = ANY (ARRAY['VERDE'::text, 'AMARELO'::text, 'VERMELHO'::text])))
);

-- Owner: apenas garante postgres no ambiente local (no Aiven o owner é o
-- usuário superuser do serviço — avnadmin — e SET ROLE postgres é proibido).
-- Portanto, não alteramos owner de forma incondicional. O acesso real é via
-- RLS policies (api_reader_select / etl_writer_all), independente de owner.

-- Constraint de unicidade e PK (idempotente via DO block)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sazonalidade_baseline_pkey') THEN
        ALTER TABLE ONLY mart.sazonalidade_baseline ADD CONSTRAINT sazonalidade_baseline_pkey PRIMARY KEY (id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sazonalidade_baseline_id_produto_id_localidade_mes_key') THEN
        ALTER TABLE ONLY mart.sazonalidade_baseline ADD CONSTRAINT sazonalidade_baseline_id_produto_id_localidade_mes_key UNIQUE (id_produto, id_localidade, mes);
    END IF;
END $$;

-- Índice de apoio por mês (igual ao backup)
CREATE INDEX IF NOT EXISTS idx_baseline_mes ON mart.sazonalidade_baseline USING btree (mes);

-- ---------------------------------------------------------------------------
-- 2) Higienização: remover linhas de produtos que saíram da camada de
--    exibição no Quality Gate de 12 meses (migration 74). A baseline restaurada
--    contém linhas de todos os produtos do momento do backup; a dim atual tem
--    863 produtos. (No incidente, 5.600 linhas órfãs foram removidas.)
-- ---------------------------------------------------------------------------
DELETE FROM mart.sazonalidade_baseline b
WHERE NOT EXISTS (
    SELECT 1 FROM staging.dim_produto p WHERE p.id_produto = b.id_produto
);

-- ---------------------------------------------------------------------------
-- 3) RLS + políticas (iguais às demais tabelas mart.*)
-- ---------------------------------------------------------------------------
ALTER TABLE mart.sazonalidade_baseline ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS api_reader_select ON mart.sazonalidade_baseline;
CREATE POLICY api_reader_select ON mart.sazonalidade_baseline
    FOR SELECT TO role_api_reader USING (true);

DROP POLICY IF EXISTS etl_writer_all ON mart.sazonalidade_baseline;
CREATE POLICY etl_writer_all ON mart.sazonalidade_baseline
    FOR ALL TO role_etl_writer USING (true) WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- 4) Prova / verificação
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_linhas integer;
    v_orfas integer;
BEGIN
    SELECT count(*) INTO v_linhas FROM mart.sazonalidade_baseline;
    SELECT count(*) INTO v_orfas FROM mart.sazonalidade_baseline b
    WHERE NOT EXISTS (SELECT 1 FROM staging.dim_produto p WHERE p.id_produto = b.id_produto);
    RAISE NOTICE 'MIGRATION 75 OK: baseline linhas=%, orfas_restantes=%', v_linhas, v_orfas;
END $$;

COMMIT;

-- Verificação esperada pós-execucao (dados restaurados do backup):
--   mart.sazonalidade_baseline = 20.088 linhas | 140 produtos com baseline
--   RLS habilitado, policies api_reader_select + etl_writer_all presentes
--   Endpoint GET /api/v1/sazonalidade* → HTTP 200 (não mais 500)
-- ============================================================================
