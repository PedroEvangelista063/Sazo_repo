BEGIN;

ALTER TABLE staging.dim_produto
    ADD COLUMN IF NOT EXISTS status_fonte TEXT NOT NULL DEFAULT 'SEM_FONTE_MAPEDADA'
    CHECK (status_fonte IN ('MAPEADA', 'SEM_FONTE_MAPEDADA'));

COMMENT ON COLUMN staging.dim_produto.status_fonte IS
    'MAPEADA → possui fonte (HF Brasil/CEASA) que cobre este produto; '
    'SEM_FONTE_MAPEDADA → nenhum adapter consegue obter preço (carnes, grãos, etc.)';

-- Mapeia automaticamente por categoria:
-- HORTIFRÚTI (FRUTAS=1, LEGUMES=2, VERDURAS=3, FLORES=4, DIVERSOS → ALIMENTO_VAREJO=9) → MAPEADA
-- PROTEINAS=6, CEREAIS_GRAOS=7, PESCADOS=5, BEBIDAS=8, OUTROS=10 → SEM_FONTE_MAPEDADA
UPDATE staging.dim_produto
SET status_fonte = 'MAPEADA'
WHERE id_categoria IN (1, 2, 3, 4, 9);

UPDATE staging.dim_produto
SET status_fonte = 'SEM_FONTE_MAPEDADA'
WHERE id_categoria IN (5, 6, 7, 8, 10)
   OR id_categoria IS NULL;

COMMIT;
