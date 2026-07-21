CREATE UNIQUE INDEX IF NOT EXISTS idx_vw_sazonalidade_unico ON mart.vw_api_produtos_sazonalidade (id_sazonalidade);
CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_filtro ON mart.vw_api_produtos_sazonalidade (uf, municipio, status_cor);
CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_categoria ON mart.vw_api_produtos_sazonalidade (categoria);
CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_produto ON mart.vw_api_produtos_sazonalidade (id_produto);
CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_ano_mes ON mart.vw_api_produtos_sazonalidade (ano, mes) WHERE ano IS NOT NULL AND mes IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_forecast ON mart.vw_api_produtos_sazonalidade (is_forecast) WHERE is_forecast = TRUE;
CREATE INDEX IF NOT EXISTS idx_vw_sazonalidade_confianca ON mart.vw_api_produtos_sazonalidade (baseline_confianca DESC) WHERE is_forecast = TRUE;
