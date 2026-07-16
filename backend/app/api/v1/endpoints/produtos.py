import hashlib
import json
from pathlib import Path
from collections import defaultdict

from fastapi import APIRouter, Query

from backend.app.core.cache import cache, safe_set
from backend.app.core.config import get_settings
from backend.app.db.session import fetch, fetchrow
from backend.app.schemas.responses import (
    SazonalidadeListResponse,
    SazonalidadeResponse,
    SazonalidadeComPrecoListResponse,
    SazonalidadeComPrecoResponse,
    SazonalidadeNacionalResponse,
    SazonalidadeNacionalListResponse,
    MesSazonalidade,
)

router = APIRouter(prefix="/sazonalidade", tags=["Sazonalidade"])


async def _carregar_regiao(regiao_id: str) -> tuple[list[str], int] | None:
    path = Path("config/regions.json")
    if not path.exists():
        return None
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    for r in data["regioes"]:
        if r["id"] == regiao_id.lower():
            ufs = r["ufs"]
            min_ufs = max(2, __import__("math").ceil(len(ufs) * 0.75))
            return ufs, min_ufs
    return None


async def _query_sazonalidade(
    regiao: str | None = None,
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
                "regiao": regiao,
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

    cached = await cache.get(cache_key)
    if cached is not None:
        return SazonalidadeListResponse(**cached)

    offset_val = (pagina - 1) * por_pagina

    if regiao:
        regiao_data = await _carregar_regiao(regiao)
        if regiao_data is None:
            return SazonalidadeListResponse(data=[], total=0, pagina=pagina, por_pagina=por_pagina)
        ufs_regiao, min_ufs = regiao_data

        if ano is not None and mes is not None:
            return await _query_regional_por_mes(
                ufs_regiao, min_ufs, regiao, ano, mes, categoria,
                pagina, por_pagina, offset_val, cache_key, settings,
            )
        return await _query_regional_snapshot(
            ufs_regiao, min_ufs, regiao, categoria,
            pagina, por_pagina, offset_val, cache_key, settings,
        )

    if uf and uf.upper() == "BR":
        if ano is not None and mes is not None:
            return await _query_br_por_mes(
                ano,
                mes,
                categoria,
                pagina,
                por_pagina,
                offset_val,
                cache_key,
                settings,
            )
        return await _query_br_snapshot(
            categoria,
            pagina,
            por_pagina,
            offset_val,
            cache_key,
            settings,
        )

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
    conds: list[tuple[str, str | None]] = [("1=1", None)]

    if uf:
        conds.append(("v.uf =", uf.upper()))
    if municipio:
        conds.append(("v.municipio ILIKE", f"%{municipio}%"))
    if produto:
        conds.append(("v.produto ILIKE", f"%{produto}%"))
    if status_cor:
        conds.append(("v.status_cor =", status_cor.upper()))
    if categoria:
        conds.append(("v.categoria =", categoria.upper()))

    params: list = []
    parts: list[str] = []
    idx = 1
    for col, val in conds:
        if val is None:
            parts.append(col)
        else:
            parts.append(f"{col} ${idx}")
            params.append(val)
            idx += 1
    where = " AND ".join(parts)

    BASE_COLS = """
        v.id_sazonalidade, v.id_produto, v.produto, v.categoria,
        v.uf, v.municipio, v.municipio_id, v.ano, v.mes,
        v.preco_referencia, v.preco_atual, v.data_referencia_atual,
        v.usou_fallback_12m, v.preco_estimado, v.status_cor, v.fonte,
        v.tendencia_futura, v.is_forecast,
        b.confianca AS confianca_baseline
    """

    BASE_JOIN = """
        LEFT JOIN mart.sazonalidade_baseline b
            ON b.id_produto = v.id_produto
           AND b.id_localidade = v.id_localidade
           AND b.mes = v.mes
    """

    count_query = f"""
        SELECT COUNT(*) AS total FROM (
            SELECT v.id_produto, v.uf,
                   ROW_NUMBER() OVER (
                       PARTITION BY v.id_produto, v.uf
                       ORDER BY v.ano DESC, v.mes DESC
                   ) AS rn
            FROM mart.vw_api_produtos_sazonalidade v
            {BASE_JOIN}
            WHERE {where}
        ) sub WHERE sub.rn = 1
    """
    data_query = f"""
        SELECT * FROM (
            SELECT {BASE_COLS},
                   ROW_NUMBER() OVER (
                       PARTITION BY v.id_produto, v.uf
                       ORDER BY v.ano DESC, v.mes DESC
                   ) AS rn
            FROM mart.vw_api_produtos_sazonalidade v
            {BASE_JOIN}
            WHERE {where}
        ) sub
        WHERE sub.rn = 1
        ORDER BY sub.status_cor, sub.uf, sub.produto
        OFFSET ${idx} LIMIT ${idx + 1}
    """
    params.extend([offset_val, por_pagina])

    total_row = await fetchrow(count_query, *params[: idx - 1])
    total = total_row["total"] if total_row else 0

    if total == 0:
        result = SazonalidadeListResponse(data=[], total=0, pagina=pagina, por_pagina=por_pagina)
        await safe_set(cache_key, result.model_dump(), settings.cache_ttl_seconds)
        return result

    rows = await fetch(data_query, *params)
    return await _build_response(rows, total, pagina, por_pagina, cache_key, settings)


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

    cached_full = await cache.get(hist_key)
    if cached_full is not None:
        return _slice_periodo(cached_full, produto, status_cor, pagina, por_pagina)

    rows = await _compute_periodo_full(ano, mes, uf, municipio, categoria)

    full = []
    for r in rows:
        full.append(
            SazonalidadeResponse(
                id_produto=r.get("id_sazonalidade", 0),
                nome_produto=r["produto"],
                icone_url=None,
                uf=r["uf"],
                municipio=r.get("municipio"),
                municipio_id=r.get("municipio_id"),
                ano=ano,
                mes=mes,
                data_referencia_atual=r["data_referencia_atual"],
                usou_fallback_12m=r.get("usou_fallback_12m", False),
                preco_estimado=r.get("preco_estimado", False),
                status_cor=r["status_cor"],
                fonte=r["fonte"],
                categoria=r.get("categoria"),
                tendencia_futura=r.get("tendencia_futura"),
                is_forecast=r.get("is_forecast", False),
                confianca_baseline=float(r["confianca_baseline"])
                if r.get("confianca_baseline")
                else None,
            )
        )

    await safe_set(hist_key, full, float(_HIST_CACHE_TTL))

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
    params: list = [ano, mes]
    conds: list[tuple[str, str | None]] = [
        ("v.ano = $1", None),
        ("v.mes = $2", None),
    ]

    idx = 3
    if uf:
        conds.append((f"v.uf = ${idx}", uf.upper()))
        params.append(uf.upper())
        idx += 1
    if municipio:
        conds.append((f"v.municipio ILIKE ${idx}", f"%{municipio}%"))
        params.append(f"%{municipio}%")
        idx += 1
    if categoria:
        conds.append((f"v.categoria = ${idx}", categoria.upper()))
        params.append(categoria.upper())
        idx += 1

    where = " AND ".join(c[0] for c in conds)

    sql = f"""
        SELECT
            v.id_sazonalidade, v.id_produto, v.produto, v.categoria,
            v.uf, v.municipio, v.municipio_id,
            $1::INTEGER AS ano_pesquisa,
            $2::INTEGER AS mes_pesquisa,
            v.data_referencia_atual, v.preco_referencia, v.preco_atual,
            v.usou_fallback_12m, v.preco_estimado, v.status_cor,
            v.fonte, v.tendencia_futura, v.is_forecast,
            b.confianca AS confianca_baseline
        FROM mart.vw_api_produtos_sazonalidade v
        LEFT JOIN mart.sazonalidade_baseline b
            ON b.id_produto = v.id_produto
           AND b.id_localidade = v.id_localidade
           AND b.mes = v.mes
        WHERE {where}
        ORDER BY v.status_cor, v.produto
    """

    return await fetch(sql, *params)


async def _build_response(rows, total, pagina, por_pagina, cache_key, settings):
    items = [
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
            usou_fallback_12m=r.get("usou_fallback_12m", False),
            preco_estimado=r.get("preco_estimado", False),
            status_cor=r["status_cor"],
            fonte=r["fonte"],
            categoria=r.get("categoria"),
            tendencia_futura=r.get("tendencia_futura"),
            is_forecast=r.get("is_forecast", False),
            confianca_baseline=float(r["confianca_baseline"])
            if r.get("confianca_baseline")
            else None,
        )
        for r in rows
    ]

    result = SazonalidadeListResponse(data=items, total=total, pagina=pagina, por_pagina=por_pagina)
    await safe_set(cache_key, result.model_dump(), settings.cache_ttl_seconds)
    return result


