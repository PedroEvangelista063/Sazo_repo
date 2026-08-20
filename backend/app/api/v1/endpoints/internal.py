from fastapi import APIRouter, Depends

from backend.app.core.cache import clear_cache
from backend.app.core.events import broadcaster
from backend.app.core.security import require_internal_api_key
from backend.app.schemas.responses import CacheClearResponse

router = APIRouter(prefix="/_internal", tags=["Internal"])


@router.get(
    "/cache-clear",
    response_model=CacheClearResponse,
    dependencies=[Depends(require_internal_api_key)],
)
async def cache_clear():
    await clear_cache()
    return CacheClearResponse(success=True, message="Cache liberado com sucesso")


@router.post(
    "/cache-clear",
    response_model=CacheClearResponse,
    dependencies=[Depends(require_internal_api_key)],
)
async def cache_clear_post():
    await clear_cache()
    return CacheClearResponse(success=True, message="Cache liberado com sucesso")


@router.post("/etl-done", dependencies=[Depends(require_internal_api_key)])
async def etl_done():
    await broadcaster.publish("ETL_FINISHED")
    return {"status": "ok", "event": "ETL_FINISHED"}
