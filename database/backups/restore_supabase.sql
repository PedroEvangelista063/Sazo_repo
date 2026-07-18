-- ============================================================================
-- RESTORE: Dados do backup local para Supabase
-- Execute este script no Supabase SQL Editor (Dashboard)
-- ============================================================================

-- 1. Desabilitar triggers temporariamente (performance)
ALTER TABLE staging.fact_precos_mensais DISABLE TRIGGER ALL;

-- 2. Inserir dim_produto (primeiro, sem FK)
INSERT INTO staging.dim_produto (id_produto, nome_produto, criado_em)
SELECT id_produto, nome_produto, criado_em
FROM dblink('host=localhost dbname=quero_comprar user=postgres password=postgres',
  'SELECT id_produto, nome_produto, criado_em FROM staging.dim_produto')
AS t(id_produto INTEGER, nome_produto TEXT, criado_em TIMESTAMPTZ)
ON CONFLICT (nome_produto) DO NOTHING;

-- 3. Inserir dim_localidade
INSERT INTO staging.dim_localidade (id_localidade, uf, municipio_id, municipio_nome, criado_em)
SELECT id_localidade, uf, municipio_id, municipio_nome, criado_em
FROM dblink('host=localhost dbname=quero_comprar user=postgres password=postgres',
  'SELECT id_localidade, uf, municipio_id, municipio_nome, criado_em FROM staging.dim_localidade')
AS t(id_localidade INTEGER, uf CHAR(2), municipio_id TEXT, municipio_nome TEXT, criado_em TIMESTAMPTZ)
ON CONFLICT (uf, municipio_id) DO NOTHING;

-- 4. Inserir fact_precos_mensais
INSERT INTO staging.fact_precos_mensais (id_produto, id_localidade, ano, mes, preco_medio, batch_id, loaded_at)
SELECT id_produto, id_localidade, ano, mes, preco_medio, batch_id, loaded_at
FROM dblink('host=localhost dbname=quero_comprar user=postgres password=postgres',
  'SELECT id_produto, id_localidade, ano, mes, preco_medio, batch_id, loaded_at FROM staging.fact_precos_mensais')
AS t(id_produto INTEGER, id_localidade INTEGER, ano SMALLINT, mes SMALLINT, preco_medio NUMERIC(14,4), batch_id UUID, loaded_at TIMESTAMPTZ)
ON CONFLICT (id_produto, id_localidade, ano, mes) DO NOTHING;

-- 5. Reabilitar triggers
ALTER TABLE staging.fact_precos_mensais ENABLE TRIGGER ALL;

-- 6. Inserir dados do mart (sazonalidade_produto, baselines)
-- ... (executar após staging estar completo)

-- 7. Refresh da Materialized View
REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade;

-- 8. Verificar contagens
SELECT 'dim_produto' as tabela, COUNT(*) as total FROM staging.dim_produto
UNION ALL
SELECT 'dim_localidade', COUNT(*) FROM staging.dim_localidade
UNION ALL
SELECT 'fact_precos_mensais', COUNT(*) FROM staging.fact_precos_mensais
UNION ALL
SELECT 'sazonalidade_produto', COUNT(*) FROM mart.sazonalidade_produto
UNION ALL
SELECT 'vw_api_produtos_sazonalidade', COUNT(*) FROM mart.vw_api_produtos_sazonalidade;