async def _query_br_snapshot(
    categoria,
    pagina,
    por_pagina,
    offset_val,
    cache_key,
    settings,
) -> SazonalidadeListResponse:
    if categoria:
        rows = await fetch("SELECT * FROM mart.fn_br_nacional_snapshot($1)", categoria.upper())
    else:
        rows = await fetch("SELECT * FROM mart.fn_br_nacional_snapshot(NULL)")
    return await _build_br_response(rows, pagina, por_pagina, offset_val, cache_key, settings)


async def _query_br_por_mes(
    ano,
    mes,
    categoria,
    pagina,
    por_pagina,
    offset_val,
    cache_key,
    settings,
) -> SazonalidadeListResponse:
    if categoria:
        rows = await fetch(
            "SELECT * FROM mart.fn_br_nacional_por_mes($1, $2, $3)",
            ano,
            mes,
            categoria.upper(),
        )
    else:
        rows = await fetch(
            "SELECT * FROM mart.fn_br_nacional_por_mes($1, $2, NULL)",
            ano,
            mes,
        )
    return await _build_br_response(rows, pagina, por_pagina, offset_val, cache_key, settings)


async def _build_br_response(rows, pagina, por_pagina, offset_val, cache_key, settings):
    total = len(rows)
    page = rows[offset_val : offset_val + por_pagina]
    items = [
        SazonalidadeResponse(
            id_produto=0,
            nome_produto=r["produto"],
            icone_url=None,
            uf="BR",
            municipio="BRASIL",
            municipio_id="0",
            ano=r["ano"],
            mes=r["mes"],
            data_referencia_atual=r["data_referencia_atual"],
            usou_fallback_12m=r.get("usou_fallback_12m", False),
            preco_estimado=r.get("preco_estimado", False),
            status_cor=r["status_cor"],
            fonte=r.get("fonte", "municipio"),
            categoria=r.get("categoria"),
            tendencia_futura=None,
            is_forecast=r.get("is_forecast", False),
            confianca_baseline=None,
        )
        for r in page
    ]
    result = SazonalidadeListResponse(data=items, total=total, pagina=pagina, por_pagina=por_pagina)
    await safe_set(cache_key, result.model_dump(), settings.cache_ttl_seconds)
    return result


