from __future__ import annotations

import asyncio
import logging
import re
from datetime import datetime

import httpx
from bs4 import BeautifulSoup

from pipeline.scraper.adapters.base import BaseAdapter, CotacaoRegional
from pipeline.scraper.retry import retry_request

logger = logging.getLogger(__name__)

BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/125.0.0.0 Safari/537.36"
    ),
    "Accept-Language": "pt-BR,pt;q=0.9",
}

CEASA_REGISTRY: dict[str, dict] = {
    "CEASA-PR": {
        "url": "https://www.ceasa.pr.gov.br/cotacao",
        "tipo": "form_search",
        "form_data": {"cotacao": "1", "produto": ""},
        "uf": "PR",
        "municipio": "Curitiba",
        "urls_fallback": [
            "https://www.ceasa.pr.gov.br/cotacoes",
            "https://www.agricultura.pr.gov.br/cotacao",
        ],
    },
    "CEASA-GO": {
        "url": "https://goias.gov.br/ceasa/cotacao",
        "tipo": "table",
        "uf": "GO",
        "municipio": "Goiania",
        "urls_fallback": [
            "https://www.ceasa.go.gov.br/cotacao",
            "https://goias.gov.br/ceasa",
        ],
    },
    "CEASA-CE": {
        "url": "https://www.ceasa.ce.gov.br/cotacao",
        "tipo": "table",
        "uf": "CE",
        "municipio": "Maracanau",
        "urls_fallback": [],
    },
    "CEASA-RS": {
        "url": "https://ceasa.rs.gov.br/cotacao",
        "tipo": "table",
        "uf": "RS",
        "municipio": "Porto Alegre",
        "urls_fallback": [
            "https://www.ceasa.rs.gov.br/cotacao",
            "https://ceasa.rs.gov.br",
        ],
    },
    "CEASA-SC": {
        "url": "https://www.ceasa.sc.gov.br/cotacoes",
        "tipo": "table",
        "uf": "SC",
        "municipio": "Sao Jose",
        "urls_fallback": [
            "https://www.ceasa.sc.gov.br",
        ],
    },
    "CEASA-BA": {
        "url": "https://www.ceasa.ba.gov.br/cotacao",
        "tipo": "table",
        "uf": "BA",
        "municipio": "Salvador",
        "urls_fallback": [],
    },
    "CEASA-MG": {
        "url": "https://www.ceasa.mg.gov.br/cotacoes",
        "tipo": "table",
        "uf": "MG",
        "municipio": "Contagem",
        "urls_fallback": [],
    },
    "CEASA-DF": {
        "url": "https://www.ceasa.df.gov.br/",
        "tipo": "table",
        "uf": "DF",
        "municipio": "Brasilia",
        "urls_fallback": [],
    },
}


