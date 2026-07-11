from __future__ import annotations

import asyncio
import json
import logging
import os
from pathlib import Path
from typing import Any

from pipeline.scraper.micro_engines.base_engine import BaseMicroEngine
from pipeline.scraper.micro_engines.ConabApiEngine import ConabApiEngine
from pipeline.scraper.micro_engines.CeagespEngine import CeagespEngine

logger = logging.getLogger(__name__)

_AUDIT_FMT = "[AUDIT] UF: {uf} | Mês/Ano: {competencia} | Alvo: {alvo} | Status: {status} | Decisão: {decisao}"

def _log_audit(level: int, **kw: str) -> None:
    logger.log(level, _AUDIT_FMT.format(**kw))

_UF_CEASA_MAP: dict[str, str] = {
    "SP": "CEAGESP",
    "MG": "CEASA-MG",
    "PR": "CEASA-PR",
    "MT": "IMEA-MT",
    "ES": "CEASA-ES",
    "DF": "CEASA-DF",
    "BA": "CEASA-BA",
    "PE": "CEASA-PE",
    "RN": "CEASA-RN",
    "MS": "CEASA-MS",
}

_ORFAOS: set[str] = {
    "AC", "AL", "AM", "AP", "GO", "MA", "PB", "PI",
    "RJ", "RO", "RR", "RS", "SC", "SE", "TO",
}

SCRAPER_TIMEOUT_SEC = 60


def _carregar_sources() -> dict:
    caminho = Path(os.getenv("SOURCES_MATRIX_PATH", "config/sources_matrix.json"))
    with open(caminho, encoding="utf-8") as f:
        return json.load(f)


