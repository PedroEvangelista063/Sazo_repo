-- ============================================================================
-- 73_poda_indices_redundantes.sql — Poda de índices redundantes do mart
-- ----------------------------------------------------------------------------
-- Remove índices comprovadamente redundantes/inutilizados de
-- mart.sazonalidade_produto para liberar disco (nó Aiven estava em ~415 MB
-- de ~500 MB, com histórico de read-only por disco cheio).
--
-- PODA 1: idx_sazonalidade_data_ref (~13 MB)
--   Duplicata da constraint UNIQUE uq_sazonalidade_data_ref
--   (id_produto, id_localidade, data_referencia_atual) — MESMA chave, apenas
--   com DESC (irrelevante para B-tree, que suporta varredura reversa).
--   Evidência de redundância (pg_stat_user_indexes):
--     • Aiven : idx 603.372 scans vs uq 0 scans
--     • Local : idx 0 scans          vs uq 6.523.742 scans
--   → o planner simplesmente alterna entre os dois para as MESMAS queries
--     (anchor chain da MV 63, LOCF). Ao dropar, todas passam a usar a UNIQUE.
--     Nenhuma mudança funcional; B-tree cobre ASC e DESC igualmente.
--
-- Idempotente (IF EXISTS) — pode rodar em qualquer ambiente (Aiven/local).
-- ============================================================================

DROP INDEX IF EXISTS mart.idx_sazonalidade_data_ref;

-- Refresca estatísticas após a poda (o planner recalcula os caminhos).
ANALYZE mart.sazonalidade_produto;
