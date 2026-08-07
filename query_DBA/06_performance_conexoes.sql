-- =============================================================================
-- 06_performance_conexoes.sql — ⚡ Performance, conexões e locks
-- =============================================================================
-- Kit do DBA — Quero Comprar VG
-- Diagnóstico de conexões ativas, locks, queries lentas e uso de recursos.
--
-- Uso: ./conectar_dba.sh -f 06_performance_conexoes.sql
-- =============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 6.1  CONEXÕES ATIVAS — quem está conectado no banco agora
-- ────────────────────────────────────────────────────────────────────────────
SELECT datname,
       usename,
       application_name,
       client_addr,
       state,
       COUNT(*) AS conexoes
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY 1, 2, 3, 4, 5
ORDER BY conexoes DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.2  QUERIES EM EXECUÇÃO — o que está rodando neste momento (com tempo)
-- ────────────────────────────────────────────────────────────────────────────
SELECT pid,
       usename,
       state,
       EXTRACT(EPOCH FROM (NOW() - query_start))::int AS segundos_rodando,
       LEFT(query, 120)                               AS query_truncada
FROM pg_stat_activity
WHERE state = 'active'
  AND query NOT ILIKE '%pg_stat_activity%'
ORDER BY segundos_rodando DESC
LIMIT 15;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.3  LOCKS — bloqueios ativos (indicam conflito entre queries)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    a.pid                                                         AS pid_bloqueador,
    b.pid                                                         AS pid_bloqueado,
    pg_blocking_pids(b.pid)                                       AS bloqueado_por,
    LEFT(a.query, 80)                                             AS query_bloqueadora,
    LEFT(b.query, 80)                                             AS query_bloqueada
FROM pg_stat_activity a
JOIN pg_stat_activity b ON b.pid = ANY(pg_blocking_pids(a.pid))
WHERE b.state <> 'idle'
LIMIT 20;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.4  TAMANHO DAS TABELAS — ranking de espaço usado (top 15)
-- ────────────────────────────────────────────────────────────────────────────
SELECT schemaname || '.' || relname                  AS tabela,
       pg_size_pretty(pg_total_relation_size(relid)) AS tamanho,
       n_live_tup                                    AS linhas_vivas
FROM pg_stat_user_tables
WHERE schemaname IN ('raw', 'staging', 'mart', 'ops')
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 15;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.5  ÍNDICES — os maiores e os não utilizados (candidatos a revisão)
-- ────────────────────────────────────────────────────────────────────────────
SELECT schemaname || '.' || relname          AS tabela,
       indexrelname                          AS indice,
       pg_size_pretty(pg_relation_size(indexrelid)) AS tamanho,
       idx_scan                              AS vezes_usado
FROM pg_stat_user_indexes
WHERE schemaname IN ('raw', 'staging', 'mart', 'ops')
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 15;

-- ────────────────────────────────────────────────────────────────────────────
-- 6.6  BLOBS / CACHE — hit ratio do buffer cache (acima de 95% = bom)
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    ROUND(100.0 * SUM(blks_hit) / NULLIF(SUM(blks_hit + blks_read), 0), 2) AS hit_ratio_pct,
    SUM(blks_read)                                                          AS leituras_disco
FROM pg_stat_database
WHERE datname = current_database();

-- ────────────────────────────────────────────────────────────────────────────
-- 6.7  VACUUM PENDENTE — tabelas que precisam de vacuum/analyze
-- ────────────────────────────────────────────────────────────────────────────
SELECT schemaname || '.' || relname AS tabela,
       n_dead_tup                   AS linhas_mortas,
       last_vacuum::timestamp,
       last_autovacuum::timestamp
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 15;
