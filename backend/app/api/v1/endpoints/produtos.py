import asyncio
import hashlib
import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Query, Response

from backend.app.core.cache import cache, safe_set
from backend.app.core.config import get_settings
from backend.app.db.session import fetch, fetchrow
from backend.app.schemas.responses import (
    MesSazonalidade,
    SazonalidadeComPrecoListResponse,
    SazonalidadeComPrecoResponse,
    SazonalidadeListResponse,
    SazonalidadeNacionalListResponse,
    SazonalidadeNacionalResponse,
    SazonalidadeResponse,
)

router = APIRouter(prefix="/sazonalidade", tags=["Sazonalidade"])


# FASE 79 (P1-2) — Memoização do X-Last-Refresh.
# Causa raiz de latência do ERR_ABORTED (axios 10s) na 1ª carga do BR:
# _ultimo_refresh_mv_iso() era chamado até 2x por request (cache key + header)
# e CADA chamada fazia 2 round-trips ao Aiven (pg_stat_file + audit.mv_refresh_log,
# ~2,5-4s cada). Memoização com TTL curto via cache store + double-checked
# asyncio.Lock: mesma request e requests próximas batem no cache.
_MV_REFRESH_CACHE_KEY = "saz:ultimo_refresh_mv"
_MV_REFRESH_TTL = 30.0  # segundos — MENOR que o TTL do cache de dados (3600s)
_mv_refresh_lock = asyncio.Lock()


def _compor_mensagem_transparencia(
    tipo_dado: str | None,
    ano_referencia: int | None,
    idade: int | None = None,
    metadado: dict[str, Any] | None = None,
) -> str | None:
    """Composição pt-BR da mensagem de proveniência temporal (sem R$).

    R-ADD-03/S3: apenas texto de proveniência — nunca valores monetários.
    R-ADD-04: tuplas com preço nulo ainda carregam a mensagem de contexto.

    ``idade`` pode vir da coluna ``idade_dado_anos`` da MV V17; quando ausente
    (ex: saída da ``fn_br_nacional_sazonalidade``, que não projeta essa coluna),
    deriva de ``ANO_ATUAL - ano_referencia`` para nunca exibir "defasagem de
    None ano".

    ``metadado`` (opcional) é o ``metadado_transparencia`` da MV quando a linha
    o expõe: FASE 79 (P1-1) emite a mensagem exata do Deep Fallback (V22) a
    partir de ``metadado.mensagem_transparencia`` quando presente.
    """
    if not tipo_dado:
        return None
    if idade is None and ano_referencia is not None:
        idade = datetime.now(UTC).year - ano_referencia
    if tipo_dado == "REAL_ATUAL":
        return f"Coleta efetiva — cotação real da CONAB no ano de referência {ano_referencia}."
    if tipo_dado == "HISTORICO_BASE":
        suf = "s" if (idade or 0) > 1 else ""
        return (
            f"Dado histórico real — última cotação real da CONAB em {ano_referencia} "
            f"(defasagem de {idade} ano{suf}). Não é estimativa sintética."
        )
    if tipo_dado == "FALLBACK_DIMENSAO":
        # FASE 79 (P1-1): linhas de projeção do Deep Fallback (V22) agora entram
        # na saída nacional — emitem a mensagem de projeção. Prioridade:
        #   1) mensagem exata gravada no metadado_transparencia da MV (quando o
        #      caller a expõe);
        #   2) derivação pelo ano_referencia (histórico usado pela projeção) —
        #      caso do /br-sazonalidade, cuja função não projeta metadado;
        #   3) sem histórico real (baseline de dimensão).
        msg = (metadado or {}).get("mensagem_transparencia")
        if msg:
            return msg
        if ano_referencia is not None:
            return f"Projecao sazonal baseada no historico de {ano_referencia}."
        return "Projecao sazonal sem historico real (baseline de dimensao)."
    return "Sem histórico real para este período — valor de referência da dimensão (fallback)."


def _is_dado_legado(ano_referencia: int | None) -> bool:
    """True quando o dado é de ano anterior ao corrente (R-ADD-02)."""
    return ano_referencia is not None and ano_referencia < datetime.now(UTC).year


async def _carregar_regiao(regiao_id: str) -> tuple[list[str], int] | None:
    path = Path("config/regions.json")
    if not path.exists():
        return None
    with open(path, encoding="utf-8") as f:  # noqa: ASYNC230 - leitura local de config
        data = json.load(f)
    for r in data["regioes"]:
        if r["id"] == regiao_id.lower():
            ufs = r["ufs"]
            min_ufs = max(2, __import__("math").ceil(len(ufs) * 0.75))
            return ufs, min_ufs
    return None


