-- ============================================================================
-- QUERO COMPRAR — Fase 84: Fato Logístico (Fluxos de Abastecimento — Boletins CONAB)
-- PostgreSQL 16+
--
-- OBJETIVO:
--   Tabela staging com os fluxos de abastecimento extraídos dos Boletins
--   Logísticos da CONAB (PDF). Cada linha representa UMA rota produto
--   origem_uf → destino_uf em um mês/ano (deduplicada via dedup_hash).
--
--   A extração gera registros repetidos (mesma rota em várias páginas do
--   boletim). O loader pipeline/load_boletins_fluxo.py deduplica ANTES da
--   carga usando dedup_hash = md5(produto|origem_uf|destino_uf|ano|mes).
--
-- QUALITY GATE (regra fundamental do projeto):
--   Nenhum mês é preenchido com dados de fallback. Meses sem registro real
--   na extração permanecem AUSENTES (NULL na projeção), fazendo o frontend
--   exibir status CINZA em vez de inventar dados históricos.
--
-- Executar: psql -U postgres -d quero_comprar -f database/84_fact_fluxo_logistico_boletins.sql
-- ============================================================================

BEGIN;

-- ============================================================================
-- SEÇÃO 1: Tabela fato de fluxos logísticos (staging)
-- ============================================================================

CREATE TABLE IF NOT EXISTS staging.fact_fluxo_logistico (
    id             SERIAL         PRIMARY KEY,
    dedup_hash     TEXT           NOT NULL UNIQUE,
    produto_nome   TEXT           NOT NULL,
    origem_uf      CHAR(2)        NOT NULL,
    origem_polo    TEXT,
    destino_uf     CHAR(2)        NOT NULL,
    destino_polo   TEXT,
    mes_referencia SMALLINT       NOT NULL,
    ano_referencia SMALLINT       NOT NULL,
    fonte          TEXT,
    pagina         INTEGER,
    criado_em      TIMESTAMPTZ    NOT NULL DEFAULT now(),
    atualizado_em  TIMESTAMPTZ    NOT NULL DEFAULT now(),
    CONSTRAINT ck_fact_fluxo_logistico_ano   CHECK (ano_referencia BETWEEN 2025 AND 2026),
    CONSTRAINT ck_fact_fluxo_logistico_mes   CHECK (mes_referencia BETWEEN 1 AND 12),
    CONSTRAINT ck_fact_fluxo_logistico_origem_uf CHECK (origem_uf ~ '^[A-Z]{2}$'),
    CONSTRAINT ck_fact_fluxo_logistico_destino_uf CHECK (destino_uf ~ '^[A-Z]{2}$')
);

-- ============================================================================
-- SEÇÃO 2: Índices de consulta
-- ============================================================================

CREATE INDEX IF NOT EXISTS ix_fact_fluxo_logistico_rotas
    ON staging.fact_fluxo_logistico (origem_uf, destino_uf);

CREATE INDEX IF NOT EXISTS ix_fact_fluxo_logistico_periodo
    ON staging.fact_fluxo_logistico (produto_nome, ano_referencia, mes_referencia);

-- ============================================================================
-- SEÇÃO 3: Permissões
-- ============================================================================

GRANT ALL ON staging.fact_fluxo_logistico TO role_etl_writer;
GRANT SELECT ON staging.fact_fluxo_logistico TO role_api_reader;

-- ============================================================================
-- SEÇÃO 4: Documentação / Quality Gate
-- ============================================================================

COMMENT ON TABLE staging.fact_fluxo_logistico IS
    'Fluxos de abastecimento logísticos extraídos dos Boletins Logísticos da CONAB. '
    '1 linha = 1 rota (produto, origem_uf, destino_uf) em um mês/ano, deduplicada por '
    'dedup_hash (md5 de produto|origem_uf|destino_uf|ano|mes). QUALITY GATE: sem dados '
    'de fallback — meses sem registro real ficam ausentes (NULL), status CINZA no frontend.';

COMMENT ON COLUMN staging.fact_fluxo_logistico.dedup_hash IS
    'md5(produto normalizado | origem_uf | destino_uf | ano_referencia | mes_referencia) '
    'com UFs em maiúsculas. Vetor adaptado do spec original (remetente/destinatário não '
    'existem no boletim CONAB).';

COMMENT ON COLUMN staging.fact_fluxo_logistico.origem_polo IS
    'Polo de origem (ex: CEASA-GO). Pode ser NULL quando o boletim não informa.';

COMMENT ON COLUMN staging.fact_fluxo_logistico.destino_polo IS
    'Polo de destino (ex: SALVADOR). Pode ser NULL quando o boletim não informa.';

COMMIT;