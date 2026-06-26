from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
from backend.app.core.config import get_settings
from backend.app.core.ratelimit import RateLimitMiddleware
from backend.app.db.session import get_pool, close_pool
from backend.app.api.v1.endpoints.produtos import router as produtos_router
from backend.app.api.v1.endpoints.internal import router as internal_router
from backend.app.api.v1.endpoints.municipios import router as municipios_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    await get_pool()
    yield
    await close_pool()


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
app.include_router(internal_router, prefix=settings.api_v1_prefix)
app.include_router(municipios_router, prefix=settings.api_v1_prefix)


@app.get("/health")
async def health():
    return {"status": "ok"}