def _build_sazonalidade_cache_key(
    regiao: str | None,
    uf: str | None,
    municipio: str | None,
    produto: str | None,
    status_cor: str | None,
    categoria: str | None,
    ano: int | None,
    mes: int | None,
    pagina: int,
    por_pagina: int,
    mv_refresh: str = "",
) -> str:
    """Chave de cache compartilhada entre o endpoint e `_query_sazonalidade`.

    Deve espelhar EXATAMENTE a chave usada no cache set (MD5 de dict com
    sort_keys, default=str), para que a checagem HIT/MISS do endpoint enxergue
    o mesmo objeto armazenado pelo helper.

    ``mv_refresh`` (mtime da MV em ISO UTC) entra na chave para que QUALQUER
    atualização da Materialized View invalide automaticamente o cache desta rota
    — a mesma estratégia já usada em ``br-sazonalidade``. Sem isso, a rota só
    seria invalidada pelo webhook de purge (que em produção aponta para
    ``localhost``) ou pelo TTL de 24h.
    """
    return hashlib.md5(
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
                "mv_refresh": mv_refresh,
            },
            sort_keys=True,
            default=str,
        ).encode()
    ).hexdigest()


async def _ultimo_refresh_mv_iso() -> str:
    """Modificação da MV em ISO8601 UTC (vazio se indisponível) — MEMOIZADO.

    Fonte primária: mtime do arquivo físico (pg_stat_file) — mais preciso.
    Fallback permission-safe: tabela ``audit.mv_refresh_log`` gravada pela
    esteira ETL após cada REFRESH. Necessário porque Aiven nega
    ``pg_stat_file`` para avnadmin/postgres, o que deixava o header
    X-Last-Refresh sempre vazio em produção. Consulta assíncrona via pool da
    API; qualquer exceção retorna ``""`` sem quebrar a resposta.

    FASE 79 (P1-2): valor memoizado por ``_MV_REFRESH_TTL`` (30s) no cache
    store com double-checked ``asyncio.Lock`` — elimina os 2 round-trips ao
    Aiven por chamada (pg_stat_file + audit.mv_refresh_log) dentro do mesmo
    request e entre requests próximas. TTL 30s < TTL do cache de dados (3600s):
    o header nunca fica desatualizado por mais de ~30s.
    """
    cached = await cache.get(_MV_REFRESH_CACHE_KEY)
    if cached is not None:
        return cached

    async with _mv_refresh_lock:
        cached = await cache.get(_MV_REFRESH_CACHE_KEY)
        if cached is not None:
            return cached

        def _fmt(last) -> str:
            if last is None:
                return ""
            if last.tzinfo is None:
                last = last.replace(tzinfo=UTC)
            return last.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")

        try:
            row = await fetchrow(
                "SELECT (pg_stat_file("
                "pg_relation_filepath('mart.vw_api_produtos_sazonalidade'::regclass)"
                ")).modification AS last_refresh"
            )
            value = _fmt(row[0] if row else None)
            if value:
                await safe_set(_MV_REFRESH_CACHE_KEY, value, _MV_REFRESH_TTL)
                return value
        except Exception:  # noqa: BLE001, S110  # sem privilégio -> fallback deliberado
            pass

        try:
            row = await fetchrow(
                "SELECT refreshed_at FROM audit.mv_refresh_log "
                "WHERE mv_name = 'vw_api_produtos_sazonalidade'"
            )
            value = _fmt(row[0] if row else None)
        except Exception:  # noqa: BLE001  # header de transparência nunca deve quebrar a resposta
            value = ""

        await safe_set(_MV_REFRESH_CACHE_KEY, value, _MV_REFRESH_TTL)
        return value


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
    cache_key = _build_sazonalidade_cache_key(
        regiao,
        uf,
        municipio,
        produto,
        status_cor,
        categoria,
        ano,
        mes,
        pagina,
        por_pagina,
        mv_refresh=await _ultimo_refresh_mv_iso(),
    )

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
                ufs_regiao,
                min_ufs,
                regiao,
                ano,
                mes,
                categoria,
                pagina,
                por_pagina,
                offset_val,
                cache_key,
                settings,
            )
        return await _query_regional_snapshot(
            ufs_regiao,
            min_ufs,
            regiao,
            categoria,
            pagina,
            por_pagina,
            offset_val,
            cache_key,
            settings,
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
        v.tendencia_futura, v.is_forecast, v.forecast_method,
        v.ano_referencia, v.tipo_dado, v.idade_dado_anos,
        b.confianca AS confianca_baseline
    """

    BASE_JOIN = """
        LEFT JOIN mart.sazonalidade_baseline b
            ON b.id_produto = v.id_produto
           AND b.id_localidade = v.id_localidade
           AND b.mes = v.mes
    """

    # QUALITY GATE: o snapshot deve refletir o último mês com DADO REAL, não a
    # projeção/fallback mais recente da MV. Prioriza estritamente REAL_ATUAL
    # (coleta efetiva do ano corrente) sobre HISTORICO_BASE (dado real defasado)
    # sobre FALLBACK_DIMENSAO no ORDER BY da window function; produtos sem
    # nenhum dado real caem para o histórico/fallback mais recente.
    _SNAPSHOT_ORDER_BY = """
        ORDER BY CASE v.tipo_dado
                     WHEN 'REAL_ATUAL' THEN 0
                     WHEN 'HISTORICO_BASE' THEN 1
                     ELSE 2
                 END,
                 v.ano DESC,
                 v.mes DESC
    """

    count_query = f"""
        SELECT COUNT(*) AS total FROM (
            SELECT v.id_produto, v.uf,
                   ROW_NUMBER() OVER (
                       PARTITION BY v.id_produto, v.uf
                       {_SNAPSHOT_ORDER_BY}
                   ) AS rn
            FROM mart.vw_api_produtos_sazonalidade v
            WHERE {where}
        ) sub WHERE sub.rn = 1
    """
    data_query = f"""
        SELECT * FROM (
            SELECT {BASE_COLS},
                   ROW_NUMBER() OVER (
                       PARTITION BY v.id_produto, v.uf
                       {_SNAPSHOT_ORDER_BY}
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
    # Chave: apenas dimensões imutáveis — sem produto, status_cor, paginação.
    # mv_refresh entra para que a atualização da MV também invalide este cache
    # aninhado (senão o outer key mudaria mas o hist serviria dado velho).
    hist_parts = [
        str(ano),
        str(mes),
        uf or "",
        municipio or "",
        categoria or "",
        await _ultimo_refresh_mv_iso(),
    ]
    hist_key = "saz_hist_" + "_".join(hist_parts).rstrip("_")

    cached_full = await cache.get(hist_key)
    if cached_full is not None:
        return _slice_periodo(cached_full, produto, status_cor, pagina, por_pagina)

    rows = await _compute_periodo_full(ano, mes, uf, municipio, categoria)

    full = []
    for r in rows:
        ano_ref = r.get("ano_referencia")
        tipo = r.get("tipo_dado")
        idade = r.get("idade_dado_anos")
        full.append(
            SazonalidadeResponse(
                id_produto=r.get("id_produto", 0),
                nome_produto=r["produto"],
                icone_url=None,
                uf=r["uf"],
                municipio=r.get("municipio"),
                municipio_id=r.get("municipio_id"),
                ano=ano,
                mes=mes,
                data_referencia_atual=r["data_referencia_atual"],
                usou_fallback_12m=r.get("usou_fallback_12m") or False,
                preco_estimado=r.get("preco_estimado") or False,
                status_cor=r["status_cor"],
                fonte=r["fonte"],
                categoria=r.get("categoria"),
                tendencia_futura=r.get("tendencia_futura"),
                is_forecast=r.get("is_forecast", False),
                confianca_baseline=float(r["confianca_baseline"])
                if r["confianca_baseline"] is not None
                else None,
                forecast_method=r.get("forecast_method"),
                ano_referencia=ano_ref,
                tipo_dado=tipo,
                mensagem_transparencia=_compor_mensagem_transparencia(tipo, ano_ref, idade),
                is_dado_legado=_is_dado_legado(ano_ref),
            )
        )

    await safe_set(hist_key, full, float(_HIST_CACHE_TTL))

    return _slice_periodo(full, produto, status_cor, pagina, por_pagina)


def _slice_periodo(full_dicts, produto, status_cor, pagina, por_pagina):
    # Normaliza entradas: com InMemoryCache o cache guarda objetos Pydantic
    # (não dicts como no Redis), e .get() falharia com AttributeError — bug de
    # produção que derrubava GET /sazonalidade?mes=... com 500 no 2º hit.
    filtered = [d if isinstance(d, dict) else d.model_dump() for d in full_dicts]
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

    # Deduplica por produto+UF (mesma semântica do snapshot): a view contém uma
    # linha por município além da linha agregada "UF (UF)", o que gerava o mesmo
    # id_produto repetido na resposta por-mês. Quando há filtro de município,
    # mantém todas as linhas do município (já únicas por produto+UF).
    dedupe_order = (
        "ORDER BY sub.status_cor, sub.produto"
        if municipio
        else "ORDER BY (sub.municipio_id IS NULL) DESC, sub.municipio, sub.id_sazonalidade"
    )

    sql = f"""
        SELECT * FROM (
            SELECT
                v.id_sazonalidade, v.id_produto, v.produto, v.categoria,
                v.uf, v.municipio, v.municipio_id,
                $1::INTEGER AS ano_pesquisa,
                $2::INTEGER AS mes_pesquisa,
                v.data_referencia_atual, v.preco_referencia, v.preco_atual,
                v.usou_fallback_12m, v.preco_estimado, v.status_cor,
                v.fonte, v.tendencia_futura, v.is_forecast, v.forecast_method,
                v.ano_referencia, v.tipo_dado, v.idade_dado_anos,
                b.confianca AS confianca_baseline,
                ROW_NUMBER() OVER (
                    PARTITION BY v.id_produto, v.uf
                    ORDER BY (v.municipio_id IS NULL) DESC, v.municipio, v.id_sazonalidade
                ) AS rn
            FROM mart.vw_api_produtos_sazonalidade v
            LEFT JOIN mart.sazonalidade_baseline b
                ON b.id_produto = v.id_produto
               AND b.id_localidade = v.id_localidade
               AND b.mes = v.mes
            WHERE {where}
        ) sub
        WHERE sub.rn = 1
        {dedupe_order}
    """

    return await fetch(sql, *params)


async def _build_response(rows, total, pagina, por_pagina, cache_key, settings):
    items = []
    for r in rows:
        ano_ref = r.get("ano_referencia")
        tipo = r.get("tipo_dado")
        items.append(
            SazonalidadeResponse(
                id_produto=r.get("id_produto", 0),
                nome_produto=r["produto"],
                icone_url=None,
                uf=r["uf"],
                municipio=r.get("municipio"),
                municipio_id=r.get("municipio_id"),
                ano=r["ano"],
                mes=r["mes"],
                data_referencia_atual=r["data_referencia_atual"],
                usou_fallback_12m=r.get("usou_fallback_12m") or False,
                preco_estimado=r.get("preco_estimado") or False,
                status_cor=r["status_cor"],
                fonte=r["fonte"],
                categoria=r.get("categoria"),
                tendencia_futura=r.get("tendencia_futura"),
                is_forecast=r.get("is_forecast", False),
                confianca_baseline=float(r["confianca_baseline"])
                if r["confianca_baseline"] is not None
                else None,
                forecast_method=r.get("forecast_method"),
                ano_referencia=ano_ref,
                tipo_dado=tipo,
                mensagem_transparencia=_compor_mensagem_transparencia(
                    tipo, ano_ref, r.get("idade_dado_anos")
                ),
                is_dado_legado=_is_dado_legado(ano_ref),
            )
        )

    result = SazonalidadeListResponse(data=items, total=total, pagina=pagina, por_pagina=por_pagina)
    await safe_set(cache_key, result.model_dump(), settings.cache_ttl_seconds)
    return result


async def _fetch_count_br_snapshot(categoria) -> int:
    if categoria:
        row = await fetchrow(
            "SELECT COUNT(*) FROM mart.fn_br_nacional_snapshot($1::TEXT)",
            categoria.upper(),
        )
    else:
        row = await fetchrow("SELECT COUNT(*) FROM mart.fn_br_nacional_snapshot(NULL::TEXT)")
    return row[0] if row else 0


async def _fetch_count_br_por_mes(ano, mes, categoria) -> int:
    if categoria:
        row = await fetchrow(
            "SELECT COUNT(*) FROM mart.fn_br_nacional_por_mes($1, $2, $3::TEXT)",
            ano,
            mes,
            categoria.upper(),
        )
    else:
        row = await fetchrow(
            "SELECT COUNT(*) FROM mart.fn_br_nacional_por_mes($1, $2, NULL::TEXT)",
            ano,
            mes,
        )
    return row[0] if row else 0


async def _fetch_page_br_snapshot(categoria, limit, offset) -> list:
    if categoria:
        return await fetch(
            "SELECT * FROM mart.fn_br_nacional_snapshot($1::TEXT, $2, $3)",
            categoria.upper(),
            limit,
            offset,
        )
    return await fetch(
        "SELECT * FROM mart.fn_br_nacional_snapshot(NULL::TEXT, $1, $2)",
        limit,
        offset,
    )


async def _fetch_page_br_por_mes(ano, mes, categoria, limit, offset) -> list:
    if categoria:
        return await fetch(
            "SELECT * FROM mart.fn_br_nacional_por_mes($1, $2, $3::TEXT, $4, $5)",
            ano,
            mes,
            categoria.upper(),
            limit,
            offset,
        )
    return await fetch(
        "SELECT * FROM mart.fn_br_nacional_por_mes($1, $2, NULL::TEXT, $3, $4)",
        ano,
        mes,
        limit,
        offset,
    )


async def _query_br_snapshot(
    categoria,
    pagina,
    por_pagina,
    offset_val,
    cache_key,
    settings,
) -> SazonalidadeListResponse:
    total = await _fetch_count_br_snapshot(categoria)
    rows = await _fetch_page_br_snapshot(categoria, por_pagina, offset_val)
    return await _build_br_response(rows, pagina, por_pagina, total, cache_key, settings)


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
    total = await _fetch_count_br_por_mes(ano, mes, categoria)
    rows = await _fetch_page_br_por_mes(ano, mes, categoria, por_pagina, offset_val)
    return await _build_br_response(rows, pagina, por_pagina, total, cache_key, settings)


async def _build_br_response(rows, pagina, por_pagina, total, cache_key, settings):
    items = []
    for r in rows:
        ano_ref = r.get("ano_referencia")
        tipo = r.get("tipo_dado")
        items.append(
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
                usou_fallback_12m=r.get("usou_fallback_12m") or False,
                preco_estimado=r.get("preco_estimado") or False,
                status_cor=r["status_cor"],
                fonte=r["fonte"],
                categoria=r.get("categoria"),
                tendencia_futura=r.get("tendencia_futura"),
                is_forecast=r.get("is_forecast", False),
                confianca_baseline=float(r["confianca_baseline"])
                if r["confianca_baseline"] is not None
                else None,
                forecast_method=r.get("forecast_method"),
                ano_referencia=ano_ref,
                tipo_dado=tipo,
                mensagem_transparencia=_compor_mensagem_transparencia(
                    tipo, ano_ref, r.get("idade_dado_anos")
                ),
                is_dado_legado=_is_dado_legado(ano_ref),
            )
        )
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
        row = await fetchrow(
            "SELECT COUNT(*) FROM mart.fn_regional_snapshot($1::text[], $2::int, $3)",
            ufs,
            min_ufs,
            categoria.upper(),
        )
    else:
        row = await fetchrow(
            "SELECT COUNT(*) FROM mart.fn_regional_snapshot($1::text[], $2::int, NULL::text)",
            ufs,
            min_ufs,
        )
    total = row[0] if row else 0

    if categoria:
        rows = await fetch(
            "SELECT * FROM mart.fn_regional_snapshot($1::text[], $2::int, $3, $4, $5)",
            ufs,
            min_ufs,
            categoria.upper(),
            por_pagina,
            offset_val,
        )
    else:
        rows = await fetch(
            "SELECT * FROM mart.fn_regional_snapshot($1::text[], $2::int, NULL::text, $3, $4)",
            ufs,
            min_ufs,
            por_pagina,
            offset_val,
        )

    items = []
    for r in rows:
        ano_ref = r.get("ano_referencia")
        tipo = r.get("tipo_dado")
        items.append(
            SazonalidadeResponse(
                id_produto=0,
                nome_produto=r["produto"],
                icone_url=None,
                uf=r["uf"],
                municipio="REGIÃO",
                municipio_id="0",
                ano=r["ano"],
                mes=r["mes"],
                data_referencia_atual=r.get("data_referencia_atual")
                or f"{r['ano']:04d}-{r['mes']:02d}",
                usou_fallback_12m=False,
                preco_estimado=False,
                status_cor=r["status_cor"],
                fonte="regiao",
                categoria=r.get("categoria"),
                tendencia_futura=None,
                is_forecast=r.get("is_forecast", False),
                confianca_baseline=float(r["confianca_baseline"])
                if r.get("confianca_baseline") is not None
                else None,
                forecast_method=r.get("forecast_method"),
                regiao=regiao_id.upper(),
                ano_referencia=ano_ref,
                tipo_dado=tipo,
                mensagem_transparencia=_compor_mensagem_transparencia(
                    tipo, ano_ref, r.get("idade_dado_anos")
                ),
                is_dado_legado=_is_dado_legado(ano_ref),
            )
        )
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
        row = await fetchrow(
            "SELECT COUNT(*) FROM mart.fn_regional_por_mes($1, $2, $3, $4, $5)",
            ufs,
            min_ufs,
            ano,
            mes,
            categoria.upper(),
        )
        rows = await fetch(
            "SELECT * FROM mart.fn_regional_por_mes($1, $2, $3, $4, $5, $6, $7)",
            ufs,
            min_ufs,
            ano,
            mes,
            categoria.upper(),
            por_pagina,
            offset_val,
        )
    else:
        row = await fetchrow(
            "SELECT COUNT(*) FROM mart.fn_regional_por_mes($1, $2, $3, $4, NULL)",
            ufs,
            min_ufs,
            ano,
            mes,
        )
        rows = await fetch(
            "SELECT * FROM mart.fn_regional_por_mes($1, $2, $3, $4, NULL, $5, $6)",
            ufs,
            min_ufs,
            ano,
            mes,
            por_pagina,
            offset_val,
        )

    total = row[0] if row else 0
    items = []
    for r in rows:
        ano_ref = r.get("ano_referencia")
        tipo = r.get("tipo_dado")
        items.append(
            SazonalidadeResponse(
                id_produto=0,
                nome_produto=r["produto"],
                icone_url=None,
                uf=r["uf"],
                municipio="REGIÃO",
                municipio_id="0",
                ano=r["ano"],
                mes=r["mes"],
                data_referencia_atual=r.get("data_referencia_atual")
                or f"{r['ano']:04d}-{r['mes']:02d}",
                usou_fallback_12m=False,
                preco_estimado=False,
                status_cor=r["status_cor"],
                fonte="regiao",
                categoria=r.get("categoria"),
                tendencia_futura=None,
                is_forecast=r.get("is_forecast", False),
                confianca_baseline=float(r["confianca_baseline"])
                if r.get("confianca_baseline") is not None
                else None,
                forecast_method=r.get("forecast_method"),
                regiao=regiao_id.upper(),
                ano_referencia=ano_ref,
                tipo_dado=tipo,
                mensagem_transparencia=_compor_mensagem_transparencia(
                    tipo, ano_ref, r.get("idade_dado_anos")
                ),
                is_dado_legado=_is_dado_legado(ano_ref),
            )
        )
    result = SazonalidadeListResponse(data=items, total=total, pagina=pagina, por_pagina=por_pagina)
    await safe_set(cache_key, result.model_dump(), settings.cache_ttl_seconds)
    return result


@router.get("", response_model=SazonalidadeListResponse)
async def listar_sazonalidade(
    response: Response,
    regiao: str | None = Query(
        None, description="ID da região (norte, nordeste, centro-oeste, sudeste, sul)"
    ),
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
    cache_key = _build_sazonalidade_cache_key(
        regiao,
        uf,
        municipio,
        produto,
        status_cor,
        categoria,
        ano,
        mes,
        pagina,
        por_pagina,
        mv_refresh=await _ultimo_refresh_mv_iso(),
    )
    cached = await cache.get(cache_key)
    if cached is not None:
        response.headers["X-Cache-Status"] = "HIT"
        response.headers["X-Last-Refresh"] = await _ultimo_refresh_mv_iso()
        return SazonalidadeListResponse(**cached)
    response.headers["X-Cache-Status"] = "MISS"
    response.headers["X-Last-Refresh"] = await _ultimo_refresh_mv_iso()
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
    response: Response,
    uf: str | None = Query(None, min_length=2, max_length=2),
    produto: str | None = Query(None),
    ano: int | None = Query(None, ge=2024, le=2030),
    mes: int | None = Query(None, ge=1, le=12),
    pagina: int = Query(1, ge=1),
    por_pagina: int = Query(500, ge=1, le=2000),
):
    settings = get_settings()
    cache_key = hashlib.md5(
        json.dumps(
            {
                "endpoint": "com-preco",
                "uf": uf,
                "produto": produto,
                "ano": ano,
                "mes": mes,
                "pagina": pagina,
                "por_pagina": por_pagina,
                "mv_refresh": await _ultimo_refresh_mv_iso(),
            },
            sort_keys=True,
        ).encode()
    ).hexdigest()

    cached = await cache.get(cache_key)
    if cached is not None:
        response.headers["X-Cache-Status"] = "HIT"
        response.headers["X-Last-Refresh"] = await _ultimo_refresh_mv_iso()
        return SazonalidadeComPrecoListResponse(**cached)

    response.headers["X-Cache-Status"] = "MISS"
    response.headers["X-Last-Refresh"] = await _ultimo_refresh_mv_iso()

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
               v.fonte, v.tendencia_futura, v.is_forecast, v.forecast_method,
               v.ano_referencia, v.tipo_dado, v.idade_dado_anos,
               b.confianca AS confianca_baseline,
               pm.preco_atual AS preco_mes_anterior
        FROM mart.vw_api_produtos_sazonalidade v
        LEFT JOIN mart.sazonalidade_baseline b
            ON b.id_produto = v.id_produto
           AND b.id_localidade = v.id_localidade
           AND b.mes = v.mes
        LEFT JOIN LATERAL (
            SELECT v2.preco_atual
            FROM mart.vw_api_produtos_sazonalidade v2
            WHERE v2.id_produto = v.id_produto
              AND v2.uf = v.uf
              AND (v2.municipio = v.municipio OR (v2.municipio IS NULL AND v.municipio IS NULL))
              AND v2.ano * 12 + v2.mes = v.ano * 12 + v.mes - 1
            LIMIT 1
        ) pm ON true
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

    result = SazonalidadeComPrecoListResponse(
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
                variacao_pct=float(r["variacao_pct"]) if r["variacao_pct"] is not None else None,
                preco_estimado=r.get("preco_estimado") or False,
                usou_fallback_12m=r.get("usou_fallback_12m") or False,
                status_cor=r["status_cor"],
                fonte=r.get("fonte"),
                tendencia_futura=r.get("tendencia_futura"),
                is_forecast=r.get("is_forecast", False),
                confianca_baseline=float(r["confianca_baseline"])
                if r["confianca_baseline"] is not None
                else None,
                forecast_method=r.get("forecast_method"),
                preco_mes_anterior=float(r["preco_mes_anterior"])
                if r["preco_mes_anterior"] is not None
                else None,
                ano_referencia=r.get("ano_referencia"),
                tipo_dado=r.get("tipo_dado"),
                mensagem_transparencia=_compor_mensagem_transparencia(
                    r.get("tipo_dado"), r.get("ano_referencia"), r.get("idade_dado_anos")
                ),
                is_dado_legado=_is_dado_legado(r.get("ano_referencia")),
            )
            for r in rows
        ],
        total=total,
        pagina=pagina,
        por_pagina=por_pagina,
    )
    await safe_set(cache_key, result.model_dump(), settings.cache_ttl_seconds)
    return result


