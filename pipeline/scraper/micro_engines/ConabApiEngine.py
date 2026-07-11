from __future__ import annotations

import csv
import io
import logging
from typing import Any

import httpx

from pipeline.scraper.micro_engines.base_engine import BaseMicroEngine

logger = logging.getLogger(__name__)

ANO_MINIMO = 2022
ANO_MAXIMO = 2026

URL_DIARIO = (
    "https://portaldeinformacoes.conab.gov.br/downloads/arquivos/ProhortDiario.txt"
)


class ConabApiEngine(BaseMicroEngine):
    """
    Micro-motor CONAB — baixa ProhortDiario.txt direto do portal CONAB.
    CSV ~30MB, ~2M linhas, cobertura nacional desde 2022.
    Filtra por ano/mês no lado do cliente.
    """

    COLUNAS = [
        "municipio_ceasa",
        "cod_ibge_municipio",
        "uf_ceasa",
        "dsc_ceasa",
        "dsc_produto",
        "sig_unidade_medida",
        "data_preco",
        "preco_diario",
    ]

    async def extract(self, url: str, ano: int, mes: int) -> dict[str, Any]:
        if ano < ANO_MINIMO or ano > ANO_MAXIMO:
            raise ValueError(f"Ano {ano} fora da janela {ANO_MINIMO}-{ANO_MAXIMO}")

        competencia = f"{ano}-{mes:02d}"
        logger.info("[CONAB] Baixando ProhortDiario.txt (~30MB) para %s", competencia)

        raw = await self._download_csv()
        linhas = self._parse_csv(raw)
        filtradas = self._filtrar(linhas, ano, mes)

        logger.info(
            "[CONAB] %d linhas filtradas para %s (de %d totais)",
            len(filtradas), competencia, len(linhas),
        )

        return {
            "fonte_id": "CONAB-PENTAHO",
            "payload_bruto": {
                "linhas": filtradas,
                "total_linhas": len(linhas),
                "competencias_disponiveis": self._competencias(linhas),
            },
            "competencia": competencia,
        }

    async def extract_all(self, ano: int, mes: int) -> list[dict[str, Any]]:
        result = await self.extract("", ano, mes)
        return [result]

    async def _download_csv(self) -> str:
        async with self._semaphore:
            async with httpx.AsyncClient(
                timeout=httpx.Timeout(120.0, connect=15.0),
                follow_redirects=True,
            ) as client:
                resp = await client.get(
                    URL_DIARIO,
                    headers={"User-Agent": "QueroComprar/2.0"},
                )
                resp.raise_for_status()
                self._circuit_breaker.registrar_sucesso()
                return resp.content.decode("iso-8859-1")

    def _parse_csv(self, raw: str) -> list[dict[str, str]]:
        linhas: list[dict[str, str]] = []
        reader = csv.DictReader(
            io.StringIO(raw),
            delimiter=";",
            fieldnames=self.COLUNAS,
        )
        for i, row in enumerate(reader):
            if i == 0:
                pular = any(
                    k in (row.get(k, "") or "") for k in self.COLUNAS
                )
                if pular:
                    continue
            linhas.append(row)
        return linhas

    def _filtrar(
        self, linhas: list[dict[str, str]], ano: int, mes: int
    ) -> list[dict[str, str]]:
        prefixo = f"{ano}/{mes:02d}"
        filtradas = []
        for row in linhas:
            data = (row.get("data_preco") or "").strip()
            if data.startswith(prefixo):
                filtradas.append(row)
        return filtradas

    @staticmethod
    def _competencias(linhas: list[dict[str, str]]) -> list[str]:
        comps: set[str] = set()
        for row in linhas:
            data = (row.get("data_preco") or "").strip()[:7]
            if data:
                comps.add(data.replace("/", "-"))
        return sorted(comps, reverse=True)

    async def close(self) -> None:
        pass
