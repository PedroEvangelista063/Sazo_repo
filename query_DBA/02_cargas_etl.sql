-- =============================================================================
-- 02_cargas_etl.sql — 🚚 Monitoramento das cargas ETL
-- =============================================================================
-- Kit do DBA — Quero Comprar VG
-- Acompanha o pipeline: coletas brutas (raw), cargas processadas e rejeições.
--
-- Uso: ./conectar_dba.sh -f 02_cargas_etl.sql
-- =============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 2.1  ÚLTIMAS CARGAS — histórico de execuções do pipeline (controle_carga)
-- ────────────────────────────────────────────────────────────────────────────
SELECT tipo,
       status,
       total_linhas,
       inseridas,
       COALESCE(erro, '') AS erro,
       criado_em
FROM raw.controle_carga
ORDER BY criado_em DESC
LIMIT 20;

-- ────────────────────────────────────────────────────────────────────────────
-- 2.2  RESUMO POR STATUS — quantas cargas com sucesso vs falha
-- ────────────────────────────────────────────────────────────────────────────
SELECT status,
       COUNT(*)                                   AS qtd_cargas,
       MAX(criado_em)::timestamp                  AS ultima_carga,
       SUM(inseridas)                             AS total_linhas_inseridas
FROM raw.controle_carga
GROUP BY status
ORDER BY 2 DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 2.3  ÚLTIMAS COLETAS BRUTAS — payloads recebidos por fonte
-- ────────────────────────────────────────────────────────────────────────────
SELECT fonte_id,
       COALESCE(competencia_alvo, '(sem competência)') AS competencia,
       processado,
       COUNT(*)                                            AS qtd,
       MAX(data_coleta)::timestamp                        AS ultima_coleta
FROM raw.coleta_bruta
GROUP BY 1, 2, 3
ORDER BY ultima_coleta DESC NULLS LAST
LIMIT 25;

-- ────────────────────────────────────────────────────────────────────────────
-- 2.4  COLETAS NÃO PROCESSADAS — payloads que ficaram para trás (alerta!)
-- ────────────────────────────────────────────────────────────────────────────
SELECT id, fonte_id, data_coleta::timestamp, competencia_alvo
FROM raw.coleta_bruta
WHERE processado = FALSE
ORDER BY data_coleta DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 2.5  REJEIÇÕES (quarentena) — dados que NÃO entraram no staging e por quê
-- ────────────────────────────────────────────────────────────────────────────
SELECT raw_id, motivo_falha, data_rejeicao::timestamp
FROM ops.quarentena_coleta
ORDER BY data_rejeicao DESC
LIMIT 30;

-- ────────────────────────────────────────────────────────────────────────────
-- 2.6  RESUMO DE REJEIÇÕES POR MOTIVO — os erros mais comuns do ETL
-- ────────────────────────────────────────────────────────────────────────────
SELECT SPLIT_PART(motivo_falha, ':', 1) AS categoria_erro,
       COUNT(*)                          AS qtd
FROM ops.quarentena_coleta
GROUP BY 1
ORDER BY 2 DESC;

-- ────────────────────────────────────────────────────────────────────────────
-- 2.7  GAPS TEMPORAIS NO FATO — últimos 6 meses com dado REAL ausente
--      (identifica competências que o pipeline ainda não coletou)
-- ────────────────────────────────────────────────────────────────────────────
WITH ultimos_6 AS (
    SELECT ano, mes FROM (VALUES
        (2026, 7), (2026, 6), (2026, 5),
        (2026, 4), (2026, 3), (2026, 2)
    ) AS t(ano, mes)
)
SELECT um.ano, um.mes, COUNT(*) AS produtos_sem_dado
FROM staging.dim_produto p
CROSS JOIN ultimos_6 um
LEFT JOIN staging.fact_precos_mensais f
    ON f.id_produto = p.id_produto AND f.ano = um.ano AND f.mes = um.mes
WHERE f.id_fato IS NULL
GROUP BY um.ano, um.mes
ORDER BY um.ano DESC, um.mes DESC;
