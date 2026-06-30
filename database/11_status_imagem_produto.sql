-- ============================================================================
-- QUERO COMPRAR — Fase 11: Status de Imagem na Dimensão Produto
-- PostgreSQL 16+
--
-- MOTIVAÇÃO:
--   546 produtos no catálogo, mas sem imagens reais. Em vez de bloquear
--   o frontend, tratamos a falta de imagem como um estado explícito:
--
--   DISPONIVEL  → thumbnail existe em assets/thumbnails/
--   PENDENTE    → aguardando curadoria manual (placeholder genérico)
--   SEM_IMAGEM  → produto sem expectativa de ter imagem
--
--   O frontend consulta esta coluna para decidir se exibe a imagem real
--   (CDN), um placeholder "Em breve", ou um emoji genérico.
-- ============================================================================

BEGIN;

ALTER TABLE staging.dim_produto
    ADD COLUMN IF NOT EXISTS status_imagem TEXT NOT NULL DEFAULT 'PENDENTE'
    CHECK (status_imagem IN ('DISPONIVEL', 'PENDENTE', 'SEM_IMAGEM'));

COMMENT ON COLUMN staging.dim_produto.status_imagem IS
    'DISPONIVEL → thumbnail existe; PENDENTE → aguardando curadoria; '
    'SEM_IMAGEM → sem expectativa de imagem';

-- Atualiza todos os produtos ALIMENTO_VAREJO existentes para PENDENTE
UPDATE staging.dim_produto
SET status_imagem = 'PENDENTE'
WHERE status_imagem IS NULL
  AND categoria_b2c = 'ALIMENTO_VAREJO';

COMMIT;
