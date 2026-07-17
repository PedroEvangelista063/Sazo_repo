-- ============================================================================
-- Migration 012: Additional Functions
-- Funções regionais, categorias, paginação
-- ============================================================================

-- fn_regioes_listar — retorna regiões com polos CEASA
CREATE OR REPLACE FUNCTION public.fn_regioes_listar()
RETURNS JSON AS $$
BEGIN
    RETURN (
        SELECT json_agg(json_build_object(
            'id', r.id,
            'nome', r.nome,
            'ufs', r.ufs,
            'polos', r.polos
        ))
        FROM (
            SELECT 
                id,
                nome,
                ufs,
                polos
            FROM json_to_recordset(
                (SELECT valor FROM ops.config_agente WHERE chave = 'regioes')::json
            ) AS r(id TEXT, nome TEXT, ufs JSON, polos JSON)
        ) r
    );
END;
$$ LANGUAGE plpgsql;

-- fn_resumo_regiao — snapshot agregado por região
CREATE OR REPLACE FUNCTION public.fn_resumo_regiao(p_regiao_id TEXT, p_ano INT DEFAULT 2025)
RETURNS JSON AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_build_object(
        'regiao', p_regiao_id,
        'ano', p_ano,
        'produtos', (
            SELECT json_agg(json_build_object(
                'produto', s.produto,
                'status_cor', s.status_cor,
                'count', s.cnt
            ))
            FROM (
                SELECT 
                    p.nome_produto AS produto,
                    sp.status_cor,
                    COUNT(*) AS cnt
                FROM mart.sazonalidade_produto sp
                JOIN staging.dim_produto p ON p.id_produto = sp.id_produto
                WHERE sp.ano = p_ano
                  AND sp.status_cor != 'INSUFICIENTE'
                GROUP BY p.nome_produto, sp.status_cor
            ) s
        )
    ) INTO v_result;
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql;
