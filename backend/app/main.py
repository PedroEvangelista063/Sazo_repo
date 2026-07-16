import asyncio
import logging

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
from backend.app.core.config import get_settings
from backend.app.core.ratelimit import RateLimitMiddleware
from backend.app.core.timeout import TimeoutMiddleware
from backend.app.db.session import get_api_pool, get_etl_pool, close_pools
from backend.app.api.v1.endpoints.produtos import router as produtos_router
from backend.app.api.v1.endpoints.categorias import router as categorias_router
from backend.app.api.v1.endpoints.internal import router as internal_router
from backend.app.api.v1.endpoints.municipios import router as municipios_router
from backend.app.api.v1.endpoints.ufs import router as ufs_router
from backend.app.api.v1.endpoints.stream import router as stream_router
from backend.app.api.v1.endpoints.admin import router as admin_router
from backend.app.core.cache import cache

logger = logging.getLogger(__name__)

_REFRESH_TIMEOUT = 120  # segundos para MV refresh


@asynccontextmanager
async def lifespan(app: FastAPI):
    await get_api_pool()
    await get_etl_pool()

    # Refresh MV + limpa cache — não crítico, com retry
    from backend.app.db.session import fetch_etl

    for attempt in (1, 2):
        try:
            await asyncio.wait_for(
                fetch_etl("REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade"),
                timeout=_REFRESH_TIMEOUT,
            )
            break
        except Exception as exc:
            logger.warning("MV refresh attempt %d failed: %s", attempt, exc)
            if attempt == 2:
                logger.error("MV refresh failed after 2 attempts — serving stale MV")

    await cache.clear()

    yield
    await close_pools()


settings = get_settings()

app = FastAPI(
    title="Quero Comprar API",
    description="API de Sazonalidade de Preços Agrícolas — B2C",
    version="2.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.add_middleware(
    TimeoutMiddleware,
    timeout_seconds=settings.request_timeout_seconds,
)

app.add_middleware(
    RateLimitMiddleware,
    requests_per_minute=settings.rate_limit_per_minute,
)

app.include_router(produtos_router, prefix=settings.api_v1_prefix)
app.include_router(categorias_router, prefix=settings.api_v1_prefix)
app.include_router(internal_router, prefix=settings.api_v1_prefix)
app.include_router(municipios_router, prefix=settings.api_v1_prefix)
app.include_router(ufs_router, prefix=settings.api_v1_prefix)
app.include_router(stream_router, prefix=settings.api_v1_prefix)
app.include_router(admin_router, prefix=settings.api_v1_prefix)


@app.get("/health")
async def health():
    return {"status": "ok"}
