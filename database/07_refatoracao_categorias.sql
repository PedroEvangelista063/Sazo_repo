-- ============================================================================
-- QUERO COMPRAR — Fase 11: Normalização de Categorias (Modelo Relacional 1:N)
-- PostgreSQL 16+  |  Combate ao Table Bloat e Entropia de Schema
--
-- MOTIVAÇÃO:
--   A categorização vivia como coluna solta (categoria_b2c TEXT) em
--   staging.dim_produto, sem valor semântico real para o frontend e sem
--   integridade referencial. Isso gerava acoplamento entre a regra de
--   negócio (categoria de varejo) e a entidade produto.
--
--   A comunidade (HN, r/dataengineering, Uber eng blogs) converge para
--   o padrão ouro: normalizar hierarquias categoriais em tabela própria
--   com chave estrangeira 1:N. Isto:
--     - Permite adicionar metadados por categoria (icone, descrição)
--     - Evita table bloat de tabelas-filhas dinâmicas (anti-pattern OCP)
--     - Acelora queries de filtro por categoria com índices diretos
--     - Prepara o schema para um futuro modelo de subcategoria
--
-- SUMÁRIO:
--   1. Criação de staging.dim_categoria (id_categoria PK, nome_categoria UNIQUE)
--   2. INSERT das categorias-base de varejo
--   3. ALTER TABLE staging.dim_produto → ADD COLUMN id_categoria FK
--   4. Migração de dados existentes (produto → categoria via padrões de nome)
--   5. Índices, constraints, permissões
-- ============================================================================

BEGIN;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 1 — Tabela de Categoria: staging.dim_categoria
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE TABLE IF NOT EXISTS staging.dim_categoria (
    id_categoria     SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome_categoria   TEXT NOT NULL,
    descricao        TEXT,
    icone_url        TEXT,
    criado_em        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_dim_categoria_nome UNIQUE (nome_categoria)
);

COMMENT ON TABLE  staging.dim_categoria IS 'Tabela de categorias de varejo (modelo relacional 1:N com dim_produto)';
COMMENT ON COLUMN staging.dim_categoria.id_categoria   IS 'PK gerada automaticamente (SMALLINT — até 32767 categorias)';
COMMENT ON COLUMN staging.dim_categoria.nome_categoria IS 'Nome amigável da categoria (ex: FRUTAS, LEGUMES, PESCADOS)';
COMMENT ON COLUMN staging.dim_categoria.descricao      IS 'Descrição opcional para exibição no frontend';
COMMENT ON COLUMN staging.dim_categoria.icone_url      IS 'URL do ícone representativo da categoria';
COMMENT ON COLUMN staging.dim_categoria.criado_em      IS 'Timestamp de criação do registro';

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 2 — População das Categorias Base
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

INSERT INTO staging.dim_categoria (nome_categoria, descricao) VALUES
    ('FRUTAS',             'Frutas frescas in natura (banana, maçã, laranja, uva, etc.)'),
    ('LEGUMES',            'Legumes e tubérculos (batata, cenoura, tomate, abóbora, etc.)'),
    ('VERDURAS',           'Verduras e folhosas (alface, couve, espinafre, rúcula, etc.)'),
    ('FLORES',             'Flores e ornamentais (rosa, orquídea, crisântemo, etc.)'),
    ('PESCADOS',           'Pescados e frutos do mar (peixe, camarão, tilápia, etc.)'),
    ('PROTEINAS',          'Carnes, ovos e laticínios (bovina, frango, leite, queijo)'),
    ('CEREAIS_GRAOS',      'Cereais, grãos e farináceos (arroz, feijão, farinha, trigo)'),
    ('BEBIDAS',            'Bebidas em geral (suco, café, refrigerante)'),
    ('ALIMENTO_VAREJO',    'Demais alimentos de varejo não classificados acima'),
    ('OUTROS',             'Máquinas, insumos, serviços e matéria-prima B2B')
ON CONFLICT (nome_categoria) DO NOTHING;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 3 — Chave Estrangeira em staging.dim_produto
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

ALTER TABLE staging.dim_produto
    ADD COLUMN IF NOT EXISTS id_categoria SMALLINT
    REFERENCES staging.dim_categoria (id_categoria)
    ON DELETE RESTRICT;

COMMENT ON COLUMN staging.dim_produto.id_categoria
    IS 'FK para staging.dim_categoria — categoria de varejo do produto (ON DELETE RESTRICT)';

CREATE INDEX IF NOT EXISTS idx_dim_produto_id_categoria
    ON staging.dim_produto (id_categoria);

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 4 — Migração de Dados Existentes
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Mapeia produtos existentes para categorias de varejo com base em
-- padrões de nome. Produtos B2B (MAQUINARIO, INSUMO, SERVICO) vão
-- para OUTROS.
--
-- NOTA: Este é um mapeamento inicial aproximado. O motor semântico
-- Python (ingestao_conab_inteligente.py) deve ser atualizado para
-- popular id_categoria corretamente nas próximas ingestões.
-- =========================================================================

