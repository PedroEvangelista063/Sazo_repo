SELECT setval('staging.dim_produto_id_produto_seq', (SELECT COALESCE(MAX(id_produto),0)+1 FROM staging.dim_produto), false);
SELECT setval('staging.dim_localidade_id_localidade_seq', (SELECT COALESCE(MAX(id_localidade),0)+1 FROM staging.dim_localidade), false);
SELECT setval('staging.dim_categoria_id_categoria_seq', (SELECT COALESCE(MAX(id_categoria),0)+1 FROM staging.dim_categoria), false);
SELECT setval('staging.fact_precos_mensais_id_fato_seq', (SELECT COALESCE(MAX(id_fato),0)+1 FROM staging.fact_precos_mensais), false);
SELECT setval('staging.confianca_baseline_id_confianca_seq', (SELECT COALESCE(MAX(id_confianca),0)+1 FROM staging.confianca_baseline), false);
SELECT setval('staging.baseline_2025_interpolado_id_baseline_seq', (SELECT COALESCE(MAX(id_baseline),0)+1 FROM staging.baseline_2025_interpolado), false);
SELECT setval('staging.dim_conab_produto_mapping_id_mapping_seq', (SELECT COALESCE(MAX(id_mapping),0)+1 FROM staging.dim_conab_produto_mapping), false);
SELECT setval('mart.sazonalidade_produto_id_sazonalidade_seq', (SELECT COALESCE(MAX(id_sazonalidade),0)+1 FROM mart.sazonalidade_produto), false);
