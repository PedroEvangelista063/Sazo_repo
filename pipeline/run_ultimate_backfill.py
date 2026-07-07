#!/usr/bin/env python3
"""Backfill definitivo — varre meses órfãos e dispara SmartCrawler com datas forçadas.

Fluxo:
  1. Consulta staging.fact_precos_mensais por cobertura mensal
  2. Filtra meses com menos de N% dos produtos mapeados
  3. Executa run_scraper_historico.py com --forcar em chunks
  4. Checkpoint salva progresso para retomada

Uso:
    python pipeline/run_ultimate_backfill.py
    python pipeline/run_ultimate_backfill.py --chunk-meses 3
    python pipeline/run_ultimate_backfill.py --reset
    python pipeline/run_ultimate_backfill.py --ano 2020 --mes 1
    python pipeline/run_ultimate_backfill.py --limpeza 30.0
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import subprocess
import sys
import time
from dataclasses import dataclass, asdict, field
from datetime import date
from pathlib import Path
from typing import Any

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("ultimate_backfill")

PROJECT_ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = PROJECT_ROOT / "database" / "processed_data" / "01_raw"
CHECKPOINT_FILE = RAW_DIR / "ultimate_backfill_checkpoint.json"

QUALIDADE_PISO = float(os.environ.get("QUALIDADE_MINIMA_PCT", "97.0"))
COBERTURA_ALVO = float(os.environ.get("COBERTURA_ALVO_PCT", "95.0"))
DATABASE_URL: str = os.environ.get(
    "DATABASE_URL_ETL",
) or os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/quero_comprar",
)
ANO_INICIO = 2020
MES_INICIO = 1
ANO_FIM = 2025
MES_FIM = 12

MESES_POR_CHUNK = int(os.environ.get("ULTIMATE_CHUNK_MESES", "12"))


@dataclass
class Checkpoint:
    chunks_ok: list[str] = field(default_factory=list)
    ultimo_chunk: str | None = None
    timestamp: str | None = None

    def salvar(self, path: Path = CHECKPOINT_FILE) -> None:
        self.timestamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(asdict(self), indent=2, ensure_ascii=False), encoding="utf-8"
        )
        logger.info("Checkpoint: %s  (%d chunks ok)", path, len(self.chunks_ok))

    @classmethod
    def carregar(cls, path: Path = CHECKPOINT_FILE) -> Checkpoint | None:
        if path.exists():
            return cls(**json.loads(path.read_text(encoding="utf-8")))
        return None


async def _detectar_orfanatos(
    conn: Any, limite_pct: float
) -> list[tuple[int, int]]:
    """Retorna meses com cobertura abaixo do limite."""
    total = await conn.fetchval(
        "SELECT count(*) FROM staging.dim_produto WHERE status_fonte = 'MAPEADA'"
    )
    if not total or total == 0:
        logger.warning("Nenhum produto MAPEADO — varrendo range completo")
        return []

    range_anos = ANO_FIM - ANO_INICIO + 1
    total_meses = range_anos * 12 - MES_INICIO + 1 + (12 - MES_FIM)
    meses_alvo = _iterar_meses(ANO_INICIO, MES_INICIO, ANO_FIM, MES_FIM)

    orfaos: list[tuple[int, int]] = []
    info: list[dict[str, Any]] = []
    for ano, mes in meses_alvo:
        existentes = await conn.fetchval(
            """
            SELECT count(DISTINCT f.id_produto)
            FROM staging.fact_precos_mensais f
            JOIN staging.dim_produto p ON p.id_produto = f.id_produto
            WHERE p.status_fonte = 'MAPEADA'
              AND f.ano = $1 AND f.mes = $2
            """,
            ano,
            mes,
        )
        cobertura = (existentes / total * 100) if existentes else 0.0
        if cobertura < limite_pct:
            orfaos.append((ano, mes))
            info.append({"ano": ano, "mes": mes, "cobertura": round(cobertura, 1)})

    if info:
        logger.info("Meses orfaos (%d abaixo de %.1f%%):", len(info), limite_pct)
        for row in info:
            logger.info("  %04d/%02d — cobertura: %.1f%%", row["ano"], row["mes"], row["cobertura"])
    else:
        logger.info("Nenhum mes orfao encontrado — cobertura minima %.1f%% ok", limite_pct)

    return orfaos


def _iterar_meses(
    ano_inicio: int, mes_inicio: int, ano_fim: int, mes_fim: int
) -> list[tuple[int, int]]:
    meses: list[tuple[int, int]] = []
    a, m = ano_inicio, mes_inicio
    while (a < ano_fim) or (a == ano_fim and m <= mes_fim):
        meses.append((a, m))
        m += 1
        if m > 12:
            m = 1
            a += 1
    return meses


def _agrupar_chunks(
    orfaos: list[tuple[int, int]], chunk_size: int
) -> list[list[tuple[int, int]]]:
    if not orfaos:
        return []
    orfaos_ordenados = sorted(orfaos)
    chunks: list[list[tuple[int, int]]] = []
    atual: list[tuple[int, int]] = [orfaos_ordenados[0]]
    for i in range(1, len(orfaos_ordenados)):
        if len(atual) >= chunk_size:
            chunks.append(atual)
            atual = []
        atual.append(orfaos_ordenados[i])
    if atual:
        chunks.append(atual)
    return chunks


def _chunk_label(chunk: list[tuple[int, int]]) -> str:
    inicio = chunk[0]
    fim = chunk[-1]
    return f"{inicio[0]:04d}-{inicio[1]:02d}_to_{fim[0]:04d}-{fim[1]:02d}"


def _executar_chunk(chunk: list[tuple[int, int]], qualidade: float) -> int:
    inicio = chunk[0]
    fim = chunk[-1]
    desde = f"{inicio[0]:04d}-{inicio[1]:02d}"
    ate = f"{fim[0]:04d}-{fim[1]:02d}"
    label = _chunk_label(chunk)

    cmd = [
        sys.executable,
        str(PROJECT_ROOT / "pipeline" / "run_scraper_historico.py"),
        "--desde", desde,
        "--ate", ate,
        "--qualidade-minima", str(qualidade),
        "--forcar",
    ]

    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONPATH"] = str(PROJECT_ROOT) + os.pathsep + env.get("PYTHONPATH", "")

    logger.info("=" * 60)
    logger.info("CHUNK %s (%d meses)", label, len(chunk))
    logger.info("  Comando: %s", " ".join(cmd))
    logger.info("=" * 60)

    t0 = time.perf_counter()
    proc = subprocess.run(
        cmd,
        cwd=str(PROJECT_ROOT),
        env=env,
        capture_output=False,
        text=True,
    )
    elapsed = time.perf_counter() - t0

    if proc.returncode == 0:
        logger.info("CHUNK %s OK em %.1fs", label, elapsed)
    else:
        logger.error("CHUNK %s FALHOU (exit=%d) em %.1fs", label, proc.returncode, elapsed)

    return proc.returncode


async def main() -> None:
    parser = argparse.ArgumentParser(
        description="Ultimate Backfill — varre meses orfaos com datas forcadas"
    )
    parser.add_argument("--chunk-meses", type=int, default=MESES_POR_CHUNK)
    parser.add_argument("--reset", action="store_true")
    parser.add_argument("--ano", type=int, default=None)
    parser.add_argument("--mes", type=int, default=None)
    parser.add_argument("--limpeza", type=float, default=QUALIDADE_PISO, help="%% limite para considerar orfao")
    parser.add_argument("--db-url", type=str, default=DATABASE_URL)
    parser.add_argument("--skip-check", action="store_true", help="Pula deteccao de orfaos, backfilleia range fixo")
    parser.add_argument("--parallel", type=int, default=1, help="Chunks simultaneos (ex: 3). Jitter automatico entre lances.")
    args = parser.parse_args()

    logger.info("=" * 60)
    logger.info("  ULTIMATE BACKFILL 2020-2025")
    logger.info("  Limpeza: %.1f%% | Chunk: %d meses | Reset: %s",
                args.limpeza, args.chunk_meses, args.reset)
    logger.info("=" * 60)

    # ── 1. Detectar meses orfaos ──────────────────────────────────
    if args.ano is not None:
        orfaos = [(args.ano, args.mes or 1)]
    elif args.skip_check:
        orfaos = _iterar_meses(ANO_INICIO, MES_INICIO, ANO_FIM, MES_FIM)
        logger.info("Skip-check: range completo = %d meses", len(orfaos))
    else:
        try:
            import asyncpg
            if sys.platform == "win32":
                asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
            conn = await asyncpg.connect(args.db_url)
            try:
                orfaos = await _detectar_orfanatos(conn, args.limpeza)
            finally:
                await conn.close()
        except Exception as e:
            logger.warning("Falha ao detectar orfaos (%s) — range fixo", e)
            orfaos = _iterar_meses(ANO_INICIO, MES_INICIO, ANO_FIM, MES_FIM)

    if not orfaos:
        logger.info("Nada a fazer — todos os meses ok.")
        return

    logger.info("Total de meses orfaos: %d", len(orfaos))

    # ── 2. Agrupar em chunks ──────────────────────────────────────
    chunks = _agrupar_chunks(orfaos, args.chunk_meses)
    logger.info("Chunks: %d (tamanho max %d meses cada)", len(chunks), args.chunk_meses)

    # ── 3. Checkpoint ─────────────────────────────────────────────
    checkpoint: Checkpoint | None = None
    if not args.reset:
        checkpoint = Checkpoint.carregar()
        if checkpoint:
            logger.info("Checkpoint: %d chunks ja concluidos", len(checkpoint.chunks_ok))
        else:
            checkpoint = Checkpoint()
    else:
        if CHECKPOINT_FILE.exists():
            CHECKPOINT_FILE.unlink()
        checkpoint = Checkpoint()

    chunks_restantes = [
        c for c in chunks if _chunk_label(c) not in checkpoint.chunks_ok
    ]
    logger.info("Chunks restantes: %d de %d", len(chunks_restantes), len(chunks))

    if not chunks_restantes:
        logger.info("Nada a fazer — todos os chunks concluidos.")
        return

    # ── 4. Execucao (sequencial ou paralela com Semaphore + Jitter) ──
    sem = asyncio.Semaphore(args.parallel)

    async def _worker(chunk: list[tuple[int, int]]) -> bool:
        async with sem:
            label = _chunk_label(chunk)
            # Jitter: atraso aleatorio entre 0-5s antes de lancar
            if args.parallel > 1:
                import random
                jitter = random.uniform(0, 5)
                logger.debug("Jitter %.1fs antes de %s", jitter, label)
                await asyncio.sleep(jitter)
            rc = _executar_chunk(chunk, args.limpeza)
            return rc == 0

    if args.parallel > 1:
        logger.info("Modo paralelo: %d chunks simultaneos com jitter", args.parallel)
        resultados = await asyncio.gather(*[_worker(c) for c in chunks_restantes])
        for chunk, ok in zip(chunks_restantes, resultados):
            label = _chunk_label(chunk)
            if ok:
                checkpoint.chunks_ok.append(label)
                checkpoint.ultimo_chunk = label
            else:
                logger.error("CHUNK %s FALHOU — checkpoint nao atualizado", label)
                sys.exit(1)
        checkpoint.salvar()
    else:
        for chunk in chunks_restantes:
            label = _chunk_label(chunk)
            rc = _executar_chunk(chunk, args.limpeza)
            if rc == 0:
                checkpoint.chunks_ok.append(label)
                checkpoint.ultimo_chunk = label
                checkpoint.salvar()
            else:
                logger.error("CHUNK %s FALHOU — checkpoint nao atualizado", label)
                sys.exit(1)

    logger.info("=" * 60)
    logger.info("  ULTIMATE BACKFILL CONCLUIDO")
    logger.info("  Chunks OK: %d", len(checkpoint.chunks_ok))
    logger.info("=" * 60)


if __name__ == "__main__":
    asyncio.run(main())