async def _query_regional_snapshot(
    ufs: list[str],
    min_ufs: int,
    regiao_id: str,
    categoria: str | None,
    pagina: int,
    por_pagina: int,
    offset_val: int,
    cache_key: str,
    settings,
) -> SazonalidadeListResponse:
    if categoria:
        rows = await fetch(
            "SELECT * FROM mart.fn_regional_snapshot($1, $2, $3)",
            ufs, min_ufs, categoria.upper(),
        )
    else:
        rows = await fetch(
            "SELECT * FROM mart.fn_regional_snapshot($1, $2, NULL)",
            ufs, min_ufs,
        )

    total = len(rows)
    page = rows[offset_val : offset_val + por_pagina]
    items = [
        SazonalidadeResponse(
            id_produto=0,
            nome_produto=r["produto"],
            icone_url=None,
            uf=regiao_id.upper(),
            municipio="REGIÃO",
            municipio_id="0",
            ano=r["ano"],
            mes=r["mes"],
            data_referencia_atual=r.get("data_referencia_atual", ""),
            usou_fallback_12m=False,
            preco_estimado=False,
            status_cor=r["status_cor"],
            fonte="regiao",
            categoria=r.get("categoria"),
            tendencia_futura=None,
            is_forecast=r.get("is_forecast", False),
            confianca_baseline=None,
        )
        for r in page
    ]
    result = SazonalidadeListResponse(data=items, total=total, pagina=pagina, por_pagina=por_pagina)
    await safe_set(cache_key, result.model_dump(), settings.cache_ttl_seconds)
    return result


