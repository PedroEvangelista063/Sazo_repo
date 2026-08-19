-- ============================================================================
-- QUERO COMPRAR — Fase 85: View de Leitura dos Fluxos Logísticos (Boletins CONAB)
-- PostgreSQL 16+
--
-- OBJETIVO:
--   Projeção de leitura (read API) sobre staging.fact_fluxo_logistico para o
--   endpoint GET /api/v1/fluxos/boletins. Expõe apenas as colunas necessárias
--   ao frontend, com a coluna `produto` (alias de produto_nome) no contrato.
--
-- QUALITY GATE (regra fundamental do projeto):
--   Nenhum mês é preenchido com dados de fallback — a view NÃO projeta meses
--   futuros nem substitui meses ausentes. Meses sem registro real permanecem
--   AUSENTES, fazendo o frontend exibir status CINZA em vez de inventar dados.
--
-- Executar: psql -U postgres -d quero_comprar -f database/85_vw_fluxo_logistico_boletins.sql
-- ============================================================================

BEGIN;

CREATE OR REPLACE VIEW staging.vw_fluxo_logistico_boletins AS
SELECT
    id,
    produto_nome               AS produto,
    origem_uf,
    origem_polo,
    destino_uf,
    destino_polo,
    mes_referencia,
    ano_referencia,
    fonte,
    pagina
FROM staging.fact_fluxo_logistico
ORDER BY ano_referencia, mes_referencia, produto_nome, origem_uf, destino_uf;

-- Permissão de leitura para a role da API (SELECT only, sem DML).
-- USAGE no schema staging é necessário para a role conseguir navegar até a
-- view (mesmo padrão já aplicado ao schema mart na migration 83).
GRANT USAGE ON SCHEMA staging TO role_api_reader;
GRANT SELECT ON staging.vw_fluxo_logistico_boletins TO role_api_reader;

-- ============================================================================
-- Documentação / Quality Gate
-- ============================================================================

COMMENT ON VIEW staging.vw_fluxo_logistico_boletins IS
    'Projeção de leitura dos fluxos de abastecimento extraídos dos Boletins '
    'Logísticos da CONAB. 1 linha = 1 rota (produto, origem_uf, destino_uf) em um '
    'mês/ano, deduplicada. QUALITY GATE: sem dados de fallback — meses sem registro '
    'real ficam ausentes (NULL), status CINZA no frontend.';

COMMENT ON COLUMN staging.vw_fluxo_logistico_boletins.produto IS
    'Nome do produto (alias de produto_nome da tabela fato).';

COMMIT;