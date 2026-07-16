from __future__ import annotations

import json
import logging
from pathlib import Path

from fastapi import APIRouter
from backend.app.schemas.responses import FlowItem, FlowListResponse

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/fluxos", tags=["Fluxos de Abastecimento"])


@router.get("", response_model=FlowListResponse)
async def listar_fluxos():
    path = Path("config/flows.json")
    if not path.exists():
        logger.warning("flows.json not found at %s", path.resolve())
        return FlowListResponse(data=[], total=0)

    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    fluxos = [FlowItem(**f) for f in data["fluxos"]]
    return FlowListResponse(data=fluxos, total=len(fluxos))
