import asyncio
import logging
from contextlib import asynccontextmanager

import asyncpg
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from backend.app.api.v1.endpoints.admin import router as admin_router
from backend.app.api.v1.endpoints.categorias import router as categorias_router
from backend.app.api.v1.endpoints.fluxos import router as fluxos_router
from backend.app.api.v1.endpoints.internal import router as internal_router
from backend.app.api.v1.endpoints.municipios import router as municipios_router
from backend.app.api.v1.endpoints.produtos import router as produtos_router
from backend.app.api.v1.endpoints.regioes import router as regioes_router
from backend.app.api.v1.endpoints.stream import router as stream_router
from backend.app.api.v1.endpoints.ufs import router as ufs_router
from backend.app.core.cache import cache, init_cache
from backend.app.core.config import get_settings
from backend.app.core.ratelimit import RateLimitMiddleware
from backend.app.core.timeout import TimeoutMiddleware
from backend.app.db.bootstrap import run_bootstrap_once
from backend.app.db.session import close_pools, get_active_mode, get_api_pool, get_etl_pool

logger = logging.getLogger(__name__)

# Garante que os loggers da aplicação exibam INFO/WARNING mesmo quando o
# uvicorn não configura um handler para o logger raiz.
if not logging.root.handlers:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

_REFRESH_TIMEOUT = 300  # segundos para MV refresh


async def _connect_pool_with_retry(
    connect_fn,  # callable returning awaitable (e.g. get_api_pool)
    name: str,
    max_wait_seconds: float = 120.0,
) -> None:
    """Faz o pool aguardar o banco voltar (ex.: recovery do Supabase) com backoff,
    em vez de derrubar o startup instantaneamente."""
    loop = asyncio.get_event_loop()
    deadline = loop.time() + max_wait_seconds
    attempt = 0
    while True:
        try:
            await connect_fn()
            logger.info("%s pool conectado.", name)
            return
        except Exception as exc:  # conectividade externa é imprevisível
            remaining = deadline - loop.time()
            if remaining <= 0:
                logger.error("%s pool não disponível após %.0fs: %s", name, max_wait_seconds, exc)
                raise
            attempt += 1
            delay = min(5.0, remaining)
            logger.warning(
                "%s pool não pronto (tentativa %d, novo try em %.0fs): %s",
                name,
                attempt,
                delay,
                exc,
            )
            await asyncio.sleep(delay)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Aguarda bancos aceitarem conexão (ex.: crash recovery do Supabase free)
    # Se a nuvem estiver fora, o failover do session.py roteia para o banco local.
    await _connect_pool_with_retry(get_api_pool, "api")
    await _connect_pool_with_retry(get_etl_pool, "etl")

    mode = get_active_mode()
    if mode == "fallback":
        logger.info("Banco ativo: fallback (local)")
        # Garante o schema mínimo no banco local (bootstrap no máximo 1x/processo).
        await run_bootstrap_once()
    else:
        logger.info("Banco ativo: primary (nuvem)")

    # Tenta cache Redis; se sem redis_url, mantém InMemoryCache
    init_cache(get_settings().redis_url)

    # Refresh MV em background — não bloqueia o startup do servidor
    # O servidor já responde health checks imediatamente

    async def _refresh_mv_once() -> None:
        """Refresca a MV numa conexão DEDICADA (fora do pool).

        Motivo: rodar via ``fetch_etl`` (pool) + ``asyncio.wait_for`` causava uma
        corrida de dupla liberação quando o timeout cancelava a operação
        (InterfaceError: connection has been released back to the pool), que
        corrompia o pool e gerava 500 transitórios em outros endpoints.
        Conexão dedicada isola totalmente a operação.
        """
        s = get_settings()
        url = s.database_url_etl or s.database_url_primary or s.database_url
        conn = await asyncpg.connect(url, timeout=30, statement_cache_size=0)
        try:
            await conn.execute(
                "REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade"
            )
        finally:
            try:
                await conn.close()
            except Exception:  # noqa: BLE001  # servidor pode ter encerrado a conexão
                logger.debug("Conexão dedicada do MV refresh já encerrada pelo servidor.")

    async def _background_mv_refresh():
        """Refresca a MV e limpa o cache em background."""
        for attempt in (1, 2):
            try:
                await asyncio.wait_for(_refresh_mv_once(), timeout=_REFRESH_TIMEOUT)
                await cache.clear()
                logger.info("Cache limpo após MV refresh em background.")
                return
            except Exception as exc:  # noqa: BLE001 — refresh em background: loga e tenta de novo
                logger.warning("MV refresh background attempt %d failed: %s", attempt, exc)
        # No Aiven free o REFRESH MV CONCURRENTLY da MV grande (~280k linhas) é
        # encerrado pelo servidor (~25s) mesmo sem statement_timeout. O app segue
        # servindo a MV populada no restore — refresh fica a cargo do pipeline.
        logger.error(
            "MV refresh background failed after 2 attempts — serving MV from last "
            "successful refresh/restore (Aiven free pode encerrar o REFRESH MV "
            "CONCURRENTLY). Dados de leitura continuam disponíveis."
        )

    asyncio.create_task(_background_mv_refresh())

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
    # Headers de transparência precisam ser legíveis pelo JS do navegador em
    # requisições cross-origin (ex.: frontend Vite -> API FastAPI). Sem
    # expose_headers, o Starlette não emite Access-Control-Expose-Headers e o
    # rodapé de transparência (PainelTransparenciaRodape) nunca renderiza.
    expose_headers=["X-Cache-Status", "X-Last-Refresh"],
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
app.include_router(regioes_router, prefix=settings.api_v1_prefix)
app.include_router(fluxos_router, prefix=settings.api_v1_prefix)


@app.get("/health")
async def health():
    mode = get_active_mode()
    return {"status": "ok", "db_mode": mode}
