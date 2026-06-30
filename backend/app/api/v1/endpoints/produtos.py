from fastapi import APIRouter, Query
from backend.app.schemas.responses import SazonalidadeResponse, SazonalidadeListResponse
from backend.app.db.session import fetch, fetchrow
from backend.app.core.cache import cache
from backend.app.core.config import get_settings
import hashlib
import json

router = APIRouter(prefix="/sazonalidade", tags=["Sazonalidade"])


async def _query_sazonalidade(
    uf: str | None = None,
    municipio: str | None = None,
    produto: str | None = None,
    status_cor: str | None = None,
    categoria: str | None = None,
    ano: int | None = None,
    mes: int | None = None,
    pagina: int = 1,
    por_pagina: int = 100,
) -> SazonalidadeListResponse:
    settings = get_settings()
    cache_key = hashlib.md5(
        json.dumps({"uf": uf, "municipio": municipio, "produto": produto,
                     "status_cor": status_cor, "categoria": categoria,
                     "ano": ano, "mes": mes,
                     "pagina": pagina, "por_pagina": por_pagina},
                    sort_keys=True, default=str).encode()
    ).hexdigest()

    cached = cache.get(cache_key)
    if cached is not None:
        return SazonalidadeListResponse(**cached)

    where_clauses = ["1=1"]
    params = []
    idx = 1

    if uf:
        where_clauses.append(f"v.uf = ${idx}")
        params.append(uf.upper())
        idx += 1
    if municipio:
        where_clauses.append(f"v.municipio ILIKE ${idx}")
        params.append(f"%{municipio}%")
        idx += 1
    if produto:
        where_clauses.append(f"v.produto ILIKE ${idx}")
        params.append(f"%{produto}%")
        idx += 1
    if status_cor:
        where_clauses.append(f"v.status_cor = ${idx}")
        params.append(status_cor.upper())
        idx += 1
    if categoria:
        where_clauses.append(f"v.categoria = ${idx}")
        params.append(categoria.upper())
        idx += 1
    if ano:
        where_clauses.append(f"v.ano = ${idx}")
        params.append(ano)
        idx += 1
    if mes:
        where_clauses.append(f"v.mes = ${idx}")
        params.append(mes)
        idx += 1

    where = " AND ".join(where_clauses)

    count_query = f"SELECT COUNT(*) as total FROM mart.vw_api_produtos_sazonalidade v WHERE {where}"
    data_query = f"""
        SELECT
            v.id_sazonalidade,
            v.produto,
            v.categoria,
            v.uf,
            v.municipio,
            v.municipio_id,
            v.ano,
            v.mes,
            v.preco_referencia,
            v.preco_atual,
            v.data_referencia_atual,
            v.usou_fallback_12m,
            v.status_cor,
            v.fonte
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE {where}
        ORDER BY v.status_cor, v.uf, v.produto
        OFFSET ${idx} LIMIT ${idx + 1}
    """
    offset_val = (pagina - 1) * por_pagina
    params.extend([offset_val, por_pagina])

    total_row = await fetchrow(count_query, *params[:idx-1])
    total = total_row["total"] if total_row else 0

    if total == 0:
        result = SazonalidadeListResponse(data=[], total=0, pagina=pagina, por_pagina=por_pagina)
        cache.set(cache_key, result.model_dump(), settings.cache_ttl_seconds)
        return result

    rows = await fetch(data_query, *params)

    items = []
    for r in rows:
        pid = r["id_sazonalidade"]
        items.append(SazonalidadeResponse(
            id_produto=pid,
            nome_produto=r["produto"],
            icone_url=None,
            uf=r["uf"],
            municipio=r.get("municipio"),
            municipio_id=r.get("municipio_id"),
            ano=r["ano"],
            mes=r["mes"],
            data_referencia_atual=r["data_referencia_atual"],
            preco_referencia=r.get("preco_referencia"),
            preco_atual=r.get("preco_atual"),
            usou_fallback_12m=r.get("usou_fallback_12m", False),
            status_cor=r["status_cor"],
            fonte=r["fonte"],
            categoria=r.get("categoria"),
        ))

    result = SazonalidadeListResponse(data=items, total=total, pagina=pagina, por_pagina=por_pagina)
    cache.set(cache_key, result.model_dump(), settings.cache_ttl_seconds)
    return result


@router.get("", response_model=SazonalidadeListResponse)
async def listar_sazonalidade(
    uf: str | None = Query(None, min_length=2, max_length=2, description="UF (BR-2)"),
    municipio: str | None = Query(None, description="Nome do municipio"),
    produto: str | None = Query(None, description="Nome do produto"),
    status_cor: str | None = Query(None, pattern=r'^(VERDE|AMARELO|VERMELHO|INSUFICIENTE)$'),
    categoria: str | None = Query(None, description="Nome da categoria (FRUTAS, LEGUMES, etc.)"),
    ano: int | None = Query(None, ge=2020, le=2030),
    mes: int | None = Query(None, ge=1, le=12),
    pagina: int = Query(1, ge=1),
    por_pagina: int = Query(100, ge=1, le=500),
):
    return await _query_sazonalidade(
        uf=uf, municipio=municipio, produto=produto, status_cor=status_cor,
        categoria=categoria,
        ano=ano, mes=mes, pagina=pagina, por_pagina=por_pagina,
    )


@router.get("/{uf}/{municipio}", response_model=SazonalidadeListResponse)
async def listar_por_localidade(
    uf: str,
    municipio: str,
    categoria: str | None = Query(None, description="Nome da categoria (FRUTAS, LEGUMES, etc.)"),
    pagina: int = Query(1, ge=1),
    por_pagina: int = Query(100, ge=1, le=500),
):
    return await _query_sazonalidade(
        uf=uf, municipio=municipio, categoria=categoria,
        pagina=pagina, por_pagina=por_pagina,
    )