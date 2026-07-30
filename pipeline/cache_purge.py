"""
cache_purge.py — Webhook de invalidação de cache pós-ETL.

Dispara um POST para o backend FastAPI limpar o cache (InMemory ou Redis)
imediatamente após o REFRESH MATERIALIZED VIEW, eliminando a janela de
dados obsoletos que existia anteriormente.

Uso:
    from pipeline.cache_purge import purge_cache
    await purge_cache()          # usa defaults
    purge_cache_sync()           # versão síncrona (sem asyncio)
"""

from __future__ import annotations

import logging
import os
import urllib.request
import urllib.error
import json

logger = logging.getLogger(__name__)

# ── Configuração via env ──────────────────────────────────────────────
CACHE_PURGE_URL = os.environ.get(
    "CACHE_PURGE_URL",
    "http://localhost:8000/api/v1/admin/cache/clear",
)
CACHE_PURGE_KEY = os.environ.get(
    "CACHE_PURGE_KEY",
    "qc_cache_purge_2026",  # mesmo valor do backend/.env → INTERNAL_API_KEY
)
CACHE_PURGE_TIMEOUT = int(os.environ.get("CACHE_PURGE_TIMEOUT", "10"))


def purge_cache_sync(
    url: str | None = None,
    api_key: str | None = None,
    timeout: int | None = None,
) -> bool:
    """Dispara o webhook de limpeza de cache (versão síncrona).

    Args:
        url: URL completa do endpoint /admin/cache/clear.
        api_key: Valor do header X-API-Key.
        timeout: Timeout da requisição em segundos.

    Returns:
        True se o backend respondeu 200, False caso contrário.
    """
    _url = url or CACHE_PURGE_URL
    _key = api_key or CACHE_PURGE_KEY
    _timeout = timeout or CACHE_PURGE_TIMEOUT

    req = urllib.request.Request(
        _url,
        method="POST",
        headers={
            "X-API-Key": _key,
            "Content-Type": "application/json",
        },
        data=b"{}",
    )

    try:
        with urllib.request.urlopen(req, timeout=_timeout) as resp:
            body = resp.read().decode("utf-8")
            data = json.loads(body)
            logger.info(
                "Cache purge: %s — %s",
                resp.status,
                data.get("message", body),
            )
            return resp.status == 200
    except urllib.error.HTTPError as exc:
        logger.error(
            "Cache purge HTTP %s: %s",
            exc.code,
            exc.read().decode("utf-8", errors="replace"),
        )
        return False
    except urllib.error.URLError as exc:
        logger.warning(
            "Cache purge FAILED (backend offline?): %s",
            exc.reason,
        )
        return False
    except Exception:
        logger.exception("Cache purge — erro inesperado")
        return False


async def purge_cache(
    url: str | None = None,
    api_key: str | None = None,
    timeout: int | None = None,
) -> bool:
    """Versão assíncrona — wrapper sobre purge_cache_sync.

    Usa ``asyncio.to_thread`` para não bloquear o event loop.
    """
    import asyncio
    return await asyncio.to_thread(
        purge_cache_sync,
        url=url,
        api_key=api_key,
        timeout=timeout,
    )
