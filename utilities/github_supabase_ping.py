#!/usr/bin/env python3
"""
github_supabase_ping.py — Ping único para o GitHub Actions.

Mantém a instância Supabase (gratuita) "acordada" enviando um `SELECT 1;`
periódico a partir de um runner do GitHub Actions, sem onerar a infraestrutura
local. O agendamento é feito pelo workflow, não por este script: ele roda UMA
vez e encerra.

FUNCIONAMENTO:
  - Lê a URL do banco SOMENTE da variável de ambiente `DATABASE_URL`
    (injetada pelo workflow a partir do secret `SUPABASE_DATABASE_URL`).
  - Conecta com asyncpg, executa `SELECT 1;` e fecha a conexão imediatamente.
  - Exit 0 em sucesso; Exit 1 em qualquer falha (o GitHub Actions marca o
    job como falho e fica visível no painel/notificações).

USO LOCAL (teste):
  export DATABASE_URL="postgresql://..."
  python3 utilities/github_supabase_ping.py
"""

import asyncio
import logging
import os
import sys

import asyncpg

_CONNECT_TIMEOUT_SECONDS = 30

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("github_ping")


def _get_database_url() -> str:
    """Retorna DATABASE_URL do ambiente ou levanta SystemExit com mensagem clara."""
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise SystemExit(
            "[KEEP-ALIVE] Variável DATABASE_URL não definida. "
            "Configure o secret SUPABASE_DATABASE_URL no repositório e "
            "mapeie-o para DATABASE_URL no workflow."
        )
    return url


async def _ping_once(url: str) -> None:
    """Conecta, executa `SELECT 1;` e fecha. Levanta exceção em qualquer falha."""
    conn = await asyncio.wait_for(
        asyncpg.connect(url, timeout=_CONNECT_TIMEOUT_SECONDS, statement_cache_size=0),
        timeout=_CONNECT_TIMEOUT_SECONDS + 10,
    )
    try:
        value = await conn.fetchval("SELECT 1;")
        if value != 1:
            raise RuntimeError(f"SELECT 1 retornou valor inesperado: {value!r}")
    finally:
        await conn.close()


def main() -> int:
    try:
        url = _get_database_url()
    except SystemExit as exc:
        logger.error("%s", exc)
        return 1

    try:
        asyncio.run(_ping_once(url))
    except Exception as exc:  # noqa: BLE001  # conectividade externa é imprevisível
        logger.error("[KEEP-ALIVE] Falha no ping: %s", exc)
        return 1

    logger.info("[KEEP-ALIVE] Supabase Ping OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
