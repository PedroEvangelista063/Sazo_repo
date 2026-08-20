"""
security.py — Verificação de chave de API interna (fail-closed).

Toda rota administrativa/_internal passa por ``require_internal_api_key``:

- ``INTERNAL_API_KEY`` não configurada → 503 "Admin routes not configured"
  (nenhum ambiente fica aberto — fail-closed em staging E produção);
- header ausente ou chave divergente → 403 (comparação em tempo constante).

Fonte única do verifier: admin.py e internal.py não duplicam mais a lógica.
"""

from __future__ import annotations

from secrets import compare_digest

from fastapi import Header, HTTPException

from backend.app.core.config import get_settings


async def require_internal_api_key(x_api_key: str | None = Header(None)) -> None:
    settings = get_settings()
    if not settings.internal_api_key:
        raise HTTPException(status_code=503, detail="Admin routes not configured")
    if x_api_key is None or not compare_digest(x_api_key, settings.internal_api_key):
        raise HTTPException(status_code=403, detail="Forbidden")
