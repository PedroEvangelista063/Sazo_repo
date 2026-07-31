-- ============================================================================
-- QUERO COMPRAR — Fase 8: Audit Triggers & Observability
-- PostgreSQL 16+  |  Pilar de Resiliência de Dados (DBA Strict Mode)
--
-- MOTIVAÇÃO:
--   O status_cor (🟢🟡🔴) é o principal contrato com o frontend B2C.
--   Se um cálculo incorreto mudar silenciosamente um VERDE para VERMELHO
--   (ou vice-versa), o consumidor perde confiança no app.
--
--   Esta trigger monitora TODAS as mudanças de status_cor na tabela
--   mart.sazonalidade_produto e registra em ops.audit_logs para que
--   o Ghost DBA Agent possa detectar anomalias matemáticas.
--
-- SUMÁRIO:
--   1. Tabela ops.audit_logs (log imutável de mudanças de status)
--   2. Função trigger ops.trg_audit_status_cor()
--   3. Trigger AFTER UPDATE na mart.sazonalidade_produto
--   4. View de consulta rápida para o Ghost DBA Agent
--   5. Permissões
-- ============================================================================

BEGIN;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 1 — Tabela de Auditoria: ops.audit_logs
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--
--
-- Cada linha representa UMA mudança de status_cor de UM produto em UMA
-- localidade. Imutável (INSERT-only). NUNCA se faz UPDATE ou DELETE aqui.
--
-- Colunas:
--   id_log            PK
--   id_produto        FK → staging.dim_produto
--   id_localidade     FK → staging.dim_localidade
--   cor_antiga        status antes da atualização (ex: 'VERDE')
--   cor_nova          status depois da atualização (ex: 'VERMELHO')
--   preco_referencia  âncora no momento da mudança (para debug)
--   preco_atual       preço que causou a mudança
--   usou_fallback     se a âncora era fallback 12m
--   data_mudanca      timestamp da mudança (NOW())
--   batch_id          opcional — batch_id da carga que causou a mudança
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE TABLE IF NOT EXISTS ops.audit_logs (
    id_log              BIGSERIAL       PRIMARY KEY,
    id_produto          INTEGER         NOT NULL,
    id_localidade       INTEGER         NOT NULL,
    cor_antiga          TEXT            NOT NULL
                        CHECK (cor_antiga IN ('VERDE','AMARELO','VERMELHO','INSUFICIENTE')),
    cor_nova            TEXT            NOT NULL
                        CHECK (cor_nova IN ('VERDE','AMARELO','VERMELHO','INSUFICIENTE')),
    preco_referencia    NUMERIC(14,4),
    preco_atual         NUMERIC(14,4),
    usou_fallback       BOOLEAN         NOT NULL DEFAULT FALSE,
    data_mudanca        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    batch_id            UUID
);

COMMENT ON TABLE ops.audit_logs IS
    'Log imutável de mudanças de status_cor em mart.sazonalidade_produto. '
    'Cada linha = uma mudança de cor (ex: VERDE→VERMELHO). '
    'Monitorado pelo Ghost DBA Agent para detectar anomalias matemáticas.';

COMMENT ON COLUMN ops.audit_logs.cor_antiga IS
    'Status anterior do semáforo antes da atualização';
COMMENT ON COLUMN ops.audit_logs.cor_nova IS
    'Novo status do semáforo após a atualização';
COMMENT ON COLUMN ops.audit_logs.preco_referencia IS
    'Âncora de preço no momento da mudança (útil para debug matemático)';
COMMENT ON COLUMN ops.audit_logs.preco_atual IS
    'Preço atual que causou a mudança de cor';
COMMENT ON COLUMN ops.audit_logs.usou_fallback IS
    'TRUE se a âncora veio do fallback 12m (produto sem baseline 2025)';
COMMENT ON COLUMN ops.audit_logs.batch_id IS
    'Batch ID da carga que acionou a mudança (pode ser NULL em recalibrações manuais)';

-- Índices para consulta eficiente pelo Ghost DBA Agent
CREATE INDEX IF NOT EXISTS idx_audit_logs_data
    ON ops.audit_logs (data_mudanca DESC);

CREATE INDEX IF NOT EXISTS idx_audit_logs_produto
    ON ops.audit_logs (id_produto, id_localidade, data_mudanca DESC);

