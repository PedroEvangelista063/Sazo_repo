from __future__ import annotations

import asyncio
import logging
import re
from typing import Any

import httpx
from bs4 import BeautifulSoup

from pipeline.scraper.micro_engines.base_engine import BaseMicroEngine

logger = logging.getLogger(__name__)

URL_PRECOSIAGROWEB = "https://sisdep.conab.gov.br/precosiagroweb/"
UFS_ALVO = ["AC", "AM", "AP", "MS", "PI", "RO", "RR", "SE"]
MESES_2024 = list(range(1, 13))

_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    "Content-Type": "application/x-www-form-urlencoded",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7",
}

_DATA_RE = re.compile(r"(\d{4})-(\d{2})|(\d{2})/(\d{4})")
_PRECO_RE = re.compile(r"(\d+[.,]\d+)")

_HEADER_NAMES = frozenset(
    {
        "produto",
        "item",
        "preço",
        "preco",
        "r$",
        "categoria",
        "classif",
        "embalagem",
        "unidade",
        "data",
        "período",
        "periodo",
    }
)


class PrecosiagrowebEngine(BaseMicroEngine):
    URL = URL_PRECOSIAGROWEB
    UFS_ALVO = UFS_ALVO
    MESES_2024 = MESES_2024

    def __init__(self) -> None:
        super().__init__()
        self._http_client: httpx.AsyncClient | None = None

    async def _ensure_client(self) -> httpx.AsyncClient:
        if self._http_client is None:
            self._http_client = httpx.AsyncClient(
                timeout=httpx.Timeout(60.0, connect=15.0),
                follow_redirects=True,
            )
        return self._http_client

    async def extract(  # type: ignore[override]
        self,
        url: str,
        ano: int,
        mes: int,
    ) -> dict[str, Any]:
        if self._circuit_breaker.esta_aberto:
            raise RuntimeError(f"CircuitBreaker aberto para {self.__class__.__name__}")

        periodo = f"{ano}-{mes:02d}"
        sem = asyncio.Semaphore(3)

        async def _extrair_uf_semaforo(uf: str) -> dict[str, Any]:
            async with sem:
                return await self._processar_com_fallback(uf, periodo)

        tarefas = [_extrair_uf_semaforo(uf) for uf in self.UFS_ALVO]
        todos_linhas: list[dict[str, Any]] = []
        total_req = 0

        for coro in asyncio.as_completed(tarefas):
            try:
                result = await coro
                linhas = result.get("payload_bruto", {}).get("linhas", [])
                todos_linhas.extend(linhas)
                total_req += 1
            except (httpx.HTTPError, OSError, RuntimeError) as exc:
                logger.error("[PRECOSIAGROWEB] Erro em UF para %s: %s", periodo, exc)

        return {
            "fonte_id": "precosiagroweb",
            "payload_bruto": {
                "linhas": todos_linhas,
                "total_requisicoes": total_req,
                "ufs": list(self.UFS_ALVO),
                "periodo": {"inicio": periodo, "fim": periodo},
            },
            "competencia": periodo,
        }

    async def _extract_uf(self, uf: str, periodo: str) -> dict[str, Any]:
        if self._circuit_breaker.esta_aberto:
            raise RuntimeError(f"CircuitBreaker aberto para {self.__class__.__name__}")

        html = await self._postar(uf, "", periodo, periodo)
        linhas = await self.transform(html)

        for linha in linhas:
            linha["uf"] = uf
            linha["data_referencia"] = periodo

        return {
            "fonte_id": "precosiagroweb",
            "payload_bruto": {
                "linhas": linhas,
                "total_linhas": len(linhas),
            },
            "competencia": periodo,
        }

    async def transform(self, html: str) -> list[dict[str, Any]]:
        soup = BeautifulSoup(html, "html.parser")
        linhas: list[dict[str, Any]] = []

        for table in soup.find_all("table"):
            for tr in table.find_all("tr"):
                celulas = tr.find_all(["td", "th"])
                textos = [c.get_text(strip=True) for c in celulas]

                if len(textos) < 2:
                    continue

                nome = textos[0].strip().lower()
                if not nome or len(nome) < 2 or nome in _HEADER_NAMES:
                    continue

                preco_val: float | None = None
                data_ref: str | None = None

                for texto in textos[1:]:
                    t = texto.strip()
                    if data_ref is None:
                        dm = _DATA_RE.search(t)
                        if dm:
                            p = dm.groups()
                            if p[0] and p[1]:
                                data_ref = f"{p[0]}-{p[1]}"
                            elif p[2] and p[3]:
                                data_ref = f"{p[3]}-{p[2]}"

                    if preco_val is None:
                        pm = _PRECO_RE.search(t.replace("R$", "").strip())
                        if pm:
                            try:
                                v = float(pm.group(1).replace(",", "."))
                                if v > 0:
                                    preco_val = v
                            except ValueError:
                                continue

                if preco_val is None:
                    continue

                linhas.append(
                    {
                        "nome_produto": nome,
                        "preco_kg": preco_val,
                        "uf": "",
                        "data_referencia": data_ref,
                    }
                )

        return linhas

    async def _postar(
        self,
        uf: str,
        produto_codigo: str,
        periodo_inicial: str,
        periodo_final: str,
    ) -> str:
        if self._circuit_breaker.esta_aberto:
            raise RuntimeError(f"CircuitBreaker aberto para {self.__class__.__name__}")

        async with self._semaphore:
            last_exc: Exception | None = None
            for attempt in range(3):
                try:
                    client = await self._ensure_client()
                    resp = await client.post(
                        self.URL,
                        data={
                            "periodo_inicial": periodo_inicial,
                            "periodo_final": periodo_final,
                            "produto": produto_codigo,
                            "uf": uf,
                        },
                        headers=_HEADERS,
                    )
                    resp.raise_for_status()
                    self._circuit_breaker.registrar_sucesso()
                    return resp.text
                except (httpx.HTTPError, ConnectionError, TimeoutError, OSError) as exc:
                    last_exc = exc
                    if attempt < 2:
                        delay = 2.0 * (2.0**attempt)
                        await asyncio.sleep(delay)
                    else:
                        self._circuit_breaker.registrar_falha()

            raise last_exc  # type: ignore[misc]

    async def _processar_com_fallback(self, uf: str, periodo: str) -> dict[str, Any]:
        ano, mes = map(int, periodo.split("-"))
        try:
            result = await self._extract_uf(uf, periodo)
            for linha in result.get("payload_bruto", {}).get("linhas", []):
                linha["uf"] = uf
                linha["data_referencia"] = periodo
            return result
        except (httpx.HTTPError, OSError, RuntimeError) as exc:
            logger.warning(
                "[PRECOSIAGROWEB] POST falhou, tentando fallback B: UF=%s periodo=%s err=%s",
                uf,
                periodo,
                exc,
            )
            fb = await self._fallback_serie_historica(uf, ano, mes)
            if fb:
                return {
                    "fonte_id": "precosiagroweb",
                    "payload_bruto": {"linhas": fb, "total_linhas": len(fb)},
                    "competencia": periodo,
                }
            logger.warning(
                "[PRECOSIAGROWEB] Fallbacks exauridos para UF=%s periodo=%s", uf, periodo
            )
            return {
                "fonte_id": "precosiagroweb",
                "payload_bruto": {"linhas": [], "total_linhas": 0},
                "competencia": periodo,
                "pendente": True,
                "erro": str(exc),
            }

    async def _fallback_serie_historica(self, uf: str, ano: int, mes: int) -> list[dict] | None:
        url = "https://portaldeinformacoes.conab.gov.br/precos-agropecuarios-serie-historica"
        try:
            client = await self._ensure_client()
            resp = await client.get(url, follow_redirects=True)
            resp.raise_for_status()
            logger.info(
                "[PRECOSIAGROWEB] Fallback Serie Historica ok para %s %d-%02d", uf, ano, mes
            )
            return []
        except (httpx.HTTPError, OSError) as exc:
            logger.warning("[PRECOSIAGROWEB] Fallback Serie Historica falhou: %s", exc)
            return None

    async def process_all_ufs(self) -> list[dict[str, Any]]:
        tarefas = []
        for uf in self.UFS_ALVO:
            for mes in self.MESES_2024:
                periodo = f"2024-{mes:02d}"
                tarefas.append(self._processar_com_fallback(uf, periodo))

        resultados: list[dict[str, Any]] = []
        for coro in asyncio.as_completed(tarefas):
            try:
                resultados.append(await coro)
            except (httpx.HTTPError, OSError, RuntimeError) as exc:
                logger.error("[PRECOSIAGROWEB] Erro inesperado: %s", exc)

        return resultados

    async def extract_all(self, ano: int, mes: int) -> list[dict[str, Any]]:
        result = await self.extract("", ano, mes)
        return [result]

    async def close(self) -> None:
        if self._http_client is not None:
            await self._http_client.aclose()
