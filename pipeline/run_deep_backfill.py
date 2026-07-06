#!/usr/bin/env python3
"""Deep Backfill 2020–2026 — execução chunkada com checkpoint.

Processa 78 meses (2020-01 a 2026-06) em lotes anuais, cada lote em
subprocesso isolado que libera toda a memória ao final. Se falhar no
meio, retoma do checkpoint sem repetir anos já concluídos.

Checkpoint salvo em:  {RAW_DIR}/deep_backfill_checkpoint.json

Uso:
    python pipeline/run_deep_backfill.py                              # range completo
    python pipeline/run_deep_backfill.py --chunk-meses 3              # chunks de 3 meses
    python pipeline/run_deep_backfill.py --reset                      # ignora checkpoint
    python pipeline/run_deep_backfill.py --ano 2024                   # só 2024
    python pipeline/run_deep_backfill.py --skip-ciclo-medalhao        # só carga, sem SP
"""

from __future__ import annotations

import argparse
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
logger = logging.getLogger("deep_backfill")

PROJECT_ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = PROJECT_ROOT / "database" / "processed_data" / "01_raw"
CHECKPOINT_FILE = RAW_DIR / "deep_backfill_checkpoint.json"

ANO_INICIO = 2020
MES_INICIO = 1
ANO_FIM = 2026
MES_FIM = 6
QUALIDADE_ALVO = float(os.environ.get("QUALIDADE_MINIMA_PCT", "97.0"))


@dataclass
class Checkpoint:
    chunks_ok: list[str] = field(default_factory=list)
    ultimo_chunk: str | None = None
    timestamp: str | None = None

    def salvar(self, path: Path = CHECKPOINT_FILE) -> None:
        self.timestamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(asdict(self), indent=2, ensure_ascii=False), encoding="utf-8")
        logger.info("Checkpoint salvo: %s  (%d chunks ok)", path, len(self.chunks_ok))

    @classmethod
    def carregar(cls, path: Path = CHECKPOINT_FILE) -> Checkpoint | None:
        if path.exists():
            data = json.loads(path.read_text(encoding="utf-8"))
            return cls(**data)
        return None


def _iterar_chunks(
    ano_inicio: int, mes_inicio: int,
    ano_fim: int, mes_fim: int,
    chunk_size: int,
) -> list[tuple[tuple[int, int], tuple[int, int]]]:
    """Divide intervalo em chunks de N meses. Retorna [(inicio, fim), ...]."""
    chunks: list[tuple[tuple[int, int], tuple[int, int]]] = []
    a, m = ano_inicio, mes_inicio
    while (a < ano_fim) or (a == ano_fim and m <= mes_fim):
        # início do chunk
        a_start, m_start = a, m
        # avança chunk_size meses
        for _ in range(chunk_size - 1):
            m += 1
            if m > 12:
                m = 1
                a += 1
        a_end, m_end = a, m
        # não ultrapassar o fim
        if (a_end > ano_fim) or (a_end == ano_fim and m_end > mes_fim):
            a_end, m_end = ano_fim, mes_fim
        chunks.append(((a_start, m_start), (a_end, m_end)))
        # avança para o próximo chunk
        m += 1
        if m > 12:
            m = 1
            a += 1
    return chunks


def _chunk_label(inicio: tuple[int, int], fim: tuple[int, int]) -> str:
    return f"{inicio[0]:04d}-{inicio[1]:02d}_to_{fim[0]:04d}-{fim[1]:02d}"


