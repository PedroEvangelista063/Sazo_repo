from __future__ import annotations

import csv
import io
import logging
from typing import Any

import httpx

from pipeline.scraper.micro_engines.base_engine import BaseMicroEngine

logger = logging.getLogger(__name__)

URL_PROHORT_MENSAL = "https://portaldeinformacoes.conab.gov.br/downloads/arquivos/ProhortMensal.txt"

COLUNAS_PROHORT_MENSAL = [
    "dsc_produto",
    "uf_ceasa",
    "id_ano_comercializacao",
    "id_mes_comercializacao",
    "valor_comercializado",
    "qtd_comercializada_kg",
]

_FIELD_MAP = {
    "nome_produto": ["dsc_produto", "produto", "nome_produto"],
    "preco_medio": ["preco_medio", "preco_kg", "preco"],
    "uf": ["uf", "estado", "UF"],
    "data_referencia": ["data_referencia", "competencia", "data"],
}


class ProhortMensalEngine(BaseMicroEngine):
    """
    Micro-motor CONAB ProHort Mensal.
    Baixa ProhortMensal.txt do portal CONAB, extrai preco medio mensal
    por produto/UF a partir de valor_comercializado / qtd_comercializada_kg.
    """

    def __init__(self) -> None:
        super().__init__()

    async def extract(self, url: str, ano: int, mes: int) -> dict[str, Any]:
        logger.info("[PROHORT-MENSAL] Baixando dados para %d-%02d", ano, mes)
        raw = await self._download()
        linhas = self._transform(raw, ano, mes)

        ufs = set()
        for linha in linhas:
            if linha.get("uf"):
                ufs.add(linha["uf"])

        logger.info("[PROHORT-MENSAL] %d linhas para %d-%02d", len(linhas), ano, mes)

        return {
            "fonte_id": "conab-prohort-mensal",
            "payload_bruto": {
                "linhas": linhas,
                "total_linhas": len(linhas),
                "ufs_abrangidas": sorted(ufs),
                "periodo_inicial": f"{ano}-{mes:02d}",
                "periodo_final": f"{ano}-{mes:02d}",
            },
            "competencia": f"{ano}-{mes:02d}",
        }

    async def extract_all(self, ano: int, mes: int) -> list[dict[str, Any]]:
        result = await self.extract("", ano, mes)
        return [result]

    async def _download(self) -> bytes:
        if self._circuit_breaker.esta_aberto:
            raise RuntimeError(f"CircuitBreaker aberto para {self.__class__.__name__}")

        async with self._semaphore:
            async with httpx.AsyncClient(
                timeout=httpx.Timeout(180.0, connect=15.0),
                follow_redirects=True,
            ) as client:
                try:
                    resp = await client.get(
                        URL_PROHORT_MENSAL,
                        headers={"User-Agent": "QueroComprar/2.0"},
                    )
                    resp.raise_for_status()
                    self._circuit_breaker.registrar_sucesso()
                    return resp.content
                except Exception:
                    self._circuit_breaker.registrar_falha()
                    raise

    def _transform(self, raw: bytes | str, ano: int, mes: int) -> list[dict[str, Any]]:
        decoded = self._decodificar(raw)
        linhas: list[dict[str, Any]] = []

        reader = csv.DictReader(io.StringIO(decoded), delimiter=";")

        for row in reader:
            row_stripped = {k.strip(): (v.strip() if v else "") for k, v in row.items()}
            if not self._is_valid(row_stripped):
                continue
            if not self._match_competencia(row_stripped, ano, mes):
                continue
            produto = self._montar_produto(row_stripped)
            if produto:
                linhas.append(produto)

        return linhas

    @staticmethod
    def _decodificar(raw: bytes | str) -> str:
        if isinstance(raw, str):
            return raw
        try:
            return raw.decode("utf-8-sig")
        except UnicodeDecodeError:
            return raw.decode("iso-8859-1")

    @staticmethod
    def _is_valid(row: dict[str, str]) -> bool:
        qtd_raw = row.get("qtd_comercializada_kg", "").strip()
        if not qtd_raw:
            return False
        try:
            qtd = float(qtd_raw.replace(",", "."))
        except (ValueError, TypeError):
            return False
        return qtd > 0

    @staticmethod
    def _match_competencia(row: dict[str, str], ano: int, mes: int) -> bool:
        row_ano = row.get("id_ano_comercializacao", "").strip()
        row_mes = row.get("id_mes_comercializacao", "").strip()
        if not row_ano or not row_mes:
            return False
        try:
            return int(row_ano) == ano and int(row_mes) == mes
        except (ValueError, TypeError):
            return False

    @staticmethod
    def _montar_produto(row: dict[str, str]) -> dict[str, Any] | None:
        nome = row.get("dsc_produto", "").strip().lower()
        if not nome:
            return None

        valor_raw = row.get("valor_comercializado", "0").replace(",", ".")
        qtd_raw = row.get("qtd_comercializada_kg", "0").replace(",", ".")

        try:
            valor = float(valor_raw)
            qtd = float(qtd_raw)
        except (ValueError, TypeError):
            return None

        if qtd <= 0:
            return None

        preco_medio = round(valor / qtd, 4)

        uf = row.get("uf_ceasa", "").strip().upper()[:2]
        if not uf:
            uf = "BR"

        ano_str = row.get("id_ano_comercializacao", "").strip()
        mes_str = row.get("id_mes_comercializacao", "").strip()
        data_ref = f"{ano_str}-{int(mes_str):02d}" if ano_str and mes_str else None

        return {
            "nome_produto": nome,
            "preco_medio": preco_medio,
            "uf": uf,
            "data_referencia": data_ref,
        }

    async def close(self) -> None:
        pass
