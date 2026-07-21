ALTER TABLE mart.sazonalidade_produto ADD COLUMN IF NOT EXISTS ano smallint;
ALTER TABLE mart.sazonalidade_produto ADD COLUMN IF NOT EXISTS mes smallint;
ALTER TABLE mart.sazonalidade_produto ADD COLUMN IF NOT EXISTS preco_medio numeric;
ALTER TABLE mart.sazonalidade_produto ADD COLUMN IF NOT EXISTS media_movel_12m numeric;
ALTER TABLE mart.sazonalidade_produto ADD COLUMN IF NOT EXISTS indice_sazonalidade numeric;