def _executar_chunk(
    inicio: tuple[int, int],
    fim: tuple[int, int],
    qualidade: float,
    skip_ciclo: bool,
) -> int:
    """Executa um chunk chamando run_scraper_historico.py como subprocesso.

    Retorna o código de saída (0 = sucesso).
    """
    desde = f"{inicio[0]:04d}-{inicio[1]:02d}"
    ate = f"{fim[0]:04d}-{fim[1]:02d}"
    label = _chunk_label(inicio, fim)

    cmd = [
        sys.executable,
        str(PROJECT_ROOT / "pipeline" / "run_scraper_historico.py"),
        "--desde", desde,
        "--ate", ate,
        "--qualidade-minima", str(qualidade),
        "--forcar",
    ]
    if skip_ciclo:
        cmd.append("--skip-load")

    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"

    logger.info("─" * 60)
    logger.info("CHUNK %s", label)
    logger.info("  Comando: %s", " ".join(cmd))
    logger.info("─" * 60)

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
        logger.info("CHUNK %s concluído em %.1fs", label, elapsed)
    else:
        logger.error("CHUNK %s FALHOU (exit=%d) em %.1fs", label, proc.returncode, elapsed)

    return proc.returncode


def main() -> None:
    parser = argparse.ArgumentParser(description="Deep Backfill 2020–2026 (chunked + checkpoint)")
    parser.add_argument("--chunk-meses", type=int, default=12, help="Meses por chunk (default=12)")
    parser.add_argument("--reset", action="store_true", help="Ignora checkpoint e recomeça do início")
    parser.add_argument("--ano", type=int, default=None, help="Processar apenas um ano específico")
    parser.add_argument("--qualidade", type=float, default=QUALIDADE_ALVO, help="%% mínima de cobertura")
    parser.add_argument("--skip-ciclo-medalhao", action="store_true", help="Só carrega dados, não recalcula sazonalidade")
    args = parser.parse_args()

    logger.info("=" * 60)
    logger.info("  DEEP BACKFILL 2020–2026")
    logger.info("  Chunk: %d meses | Reset: %s | Skip-ciclo: %s",
                args.chunk_meses, args.reset, args.skip_ciclo_medalhao)
    logger.info("=" * 60)

    if args.ano:
        chunks = [((args.ano, 1), (args.ano, 12))]
    else:
        chunks = _iterar_chunks(ANO_INICIO, MES_INICIO, ANO_FIM, MES_FIM, args.chunk_meses)
    logger.info("Total de chunks planejados: %d", len(chunks))

    # ── Checkpoint ────────────────────────────────────────────────
    checkpoint: Checkpoint | None = None
    if not args.reset:
        checkpoint = Checkpoint.carregar()
        if checkpoint:
            logger.info("Checkpoint encontrado: %d chunks já concluídos", len(checkpoint.chunks_ok))
        else:
            logger.info("Nenhum checkpoint encontrado — começando do zero.")
            checkpoint = Checkpoint()
    else:
        if CHECKPOINT_FILE.exists():
            CHECKPOINT_FILE.unlink()
            logger.info("Checkpoint removido (--reset).")
        checkpoint = Checkpoint()

    # ── Execução ──────────────────────────────────────────────────
    chunks_restantes = [
        c for c in chunks if _chunk_label(c[0], c[1]) not in checkpoint.chunks_ok
    ]
    logger.info("Chunks restantes: %d de %d", len(chunks_restantes), len(chunks))

    if not chunks_restantes:
        logger.info("Nada a fazer — todos os chunks já foram concluídos.")
        return

    falhas = 0
    for inicio, fim in chunks_restantes:
        label = _chunk_label(inicio, fim)
        rc = _executar_chunk(inicio, fim, args.qualidade, args.skip_ciclo_medalhao)

        if rc == 0:
            checkpoint.chunks_ok.append(label)
            checkpoint.ultimo_chunk = label
            checkpoint.salvar()
        else:
            falhas += 1
            logger.error("CHUNK %s FALHOU — ver logs acima. Checkpoint NÃO atualizado.", label)
            logger.info("Para retomar, execute novamente o mesmo comando.")
            sys.exit(1)

    logger.info("=" * 60)
    logger.info("  DEEP BACKFILL CONCLUÍDO")
    logger.info("  Chunks OK: %d | Falhas: %d", len(checkpoint.chunks_ok), falhas)
    logger.info("  Checkpoint: %s", CHECKPOINT_FILE)
    logger.info("=" * 60)


if __name__ == "__main__":
    main()
