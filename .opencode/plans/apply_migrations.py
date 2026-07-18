"""Apply Phase 4 DB migrations."""
import asyncio
import asyncpg

MIGRATION_34 = """
CREATE OR REPLACE VIEW mart.vw_categorias AS
SELECT
    c.id_categoria,
    c.nome_categoria,
    c.descricao,
    COUNT(DISTINCT p.id_produto) AS total_produtos
FROM staging.dim_categoria c
LEFT JOIN staging.dim_produto p
    ON p.id_categoria = c.id_categoria
   AND p.categoria_b2c = 'ALIMENTO_VAREJO'
GROUP BY c.id_categoria, c.nome_categoria, c.descricao
ORDER BY c.nome_categoria;

CREATE OR REPLACE VIEW mart.vw_municipios AS
SELECT DISTINCT
    l.uf,
    l.municipio_nome AS municipio
FROM staging.dim_localidade l
WHERE l.municipio_nome IS NOT NULL
  AND l.municipio_nome != ''
ORDER BY l.uf, l.municipio_nome;

GRANT SELECT ON mart.vw_categorias TO role_api_reader;
GRANT SELECT ON mart.vw_municipios TO role_api_reader;
"""

MIGRATION_33 = r"""
CREATE OR REPLACE FUNCTION mart.fn_br_nacional_snapshot(
    p_categoria TEXT DEFAULT NULL,
    p_limit     INTEGER DEFAULT NULL,
    p_offset    INTEGER DEFAULT 0
)
RETURNS TABLE(
    produto TEXT, classificao_produto TEXT, categoria TEXT,
    uf TEXT, municipio TEXT, municipio_id TEXT,
    ano INTEGER, mes INTEGER,
    data_referencia_atual TEXT,
    preco_referencia NUMERIC, preco_atual NUMERIC,
    usou_fallback_12m BOOLEAN, preco_estimado BOOLEAN,
    status_cor TEXT, fonte TEXT, is_forecast BOOLEAN,
    total_ufs BIGINT
) LANGUAGE plpgsql STABLE AS $body$
DECLARE
    v_ultimo_ano INTEGER;
    v_ultimo_mes INTEGER;
BEGIN
    SELECT MAX(v.ano), MAX(v.mes) FILTER (WHERE v.ano = (SELECT MAX(v2.ano) FROM mart.vw_api_produtos_sazonalidade v2))
    INTO v_ultimo_ano, v_ultimo_mes
    FROM mart.vw_api_produtos_sazonalidade v;
    IF v_ultimo_ano IS NULL THEN RETURN; END IF;
    RETURN QUERY
    SELECT * FROM mart.fn_br_nacional_por_mes(v_ultimo_ano, v_ultimo_mes, p_categoria, p_limit, p_offset);
END;
$body$;

GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_snapshot(TEXT, INTEGER, INTEGER) TO role_api_reader;
"""

async def main():
    dsn = "postgresql://postgres:postgres@localhost:5432/quero_comprar"
    conn = await asyncpg.connect(dsn)
    try:
        user = await conn.fetchval("SELECT current_user")
        print(f"Conectado como: {user}")

        # Migration 34
        print("\n--- Migration 34: mart.vw_categorias + mart.vw_municipios ---")
        await conn.execute(MIGRATION_34)
        print("OK")

        # Migration 33 (partial - snapshot apenas)
        print("\n--- Migration 33: fn_br_nacional_snapshot com paginacao ---")
        await conn.execute(MIGRATION_33)
        print("OK")

        # Verify
        print("\n--- Verificacao ---")
        views = await conn.fetch("SELECT table_name FROM information_schema.views WHERE table_schema='mart' AND table_name IN ('vw_categorias','vw_municipios')")
        for v in views:
            print(f"  View criada: mart.{v['table_name']}")

        funcs = await conn.fetch("SELECT proname, pronargs FROM pg_proc WHERE pronamespace='mart'::regnamespace AND proname LIKE 'fn_br_nacional_snapshot'")
        for f in funcs:
            print(f"  Funcao atualizada: {f['proname']} ({f['pronargs']} args)")

    except Exception as e:
        print(f"ERRO: {e}")
    finally:
        await conn.close()

asyncio.run(main())
