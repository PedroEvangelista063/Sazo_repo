"""Endpoints de Fluxos Logísticos dos Boletins CONAB (Fase 5 — camada de sync).

Lê a view ``staging.vw_fluxo_logistico_boletins`` (role_api_reader, SELECT
only) e expõe as rotas produto origem_uf → destino_uf por mês/ano com
filtros opcionais e paginação.

QUALITY GATE (regra fundamental do projeto):
  A view NÃO preenche meses futuros nem substitui meses ausentes com fallback.
  Meses sem registro real retornam 0 linhas — o frontend exibe status CINZA.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Query

from backend.app.db.session import fetch, fetchrow
from backend.app.schemas.responses import BoletimFlowItem, BoletimFlowListResponse

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/fluxos", tags=["Fluxos de Abastecimento"])

_BASE_COLS = """
    id, produto, origem_uf, origem_polo, destino_uf, destino_polo,
    mes_referencia, ano_referencia, fonte, pagina
"""

_ORDER_BY = "ORDER BY ano_referencia DESC, mes_referencia DESC, produto, origem_uf, destino_uf"


@router.get("/boletins", response_model=BoletimFlowListResponse)
async def listar_fluxos_boletins(
    produto: str | None = Query(None, description="Filtro por nome do produto (ex: milho, soja)"),
    origem_uf: str | None = Query(
        None, min_length=2, max_length=2, description="UF de origem (BR-2)"
    ),
    destino_uf: str | None = Query(
        None, min_length=2, max_length=2, description="UF de destino (BR-2)"
    ),
    ano_referencia: int | None = Query(
        None, ge=2025, le=2026, description="Ano de referência da rota"
    ),
    mes_referencia: int | None = Query(
        None, ge=1, le=12, description="Mês de referência da rota (1-12)"
    ),
    limit: int = Query(200, ge=1, le=1000, description="Tamanho da página"),
    offset: int = Query(0, ge=0, description="Deslocamento da página"),
):
    try:
        conds: list[str] = ["1=1"]
        params: list[object] = []
        idx = 1

        if produto:
            conds.append(f"produto ILIKE ${idx}")
            params.append(f"%{produto}%")
            idx += 1
        if origem_uf:
            conds.append(f"origem_uf = ${idx}")
            params.append(origem_uf.upper())
            idx += 1
        if destino_uf:
            conds.append(f"destino_uf = ${idx}")
            params.append(destino_uf.upper())
            idx += 1
        if ano_referencia is not None:
            conds.append(f"ano_referencia = ${idx}")
            params.append(ano_referencia)
            idx += 1
        if mes_referencia is not None:
            conds.append(f"mes_referencia = ${idx}")
            params.append(mes_referencia)
            idx += 1

        where = " AND ".join(conds)

        total_row = await fetchrow(
            f"SELECT COUNT(*) AS total FROM staging.vw_fluxo_logistico_boletins WHERE {where}",
            *params,
        )
        total = total_row["total"] if total_row else 0

        if total == 0:
            return BoletimFlowListResponse(data=[], total=0, limit=limit, offset=offset)

        rows = await fetch(
            f"""
            SELECT {_BASE_COLS}
            FROM staging.vw_fluxo_logistico_boletins
            WHERE {where}
            {_ORDER_BY}
            OFFSET ${idx} LIMIT ${idx + 1}
            """,
            *params,
            offset,
            limit,
        )
    except Exception as exc:  # noqa: BLE001 — endpoint tolerante: falha vira lista vazia
        logger.error("[fluxos/boletins] Erro ao consultar banco: %s", exc)
        return BoletimFlowListResponse(data=[], total=0, limit=limit, offset=offset)

    boletins: list[BoletimFlowItem] = []
    for r in rows:
        try:
            boletins.append(
                BoletimFlowItem(
                    id=r["id"],
                    produto=r["produto"] or "",
                    origem_uf=r["origem_uf"] or "",
                    origem_polo=r.get("origem_polo"),
                    destino_uf=r["destino_uf"] or "",
                    destino_polo=r.get("destino_polo"),
                    mes_referencia=r["mes_referencia"],
                    ano_referencia=r["ano_referencia"],
                    fonte=r.get("fonte"),
                    pagina=r.get("pagina"),
                )
            )
        except Exception as exc:  # noqa: BLE001 — linha defeituosa é pulada, não derruba o lote
            logger.warning(
                "[fluxos/boletins] Erro ao montar BoletimFlowItem para id=%s: %s",
                r.get("id"),
                exc,
            )
            continue

    return BoletimFlowListResponse(data=boletins, total=total, limit=limit, offset=offset)
