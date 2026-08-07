-- =============================================================================
-- 05_audit_observabilidade.sql — 🕵️ Auditoria e observabilidade (ops)
-- =============================================================================
-- Kit do DBA — Quero Comprar VG
-- Acompanha tudo o que muda no banco: reclassificações de status, quarentena,
-- erros de DDL e auditoria LLM.
--
-- Uso: ./conectar_dba.sh -f 05_audit_observabilidade.sql
-- =============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 5.1  MUDANÇAS DE STATUS (semáforo) — visão geral de transições
--      (ex: quanto produto ficou VERDE→AMARELO quando a safra virou)
-- ────────────────────────────────────────────────────────────────────────────
SELECT cor_antiga, cor_nova, COUNT(*) AS qtd
FROM ops.audit_logs
GROUP BY 1, 2
ORDER BY 3 DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 5.1b  VIEW PRONTA — últimas mudanças de status com nomes (ops.vw_ultimas_mudancas_status)
--        Gerada pela migration 000014 — evita joins manuais
-- ────────────────────────────────────────────────────────────────────────────
SELECT produto,
       uf,
       municipio,
       cor_antiga,
       cor_nova,
       preco_referencia,
       preco_atual,
       usou_fallback,
       data_mudanca::timestamp
FROM ops.vw_ultimas_mudancas_status
ORDER BY data_mudanca DESC
LIMIT 30;

-- ────────────────────────────────────────────────────────────────────────────
-- 5.2  ÚLTIMAS MUDANÇAS DE STATUS — atividade recente do recálculo
-- ────────────────────────────────────────────────────────────────────────────
SELECT data_mudanca::timestamp,
       p.nome_produto,
       l.uf,
       cor_antiga,
       cor_nova,
       usou_fallback
FROM ops.audit_logs a
LEFT JOIN staging.dim_produto p    ON p.id_produto = a.id_produto
LEFT JOIN staging.dim_localidade l ON l.id_localidade = a.id_localidade
ORDER BY a.data_mudanca DESC
LIMIT 30;

-- ────────────────────────────────────────────────────────────────────────────
-- 5.3  MUDANÇAS POR DIA — volume de reclassificações (detecta recalibragem)
-- ────────────────────────────────────────────────────────────────────────────
SELECT data_mudanca::date AS dia, COUNT(*) AS mudancas
FROM ops.audit_logs
GROUP BY 1
ORDER BY 1 DESC
LIMIT 30;

-- ────────────────────────────────────────────────────────────────────────────
-- 5.4  USO DE FALLBACK — quantas reclassificações usaram fallback de baseline
-- ────────────────────────────────────────────────────────────────────────────
SELECT usou_fallback, COUNT(*) AS qtd
FROM ops.audit_logs
GROUP BY 1;

-- ────────────────────────────────────────────────────────────────────────────
-- 5.5  ERROS DE DDL — falhas de execução de migrations capturadas
-- ────────────────────────────────────────────────────────────────────────────
SELECT id, script, erro, executado_em
FROM ops.controle_erros_ddl
ORDER BY executado_em DESC
LIMIT 20;

-- ────────────────────────────────────────────────────────────────────────────
-- 5.6  QUERIES DE IA (audit_llm_queries) — atividades de agentes no banco
-- ────────────────────────────────────────────────────────────────────────────
SELECT * FROM ops.audit_llm_queries
ORDER BY criado_em DESC
LIMIT 10;

-- ────────────────────────────────────────────────────────────────────────────
-- 5.7  CONFIGURAÇÃO DE AGENTES — estados persistidos dos agentes IA
-- ────────────────────────────────────────────────────────────────────────────
SELECT * FROM ops.config_agente
ORDER BY atualizado_em DESC
LIMIT 10;