async def _query_br_sazonalidade(
    ano: int,
    categoria: str | None,
    min_ufs: int,
    pagina: int,
    por_pagina: int,
    offset_val: int,
    cache_key: str,
    settings,
) -> SazonalidadeNacionalListResponse:
    if categoria:
        rows = await fetch(
            "SELECT * FROM mart.fn_br_nacional_sazonalidade($1, $2, $3, $4, $5)",
            ano,
            categoria.upper(),
            min_ufs,
            por_pagina,
            offset_val,
        )
        total_row = await fetchrow(
            "SELECT COUNT(DISTINCT produto) FROM mart.fn_br_nacional_sazonalidade($1, $2, $3)",
            ano,
            categoria.upper(),
            min_ufs,
        )
    else:
        rows = await fetch(
            "SELECT * FROM mart.fn_br_nacional_sazonalidade($1, NULL, $2, $3, $4)",
            ano,
            min_ufs,
            por_pagina,
            offset_val,
        )
        total_row = await fetchrow(
            "SELECT COUNT(DISTINCT produto) FROM mart.fn_br_nacional_sazonalidade($1, NULL, $2)",
            ano,
            min_ufs,
        )

    prod_map: dict[str, dict] = {}
    for r in rows:
        key = r["produto"]
        if key not in prod_map:
            prod_map[key] = {
                "produto": r["produto"],
                "classificao_produto": r["classificao_produto"],
                "categoria": r["categoria"],
                "total_ufs": 0,
                "meses": [],
            }
        # total_ufs reflete o MAX de UFs observadas no ano (não fixa no mês 1)
        if r["total_ufs"] and r["total_ufs"] > prod_map[key]["total_ufs"]:
            prod_map[key]["total_ufs"] = r["total_ufs"]
        prod_map[key]["meses"].append(
            MesSazonalidade(
                mes=r["mes"],
                status_cor=r["status_cor"],
                is_forecast=r["is_forecast"],
                baseline_confianca=float(r["baseline_confianca"])
                if r["baseline_confianca"] is not None
                else None,
                forecast_method=r.get("forecast_method"),
                calculado_em=r.get("calculado_em"),
                ano_referencia=r.get("ano_referencia"),
                tipo_dado=r.get("tipo_dado"),
                mensagem_transparencia=_compor_mensagem_transparencia(
                    r.get("tipo_dado"), r.get("ano_referencia"), r.get("idade_dado_anos")
                ),
                is_dado_legado=_is_dado_legado(r.get("ano_referencia")),
            )
        )

    # Paginação push-down na fn (p_limit/p_offset por PRODUTO); total vem de
    # COUNT(DISTINCT produto) sobre a função sem limit (grade de 12 meses).
    total = total_row[0] if total_row else 0
    items = [SazonalidadeNacionalResponse(**item) for item in prod_map.values()]
    result = SazonalidadeNacionalListResponse(
        data=items, total=total, pagina=pagina, por_pagina=por_pagina
    )
    await safe_set(cache_key, result.model_dump(), settings.cache_ttl_seconds)
    return result


