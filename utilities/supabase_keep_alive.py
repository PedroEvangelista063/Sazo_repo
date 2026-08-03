#!/usr/bin/env python3
"""
supabase_keep_alive.py — Keep-alive para a instância Supabase (gratuita).

Em planos free do Supabase, a instância pode "adormecer" (pause) quando fica
muito tempo sem conexão. Este script faz um ping periódico (`SELECT 1`) no banco
remoto via conexão asyncpg, mantendo a instância "acordada".

FUNCIONAMENTO:
  - Lê DATABASE_URL de backend/.env (via python-dotenv). Se a variável já
    estiver definida no ambiente, ela tem prioridade.
  - Fallback de variáveis: DATABASE_URL -> DATABASE_URL_PRIMARY -> DATABASE_URL_API.
  - Em loop infinito, a cada 300s abre uma conexão, executa `SELECT 1;` e fecha.
  - Erros transitórios NÃO derrubam o script: cada iteração trata o erro e segue.
  - `--once`: executa um único ping e encerra (usado no cron).

COMO RODAR:

  1) Em primeiro plano:
       python3 utilities/supabase_keep_alive.py

  2) Em segundo plano (nohup):
       nohup python3 utilities/supabase_keep_alive.py \
         >> utilities/logs/keep_alive.log 2>&1 &

  3) Via cron (1 execução por minuto, --once):
       * * * * *  cd /home/pedroeduardo/projetos/quero_comprar_vg && \
                  /usr/bin/python3 utilities/supabase_keep_alive.py --once \
                  >> utilities/logs/keep_alive.log 2>&1

  4) Via systemd (user unit — recomendado para serviço contínuo).
     Crie ~/.config/systemd/user/supabase-keep-alive.service:

       [Unit]
       Description=Supabase keep-alive (ping periódico)
       After=network-online.target

       [Service]
       Type=simple
       WorkingDirectory=%h/projetos/quero_comprar_vg
       ExecStart=%h/projetos/quero_comprar_vg/.venv/bin/python3 \
                 %h/projetos/quero_comprar_vg/utilities/supabase_keep_alive.py
       Restart=on-failure
       RestartSec=10

       [Install]
       WantedBy=default.target

     Depois habilite:
       systemctl --user daemon-reload
       systemctl --user enable --now supabase-keep-alive.service

  5) Windows (Agendador de Tarefas):
     - Ação: Iniciar programa
     - Programa: caminho para python.exe
     - Argumentos: utilities\\supabase_keep_alive.py --once
     - Iniciar em: C:\\caminho\\para\\quero_comprar_vg
     - Gatilho: repetir a cada 5 minutos, indefinidamente
"""

import asyncio
import logging
import os
import signal
import sys
from pathlib import Path

import asyncpg
from dotenv import load_dotenv

# Caminho do .env relativo a este script — funciona de qualquer diretório.
_DOTENV_PATH = Path(__file__).resolve().parent.parent / "backend" / ".env"
_INTERVAL_SECONDS = 300

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("keep_alive")

_shutdown = asyncio.Event()


def _get_database_url() -> str:
    """Resolve a URL do banco: ambiente > backend/.env > DATABASE_URL_PRIMARY > DATABASE_URL_API."""
    load_dotenv(_DOTENV_PATH, override=False)

    url = (
        os.environ.get("DATABASE_URL")
        or os.environ.get("DATABASE_URL_PRIMARY")
        or os.environ.get("DATABASE_URL_API")
    )
    if not url:
        raise SystemExit(
            "[KEEP-ALIVE] Nenhuma URL definida. Configure DATABASE_URL em backend/.env "
            "(ou exporte DATABASE_URL / DATABASE_URL_PRIMARY / DATABASE_URL_API)."
        )
    return url


async def _ping_once() -> None:
    """Abre uma conexão, executa `SELECT 1;` e fecha. Levanta exceção em falha."""
    url = _get_database_url()
    conn = await asyncpg.connect(url, timeout=30, statement_cache_size=0)
    try:
        value = await conn.fetchval("SELECT 1;")
        if value != 1:
            raise RuntimeError(f"SELECT 1 retornou valor inesperado: {value!r}")
    finally:
        await conn.close()


async def _run(once: bool) -> int:
    """Loop principal. Retorna 0 em sucesso, 1 se houve falha na última iteração."""
    exit_code = 0
    while True:
        try:
            await asyncio.wait_for(_ping_once(), timeout=60)
            logger.info("[KEEP-ALIVE] Supabase Ping OK")
            exit_code = 0
        except Exception as exc:  # noqa: BLE001  # conectividade externa é imprevisível
            logger.error("[KEEP-ALIVE] Falha no ping: %s", exc)
            exit_code = 1

        if once:
            return exit_code

        # Aguarda o intervalo, mas acorda cedo se chegar SIGINT/SIGTERM.
        try:
            await asyncio.wait_for(_shutdown.wait(), timeout=_INTERVAL_SECONDS)
            logger.info("[KEEP-ALIVE] Encerrando por sinal recebido.")
            return 0
        except TimeoutError:
            continue


def main() -> int:
    once = "--once" in sys.argv

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    def _handle_signal(_signum: int, _frame) -> None:
        logger.info("[KEEP-ALIVE] Sinal recebido, desligando graciosamente...")
        _shutdown.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _handle_signal, sig, None)
        except (NotImplementedError, RuntimeError):
            signal.signal(sig, _handle_signal)

    try:
        return loop.run_until_complete(_run(once))
    finally:
        loop.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001  # nunca deixar o processo estourar
        logger.error("[KEEP-ALIVE] Erro fatal: %s", exc)
        sys.exit(1)