-- Índice para detectar padrões: mesma mudança de cor repetida muitas vezes
CREATE INDEX IF NOT EXISTS idx_audit_logs_padrao
    ON ops.audit_logs (cor_antiga, cor_nova, data_mudanca);

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 2 — Função Trigger: ops.trg_audit_status_cor()
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--
--
-- Disparada APÓS UPDATE na mart.sazonalidade_produto.
-- Compara OLD.status_cor com NEW.status_cor.
-- Se DIFERENTE, insere um registro em ops.audit_logs.
--
-- IMPORTANTE: A trigger é AFTER EACH ROW. Isso significa que se um
-- UPSERT atualizar 10.000 linhas, cada uma que mudar de cor gerará
-- um log. Para volumes muito grandes, considere mudar para uma função
-- de aggregation em lote (AFTER STATEMENT). Por enquanto, o volume
-- (centenas a milhares de produtos) torna row-level aceitável.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE FUNCTION ops.trg_audit_status_cor()
RETURNS TRIGGER AS $$
BEGIN
    -- Só registra se a cor MUDOU
    IF OLD.status_cor IS DISTINCT FROM NEW.status_cor THEN
        INSERT INTO ops.audit_logs (
            id_produto,
            id_localidade,
            cor_antiga,
            cor_nova,
            preco_referencia,
            preco_atual,
            usou_fallback,
            data_mudanca,
            batch_id
        ) VALUES (
            NEW.id_produto,
            NEW.id_localidade,
            OLD.status_cor,
            NEW.status_cor,
            NEW.preco_referencia,
            NEW.preco_atual,
            COALESCE(NEW.usou_fallback_12m, FALSE),
            NOW(),
            NULL              -- batch_id: pode ser enriquecido pela aplicação
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION ops.trg_audit_status_cor() IS
    'Registra em ops.audit_logs toda mudança de status_cor em '
    'mart.sazonalidade_produto. Previne silent failures matemáticos '
    'ao permitir rastrear quando e por que um VERDE virou VERMELHO.';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 3 — Criação da Trigger
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--

DROP TRIGGER IF EXISTS trg_audit_status_cor ON mart.sazonalidade_produto;

CREATE OR REPLACE TRIGGER trg_audit_status_cor
    AFTER UPDATE ON mart.sazonalidade_produto
    FOR EACH ROW
    EXECUTE FUNCTION ops.trg_audit_status_cor();

COMMENT ON TRIGGER trg_audit_status_cor ON mart.sazonalidade_produto IS
    'Monitora mudanças de status_cor e registra em ops.audit_logs. '
    'Essencial para detectar silent failures no cálculo do semáforo.';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 4 — View de Consulta Rápida para o Ghost DBA Agent
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--
--
-- Facilita a consulta pelo Ghost DBA Agent: mudanças recentes +
-- nome do produto + UF + município, tudo em uma view flat.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE VIEW ops.vw_ultimas_mudancas_status AS
SELECT
    al.id_log,
    p.nome_produto      AS produto,
    l.uf,
    l.municipio_nome    AS municipio,
    al.cor_antiga,
    al.cor_nova,
    al.preco_referencia,
    al.preco_atual,
    al.usou_fallback,
    al.data_mudanca
FROM ops.audit_logs al
JOIN staging.dim_produto    p ON p.id_produto    = al.id_produto
JOIN staging.dim_localidade l ON l.id_localidade = al.id_localidade
ORDER BY al.data_mudanca DESC;

COMMENT ON VIEW ops.vw_ultimas_mudancas_status IS
    'View flat para o Ghost DBA Agent consultar as últimas mudanças de '
    'status_cor com dados legíveis (nome do produto, UF, município).';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 5 — Permissões
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~--

GRANT USAGE ON SCHEMA ops TO role_etl_writer;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA ops TO role_etl_writer;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA ops TO role_etl_writer;
GRANT INSERT ON ops.audit_logs TO role_etl_writer;

-- role_api_reader NÃO tem acesso ao schema ops (dados são internos)
-- Mas para debugging, o Ghost DBA Agent pode precisar de SELECT
-- GRANT SELECT ON ops.vw_ultimas_mudancas_status TO role_api_reader;

COMMIT;
