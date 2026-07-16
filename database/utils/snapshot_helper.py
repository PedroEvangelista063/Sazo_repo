from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timedelta
from typing import Any

logger = logging.getLogger(__name__)

CHECKPOINT_PATH = "database/processed_data/01_raw/ultimate_backfill_checkpoint.json"


async def export_snapshot(
    conexao: Any,
    schema: str,
    tabela: str,
    diretorio: str,
) -> None:
    os.makedirs(diretorio, exist_ok=True)
    agora = datetime.now()
    nome = f"{tabela}_{agora.year}_{agora.month:02d}"
    parquet_path = os.path.join(diretorio, f"{nome}.parquet")

    try:
        sql = (
            f"COPY (SELECT * FROM {schema}.{tabela} "
            f"ORDER BY ano, mes, id_produto, id_localidade) "
            f"TO '{parquet_path}' WITH (FORMAT PARQUET)"
        )
        await conexao.execute(sql)
        logger.info("[SNAPSHOT] %s parquet via COPY OK", nome)
    except Exception:
        logger.warning("[SNAPSHOT] COPY PARQUET falhou, tentando Polars", exc_info=True)
        try:
            rows = await conexao.fetch(f"SELECT * FROM {schema}.{tabela}")
            if rows:
                import polars as pl

                df = pl.DataFrame([dict(r) for r in rows])
                df.write_parquet(parquet_path)
                logger.info("[SNAPSHOT] %s parquet via Polars %d linhas", nome, len(rows))
            else:
                logger.info("[SNAPSHOT] %s vazia pulando", tabela)
        except Exception as exc2:
            logger.warning("[SNAPSHOT] falha total %s: %s", nome, exc2)


def atualizar_checkpoint(fontes: dict[str, str | None]) -> None:
    agora = datetime.now().isoformat()
    dados: dict[str, Any] = {}
    if os.path.exists(CHECKPOINT_PATH):
        with open(CHECKPOINT_PATH, encoding="utf-8") as f:
            dados = json.load(f)
    for fonte, competencia in fontes.items():
        dados[fonte] = {
            "ultima_carga": agora,
            "competencia": competencia,
        }
    os.makedirs(os.path.dirname(CHECKPOINT_PATH), exist_ok=True)
    with open(CHECKPOINT_PATH, "w", encoding="utf-8") as f:
        json.dump(dados, f, ensure_ascii=False, indent=2)


def verificar_staleness(max_dias: int = 45) -> list[str]:
    if not os.path.exists(CHECKPOINT_PATH):
        return []
    with open(CHECKPOINT_PATH, encoding="utf-8") as f:
        dados: dict[str, Any] = json.load(f)
    agora = datetime.now()
    limite = timedelta(days=max_dias)
    stale: list[str] = []
    for fonte, info in dados.items():
        ultima = datetime.fromisoformat(info["ultima_carga"])
        if agora - ultima > limite:
            stale.append(fonte)
    return stale