DO $$
DECLARE
    v_cat_frutas      SMALLINT := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'FRUTAS');
    v_cat_legumes     SMALLINT := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'LEGUMES');
    v_cat_verduras    SMALLINT := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'VERDURAS');
    v_cat_flores      SMALLINT := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'FLORES');
    v_cat_pescados    SMALLINT := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'PESCADOS');
    v_cat_proteinas   SMALLINT := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'PROTEINAS');
    v_cat_cereais     SMALLINT := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'CEREAIS_GRAOS');
    v_cat_bebidas     SMALLINT := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'BEBIDAS');
    v_cat_alimento    SMALLINT := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'ALIMENTO_VAREJO');
    v_cat_outros      SMALLINT := (SELECT id_categoria FROM staging.dim_categoria WHERE nome_categoria = 'OUTROS');
BEGIN
    UPDATE staging.dim_produto
    SET id_categoria = CASE
        -- ── FRUTAS ────────────────────────────────────────────────────
        WHEN nome_produto ~* '^(abacate|abacaxi|acerola|ameixa|amora|banana|cacau|caju|caqui|carambola|cereja|coco|damasco|figo|framboesa|fruta|goiaba|graviola|jabuticaba|jaca|kiwi|laranja|limão|lima|maçã|mamão|manga|maracujá|melancia|melão|mexerica|morango|nectarina|pêra|pêssego|pitanga|romã|tangerina|uva|graviola|jambo|pitaya|abiu|cupuaçu)'
        THEN v_cat_frutas

        -- ── LEGUMES ───────────────────────────────────────────────────
        WHEN nome_produto ~* '^(abóbora|abobrinha|batata|berinjela|beterraba|cenoura|chuchu|ervilha|grão|inhame|lentilha|mandioca|mandioquinha|milho|pepino|pimenta|pimentão|quiabo|repolho|tomate|vagem|rabanete|nabo|alcachofra|aspargo|palmito|azeitona|maxixe|cará|jiló)'
        THEN v_cat_legumes

        -- ── VERDURAS ──────────────────────────────────────────────────
        WHEN nome_produto ~* '^(agrião|alface|almeirão|brócolis|cebolinha|chicória|couve|couve.flor|escarola|espinafre|hortelã|manjericão|mostarda|rúcula|salsinha|salsa|coentro|endívia|alho.poró|acelga)'
        THEN v_cat_verduras

        -- ── FLORES ────────────────────────────────────────────────────
        WHEN nome_produto ~* '(flor|orquídea|rosa|crisântemo|girassol|lírio|tulipa|violeta|begônia|azaleia)'
            OR (categoria_b2c = 'ALIMENTO_VAREJO' AND nome_produto ~* '^(flores?|mudas?|plantas?|ornamental)')
        THEN v_cat_flores

        -- ── PESCADOS ──────────────────────────────────────────────────
        WHEN nome_produto ~* '^(peixe|pescado|camarão|tilápia|sardinha|atum|salmão|bacalhau|linguado|corvina|anchova|robalo|dourado|pintado|tambaqui|surubim|merluza|polvo|lula|ostra|marisco|caranguejo|siri)'
        THEN v_cat_pescados

        -- ── PROTEINAS ─────────────────────────────────────────────────
        WHEN nome_produto ~* '^(carne|bovina|suína|frango|linguiça|laticínio|leite|queijo|manteiga|iogurte|ovo|presunto|mortadela|salame|hambúrguer|nugget|salsicha|bacon|costela|alcatra|picanha|maminha|coxão|patinho|acém|peito)'
        THEN v_cat_proteinas

        -- ── CEREAIS_GRAOS ─────────────────────────────────────────────
        WHEN nome_produto ~* '^(arroz|feijão|farinha|trigo|aveia|centeio|cevada|milho|soja|fubá|polvilho|fécula|amido)'
        THEN v_cat_cereais

        -- ── BEBIDAS ───────────────────────────────────────────────────
        WHEN nome_produto ~* '^(café|suco|refrigerante|bebida|cerveja|vinho|cachaça|água|isotônico|energético|chá)'
        THEN v_cat_bebidas

        -- ── ALIMENTO_VAREJO (residual de alimentos) ───────────────────
        WHEN categoria_b2c = 'ALIMENTO_VAREJO'
        THEN v_cat_alimento

        -- ── OUTROS (B2B, máquinas, insumos, serviços) ─────────────────
        ELSE v_cat_outros
    END
    WHERE id_categoria IS NULL;

    RAISE NOTICE 'Migração de categorias concluída. Produtos sem categoria: %',
        (SELECT count(*) FROM staging.dim_produto WHERE id_categoria IS NULL);
END $$;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 5 — Aplicar NOT NULL após migração
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Produtos órfãos (categoria OUTROS) são aceitáveis, mas a coluna deve
-- ser NOT NULL para garantir integridade referencial futura.

ALTER TABLE staging.dim_produto
    ALTER COLUMN id_categoria SET NOT NULL;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- SEÇÃO 6 — Permissões
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

GRANT ALL ON TABLE staging.dim_categoria TO role_etl_writer;
GRANT SELECT ON TABLE staging.dim_categoria TO role_api_reader;

COMMIT;
