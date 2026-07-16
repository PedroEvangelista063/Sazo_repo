CREATE OR REPLACE FUNCTION mart.fn_regional_snapshot(
    p_ufs TEXT[],
    p_min_ufs INTEGER DEFAULT 2,
    p_categoria TEXT DEFAULT NULL
)
RETURNS TABLE(
    produto TEXT,
    classificao_produto TEXT,
    categoria TEXT,
    uf TEXT,
    municipio TEXT,
    status_cor TEXT,
    total_ufs BIGINT,
    data_referencia_atual TEXT,
    is_forecast BOOLEAN,
    fonte TEXT,
    ano INTEGER,
    mes INTEGER
)
LANGUAGE SQL
STABLE
AS $$
    WITH latest_per_uf AS (
        SELECT DISTINCT ON (v.id_produto, v.uf)
            v.id_produto,
            v.produto,
            v.classificao_produto,
            v.categoria,
            v.uf,
            v.municipio,
            v.status_cor,
            v.ano,
            v.mes,
            v.data_referencia_atual,
            v.is_forecast,
            v.fonte
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.uf = ANY(p_ufs)
          AND (p_categoria IS NULL OR v.categoria = p_categoria)
        ORDER BY v.id_produto, v.uf, v.ano DESC, v.mes DESC
    ),
    regional_moda AS (
        SELECT
            id_produto,
            COUNT(DISTINCT uf) AS total_ufs,
            MODE() WITHIN GROUP (ORDER BY status_cor) AS moda_status
        FROM latest_per_uf
        GROUP BY id_produto
        HAVING COUNT(DISTINCT uf) >= p_min_ufs
    )
    SELECT
        lp.produto::TEXT,
        lp.classificao_produto::TEXT,
        lp.categoria::TEXT,
        p_ufs[1]::TEXT AS uf,
        'REGIÃO'::TEXT AS municipio,
        rm.moda_status::TEXT AS status_cor,
        rm.total_ufs::BIGINT,
        MAX(lp.data_referencia_atual)::TEXT AS data_referencia_atual,
        BOOL_OR(lp.is_forecast) AS is_forecast,
        'regiao'::TEXT AS fonte,
        MAX(lp.ano)::INTEGER AS ano,
        MAX(lp.mes)::INTEGER AS mes
    FROM regional_moda rm
    JOIN latest_per_uf lp ON lp.id_produto = rm.id_produto
    GROUP BY lp.produto, lp.classificao_produto, lp.categoria, rm.moda_status, rm.total_ufs
    ORDER BY rm.moda_status, lp.produto;
$$;


CREATE OR REPLACE FUNCTION mart.fn_regional_por_mes(
    p_ufs TEXT[],
    p_min_ufs INTEGER DEFAULT 2,
    p_ano INTEGER DEFAULT NULL,
    p_mes INTEGER DEFAULT NULL,
    p_categoria TEXT DEFAULT NULL
)
RETURNS TABLE(
    produto TEXT,
    classificao_produto TEXT,
    categoria TEXT,
    uf TEXT,
    municipio TEXT,
    status_cor TEXT,
    total_ufs BIGINT,
    data_referencia_atual TEXT,
    is_forecast BOOLEAN,
    fonte TEXT,
    ano INTEGER,
    mes INTEGER
)
LANGUAGE SQL
STABLE
AS $$
    WITH regional_data AS (
        SELECT DISTINCT ON (v.id_produto, v.uf)
            v.id_produto,
            v.produto,
            v.classificao_produto,
            v.categoria,
            v.uf,
            v.municipio,
            v.status_cor,
            v.ano,
            v.mes,
            v.data_referencia_atual,
            v.is_forecast,
            v.fonte
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.uf = ANY(p_ufs)
          AND (p_categoria IS NULL OR v.categoria = p_categoria)
          AND (p_ano IS NULL OR v.ano = p_ano)
          AND (p_mes IS NULL OR v.mes = p_mes)
        ORDER BY v.id_produto, v.uf, v.ano DESC, v.mes DESC
    ),
    regional_moda AS (
        SELECT
            id_produto,
            COUNT(DISTINCT uf) AS total_ufs,
            MODE() WITHIN GROUP (ORDER BY status_cor) AS moda_status
        FROM regional_data
        GROUP BY id_produto
        HAVING COUNT(DISTINCT uf) >= p_min_ufs
    )
    SELECT
        lp.produto::TEXT,
        lp.classificao_produto::TEXT,
        lp.categoria::TEXT,
        p_ufs[1]::TEXT AS uf,
        'REGIÃO'::TEXT AS municipio,
        rm.moda_status::TEXT AS status_cor,
        rm.total_ufs::BIGINT,
        MAX(lp.data_referencia_atual)::TEXT AS data_referencia_atual,
        BOOL_OR(lp.is_forecast) AS is_forecast,
        'regiao'::TEXT AS fonte,
        COALESCE(p_ano, MAX(lp.ano))::INTEGER AS ano,
        COALESCE(p_mes, MAX(lp.mes))::INTEGER AS mes
    FROM regional_moda rm
    JOIN regional_data lp ON lp.id_produto = rm.id_produto
    GROUP BY lp.produto, lp.classificao_produto, lp.categoria, rm.moda_status, rm.total_ufs
    ORDER BY rm.moda_status, lp.produto;
$$;
