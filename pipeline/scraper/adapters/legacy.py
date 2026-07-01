from __future__ import annotations

import asyncio
import logging
import re
from datetime import date, datetime

import httpx
from bs4 import BeautifulSoup

from pipeline.scraper.ceasa_spider import (
    CEAGESPSpider,
    CotacaoHistorica,
    HFBrasilSpider,
    extrair_fator_kg,
    limpar_preco,
)
from pipeline.scraper.price_collector import ScraperAdapter

logger = logging.getLogger(__name__)

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    "Accept-Language": "pt-BR,pt;q=0.9",
}

RE_UNIDADE = re.compile(r"\s+\d+[A-Za-z].*$")
RE_CEASA = re.compile(
    r"CEASA[-\s]*(?P<sigla>[A-Z]{2})\s+(?P<cidade>.+?)\s*\((?P<uf>[A-Z]{2})\)"
)
UF_LIST = [
    "ac", "al", "am", "ap", "ba", "ce", "df", "es", "go", "ma", "mg",
    "ms", "mt", "pa", "pb", "pe", "pi", "pr", "rj", "rn", "ro", "rr",
    "rs", "sc", "se", "sp", "to",
]


def _limpar_produto_agrolink(nome: str) -> str:
    return RE_UNIDADE.sub("", nome).strip()


def _extrair_uf_municipio(ceasa_text: str) -> tuple[str, str]:
    m = RE_CEASA.search(ceasa_text)
    if m:
        return m.group("uf"), m.group("cidade")
    return "BR", ceasa_text


class HFBrasilAdapter(ScraperAdapter):
    def __init__(self, uf: str, municipio: str):
        self.uf = uf
        self.municipio = municipio

    async def fetch(self) -> list[CotacaoHistorica]:
        spider = HFBrasilSpider(self.uf, self.municipio, self.semaforo)
        return await spider.coletar_snapshot(ano=self.ano, mes=self.mes)


class CEAGESPAdapter(ScraperAdapter):
    def __init__(self, uf: str, municipio: str):
        self.uf = uf
        self.municipio = municipio

    async def fetch(self) -> list[CotacaoHistorica]:
        spider = CEAGESPSpider(self.uf, self.municipio, self.semaforo)
        return await spider.coletar_snapshot()


class AgrolinkCEASAAdapter(ScraperAdapter):
    BASE = "https://www.agrolink.com.br/cotacoes/ceasa/ceasa---"

    def __init__(self, ufs: list[str] | None = None):
        self.ufs = ufs or UF_LIST
        self.nome = "AgrolinkCEASA"

    async def fetch(self) -> list[CotacaoHistorica]:
        async with httpx.AsyncClient(headers=HEADERS, timeout=15, follow_redirects=True) as c:
            results: list[CotacaoHistorica] = []
            seen = set()

            for uf in self.ufs:
                url = f"{self.BASE}{uf}"
                try:
                    r = await c.get(url)
                    if r.status_code != 200:
                        continue
                    soup = BeautifulSoup(r.text, "html.parser")
                    table = soup.find("table")
                    if not table:
                        continue
                    rows = table.find_all("tr")
                    header = rows[0] if rows else None
                    data_rows = rows[1:] if header else rows
                    for row in data_rows:
                        cells = row.find_all(["td", "th"])
                        if len(cells) < 4:
                            continue

                        produto_raw = cells[0].get_text(strip=True)
                        ceasa_raw = cells[1].get_text(strip=True)
                        preco_raw = cells[2].get_text(strip=True)
                        data_raw = cells[3].get_text(strip=True)

                        uf_ceasa, municipio = _extrair_uf_municipio(ceasa_raw)
                        produto_clean = _limpar_produto_agrolink(produto_raw)
                        preco = limpar_preco(preco_raw)
                        fator = extrair_fator_kg(produto_raw)

                        parts = data_raw.split("/")
                        if len(parts) != 3:
                            continue
                        try:
                            dt = datetime(int(parts[2]), int(parts[1]), int(parts[0]))
                        except ValueError:
                            continue

                        dedup_key = f"{produto_clean}|{uf_ceasa}|{preco}|{data_raw}"
                        if preco is None or dedup_key in seen:
                            continue
                        seen.add(dedup_key)

                        results.append(CotacaoHistorica(
                            produto_original=produto_clean,
                            uf=uf_ceasa,
                            municipio=municipio,
                            ano=dt.year,
                            mes=dt.month,
                            preco_bruto=preco,
                            fator_kg=fator,
                            fonte="Agrolink CEASA",
                            data_coleta=dt.date().isoformat(),
                        ))
                except Exception as e:
                    logger.warning("Agrolink %s falhou: %s", uf, e)
                    continue

            logger.info("AgrolinkCEASAAdapter: %d cotacoes de %d UFs", len(results), len(self.ufs))
            return results


def adapter_discovery(localidade: dict) -> ScraperAdapter | None:
    logger.warning(
        "Nenhum adapter implementado para fonte '%s' (%s-%s). "
        "Crie um adapter em adapters.py e registre manualmente.",
        localidade.get("fonte", "?"),
        localidade.get("uf", "?"),
        localidade.get("municipio", "?"),
    )
    return None