class CeasaStandardAdapter(BaseAdapter):
    nome = "CeasaStandard"
    fonte = ""

    def __init__(
        self,
        fonte: str = "",
        uf: str = "",
        municipio: str = "",
        url: str | None = None,
        tipo: str = "table",
        urls_fallback: list[str] | None = None,
    ):
        self.fonte = fonte
        self.uf = uf
        self.municipio = municipio
        self._url = url
        self._tipo = tipo
        self._urls_fallback = urls_fallback or []

    @classmethod
    def from_registry(cls, nome_fonte: str) -> CeasaStandardAdapter | None:
        cfg = CEASA_REGISTRY.get(nome_fonte)
        if not cfg:
            return None
        return cls(
            fonte=nome_fonte,
            uf=cfg["uf"],
            municipio=cfg["municipio"],
            url=cfg.get("url", cfg.get("urls_fallback", [None])[0] if cfg.get("urls_fallback") else None),
            tipo=cfg["tipo"],
            urls_fallback=cfg.get("urls_fallback", []),
        )

    @retry_request(retries=3, delay=5)
    async def fetch(self) -> list[CotacaoRegional]:
        if self._tipo == "form_search":
            return await self._fetch_form_search()
        return await self._fetch_table()

    async def _fetch_form_search(self) -> list[CotacaoRegional]:
        urls_tentar = [self._url] + self._urls_fallback if self._url else self._urls_fallback
        if not urls_tentar:
            logger.warning("%s: nenhuma URL configurada para form_search", self.fonte)
            return []

        async with httpx.AsyncClient(
            headers=BROWSER_HEADERS, timeout=30, follow_redirects=True
        ) as client:
            ultimo_erro: Exception | None = None
            for url in urls_tentar:
                if not url:
                    continue
                try:
                    r = await client.get(url)
                    r.raise_for_status()
                    soup = BeautifulSoup(r.text, "html.parser")
                    form = soup.find("form")
                    if form:
                        action = form.get("action", "")
                        inputs = form.find_all("input")
                        data = {}
                        for inp in inputs:
                            name = inp.get("name")
                            if name:
                                data[name] = inp.get("value", "")
                        if action:
                            post_url = action if action.startswith("http") else url.rstrip("/") + "/" + action.lstrip("/")
                        else:
                            post_url = url
                        r2 = await client.post(post_url, data=data)
                        r2.raise_for_status()
                        soup = BeautifulSoup(r2.text, "html.parser")
                    resultados = self._parse_table(soup)
                    if resultados:
                        logger.info("%s: %d cotacoes de %s (form_search)", self.fonte, len(resultados), url)
                        return resultados
                except (httpx.HTTPStatusError, httpx.ConnectError, httpx.TimeoutException) as e:
                    ultimo_erro = e
                    logger.debug("%s: falhou em %s: %s, tentando fallback...", self.fonte, url, e)

            logger.warning("%s: form_search esgotou URLs. Ultimo erro: %s", self.fonte, ultimo_erro)
            return []

    async def _fetch_table(self) -> list[CotacaoRegional]:
        urls_tentar = [self._url] + self._urls_fallback if self._url else self._urls_fallback
        if not urls_tentar:
            logger.warning("%s: nenhuma URL configurada", self.fonte)
            return []

        async with httpx.AsyncClient(
            headers=BROWSER_HEADERS, timeout=30, follow_redirects=True
        ) as client:
            ultimo_erro: Exception | None = None
            for url in urls_tentar:
                if not url:
                    continue
                try:
                    r = await client.get(url)
                    r.raise_for_status()
                    soup = BeautifulSoup(r.text, "html.parser")
                    resultados = self._parse_table(soup)
                    if resultados:
                        logger.info("%s: %d cotacoes de %s", self.fonte, len(resultados), url)
                        return resultados
                    logger.debug("%s: 0 cotacoes de %s, tentando fallback...", self.fonte, url)
                except httpx.HTTPStatusError as e:
                    ultimo_erro = e
                    logger.debug("%s: HTTP %s em %s, tentando fallback...", self.fonte, e.response.status_code, url)
                except (httpx.ConnectError, httpx.TimeoutException) as e:
                    ultimo_erro = e
                    logger.debug("%s: conexao falhou em %s: %s", self.fonte, url, e)

            logger.warning("%s: todas as URLs falharam. Ultimo erro: %s", self.fonte, ultimo_erro)
            return []

    def _parse_table(self, soup: BeautifulSoup) -> list[CotacaoRegional]:
        resultados: list[CotacaoRegional] = []
        seen = set()

        tabelas = soup.find_all("table")
        if not tabelas:
            tabelas_alternativas = soup.find_all("div", class_=re.compile(r"(table|grid|cotacao|preco)", re.I))
            if not tabelas_alternativas:
                logger.warning("%s: nenhuma tabela encontrada", self.fonte)
                return resultados

        for tabela in tabelas:
            rows = tabela.find_all("tr")
            if len(rows) < 2:
                continue
            header_cells = rows[0].find_all(["th", "td"])
            headers = [h.get_text(strip=True).lower() for h in header_cells]

            col_produto = self._find_col(headers, ["produto", "produto", "descricao", "item", "especificacao"])
            col_preco_min = self._find_col(headers, ["preco min", "preco minimo", "minimo", "menor", "min"])
            col_preco_max = self._find_col(headers, ["preco max", "preco maximo", "maximo", "maior", "max"])
            col_preco_med = self._find_col(headers, ["preco medio", "preco médio", "medio", "preco", "preço", "preco comum", "comum"])
            col_unidade = self._find_col(headers, ["unidade", "und", "embalagem", "emablagem"])
            col_data = self._find_col(headers, ["data", "data cotacao", "dt cotacao", "periodo", "referencia"])
            col_uf = self._find_col(headers, ["uf", "estado"])

            if col_produto is None:
                continue

            for row in rows[1:]:
                cells = row.find_all(["td", "th"])
                if len(cells) < col_produto + 1:
                    continue

                produto_raw = cells[col_produto].get_text(strip=True) if col_produto < len(cells) else ""
                if not produto_raw or produto_raw.lower() in ("produto", "item", ""):
                    continue

                preco_min = self.limpar_valor(cells[col_preco_min].get_text(strip=True)) if col_preco_min is not None and col_preco_min < len(cells) else None
                preco_max = self.limpar_valor(cells[col_preco_max].get_text(strip=True)) if col_preco_max is not None and col_preco_max < len(cells) else None
                preco_med = self.limpar_valor(cells[col_preco_med].get_text(strip=True)) if col_preco_med is not None and col_preco_med < len(cells) else None

                unidade_raw = cells[col_unidade].get_text(strip=True) if col_unidade is not None and col_unidade < len(cells) else ""
                fator = self.normalizar_unidade(unidade_raw)

                data_raw = cells[col_data].get_text(strip=True) if col_data is not None and col_data < len(cells) else ""
                periodo = self.extrair_periodo(data_raw)

                uf_row = cells[col_uf].get_text(strip=True) if col_uf is not None and col_uf < len(cells) else self.uf

                preco_bruto = preco_med or preco_min or 0.0
                if preco_bruto <= 0:
                    continue

                produto_norm = self.normalizar_produto(produto_raw)

                dedup_key = f"{produto_norm}|{uf_row}|{preco_bruto}|{data_raw}"
                if dedup_key in seen:
                    continue
                seen.add(dedup_key)

                resultados.append(CotacaoRegional(
                    produto_original=produto_raw,
                    produto_normalizado=produto_norm,
                    uf=uf_row,
                    municipio=self.municipio,
                    ano=periodo[0] if periodo else 0,
                    mes=periodo[1] if periodo else 0,
                    data_cotacao=data_raw,
                    fonte=self.fonte,
                    unidade_medida=unidade_raw,
                    preco_min=preco_min,
                    preco_max=preco_max,
                    preco_medio=preco_med,
                    preco_bruto=preco_bruto,
                    fator_kg=fator,
                    status_coleta="sucesso",
                ))

        logger.info("%s: %d cotacoes", self.fonte, len(resultados))
        return resultados

    @staticmethod
    def _find_col(headers: list[str], candidates: list[str]) -> int | None:
        for i, h in enumerate(headers):
            for cand in candidates:
                if cand in h:
                    return i
        return None
