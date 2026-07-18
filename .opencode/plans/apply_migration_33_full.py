"""Apply full migration 33 - LIMIT/OFFSET for all functions."""
import asyncio
import asyncpg

SQL = r"""
CREATE OR REPLACE FUNCTION mart.fn_br_nacional_por_mes(
    p_ano       INTEGER,
    p_mes       INTEGER,
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
    v_categoria_filter TEXT := COALESCE(p_categoria, '%%');
BEGIN
    RETURN QUERY
    WITH uf_consolidado AS (
        SELECT
            v.produto, v.classificao_produto,
            COALESCE(v.categoria, 'ALIMENTO_VAREJO') AS categoria_final,
            v.uf, COUNT(*)::NUMERIC AS peso_uf,
            AVG(v.preco_referencia) AS uf_preco_ref,
            AVG(v.preco_atual) AS uf_preco_atual,
            BOOL_OR(v.usou_fallback_12m) AS uf_fallback,
            BOOL_OR(v.preco_estimado) AS uf_estimado,
            BOOL_OR(v.is_forecast) AS uf_forecast,
            MODE() WITHIN GROUP (ORDER BY v.status_cor) AS uf_status_cor
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.ano = p_ano AND v.mes = p_mes
          AND (p_categoria IS NULL OR v.categoria ILIKE v_categoria_filter)
        GROUP BY v.produto, v.classificao_produto, v.categoria_final, v.uf
    )
    SELECT
        uf.produto, uf.classificao_produto, uf.categoria_final,
        'BR'::TEXT, 'BRASIL'::TEXT, '0'::TEXT,
        p_ano, p_mes, (p_ano || '-' || LPAD(p_mes::TEXT, 2, '0'))::TEXT,
        ROUND(SUM(uf.uf_preco_ref * uf.peso_uf) / NULLIF(SUM(uf.peso_uf), 0), 4),
        ROUND(SUM(uf.uf_preco_atual * uf.peso_uf) / NULLIF(SUM(uf.peso_uf), 0), 4),
        BOOL_OR(uf.uf_fallback), BOOL_OR(uf.uf_estimado),
        MODE() WITHIN GROUP (ORDER BY uf.uf_status_cor),
        'municipio'::TEXT, BOOL_OR(uf.uf_forecast),
        COUNT(DISTINCT uf.uf)
    FROM uf_consolidado uf
    GROUP BY uf.produto, uf.classificao_produto, uf.categoria_final
    HAVING COUNT(DISTINCT uf.uf) >= 5
    ORDER BY 13, uf.produto
    LIMIT p_limit OFFSET p_offset;
END;
$body$;

CREATE OR REPLACE FUNCTION mart.fn_regional_por_mes(
    p_ufs TEXT[], p_min_ufs INTEGER DEFAULT 2,
    p_ano INTEGER DEFAULT NULL, p_mes INTEGER DEFAULT NULL,
    p_categoria TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT NULL, p_offset INTEGER DEFAULT 0
)
RETURNS TABLE(
    produto TEXT, classificao_produto TEXT, categoria TEXT,
    uf TEXT, municipio TEXT, status_cor TEXT,
    total_ufs BIGINT, data_referencia_atual TEXT,
    is_forecast BOOLEAN, fonte TEXT, ano INTEGER, mes INTEGER
) LANGUAGE SQL STABLE AS $body$
    WITH regional_data AS (
        SELECT DISTINCT ON (v.id_produto, v.uf)
            v.id_produto, v.produto, v.classificao_produto, v.categoria,
            v.uf, v.municipio, v.status_cor, v.ano, v.mes,
            v.data_referencia_atual, v.is_forecast, v.fonte
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.uf = ANY(p_ufs)
          AND (p_categoria IS NULL OR v.categoria = p_categoria)
          AND (p_ano IS NULL OR v.ano = p_ano)
          AND (p_mes IS NULL OR v.mes = p_mes)
        ORDER BY v.id_produto, v.uf, v.ano DESC, v.mes DESC
    ),
    regional_moda AS (
        SELECT id_produto, COUNT(DISTINCT uf) AS total_ufs,
               MODE() WITHIN GROUP (ORDER BY status_cor) AS moda_status
        FROM regional_data GROUP BY id_produto
        HAVING COUNT(DISTINCT uf) >= p_min_ufs
    )
    SELECT lp.produto::TEXT, lp.classificao_produto::TEXT, lp.categoria::TEXT,
           p_ufs[1]::TEXT AS uf, 'REGIAO'::TEXT AS municipio,
           rm.moda_status::TEXT AS status_cor, rm.total_ufs::BIGINT,
           MAX(lp.data_referencia_atual)::TEXT, BOOL_OR(lp.is_forecast),
           'regiao'::TEXT, COALESCE(p_ano, MAX(lp.ano))::INTEGER, COALESCE(p_mes, MAX(lp.mes))::INTEGER
    FROM regional_moda rm
    JOIN regional_data lp ON lp.id_produto = rm.id_produto
    GROUP BY lp.produto, lp.classificao_produto, lp.categoria, rm.moda_status, rm.total_ufs
    ORDER BY rm.moda_status, lp.produto
    LIMIT p_limit OFFSET p_offset;
$body$;

CREATE OR REPLACE FUNCTION mart.fn_regional_snapshot(
    p_ufs TEXT[], p_min_ufs INTEGER DEFAULT 2,
    p_categoria TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT NULL, p_offset INTEGER DEFAULT 0
)
RETURNS TABLE(
    produto TEXT, classificao_produto TEXT, categoria TEXT,
    uf TEXT, municipio TEXT, status_cor TEXT,
    total_ufs BIGINT, data_referencia_atual TEXT,
    is_forecast BOOLEAN, fonte TEXT, ano INTEGER, mes INTEGER
) LANGUAGE SQL STABLE AS $body$
    WITH latest_per_uf AS (
        SELECT DISTINCT ON (v.id_produto, v.uf)
            v.id_produto, v.produto, v.classificao_produto, v.categoria,
            v.uf, v.municipio, v.status_cor, v.ano, v.mes,
            v.data_referencia_atual, v.is_forecast, v.fonte
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.uf = ANY(p_ufs)
          AND (p_categoria IS NULL OR v.categoria = p_categoria)
        ORDER BY v.id_produto, v.uf, v.ano DESC, v.mes DESC
    ),
    regional_moda AS (
        SELECT id_produto, COUNT(DISTINCT uf) AS total_ufs,
               MODE() WITHIN GROUP (ORDER BY status_cor) AS moda_status
        FROM latest_per_uf GROUP BY id_produto
        HAVING COUNT(DISTINCT uf) >= p_min_ufs
    )
    SELECT lp.produto::TEXT, lp.classificao_produto::TEXT, lp.categoria::TEXT,
           p_ufs[1]::TEXT AS uf, 'REGIAO'::TEXT AS municipio,
           rm.moda_status::TEXT AS status_cor, rm.total_ufs::BIGINT,
           MAX(lp.data_referencia_atual)::TEXT, BOOL_OR(lp.is_forecast),
           'regiao'::TEXT, MAX(lp.ano)::INTEGER, MAX(lp.mes)::INTEGER
    FROM regional_moda rm
    JOIN latest_per_uf lp ON lp.id_produto = rm.id_produto
    GROUP BY lp.produto, lp.classificao_produto, lp.categoria, rm.moda_status, rm.total_ufs
    ORDER BY rm.moda_status, lp.produto
    LIMIT p_limit OFFSET p_offset;
$body$;
"""

async def main():
    conn = await asyncpg.connect("postgresql://postgres:postgres@localhost:5432/quero_comprar")
    try:
        print("Aplicando full migration 33...")
        await conn.execute(SQL)
        print("OK")

        # Verify
        funcs = await conn.fetch("""
            SELECT proname, pronargs
            FROM pg_proc
            WHERE pronamespace = 'mart'::regnamespace
              AND proname IN ('fn_br_nacional_por_mes','fn_br_nacional_snapshot','fn_regional_por_mes','fn_regional_snapshot')
            ORDER BY proname, pronargs
        """)
        print("\nFuncoes apos migration:")
        for f in funcs:
            print(f"  {f['proname']}({f['pronargs']} args)")
    finally:
        await conn.close()

asyncio.run(main())