@router.get("/br-sazonalidade", response_model=SazonalidadeNacionalListResponse)
async def listar_br_sazonalidade(
    response: Response,
    ano: int = Query(..., ge=2024, le=2030, description="Ano da sazonalidade"),
    categoria: str | None = Query(None, description="Filtro por categoria"),
    min_ufs: int = Query(1, ge=1, le=27, description="Mínimo de UFs por produto/mês"),
    pagina: int = Query(1, ge=1),
    por_pagina: int = Query(100, ge=1, le=2000),
):
    settings = get_settings()
    # Chave atrelada ao X-Last-Refresh da MV: quando a MV é recriada, o
    # modification time muda e a chave muda — o cache antigo é ignorado.
    mv_refresh = await _ultimo_refresh_mv_iso()
    cache_key = hashlib.md5(
        json.dumps(
            {
                "route": "br_sazonalidade",
                # FASE 79 (P1-1): saída da fn muda (inclui projeção) → v6 invalida
                # o cache v5 (que não tinha FALLBACK_DIMENSAO na grade).
                "v": 6,
                "ano": ano,
                "categoria": categoria,
                "min_ufs": min_ufs,
                "pagina": pagina,
                "por_pagina": por_pagina,
                "mv_refresh": mv_refresh,
            },
            sort_keys=True,
            default=str,
        ).encode()
    ).hexdigest()

    cached = await cache.get(cache_key)
    if cached is not None:
        response.headers["X-Cache-Status"] = "HIT"
        response.headers["X-Last-Refresh"] = await _ultimo_refresh_mv_iso()
        return SazonalidadeNacionalListResponse(**cached)

    response.headers["X-Cache-Status"] = "MISS"
    response.headers["X-Last-Refresh"] = await _ultimo_refresh_mv_iso()
    offset_val = (pagina - 1) * por_pagina
    return await _query_br_sazonalidade(
        ano, categoria, min_ufs, pagina, por_pagina, offset_val, cache_key, settings
    )


