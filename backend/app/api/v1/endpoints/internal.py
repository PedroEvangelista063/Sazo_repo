from fastapi import APIRouter, Header, HTTPException, Depends
from typing import Optional
from backend.app.schemas.responses import CacheClearResponse
from backend.app.core.cache import clear_cache
from backend.app.core.config import get_settings

router = APIRouter(prefix="/_internal", tags=["Internal"])


async def verify_api_key(x_api_key: Optional[str] = Header(None)) -> None:
    settings = get_settings()
    if settings.internal_api_key and x_api_key != settings.internal_api_key:
        raise HTTPException(status_code=403, detail="Forbidden")


@router.get("/cache-clear", response_model=CacheClearResponse, dependencies=[Depends(verify_api_key)])
async def cache_clear():
    await clear_cache()
    return CacheClearResponse(success=True, message="Cache liberado com sucesso")


@router.post("/cache-clear", response_model=CacheClearResponse, dependencies=[Depends(verify_api_key)])
async def cache_clear_post():
    await clear_cache()
    return CacheClearResponse(success=True, message="Cache liberado com sucesso")
