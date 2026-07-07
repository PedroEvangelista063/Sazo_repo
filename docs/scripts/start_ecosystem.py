#!/usr/bin/env python3
"""Orquestrador assíncrono do ecossistema Quero Comprar.

Flow:
  1. Sobe Uvicorn (FastAPI) + Vite (Frontend) em paralelo (não-bloqueante)
  2. Aguarda health check da API (polling até 200 OK)
  3. Dispara scraper ETL em background (processo detached)
  4. Forward de SIGINT/SIGTERM para todos os filhos
"""

from __future__ import annotations

import asyncio
import logging
import os
import platform
import signal
import sys
import time
from typing import NoReturn

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("orchestrator")

PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))
API_PORT = int(os.environ.get("PORT", "8000"))
HEALTH_URL = f"http://127.0.0.1:{API_PORT}/health"
HEALTH_POLL_INTERVAL = 0.5  # segundos
HEALTH_TIMEOUT = 30  # segundos máximo para API subir
PYTHON = sys.executable or "python"
NPM = "npm.cmd" if platform.system() == "Windows" else "npm"


async def _start_process(cmd: list[str], name: str, cwd: str | None = None) -> asyncio.subprocess.Process:
    logger.info("Starting %s: %s", name, " ".join(cmd))
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        cwd=cwd or PROJECT_ROOT,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    _start_stdout_reader(proc, name)
    return proc


def _start_stdout_reader(proc: asyncio.subprocess.Process, name: str) -> None:
    async def _reader():
        assert proc.stdout is not None
        while True:
            line = await proc.stdout.readline()
            if not line:
                break
            logger.info("[%s] %s", name, line.decode(errors="replace").rstrip())

    asyncio.ensure_future(_reader())


async def _wait_for_health(timeout: int = HEALTH_TIMEOUT) -> bool:
    import httpx

    logger.info("Waiting for API health at %s ...", HEALTH_URL)
    deadline = time.monotonic() + timeout
    async with httpx.AsyncClient() as client:
        while time.monotonic() < deadline:
            try:
                resp = await client.get(HEALTH_URL, timeout=2.0)
                if resp.status_code == 200:
                    logger.info("API is healthy.")
                    return True
            except (httpx.ConnectError, httpx.TimeoutException):
                pass
            await asyncio.sleep(HEALTH_POLL_INTERVAL)
    logger.error("API did not become healthy within %ds.", timeout)
    return False


async def main() -> NoReturn:
    processes: list[asyncio.subprocess.Process] = []

    def _shutdown(sig: signal.Signals) -> None:
        logger.warning("Received %s, shutting down children...", sig.name)
        for proc in processes:
            if proc.returncode is None:
                proc.terminate()

    loop = asyncio.get_event_loop()
    for s in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(s, lambda s=s: _shutdown(s))
        except (ValueError, NotImplementedError):
            pass  # Windows does not support add_signal_handler fully

    # ── 1. Start Uvicorn ────────────────────────────────────────
    uvicorn_proc = await _start_process(
        [PYTHON, "-m", "uvicorn", "backend.app.main:app",
         "--host", "0.0.0.0", "--port", str(API_PORT)],
        name="uvicorn",
    )
    processes.append(uvicorn_proc)

    # ── 2. Wait for health ──────────────────────────────────────
    healthy = await _wait_for_health()
    if not healthy:
        logger.error("Aborting startup — API not healthy.")
        _shutdown(signal.SIGTERM)
        sys.exit(1)

    # ── 3. Start Vite dev server ────────────────────────────────
    frontend_dir = os.path.join(PROJECT_ROOT, "frontend")
    vite_proc = await _start_process(
        [NPM, "run", "dev"],
        name="vite",
        cwd=frontend_dir,
    )
    processes.append(vite_proc)

    # Give Vite a moment to bind before firing scraper
    await asyncio.sleep(2)

    # ── 4. Fire scraper in background (detached) ────────────────
    logger.info("Starting scraper ETL in background...")
    scraper_args = [
        PYTHON, "-m", "pipeline.run_scraper_historico", "--concorrencia", "4",
    ]
    if platform.system() == "Windows":
        # Use CREATE_NEW_PROCESS_GROUP + DETACHED_PROCESS on Windows
        scraper_proc = await asyncio.create_subprocess_exec(
            *scraper_args,
            cwd=PROJECT_ROOT,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            creationflags=subprocess.CREATE_NEW_PROCESS_GROUP,  # type: ignore
        )
    else:
        scraper_proc = await asyncio.create_subprocess_exec(
            *scraper_args,
            cwd=PROJECT_ROOT,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            start_new_session=True,
        )
    # Start reader but do NOT append to processes list — detached
    _start_stdout_reader(scraper_proc, "scraper")

    logger.info("Orchestrator ready. Uvicorn[%d] Vite[%d] Scraper[%d]",
                uvicorn_proc.pid, vite_proc.pid, scraper_proc.pid)

    # ── 5. Monitor children forever ─────────────────────────────
    while True:
        await asyncio.sleep(1)
        # If either Uvicorn or Vite dies, shutdown the rest
        if uvicorn_proc.returncode is not None:
            logger.error("Uvicorn exited (code=%d). Shutting down.", uvicorn_proc.returncode)
            _shutdown(signal.SIGTERM)
            sys.exit(1)
        if vite_proc.returncode is not None:
            logger.error("Vite exited (code=%d). Shutting down.", vite_proc.returncode)
            _shutdown(signal.SIGTERM)
            sys.exit(1)


if __name__ == "__main__":
    import subprocess  # for Windows creationflags

    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Interrupted by user.")
        sys.exit(0)