@router.get("/{uf}/{municipio}", response_model=SazonalidadeListResponse)
async def listar_por_localidade(
    response: Response,
    uf: str,
    municipio: str,
    categoria: str | None = Query(None, description="Nome da categoria (FRUTAS, LEGUMES, etc.)"),
    ano: int | None = Query(None, ge=2024, le=2030),
    mes: int | None = Query(None, ge=1, le=12),
    pagina: int = Query(1, ge=1),
    por_pagina: int = Query(100, ge=1, le=2000),
):
    cache_key = _build_sazonalidade_cache_key(
        regiao=None,
        uf=uf,
        municipio=municipio,
        produto=None,
        status_cor=None,
        categoria=categoria,
        ano=ano,
        mes=mes,
        pagina=pagina,
        por_pagina=por_pagina,
        mv_refresh=await _ultimo_refresh_mv_iso(),
    )
    cached = await cache.get(cache_key)
    response.headers["X-Cache-Status"] = "HIT" if cached is not None else "MISS"
    response.headers["X-Last-Refresh"] = await _ultimo_refresh_mv_iso()
    return await _query_sazonalidade(
        uf=uf,
        municipio=municipio,
        categoria=categoria,
        ano=ano,
        mes=mes,
        pagina=pagina,
        por_pagina=por_pagina,
    )
