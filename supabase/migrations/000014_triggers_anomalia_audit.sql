-- ============================================================================
-- QUERO COMPRAR — Migration 000014: Triggers de Anomalia UF-based + Audit
-- PostgreSQL 17+  |  Forward-only  |  Idempotent
--
-- OBJETIVO:
--   1. Atualizar trigger de anomalia para comparar por UF (não município)
--   2. Criar infraestrutura de auditoria de status_cor no schema ops
--      (tabela audit_logs, função trigger, trigger AFTER UPDATE, view)
--   3. Garantir rastreabilidade de mudanças para o Ghost DBA Agent
--
-- DEPENDÊNCIA: migration 000013 (sazonalidade_produto com colunas)
-- ============================================================================

BEGIN;
SET lock_timeout = '30s';

-- ============================================================================
-- SEÇÃO 1: Atualização da Trigger de Anomalia — UF-based (db/03, db/04)
-- ============================================================================
--
-- A trigger original comparava preço com a média do mesmo id_produto E
-- id_localidade (município individual). A versão UF-based resolve a UF
-- a partir de dim_localidade e compara com a média de TODOS os municípios
-- da mesma UF para o mesmo produto. Isso captura melhor anomalias quando
-- a carga vem de fontes UF-level vs municipio-level.
--
-- Estrutura mantida: staging.precos_rejeitados (já existe)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION staging.trg_valida_anomalia_preco()
RETURNS TRIGGER AS $$
DECLARE
    v_media_historica NUMERIC(14,4);
    v_dados_brutos    JSONB;
    v_uf              CHAR(2);
BEGIN
    -- Resolve a UF da localidade que está sendo inserida
    SELECT uf INTO v_uf
    FROM staging.dim_localidade
    WHERE id_localidade = NEW.id_localidade;

    -- Sem localidade conhecida → deixa passar
    IF v_uf IS NULL THEN
        RETURN NEW;
    END IF;

    -- Média histórica do MESMO produto na MESMA UF (qualquer município)
    SELECT AVG(f.preco_medio) INTO v_media_historica
    FROM staging.fact_precos_mensais f
    JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
    WHERE f.id_produto = NEW.id_produto
      AND l.uf         = v_uf
      AND NOT (f.ano = NEW.ano AND f.mes = NEW.mes);

    -- Sem histórico → deixa passar (primeira ocorrência)
    IF v_media_historica IS NULL THEN
        RETURN NEW;
    END IF;

    -- Preço > 500% da média da UF → quarentena
    IF NEW.preco_medio > (v_media_historica * 5.0) THEN
        v_dados_brutos := jsonb_build_object(
            'produto_id',      NEW.id_produto,
            'localidade_id',   NEW.id_localidade,
            'uf',              v_uf,
            'ano',             NEW.ano,
            'mes',             NEW.mes,
            'preco_enviado',   NEW.preco_medio,
            'media_historica', v_media_historica
        );

        INSERT INTO staging.precos_rejeitados (
            id_produto, id_localidade, ano, mes,
            preco_medio, preco_medio_historico, razao,
            dados_brutos, batch_id
        ) VALUES (
            NEW.id_produto, NEW.id_localidade, NEW.ano, NEW.mes,
            NEW.preco_medio, v_media_historica,
            'Preço excede 500% da média histórica do mesmo produto na mesma UF',
            v_dados_brutos, NEW.batch_id
        );

        RETURN NULL;  -- aborta esta linha, mas não a transação
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION staging.trg_valida_anomalia_preco() IS
    'Desvia para quarentena preços >500% da média do mesmo id_produto + UF. '
    'Versão UF-based: resolve UF de dim_localidade e compara na UF inteira.';

-- Garante que o trigger existe com a condição WHEN
DROP TRIGGER IF EXISTS trg_valida_anomalia_preco
    ON staging.fact_precos_mensais;

CREATE OR REPLACE TRIGGER trg_valida_anomalia_preco
    BEFORE INSERT ON staging.fact_precos_mensais
    FOR EACH ROW
    WHEN (NEW.preco_medio IS NOT NULL)
    EXECUTE FUNCTION staging.trg_valida_anomalia_preco();

