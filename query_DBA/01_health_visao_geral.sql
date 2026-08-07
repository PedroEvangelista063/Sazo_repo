-- =============================================================================
-- 01_health_visao_geral.sql — 🩺 Saúde geral do banco local
-- =============================================================================
-- Kit do DBA — Quero Comprar VG
-- Queries read-only. Validadas em 2026-08-06 contra o banco local.
--
-- Uso: ./conectar_dba.sh -f 01_health_visao_geral.sql
-- =============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1.1  PAINEL EXECUTIVO — contagens por camada
--      (raw → staging → mart → ops) em uma única consulta
-- ────────────────────────────────────────────────────────────────────────────
SELECT 'RAW: raw.coleta_bruta'          AS secao, COUNT(*) AS total FROM raw.coleta_bruta
UNION ALL SELECT 'RAW: raw.controle_carga', COUNT(*) FROM raw.controle_carga
UNION ALL SELECT 'STAGING: staging.dim_produto', COUNT(*) FROM staging.dim_produto
UNION ALL SELECT 'STAGING: staging.dim_localidade', COUNT(*) FROM staging.dim_localidade
UNION ALL SELECT 'STAGING: staging.fact_precos_mensais', COUNT(*) FROM staging.fact_precos_mensais
UNION ALL SELECT 'MART: mart.sazonalidade_produto', COUNT(*) FROM mart.sazonalidade_produto
UNION ALL SELECT 'OPS: ops.audit_logs', COUNT(*) FROM ops.audit_logs
UNION ALL SELECT 'OPS: ops.quarentena_coleta', COUNT(*) FROM ops.quarentena_coleta
ORDER BY 1;

-- ────────────────────────────────────────────────────────────────────────────
-- 1.2  PERÍODO COBERTO — extensão temporal dos dados no fato
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    MIN(ano)                                   AS ano_inicio,
    MAX(ano)                                   AS ano_fim,
    COUNT(DISTINCT (ano, mes))                 AS meses_unicos,
    COUNT(DISTINCT id_produto)                 AS produtos_unicos,
    COUNT(DISTINCT id_localidade)              AS localidades_unicas
FROM staging.fact_precos_mensais;

-- ────────────────────────────────────────────────────────────────────────────
-- 1.3  REGISTROS POR ANO — volume histórico (identifica buracos de ano)
-- ────────────────────────────────────────────────────────────────────────────
SELECT ano, COUNT(*) AS registros
FROM staging.fact_precos_mensais
GROUP BY ano
ORDER BY ano;

-- ────────────────────────────────────────────────────────────────────────────
-- 1.4  FRESCOR DOS DADOS — último mês com dado real (não forecast)
-- ────────────────────────────────────────────────────────────────────────────
SELECT MAX(ano) AS ultimo_ano, MAX(mes) AS ultimo_mes
FROM mart.sazonalidade_produto
WHERE is_forecast = FALSE;

-- ────────────────────────────────────────────────────────────────────────────
-- 1.5  HEALTH CHECK GERAL — tabelas mais recentes por último INSERT
-- ────────────────────────────────────────────────────────────────────────────
SELECT schemaname || '.' || relname                          AS tabela,
       n_live_tup                                             AS linhas_vivas,
       last_vacuum::timestamp                                 AS ultimo_vacuum,
       last_autovacuum::timestamp                             AS ultimo_autovacuum
FROM pg_stat_user_tables
WHERE schemaname IN ('raw', 'staging', 'mart', 'ops')
ORDER BY n_live_tup DESC
LIMIT 15;

-- ────────────────────────────────────────────────────────────────────────────
-- 1.6  TAMANHO DO BANCO — espaço por schema (ajuda a monitorar disco)
-- ────────────────────────────────────────────────────────────────────────────
SELECT table_schema AS schema, pg_size_pretty(SUM(pg_total_relation_size(quote_ident(table_schema) || '.' || quote_ident(table_name)))) AS tamanho
FROM information_schema.tables
WHERE table_schema IN ('raw', 'staging', 'mart', 'ops')
  AND table_type = 'BASE TABLE'
GROUP BY table_schema
ORDER BY 2 DESC;