async def _query_regional_por_mes(
    ufs: list[str],
    min_ufs: int,
    regiao_id: str,
    ano: int,
    mes: int,
    categoria: str | None,
    pagina: int,
    por_pagina: int,
    offset_val: int,
    cache_key: str,
    settings,
) -> SazonalidadeListResponse:
    if categoria:
        rows = await fetch(
            "SELECT * FROM mart.fn_regional_por_mes($1, $2, $3, $4, $5)",
            ufs, min_ufs, ano, mes, categoria.upper(),
        )
    else:
        rows = await fetch(
            "SELECT * FROM mart.fn_regional_por_mes($1, $2, $3, $4, NULL)",
            ufs, min_ufs, ano, mes,
        )

    total = len(rows)
    page = rows[offset_val : offset_val + por_pagina]
    items = [
        SazonalidadeResponse(
            id_produto=0,
            nome_produto=r["produto"],
            icone_url=None,
            uf=regiao_id.upper(),
            municipio="REGIÃO",
            municipio_id="0",
            ano=r["ano"],
            mes=r["mes"],
            data_referencia_atual=r.get("data_referencia_atual", ""),
            usou_fallback_12m=False,
            preco_estimado=False,
            status_cor=r["status_cor"],
            fonte="regiao",
            categoria=r.get("categoria"),
            tendencia_futura=None,
            is_forecast=r.get("is_forecast", False),
            confianca_baseline=None,
        )
        for r in page
    ]
    result = SazonalidadeListResponse(data=items, total=total, pagina=pagina, por_pagina=por_pagina)
    await safe_set(cache_key, result.model_dump(), settings.cache_ttl_seconds)
    return result


