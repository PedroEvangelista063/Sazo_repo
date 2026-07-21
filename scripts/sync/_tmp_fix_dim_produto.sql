ALTER TABLE staging.dim_produto ADD COLUMN IF NOT EXISTS conab_id_produto INTEGER;
ALTER TABLE staging.dim_produto ADD COLUMN IF NOT EXISTS classificao_produto TEXT;
ALTER TABLE staging.dim_produto ADD COLUMN IF NOT EXISTS categoria_b2c TEXT;
ALTER TABLE staging.dim_produto ADD COLUMN IF NOT EXISTS id_categoria SMALLINT NOT NULL DEFAULT 9;
ALTER TABLE staging.dim_produto ADD COLUMN IF NOT EXISTS status_imagem TEXT NOT NULL DEFAULT 'PENDENTE';
ALTER TABLE staging.dim_produto ADD COLUMN IF NOT EXISTS status_fonte TEXT NOT NULL DEFAULT 'SEM_FONTE_MAPEDADA';
