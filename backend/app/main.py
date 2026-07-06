from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
from backend.app.core.config import get_settings
from backend.app.core.ratelimit import RateLimitMiddleware
from backend.app.db.session import get_api_pool, get_etl_pool, close_pools
from backend.app.api.v1.endpoints.produtos import router as produtos_router
from backend.app.api.v1.endpoints.categorias import router as categorias_router
from backend.app.api.v1.endpoints.internal import router as internal_router
from backend.app.api.v1.endpoints.municipios import router as municipios_router
from backend.app.api.v1.endpoints.ufs import router as ufs_router
from backend.app.api.v1.endpoints.stream import router as stream_router
from backend.app.core.cache import cache


@asynccontextmanager
async def lifespan(app: FastAPI):
    await get_api_pool()
    await get_etl_pool()

    try:
        from backend.app.db.session import fetch_etl
        await fetch_etl("REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade")
        cache.clear()
    except Exception:
        pass

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
    RateLimitMiddleware,
    requests_per_minute=settings.rate_limit_per_minute,
)

app.include_router(produtos_router, prefix=settings.api_v1_prefix)
app.include_router(categorias_router, prefix=settings.api_v1_prefix)
app.include_router(internal_router, prefix=settings.api_v1_prefix)
app.include_router(municipios_router, prefix=settings.api_v1_prefix)
app.include_router(ufs_router, prefix=settings.api_v1_prefix)
app.include_router(stream_router, prefix=settings.api_v1_prefix)


@app.get("/health")
async def health():
    return {"status": "ok"}
