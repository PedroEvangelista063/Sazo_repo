from __future__ import annotations

import json
import logging
from pathlib import Path

from fastapi import APIRouter
from backend.app.schemas.responses import RegiaoInfo, RegioesResponse, PoloInfo

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/regioes", tags=["Regiões"])


@router.get("", response_model=RegioesResponse)
async def listar_regioes():
    path = Path("config/regions.json")
    if not path.exists():
        logger.warning("regions.json not found at %s", path.resolve())
        return RegioesResponse(regioes=[])

    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    regioes = [RegiaoInfo(**r) for r in data["regioes"]]
    return RegioesResponse(regioes=regioes)