@router.get("", response_model=SazonalidadeListResponse)
async def listar_sazonalidade(
    regiao: str | None = Query(None, description="ID da região (norte, nordeste, centro-oeste, sudeste, sul)"),
    uf: str | None = Query(None, min_length=2, max_length=2, description="UF (BR-2)"),
    municipio: str | None = Query(None, description="Nome do municipio"),
    produto: str | None = Query(None, description="Nome do produto"),
    status_cor: str | None = Query(None, pattern=r"^(VERDE|AMARELO|VERMELHO)$"),
    categoria: str | None = Query(None, description="Nome da categoria (FRUTAS, LEGUMES, etc.)"),
    ano: int | None = Query(None, ge=2024, le=2030),
    mes: int | None = Query(None, ge=1, le=12),
    pagina: int = Query(1, ge=1),
    por_pagina: int = Query(100, ge=1, le=2000),
):
    return await _query_sazonalidade(
        regiao=regiao,
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


@router.get("/com-preco", response_model=SazonalidadeComPrecoListResponse)
async def listar_sazonalidade_com_preco(
    uf: str | None = Query(None, min_length=2, max_length=2),
    produto: str | None = Query(None),
    ano: int | None = Query(None, ge=2024, le=2030),
    mes: int | None = Query(None, ge=1, le=12),
    pagina: int = Query(1, ge=1),
    por_pagina: int = Query(500, ge=1, le=2000),
):
    offset_val = (pagina - 1) * por_pagina
    conds = ["1=1"]
    params: list = []
    idx = 1

    if uf:
        conds.append(f"v.uf = ${idx}")
        params.append(uf.upper())
        idx += 1
    if produto:
        conds.append(f"v.produto ILIKE ${idx}")
        params.append(f"%{produto}%")
        idx += 1
    if ano is not None:
        conds.append(f"v.ano = ${idx}")
        params.append(ano)
        idx += 1
    if mes is not None:
        conds.append(f"v.mes = ${idx}")
        params.append(mes)
        idx += 1

    where = " AND ".join(conds)

    sql = f"""
        SELECT v.id_produto, v.produto, v.categoria, v.uf,
               v.municipio, v.municipio_id, v.ano, v.mes,
               v.data_referencia_atual,
               v.preco_referencia, v.preco_atual,
               v.variacao_pct, v.preco_estimado,
               v.usou_fallback_12m, v.status_cor,
               v.fonte, v.tendencia_futura, v.is_forecast,
               b.confianca AS confianca_baseline,
               NULL::NUMERIC(14,4) AS preco_mes_anterior
        FROM mart.vw_api_produtos_sazonalidade v
        LEFT JOIN mart.sazonalidade_baseline b
            ON b.id_produto = v.id_produto
           AND b.id_localidade = v.id_localidade
           AND b.mes = v.mes
        WHERE {where}
        ORDER BY v.produto, v.uf, v.ano DESC, v.mes DESC
        OFFSET ${idx} LIMIT ${idx + 1}
    """
    params.extend([offset_val, por_pagina])

    rows = await fetch(sql, *params)

    count_sql = f"""
        SELECT COUNT(*) FROM mart.vw_api_produtos_sazonalidade v
        WHERE {where}
    """
    total_row = await fetchrow(count_sql, *params[: idx - 1])
    total = total_row[0] if total_row else 0

    return SazonalidadeComPrecoListResponse(
        data=[
            SazonalidadeComPrecoResponse(
                id_produto=r["id_produto"],
                nome_produto=r["produto"],
                categoria=r.get("categoria"),
                uf=r["uf"],
                municipio=r.get("municipio"),
                municipio_id=r.get("municipio_id"),
                ano=r["ano"],
                mes=r["mes"],
                data_referencia_atual=r["data_referencia_atual"],
                preco_referencia=float(r["preco_referencia"])
                if r.get("preco_referencia")
                else None,
                preco_atual=float(r["preco_atual"]) if r.get("preco_atual") else None,
                variacao_pct=float(r["variacao_pct"]) if r.get("variacao_pct") else None,
                preco_estimado=r.get("preco_estimado", False),
                usou_fallback_12m=r.get("usou_fallback_12m", False),
                status_cor=r["status_cor"],
                fonte=r.get("fonte"),
                tendencia_futura=r.get("tendencia_futura"),
                is_forecast=r.get("is_forecast", False),
                confianca_baseline=float(r["confianca_baseline"])
                if r.get("confianca_baseline")
                else None,
                preco_mes_anterior=float(r["preco_mes_anterior"])
                if r.get("preco_mes_anterior")
                else None,
            )
            for r in rows
        ],
        total=total,
        pagina=pagina,
        por_pagina=por_pagina,
    )


async def _query_br_sazonalidade(
    ano: int,
    categoria: str | None,
    pagina: int,
    por_pagina: int,
    offset_val: int,
    cache_key: str,
    settings,
) -> SazonalidadeNacionalListResponse:
    if categoria:
        rows = await fetch(
            "SELECT * FROM mart.fn_br_nacional_sazonalidade($1, $2)",
            ano,
            categoria.upper(),
        )
    else:
        rows = await fetch(
            "SELECT * FROM mart.fn_br_nacional_sazonalidade($1)",
            ano,
        )

    prod_map: dict[str, dict] = {}
    for r in rows:
        key = r["produto"]
        if key not in prod_map:
            prod_map[key] = {
                "produto": r["produto"],
                "classificao_produto": r["classificao_produto"],
                "categoria": r["categoria"],
                "total_ufs": r["total_ufs_nac"],
                "meses": [],
            }
        prod_map[key]["meses"].append(
            MesSazonalidade(
                mes=r["mes"],
                status_cor=r["status_cor_nac"],
                is_forecast=r["is_forecast_nac"],
                baseline_confianca=float(r["confianca_nac"])
                if r["confianca_nac"] is not None
                else None,
            )
        )

    all_items = list(prod_map.values())
    total = len(all_items)
    page = all_items[offset_val : offset_val + por_pagina]

    items = [SazonalidadeNacionalResponse(**item) for item in page]
    result = SazonalidadeNacionalListResponse(
        data=items, total=total, pagina=pagina, por_pagina=por_pagina
    )
    await safe_set(cache_key, result.model_dump(), settings.cache_ttl_seconds)
    return result


@router.get("/br-sazonalidade", response_model=SazonalidadeNacionalListResponse)
async def listar_br_sazonalidade(
    ano: int = Query(..., ge=2024, le=2030, description="Ano da sazonalidade"),
    categoria: str | None = Query(None, description="Filtro por categoria"),
    pagina: int = Query(1, ge=1),
    por_pagina: int = Query(100, ge=1, le=2000),
):
    settings = get_settings()
    cache_key = hashlib.md5(
        json.dumps(
            {"route": "br_sazonalidade", "ano": ano, "categoria": categoria, "pagina": pagina, "por_pagina": por_pagina},
            sort_keys=True,
            default=str,
        ).encode()
    ).hexdigest()

    cached = await cache.get(cache_key)
    if cached is not None:
        return SazonalidadeNacionalListResponse(**cached)

    offset_val = (pagina - 1) * por_pagina
    return await _query_br_sazonalidade(ano, categoria, pagina, por_pagina, offset_val, cache_key, settings)


@router.get("/{uf}/{municipio}", response_model=SazonalidadeListResponse)
async def listar_por_localidade(
    uf: str,
    municipio: str,
    categoria: str | None = Query(None, description="Nome da categoria (FRUTAS, LEGUMES, etc.)"),
    ano: int | None = Query(None, ge=2024, le=2030),
    mes: int | None = Query(None, ge=1, le=12),
    pagina: int = Query(1, ge=1),
    por_pagina: int = Query(100, ge=1, le=2000),
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