COMMENT ON TRIGGER trg_valida_anomalia_preco ON staging.fact_precos_mensais IS
    'Bloqueia inserções com preço >500% da média do mesmo produto na mesma UF. '
    'Redireciona para staging.precos_rejeitados (quarentena).';

-- ============================================================================
-- SEÇÃO 2: Tabela de Auditoria — ops.audit_logs (db/06)
-- ============================================================================
--
-- Log imutável de mudanças de status_cor em mart.sazonalidade_produto.
-- Cada linha = uma mudança de cor (ex: VERDE→VERMELHO).
-- Monitorado pelo Ghost DBA Agent para detectar anomalias matemáticas.
--
-- Índices:
--   idx_audit_logs_data      — consulta por data (recente primeiro)
--   idx_audit_logs_produto   — consulta por produto+localidade
--   idx_audit_logs_padrao    — detecção de padrões de mudança repetida
-- ---------------------------------------------------------------------------

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

CREATE INDEX IF NOT EXISTS idx_audit_logs_data
    ON ops.audit_logs (data_mudanca DESC);

CREATE INDEX IF NOT EXISTS idx_audit_logs_produto
    ON ops.audit_logs (id_produto, id_localidade, data_mudanca DESC);

CREATE INDEX IF NOT EXISTS idx_audit_logs_padrao
    ON ops.audit_logs (cor_antiga, cor_nova, data_mudanca);

-- ============================================================================
-- SEÇÃO 3: Função Trigger — ops.trg_audit_status_cor() (db/06)
-- ============================================================================
--
-- Disparada APÓS UPDATE na mart.sazonalidade_produto.
-- Compara OLD.status_cor com NEW.status_cor.
-- Se DIFERENTE, insere um registro em ops.audit_logs.
--
-- AFTER EACH ROW: aceitável para centenas a milhares de produtos.
-- Para milhões de linhas, considerar AFTER STATEMENT com aggregation.
-- ---------------------------------------------------------------------------

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
            NEW.usou_fallback_12m,
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

-- ============================================================================
-- SEÇÃO 4: Trigger AFTER UPDATE na mart.sazonalidade_produto (db/06)
-- ============================================================================

DROP TRIGGER IF EXISTS trg_audit_status_cor ON mart.sazonalidade_produto;

CREATE OR REPLACE TRIGGER trg_audit_status_cor
    AFTER UPDATE ON mart.sazonalidade_produto
    FOR EACH ROW
    EXECUTE FUNCTION ops.trg_audit_status_cor();

COMMENT ON TRIGGER trg_audit_status_cor ON mart.sazonalidade_produto IS
    'Monitora mudanças de status_cor e registra em ops.audit_logs. '
    'Essencial para detectar silent failures no cálculo do semáforo.';

-- ============================================================================
-- SEÇÃO 5: View de Consulta — ops.vw_ultimas_mudancas_status (db/06)
-- ============================================================================
--
-- View flat para o Ghost DBA Agent consultar as últimas mudanças de
-- status_cor com dados legíveis (nome do produto, UF, município).
-- ---------------------------------------------------------------------------

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

-- ============================================================================
-- SEÇÃO 6: Permissões — schema ops (db/06)
-- ============================================================================

GRANT USAGE ON SCHEMA ops TO role_etl_writer;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA ops TO role_etl_writer;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA ops TO role_etl_writer;
GRANT INSERT ON ops.audit_logs TO role_etl_writer;

-- role_api_reader NÃO tem acesso ao schema ops (dados são internos)
-- GRANT SELECT ON ops.vw_ultimas_mudancas_status TO role_api_reader;

-- ============================================================================
-- SEÇÃO 7: Refresh da Materialized View (pós-audit trigger)
-- ============================================================================
--
-- A MV vw_api_produtos_sazonalidade depende de sazonalidade_produto.
-- Após criar a trigger de auditoria, fazemos um refresh CONCURRENTLY
-- para garantir que a MV reflita o estado mais recente sem bloquear.
-- ---------------------------------------------------------------------------

REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- ============================================================================
-- FIM — Migration 000014
-- ============================================================================

COMMIT;
