-- ============================================================================
-- QUERO COMPRAR — DDL de Observabilidade e Self-Healing (Fase 2)
-- PostgreSQL 16+  |  Data Observability + Ghost DBA Agent
--
-- Cria o schema ops com tabelas de auditoria para o Agente de Autocura.
-- Deve ser executado APÓS o 01_ddl_medalhao.sql.
-- ============================================================================

BEGIN;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 0 — SCHEMA OPS (Observability & Platform Services)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE SCHEMA IF NOT EXISTS ops;

COMMENT ON SCHEMA ops IS 'Schema do Ghost DBA Agent — logs de erro, auditoria LLM, alertas';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 1 — Tabela: ops.controle_erros_ddl
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Armazena TODAS as exceções capturadas pelo pipeline de ingestão que
-- sugiram mudança de schema (column not found, tipo incompatível,
-- VIEW quebrada no REFRESH, etc.).
--
-- O Ghost DBA Agent faz polling NÃO resolvidos (resolvido_por_ia = FALSE)
-- e tenta autocura via LLM.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE TABLE ops.controle_erros_ddl (
    id_erro             BIGSERIAL       PRIMARY KEY,
    erro_traceback      TEXT            NOT NULL,
    query_causadora     TEXT,
    schema_nome         TEXT,                               -- ex: staging, mart
    objeto_nome         TEXT,                               -- ex: fact_precos_mensais, vw_api_produtos_sazonalidade
    contexto_extra      JSONB,                              -- amostra de colunas, tipo do erro, etc.
    resolvido_por_ia    BOOLEAN         NOT NULL DEFAULT FALSE,
    data_erro           TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    data_resolucao      TIMESTAMPTZ,
    tentativas_ia       SMALLINT        NOT NULL DEFAULT 0
);

CREATE INDEX idx_erros_pendentes
    ON ops.controle_erros_ddl (data_erro)
    WHERE resolvido_por_ia = FALSE;

CREATE INDEX idx_erros_objeto
    ON ops.controle_erros_ddl (schema_nome, objeto_nome);

COMMENT ON TABLE ops.controle_erros_ddl IS
    'Filas de erros DDL para o Ghost DBA Agent — polling frequente pelo agente';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 2 — Tabela: ops.audit_llm_queries
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Registro IMUTÁVEL de CADA comando SQL que a IA executou no banco.
-- Essencial para pós-mortem: se a IA quebrar algo, sabemos exatamente
-- o que foi executado e quando.
--
-- Regra de Segurança: o Ghost DBA Agent só pode executar comandos
-- que começam com CREATE OR REPLACE VIEW / FUNCTION / TRIGGER.
-- Qualquer bloqueio fica registrado aqui com status = 'bloqueado'.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE TABLE ops.audit_llm_queries (
    id_audit            BIGSERIAL       PRIMARY KEY,
    id_erro             INTEGER         REFERENCES ops.controle_erros_ddl(id_erro)
                                        ON DELETE SET NULL,
    sql_original        TEXT            NOT NULL,           -- SQL como veio do LLM (bruto)
    sql_sanitizado      TEXT,                               -- SQL após regex de segurança (pode ser NULL se bloqueado)
    status_exec         TEXT            NOT NULL
                        CHECK (status_exec IN ('executando', 'sucesso', 'falha', 'bloqueado')),
    erro_exec           TEXT,                               -- erro do banco se falhou
    diff_colunas        JSONB,          -- {antigo: [...], novo: [...]} — diff antes/depois
    prompt_enviado      TEXT,                               -- o prompt completo que foi para o LLM (debug)
    resposta_llm        TEXT,                               -- resposta crua do LLM (debug)
    executado_em        TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_erro ON ops.audit_llm_queries (id_erro);

COMMENT ON TABLE ops.audit_llm_queries IS
    'Auditoria forense de todas as ações corretivas da IA — imutável';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 3 — Tabela: ops.config_agente
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Configuração dinâmica do Ghost DBA Agent que pode ser alterada sem
-- reiniciar o daemon (polling via SELECT).
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE TABLE ops.config_agente (
    chave               TEXT            PRIMARY KEY,
    valor               TEXT            NOT NULL,
    descricao           TEXT,
    atualizado_em       TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

INSERT INTO ops.config_agente (chave, valor, descricao) VALUES
    ('polling_interval_seg',       '300',    'Intervalo entre polls na tabela de erros (segundos)'),
    ('max_tentativas_ia',          '3',      'Máximo de tentativas de autocura por erro'),
    ('webhook_url',                '',       'URL do webhook Discord/Telegram para alertas'),
    ('webhook_enabled',            'false',  'Ativar disparo de webhook (true/false)'),
    ('fastapi_cache_url',          'http://localhost:8000/api/v1/_internal/cache-clear', 'Endpoint interno de invalidação de cache'),
    ('llm_api_endpoint',           'http://localhost:11434/api/generate', 'Endpoint da API do LLM para autocura'),
    ('llm_model',                  'codellama:13b', 'Modelo LLM usado para geração de SQL'),
    ('max_diff_colunas',           '10',     'Máximo de colunas de amostra enviadas ao LLM');

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 4 — FUNÇÕES DE LOG (usadas pelo pipeline Python)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE FUNCTION ops.fn_registrar_erro_ddl(
    p_erro_traceback    TEXT,
    p_query_causadora   TEXT DEFAULT NULL,
    p_schema_nome       TEXT DEFAULT NULL,
    p_objeto_nome       TEXT DEFAULT NULL,
    p_contexto_extra    JSONB DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO ops.controle_erros_ddl
        (erro_traceback, query_causadora, schema_nome, objeto_nome, contexto_extra)
    VALUES (p_erro_traceback, p_query_causadora, p_schema_nome, p_objeto_nome, p_contexto_extra)
    RETURNING id_erro INTO v_id;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION ops.fn_registrar_erro_ddl IS
    'Registra um erro de DDL na fila do Ghost DBA Agent. Retorna o ID do erro.';

CREATE OR REPLACE FUNCTION ops.fn_resolver_erro(
    p_id_erro       BIGINT,
    p_sql_gerado    TEXT,
    p_status        TEXT,     -- 'sucesso' ou 'falha'
    p_erro_exec     TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE ops.controle_erros_ddl
    SET resolvido_por_ia = (p_status = 'sucesso'),
        data_resolucao   = NOW(),
        tentativas_ia    = tentativas_ia + 1
    WHERE id_erro = p_id_erro;

    INSERT INTO ops.audit_llm_queries
        (id_erro, sql_original, sql_sanitizado, status_exec, erro_exec)
    VALUES (p_id_erro, p_sql_gerado, p_sql_gerado, p_status, p_erro_exec);
END;
$$;

COMMENT ON FUNCTION ops.fn_resolver_erro IS
    'Marca um erro como resolvido (ou falha) e registra na auditoria LLM';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 5 — PERMISSÕES
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

GRANT USAGE ON SCHEMA ops TO role_etl_writer;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA ops TO role_etl_writer;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA ops TO role_etl_writer;
GRANT EXECUTE ON ALL FUNCTIONS       IN SCHEMA ops TO role_etl_writer;

-- role_api_reader não precisa de acesso ao schema ops (dados internos)

COMMIT;
