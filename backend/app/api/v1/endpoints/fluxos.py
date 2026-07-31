from __future__ import annotations

import logging

from fastapi import APIRouter
from backend.app.db.session import fetch
from backend.app.schemas.responses import FlowItem, FlowListResponse

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/fluxos", tags=["Fluxos de Abastecimento"])

SQL_FLUXOS = """
SELECT
    f.id_fluxo,
    f.produto           AS item,
    f.origem_uf,
    f.origem_polo,
    f.destino_regiao_id,
    f.destino_uf,
    f.meses,
    f.sazonalidade,
    f.preco_referencial,
    f.tipo,
    f.descricao_tipo,
    f.periodicidade,
    f.regiao_destino_nome
FROM staging.vw_fluxos_regionais f
ORDER BY f.destino_regiao_id, f.origem_uf, f.produto
"""


@router.get("", response_model=FlowListResponse)
async def listar_fluxos():
    try:
        rows = await fetch(SQL_FLUXOS)
    except Exception as exc:
        logger.error("[fluxos] Erro ao consultar banco: %s", exc)
        return FlowListResponse(data=[], total=0)

    fluxos: list[FlowItem] = []
    for r in rows:
        try:
            meses_raw = r.get("meses") or []
            if isinstance(meses_raw, (list, tuple)):
                meses_list = [int(m) for m in meses_raw]
            else:
                meses_list = []

            fluxos.append(
                FlowItem(
                    id=r["id_fluxo"],
                    item=r["item"] or "",
                    origem_uf=r["origem_uf"] or "",
                    origem_polo=r["origem_polo"] or "",
                    destino_regiao_id=r["destino_regiao_id"] or "",
                    destino_uf=r["destino_uf"] or "",
                    meses=meses_list,
                    sazonalidade=r["sazonalidade"] or "",
                    preco_referencial=r["preco_referencial"] or "",
                    tipo=r["tipo"] or "",
                    descricao_tipo=r.get("descricao_tipo"),
                    periodicidade=r.get("periodicidade"),
                    regiao_destino_nome=r.get("regiao_destino_nome"),
                )
            )
        except Exception as exc:
            logger.warning("[fluxos] Erro ao montar FlowItem para id=%s: %s", r.get("id_fluxo"), exc)
            continue

    return FlowListResponse(data=fluxos, total=len(fluxos))
