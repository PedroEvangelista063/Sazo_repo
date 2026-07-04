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
        json.dumps(
            {
                "uf": uf,
                "municipio": municipio,
                "produto": produto,
                "status_cor": status_cor,
                "categoria": categoria,
                "ano": ano,
                "mes": mes,
                "pagina": pagina,
                "por_pagina": por_pagina,
            },
            sort_keys=True,
            default=str,
        ).encode()
    ).hexdigest()

    cached = cache.get(cache_key)
    if cached is not None:
        return SazonalidadeListResponse(**cached)

    offset_val = (pagina - 1) * por_pagina

    if ano is not None and mes is not None:
        return await _query_sazonalidade_por_mes(
            ano,
            mes,
            uf,
            municipio,
            produto,
            status_cor,
            categoria,
            pagina,
            por_pagina,
            offset_val,
            cache_key,
            settings,
        )

    return await _query_sazonalidade_snapshot(
        uf,
        municipio,
        produto,
        status_cor,
        categoria,
        pagina,
        por_pagina,
        offset_val,
        cache_key,
        settings,
    )


async def _query_sazonalidade_snapshot(
    uf,
    municipio,
    produto,
    status_cor,
    categoria,
    pagina,
    por_pagina,
    offset_val,
    cache_key,
    settings,
) -> SazonalidadeListResponse:
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
            v.preco_estimado,
            v.status_cor,
            v.fonte
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE {where}
        ORDER BY v.status_cor, v.uf, v.produto
        OFFSET ${idx} LIMIT ${idx + 1}
    """
    params.extend([offset_val, por_pagina])

    total_row = await fetchrow(count_query, *params[: idx - 1])
    total = total_row["total"] if total_row else 0

    if total == 0:
        result = SazonalidadeListResponse(data=[], total=0, pagina=pagina, por_pagina=por_pagina)
        cache.set(cache_key, result.model_dump(), settings.cache_ttl_seconds)
        return result

    rows = await fetch(data_query, *params)
    return _build_response(rows, total, pagina, por_pagina, cache_key, settings)


_HIST_CACHE_TTL = 86_400  # 24h — dados históricos imutáveis


async def _query_sazonalidade_por_mes(
    ano: int,
    mes: int,
    uf,
    municipio,
    produto,
    status_cor,
    categoria,
    pagina,
    por_pagina,
    offset_val,
    _cache_key,
    settings,
) -> SazonalidadeListResponse:
    # Chave: apenas dimensões imutáveis — sem produto, status_cor, paginação
    hist_parts = [str(ano), str(mes), uf or "", municipio or "", categoria or ""]
    hist_key = "saz_hist_" + "_".join(hist_parts).rstrip("_")

    cached_full = cache.get(hist_key)
    if cached_full is not None:
        return _slice_periodo(cached_full, produto, status_cor, pagina, por_pagina)

    rows = await _compute_periodo_full(ano, mes, uf, municipio, categoria)

    full = []
    for i, r in enumerate(rows):
        full.append(
            SazonalidadeResponse(
                id_produto=i + 1,
                nome_produto=r["produto"],
                icone_url=None,
                uf=r["uf"],
                municipio=r.get("municipio"),
                municipio_id=r.get("municipio_id"),
                ano=ano,
                mes=mes,
                data_referencia_atual=r["data_referencia_atual"],
                preco_referencia=r.get("preco_referencia"),
                preco_atual=r.get("preco_atual"),
                usou_fallback_12m=r.get("usou_fallback_12m", False),
                preco_estimado=r.get("preco_estimado", False),
                status_cor=r["status_cor"],
                fonte=r["fonte"],
                categoria=r.get("categoria"),
            )
        )

    cache.set(hist_key, full, _HIST_CACHE_TTL)

    return _slice_periodo(full, produto, status_cor, pagina, por_pagina)


def _slice_periodo(full_dicts, produto, status_cor, pagina, por_pagina):
    filtered = full_dicts
    if produto:
        p = produto.upper()
        filtered = [d for d in filtered if p in (d.get("nome_produto") or "").upper()]
    if status_cor:
        s = status_cor.upper()
        filtered = [d for d in filtered if d.get("status_cor") == s]

    total = len(filtered)
    start = (pagina - 1) * por_pagina
    page = filtered[start : start + por_pagina]
    if page and isinstance(page[0], dict):
        page = [SazonalidadeResponse(**d) for d in page]
    return SazonalidadeListResponse(data=page, total=total, pagina=pagina, por_pagina=por_pagina)


async def _compute_periodo_full(ano, mes, uf, municipio, categoria):
    params = [ano, mes]
    idx = 3

    dim = []
    if uf:
        dim.append(f"v.uf = ${idx}")
        params.append(uf.upper())
        idx += 1
    if municipio:
        dim.append(f"v.municipio ILIKE ${idx}")
        params.append(f"%{municipio}%")
        idx += 1
    if categoria:
        dim.append(f"v.categoria = ${idx}")
        params.append(categoria.upper())
        idx += 1

    dim_sql = " AND ".join(dim) if dim else "1=1"

    sql = f"""
        SELECT
            v.produto,
            v.categoria,
            v.uf,
            v.municipio,
            v.municipio_id,
            $1::INTEGER AS ano_pesquisa,
            $2::INTEGER AS mes_pesquisa,
            v.data_referencia_atual,
            v.preco_referencia,
            v.preco_atual,
            v.usou_fallback_12m,
            v.preco_estimado,
            v.status_cor,
            v.fonte
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE {dim_sql}
        ORDER BY v.status_cor, v.produto
    """

    return await fetch(sql, *params)


def _build_response(rows, total, pagina, por_pagina, cache_key, settings):
    items = []
    for r in rows:
        items.append(
            SazonalidadeResponse(
                id_produto=r.get("id_sazonalidade", 0),
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
                preco_estimado=r.get("preco_estimado", False),
                status_cor=r["status_cor"],
                fonte=r["fonte"],
                categoria=r.get("categoria"),
            )
        )

    result = SazonalidadeListResponse(data=items, total=total, pagina=pagina, por_pagina=por_pagina)
    cache.set(cache_key, result.model_dump(), settings.cache_ttl_seconds)
    return result


@router.get("", response_model=SazonalidadeListResponse)
async def listar_sazonalidade(
    uf: str | None = Query(None, min_length=2, max_length=2, description="UF (BR-2)"),
    municipio: str | None = Query(None, description="Nome do municipio"),
    produto: str | None = Query(None, description="Nome do produto"),
    status_cor: str | None = Query(None, pattern=r"^(VERDE|AMARELO|VERMELHO)$"),
    categoria: str | None = Query(None, description="Nome da categoria (FRUTAS, LEGUMES, etc.)"),
    ano: int | None = Query(None, ge=2020, le=2030),
    mes: int | None = Query(None, ge=1, le=12),
    pagina: int = Query(1, ge=1),
    por_pagina: int = Query(100, ge=1, le=500),
):
    return await _query_sazonalidade(
        uf=uf,
        municipio=municipio,
        produto=produto,
        status_cor=status_cor,
        categoria=categoria,
        ano=ano,
        mes=mes,
        pagina=pagina,
        por_pagina=por_pagina,
    )


@router.get("/{uf}/{municipio}", response_model=SazonalidadeListResponse)
async def listar_por_localidade(
    uf: str,
    municipio: str,
    categoria: str | None = Query(None, description="Nome da categoria (FRUTAS, LEGUMES, etc.)"),
    ano: int | None = Query(None, ge=2020, le=2030),
    mes: int | None = Query(None, ge=1, le=12),
    pagina: int = Query(1, ge=1),
    por_pagina: int = Query(100, ge=1, le=500),
):
    return await _query_sazonalidade(
        uf=uf,
        municipio=municipio,
        categoria=categoria,
        ano=ano,
        mes=mes,
        pagina=pagina,
        por_pagina=por_pagina,
    )
