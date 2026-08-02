from __future__ import annotations

import csv
import io
import logging
from typing import Any

import httpx

from pipeline.scraper.micro_engines.base_engine import BaseMicroEngine

logger = logging.getLogger(__name__)

URL_PRECOS_MENSAIS_UF = (
    "https://portaldeinformacoes.conab.gov.br/downloads/arquivos/PrecosMensalUF.txt"
)

COLUNAS_PRECOS_MENSAIS_UF = [
    "produto",
    "classificao_produto",
    "id_produto",
    "uf",
    "regiao",
    "ano",
    "mes",
    "dsc_nivel_comercializacao",
    "valor_produto_kg",
]


class PrecosMensalUfEngine(BaseMicroEngine):
    """
    Micro-motor CONAB Precos Mensais por UF.
    Baixa PrecosMensalUF.txt do portal CONAB (~3,6MB) e filtra por ano/mês.
    Entrega linhas normalizadas no contrato do SortingEngine:
    nome_produto, preco_kg, uf, data_referencia.
    """

    def __init__(self) -> None:
        super().__init__()

    async def extract(self, url: str, ano: int, mes: int) -> dict[str, Any]:
        logger.info("[PRECOS-MENSAIS-UF] Baixando dados para %d-%02d", ano, mes)
        raw = await self._download()
        linhas, competencias = self._transform(raw, ano, mes)

        logger.info(
            "[PRECOS-MENSAIS-UF] %d linhas para %d-%02d (de %d competências disponíveis)",
            len(linhas),
            ano,
            mes,
            len(competencias),
        )

        return {
            "fonte_id": "CONAB-PRECOS-MENSAIS-UF",
            "payload_bruto": {
                "linhas": linhas,
                "total_linhas": len(linhas),
                "competencias_disponiveis": competencias,
            },
            "competencia": f"{ano}-{mes:02d}",
        }

    async def extract_all(self, ano: int, mes: int) -> list[dict[str, Any]]:
        result = await self.extract("", ano, mes)
        return [result]

    async def _download(self) -> bytes:
        if self._circuit_breaker.esta_aberto:
            raise RuntimeError(f"CircuitBreaker aberto para {self.__class__.__name__}")

        async with (
            self._semaphore,
            httpx.AsyncClient(
                timeout=httpx.Timeout(180.0, connect=15.0),
                follow_redirects=True,
            ) as client,
        ):
            try:
                resp = await client.get(
                    URL_PRECOS_MENSAIS_UF,
                    headers={"User-Agent": "QueroComprar/2.0"},
                )
                resp.raise_for_status()
                self._circuit_breaker.registrar_sucesso()
                return resp.content
            except Exception:
                self._circuit_breaker.registrar_falha()
                raise

    def _transform(
        self, raw: bytes | str, ano: int, mes: int
    ) -> tuple[list[dict[str, Any]], list[str]]:
        decoded = self._decodificar(raw)
        linhas: list[dict[str, Any]] = []
        competencias: set[str] = set()

        reader = csv.DictReader(io.StringIO(decoded), delimiter=";")

        for row in reader:
            row_stripped = {k.strip(): (v.strip() if v else "") for k, v in row.items()}
            if not self._match_competencia(row_stripped, ano, mes):
                continue

            comp = f"{row_stripped.get('ano', '')}-{int(row_stripped['mes']):02d}"
            if len(comp) == len("YYYY-MM"):
                competencias.add(comp)

            item = self._montar_item(row_stripped)
            if item:
                linhas.append(item)

        return linhas, sorted(competencias, reverse=True)

    @staticmethod
    def _decodificar(raw: bytes | str) -> str:
        if isinstance(raw, str):
            return raw
        try:
            return raw.decode("utf-8-sig")
        except UnicodeDecodeError:
            return raw.decode("iso-8859-1")

    @staticmethod
    def _match_competencia(row: dict[str, str], ano: int, mes: int) -> bool:
        row_ano = row.get("ano", "").strip()
        row_mes = row.get("mes", "").strip()
        if not row_ano or not row_mes:
            return False
        try:
            return int(row_ano) == ano and int(row_mes) == mes
        except (ValueError, TypeError):
            return False

    @staticmethod
    def _montar_item(row: dict[str, str]) -> dict[str, Any] | None:
        nome = row.get("produto", "").strip().lower()
        if not nome:
            return None

        valor_raw = row.get("valor_produto_kg", "").replace(",", ".").strip()
        try:
            preco = float(valor_raw)
        except (ValueError, TypeError):
            return None

        if preco <= 0:
            return None

        uf = row.get("uf", "").strip().upper()[:2]
        if not uf:
            uf = "BR"

        ano_str = row.get("ano", "").strip()
        mes_str = row.get("mes", "").strip()
        data_ref = f"{ano_str}-{int(mes_str):02d}" if ano_str and mes_str else None

        return {
            "nome_produto": nome,
            "preco_kg": round(preco, 4),
            "uf": uf,
            "data_referencia": data_ref,
            "id_produto": row.get("id_produto", "").strip(),
            "classificao_produto": row.get("classificao_produto", "").strip(),
            "dsc_nivel_comercializacao": row.get("dsc_nivel_comercializacao", "").strip(),
            "regiao": row.get("regiao", "").strip(),
        }

    async def close(self) -> None:
        pass