class AutonomousOrchestrator:
    """
    Orquestrador autônomo em cascata (Self-Healing Flow).
    Passo 1 → CEASA direta | Passo 2 → Agregadores | Passo 3 → Discovery.
    """

    def __init__(self) -> None:
        self._sources = _carregar_sources()

    # ──────────────────────────────────────────────
    # Passo 1 — Motor direto da CEASA do estado
    # ──────────────────────────────────────────────
    async def _passo_direto(
        self, uf: str, ano: int, mes: int
    ) -> list[dict[str, Any]] | None:
        fonte_id = _UF_CEASA_MAP.get(uf.upper())
        if not fonte_id:
            _log_audit(logging.INFO, uf=uf, competencia=f"{ano}-{mes:02d}", alvo=f"CEASA_DIRETA_{uf}", status="SKIP", decisao=f"UF {uf} sem CEASA direta mapeada → orfão")
            return None

        _log_audit(logging.INFO, uf=uf, competencia=f"{ano}-{mes:02d}", alvo=fonte_id, status="TENTANDO", decisao="Passo 1: motor CEASA direto")
        fonte = self._encontrar_fonte(fonte_id, "ceasas_diretas")
        if not fonte:
            return None

        url = fonte["url_base"]
        engine = self._resolver_motor(fonte_id)
        if not engine:
            _log_audit(logging.WARNING, uf=uf, competencia=f"{ano}-{mes:02d}", alvo=fonte_id, status="SKIP", decisao="Nenhum motor registrado para CEASA direta")
            return None
        resultado = await self._executar_com_timeout(engine, url, ano, mes, fonte_id)
        if resultado:
            _log_audit(logging.INFO, uf=uf, competencia=f"{ano}-{mes:02d}", alvo=fonte_id, status="SUCESSO", decisao="Dados coletados via CEASA direta")
            return [resultado]
        return None

    # ──────────────────────────────────────────────
    # Passo 2 — Agregadores nacionais (fallback)
    # ──────────────────────────────────────────────
    async def _passo_agregadores(
        self, uf: str, ano: int, mes: int
    ) -> list[dict[str, Any]] | None:
        agregadores = self._sources.get("agregadores", [])
        for fonte in agregadores:
            fonte_id = fonte["fonte_id"]
            _log_audit(logging.INFO, uf=uf, competencia=f"{ano}-{mes:02d}", alvo=fonte_id, status="TENTANDO", decisao="Passo 2: agregador nacional")
            engine = self._resolver_motor(fonte_id)
            if not engine:
                _log_audit(logging.WARNING, uf=uf, competencia=f"{ano}-{mes:02d}", alvo=fonte_id, status="SKIP", decisao="Nenhum motor registrado")
                continue
            url = fonte["url_base"]
            resultado = await self._executar_com_timeout(engine, url, ano, mes, fonte_id)
            if resultado:
                _log_audit(logging.INFO, uf=uf, competencia=f"{ano}-{mes:02d}", alvo=fonte_id, status="SUCESSO", decisao="Dados coletados via agregador")
                return [resultado]
        return None

    # ──────────────────────────────────────────────
    # Passo 3 — Discovery autônomo (web search)
    # ──────────────────────────────────────────────
    async def _passo_discovery(
        self, uf: str, ano: int, mes: int
    ) -> list[dict[str, Any]]:
        _log_audit(logging.INFO, uf=uf, competencia=f"{ano}-{mes:02d}", alvo="DISCOVERY_AUTONOMO", status="TENTANDO", decisao="Passo 3: todos os motores falharam → acionando discovery engine")
        from pipeline.scraper.discovery_engine import DiscoveryEngine

        engine = DiscoveryEngine()
        try:
            resultados = await asyncio.wait_for(
                engine.buscar(uf, ano, mes),
                timeout=SCRAPER_TIMEOUT_SEC,
            )
        except asyncio.TimeoutError:
            _log_audit(logging.WARNING, uf=uf, competencia=f"{ano}-{mes:02d}", alvo="DISCOVERY_AUTONOMO", status="TIMEOUT", decisao=f"Discovery excedeu {SCRAPER_TIMEOUT_SEC}s")
            return []
        _log_audit(logging.INFO, uf=uf, competencia=f"{ano}-{mes:02d}", alvo="DISCOVERY_AUTONOMO", status="SUCESSO" if resultados else "VAZIO", decisao=f"Discovery retornou {len(resultados)} registros")
        return resultados

    # ──────────────────────────────────────────────
    # Orquestração principal — cascata completa
    # ──────────────────────────────────────────────
    async def coletar(
        self, uf: str, competencia: str
    ) -> list[dict[str, Any]]:
        ano_str, mes_str = competencia.split("-")
        ano, mes = int(ano_str), int(mes_str)

        if ano < 2024 or ano > 2026:
            raise ValueError(f"competencia {competencia} fora da janela 2024-2026")

        resultado: list[dict[str, Any]] | None = None

        resultado = await self._passo_direto(uf, ano, mes)

        if not resultado:
            resultado = await self._passo_agregadores(uf, ano, mes)

        if not resultado:
            resultado = await self._passo_discovery(uf, ano, mes)

        return resultado or []

    # ──────────────────────────────────────────────
    # Execução blindada com timeout + cleanup
    # ──────────────────────────────────────────────
    async def _executar_com_timeout(
        self,
        engine: BaseMicroEngine,
        url: str,
        ano: int,
        mes: int,
        fonte_id: str,
    ) -> dict[str, Any] | None:
        try:
            return await asyncio.wait_for(
                engine.extract(url, ano, mes),
                timeout=SCRAPER_TIMEOUT_SEC,
            )
        except asyncio.TimeoutError:
            _log_audit(logging.WARNING, uf="?", competencia=f"{ano}-{mes:02d}", alvo=fonte_id, status="TIMEOUT", decisao=f"Motor excedeu {SCRAPER_TIMEOUT_SEC}s — abortando")
            return None
        except Exception as exc:
            _log_audit(logging.WARNING, uf="?", competencia=f"{ano}-{mes:02d}", alvo=fonte_id, status="FALHA", decisao=f"Exceção: {exc}")
            return None
        finally:
            await engine.close()

    # ──────────────────────────────────────────────
    # Helpers
    # ──────────────────────────────────────────────
    def _encontrar_fonte(
        self, fonte_id: str, categoria: str
    ) -> dict | None:
        for item in self._sources.get(categoria, []):
            if item["fonte_id"] == fonte_id:
                return item
        return None

    @staticmethod
    def _resolver_motor(fonte_id: str) -> BaseMicroEngine | None:
        if "ceagesp" in fonte_id.lower():
            return CeagespEngine()
        if "conab" in fonte_id.lower():
            return ConabApiEngine()
        logger.debug("Nenhum motor registrado para %s", fonte_id)
        return None

    async def close(self) -> None:
        pass

    async def __aenter__(self) -> "AutonomousOrchestrator":
        return self

    async def __aexit__(self, *args: Any) -> None:
        await self.close()
