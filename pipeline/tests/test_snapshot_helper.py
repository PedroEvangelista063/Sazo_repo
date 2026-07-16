from __future__ import annotations

import json
import os
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest


@pytest.fixture(autouse=True)
def _isolate_checkpoint(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setattr(
        "database.utils.snapshot_helper.CHECKPOINT_PATH",
        str(tmp_path / "ultimate_backfill_checkpoint.json"),
    )


# ──────────────────────────────────────────────
# Tests: atualizar_checkpoint
# ──────────────────────────────────────────────


class TestAtualizarCheckpoint:
    def test_cria_arquivo_se_nao_existe(self) -> None:
        from database.utils.snapshot_helper import (
            CHECKPOINT_PATH,
            atualizar_checkpoint,
        )

        fontes = {"conab-precos-uf": "2026-07"}
        atualizar_checkpoint(fontes)
        assert os.path.exists(CHECKPOINT_PATH)
        with open(CHECKPOINT_PATH, encoding="utf-8") as f:
            dados = json.load(f)
        assert "conab-precos-uf" in dados
        assert dados["conab-precos-uf"]["competencia"] == "2026-07"

    def test_merge_com_dados_existentes(self) -> None:
        from database.utils.snapshot_helper import atualizar_checkpoint

        atualizar_checkpoint({"fonte-a": "2026-06"})
        atualizar_checkpoint({"fonte-b": "2026-07", "fonte-a": "2026-07"})

        from database.utils.snapshot_helper import CHECKPOINT_PATH

        with open(CHECKPOINT_PATH, encoding="utf-8") as f:
            dados = json.load(f)
        assert "fonte-a" in dados
        assert "fonte-b" in dados
        assert dados["fonte-a"]["competencia"] == "2026-07"

    def test_nao_perde_dados_antigos_no_merge(self) -> None:
        from database.utils.snapshot_helper import atualizar_checkpoint

        atualizar_checkpoint({"fonte-a": "2026-06"})
        atualizar_checkpoint({"fonte-b": "2026-07"})

        from database.utils.snapshot_helper import CHECKPOINT_PATH

        with open(CHECKPOINT_PATH, encoding="utf-8") as f:
            dados = json.load(f)
        assert "fonte-a" in dados
        assert "fonte-b" in dados

    def test_ultima_carga_e_timestamp_valido(self) -> None:
        from database.utils.snapshot_helper import atualizar_checkpoint

        antes = datetime.now()
        atualizar_checkpoint({"fonte": "2026-07"})

        from database.utils.snapshot_helper import CHECKPOINT_PATH

        with open(CHECKPOINT_PATH, encoding="utf-8") as f:
            dados = json.load(f)
        ts = datetime.fromisoformat(dados["fonte"]["ultima_carga"])
        assert antes <= ts <= datetime.now()


# ──────────────────────────────────────────────
# Tests: verificar_staleness
# ──────────────────────────────────────────────


class TestVerificarStaleness:
    def test_arquivo_inexistente_retorna_vazio(self) -> None:
        from database.utils.snapshot_helper import CHECKPOINT_PATH, verificar_staleness

        if os.path.exists(CHECKPOINT_PATH):
            os.remove(CHECKPOINT_PATH)
        assert verificar_staleness() == []

    def test_dentro_do_prazo(self) -> None:
        from database.utils.snapshot_helper import atualizar_checkpoint, verificar_staleness

        atualizar_checkpoint({"conab-precos-uf": "2026-07"})
        assert verificar_staleness(max_dias=45) == []

    def test_source_stale(self) -> None:
        from database.utils.snapshot_helper import CHECKPOINT_PATH, atualizar_checkpoint, verificar_staleness

        atualizar_checkpoint({"fonte-stale": "2026-01"})
        dados = {"fonte-stale": {"ultima_carga": "2026-01-01T00:00:00", "competencia": "2026-01"}}
        with open(CHECKPOINT_PATH, "w", encoding="utf-8") as f:
            json.dump(dados, f)
        stale = verificar_staleness(max_dias=45)
        assert "fonte-stale" in stale

    def test_mistura_fresh_e_stale(self) -> None:
        from database.utils.snapshot_helper import CHECKPOINT_PATH, verificar_staleness

        agora = datetime.now()
        dados = {
            "fonte-fresh": {"ultima_carga": agora.isoformat(), "competencia": "2026-07"},
            "fonte-stale": {"ultima_carga": "2026-01-01T00:00:00", "competencia": "2026-01"},
        }
        with open(CHECKPOINT_PATH, "w", encoding="utf-8") as f:
            json.dump(dados, f)
        stale = verificar_staleness(max_dias=45)
        assert "fonte-stale" in stale
        assert "fonte-fresh" not in stale

    def test_max_dias_personalizado(self) -> None:
        from database.utils.snapshot_helper import CHECKPOINT_PATH, verificar_staleness

        trinta_atras = (datetime.now() - timedelta(days=30)).isoformat()
        dados = {
            "fonte-30d": {"ultima_carga": trinta_atras, "competencia": "2026-06"},
        }
        with open(CHECKPOINT_PATH, "w", encoding="utf-8") as f:
            json.dump(dados, f)
        assert "fonte-30d" not in verificar_staleness(max_dias=60)
        assert "fonte-30d" in verificar_staleness(max_dias=25)


# ──────────────────────────────────────────────
# Tests: export_snapshot
# ──────────────────────────────────────────────


class TestExportSnapshot:
    @pytest.mark.asyncio
    async def test_sucesso_copy_to_parquet(self, tmp_path: Path) -> None:
        from database.utils.snapshot_helper import export_snapshot

        mock_conn = AsyncMock()

        await export_snapshot(mock_conn, "staging", "fact_precos_mensais", str(tmp_path))
        mock_conn.execute.assert_called_once()
        sql = mock_conn.execute.call_args[0][0]
        assert "COPY" in sql
        assert "PARQUET" in sql

    @pytest.mark.asyncio
    async def test_tabela_vazia(self, tmp_path: Path) -> None:
        from database.utils.snapshot_helper import export_snapshot

        mock_conn = AsyncMock()
        mock_conn.execute.side_effect = RuntimeError("COPY PARQUET not supported")
        mock_conn.fetch.return_value = []

        await export_snapshot(mock_conn, "staging", "fact_precos_mensais", str(tmp_path))
        assert len(list(tmp_path.glob("*"))) == 0

    @pytest.mark.asyncio
    async def test_fallback_polars_quando_copy_falha(self, tmp_path: Path) -> None:
        from database.utils.snapshot_helper import export_snapshot

        mock_conn = AsyncMock()
        mock_conn.execute.side_effect = RuntimeError("COPY PARQUET not supported")
        mock_conn.fetch.return_value = [
            {"id": 1, "produto": "Tomate", "preco": 5.0},
        ]

        await export_snapshot(mock_conn, "staging", "fact_precos_mensais", str(tmp_path))

        files = list(tmp_path.glob("fact_precos_mensais_*.parquet"))
        assert len(files) == 1

    @pytest.mark.asyncio
    async def test_nao_lanca_excecao_em_erro_total(self, tmp_path: Path) -> None:
        from database.utils.snapshot_helper import export_snapshot

        mock_conn = AsyncMock()
        mock_conn.execute.side_effect = RuntimeError("DB error")

        await export_snapshot(mock_conn, "staging", "fact_precos_mensais", str(tmp_path))

    @pytest.mark.asyncio
    async def test_cria_diretorio_se_nao_existe(self, tmp_path: Path) -> None:
        from database.utils.snapshot_helper import export_snapshot

        subdir = tmp_path / "sub" / "dir"
        mock_conn = AsyncMock()

        await export_snapshot(mock_conn, "staging", "tabela", str(subdir))
        assert subdir.exists()
