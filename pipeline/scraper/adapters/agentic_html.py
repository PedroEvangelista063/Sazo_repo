from __future__ import annotations

import asyncio
import logging
import re

import httpx
from bs4 import BeautifulSoup

from pipeline.scraper.adapters.base import CotacaoRegional, validar_cotacao
from pipeline.scraper.url_manager import (
    ColumnMapping,
    PaginationConfig,
    _is_static_url,
    baixar_arquivo_estatico,
    resolver_url_template,
)

logger = logging.getLogger(__name__)

BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/125.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7",
}

PRODUTOS_ALVO = [
    "tomate", "cebola", "batata", "cenoura", "alface", "beterraba",
    "abobrinha", "pepino", "pimentao", "banana", "laranja", "maca",
    "mamao", "uva", "melancia", "morango", "abacate", "abacaxi",
    "manga", "goiaba", "maracuja", "limao", "repolho", "vagem",
    "milho", "batata doce", "mandioca", "alho", "cebolinha", "couve",
    "couve-flor", "brocolis", "espinafre",
]

RE_PRECO_PROXIMO = re.compile(
    r"(?P<produto>" + "|".join(PRODUTOS_ALVO) + r").{0,60}?R?\$?\s*(?P<preco>[\d.,]+)",
    re.IGNORECASE,
)

RE_PRECO_TABELA = re.compile(
    r"(?P<produto>\w[\w\s]+?)\s{2,}(?P<preco>R?\$?\s*[\d.,]+)",
)

RE_PRECO_ISOLADO = re.compile(r"R?\$?\s*([\d.,]+)")


class AgenticHtmlAdapter:
    """Category D: Fast httpx-based adapter for legacy CEASA sites.

    Features (2026):
      - URL templates with {YYYY}, {MM}, {DATA}, {PAGE} placeholders
      - Automatic pagination (iterates ?pagina=N while table is full)
      - Static file download (.csv, .xls, .xlsx -> polars)
      - Fallback chain with multiple URLs
    """

    def __init__(
        self,
        url: str = "",
        url_template: str = "",
        uf: str = "",
        municipio: str = "",
        fonte: str = "",
        urls_fallback: list[str] | None = None,
        ano: int | None = None,
        mes: int | None = None,
        pagination: PaginationConfig | None = None,
        columns: ColumnMapping | None = None,
    ):
        self.url = url
        self.url_template = url_template
        self.uf = uf
        self.municipio = municipio
        self.fonte = fonte
        self._urls_fallback = urls_fallback or []
        self.ano = ano
        self.mes = mes
        self.pagination = pagination
        self.columns = columns

    async def fetch(self) -> list[CotacaoRegional]:
        urls_tentar: list[str] = []

        if self.url_template:
            resolved = resolver_url_template(
                self.url_template, ano=self.ano, mes=self.mes, uf=self.uf
            )
            urls_tentar.append(resolved)
        elif self.url:
            urls_tentar.append(self.url)

        urls_tentar.extend(self._urls_fallback)

        if not urls_tentar:
            logger.warning("[AgenticHtml] Nenhuma URL configurada para %s", self.fonte)
            return []

        async with httpx.AsyncClient(
            verify=False, timeout=15.0, headers=BROWSER_HEADERS, follow_redirects=True
        ) as client:
            for url in urls_tentar:
                if not url:
                    continue
                try:
                    if _is_static_url(url):
                        resultados = await baixar_arquivo_estatico(
                            url,
                            columns=self.columns,
                            uf=self.uf,
                            municipio=self.municipio,
                            fonte=self.fonte or "CEASA",
                            ano=self.ano,
                            mes=self.mes,
                        )
                        if resultados:
                            return resultados
                        continue

                    logger.info("[AgenticHtml] Tentando %s", url)
                    response = await client.get(url)
                    response.raise_for_status()

                    ct = response.headers.get("content-type", "")
                    if _is_static_url(url) or "csv" in ct or "excel" in ct or "spreadsheet" in ct:
                        resultados = await baixar_arquivo_estatico(
                            url,
                            columns=self.columns,
                            uf=self.uf,
                            municipio=self.municipio,
                            fonte=self.fonte or "CEASA",
                            ano=self.ano,
                            mes=self.mes,
                        )
                        if resultados:
                            return resultados
                        continue

                    resultados = await self._fetch_with_pagination(client, url)
                    if resultados:
                        return resultados

                    logger.debug("[AgenticHtml] 0 resultados em %s, tentando fallback...", url)
                except Exception as e:
                    logger.debug("[AgenticHtml] Falha em %s: %s, tentando fallback...", url, e)

            logger.error("[AgenticHtml] Todas as URLs falharam para %s.", self.fonte)
            return []

    async def _fetch_with_pagination(
        self, client: httpx.AsyncClient, base_url: str
    ) -> list[CotacaoRegional]:
        html = await self._fetch_page(client, base_url)
        if not html:
            return []

        resultados = self._extract(html)
        if not self.pagination or not resultados:
            return resultados

        pagina = self.pagination.page_start + self.pagination.page_step
        max_pages = self.pagination.max_pages
        min_rows = self.pagination.min_rows_to_paginate

        while len(resultados) >= min_rows and pagina <= (self.pagination.max_pages + self.pagination.page_start - 1):
            page_url = resolver_url_template(
                base_url, ano=self.ano, mes=self.mes, page=pagina, uf=self.uf
            )
            logger.info(
                "[AgenticHtml] Pagina %d: %s (ja temos %d resultados)",
                pagina, page_url, len(resultados),
            )

            html_page = await self._fetch_page(client, page_url)
            if not html_page:
                break

            pagina_resultados = self._extract(html_page)
            if not pagina_resultados:
                if self.pagination.stop_on_empty:
                    break
                pagina += self.pagination.page_step
                continue

            if self.pagination.stop_on_duplicate:
                existing_products = {r.produto_original for r in resultados}
                new_products = [
                    r for r in pagina_resultados
                    if r.produto_original not in existing_products
                ]
                if not new_products:
                    logger.info("[AgenticHtml] Pagina %d: todos os produtos ja vistos, parando", pagina)
                    break
                resultados.extend(new_products)
            else:
                resultados.extend(pagina_resultados)

            pagina += self.pagination.page_step

        logger.info("[AgenticHtml] Total com paginacao: %d cotacoes", len(resultados))
        return resultados

    async def _fetch_page(
        self, client: httpx.AsyncClient, url: str
    ) -> str | None:
        try:
            resp = await client.get(url)
            resp.raise_for_status()
            return resp.text
        except Exception as e:
            logger.debug("[AgenticHtml] _fetch_page falhou em %s: %s", url, e)
            return None

    def _extract(self, html: str) -> list[CotacaoRegional]:
        resultados: list[CotacaoRegional] = []

        resultados = self._parse_tables(html)
        if resultados:
            return resultados

        resultados = self._parse_text_heuristic(html)
        if resultados:
            return resultados

        resultados = self._parse_regex_fallback(html)

        return resultados

    def _parse_tables(self, html: str) -> list[CotacaoRegional]:
        soup = BeautifulSoup(html, "lxml")
        resultados: list[CotacaoRegional] = []

        for table in soup.find_all("table"):
            rows = table.find_all("tr")
            if len(rows) < 2:
                continue

            header_text = " ".join(
                c.get_text(strip=True).lower() for c in rows[0].find_all(["th", "td"])
            )
            if not any(k in header_text for k in ("produto", "preco", "cotacao", "item")):
                continue

            headers = [c.get_text(strip=True).lower() for c in rows[0].find_all(["th", "td"])]
            col_produto = self._find_col(headers, ["produto", "item", "descricao", "especificacao"])
            col_preco = self._find_col(
                headers, ["preco medio", "preco", "preço", "valor", "cotacao"]
            )

            if col_produto is None:
                col_produto = 0
            if col_preco is None:
                col_preco = min(len(headers) - 1, 1)

            for row in rows[1:]:
                cells = row.find_all(["td", "th"])
                if len(cells) <= max(col_produto, col_preco):
                    continue

                produto = cells[col_produto].get_text(strip=True)
                if not produto or len(produto) < 3:
                    continue

                preco_raw = cells[col_preco].get_text(strip=True)
                preco = self._limpar_preco(preco_raw)
                if preco is None:
                    continue

                cot = self._make_cotacao(produto, preco)
                if cot:
                    resultados.append(cot)

            if resultados:
                break

        return resultados

    def _parse_text_heuristic(self, html: str) -> list[CotacaoRegional]:
        soup = BeautifulSoup(html, "lxml")
        text = soup.get_text(separator=" ")
        resultados: list[CotacaoRegional] = []

        for match in RE_PRECO_PROXIMO.finditer(text):
            produto = match.group("produto").strip().capitalize()
            preco_raw = match.group("preco")
            preco = self._limpar_preco(preco_raw)
            if preco is not None:
                cot = self._make_cotacao(produto, preco)
                if cot:
                    resultados.append(cot)

        return resultados

    def _parse_regex_fallback(self, html: str) -> list[CotacaoRegional]:
        soup = BeautifulSoup(html, "lxml")
        text = soup.get_text(separator=" ")
        resultados: list[CotacaoRegional] = []

        for match in RE_PRECO_TABELA.finditer(text):
            produto = match.group("produto").strip().capitalize()
            preco_raw = match.group("preco")
            preco = self._limpar_preco(preco_raw)
            if preco is not None and len(produto) >= 3:
                cot = self._make_cotacao(produto, preco)
                if cot:
                    resultados.append(cot)

        return resultados

    def _make_cotacao(self, produto: str, preco: float) -> CotacaoRegional | None:
        cot = CotacaoRegional(
            produto_original=produto,
            preco_bruto=preco,
            uf=self.uf,
            municipio=self.municipio,
            fonte=self.fonte or "CEASA",
            ano=self.ano or 0,
            mes=self.mes or 0,
            status_coleta="sucesso",
        )
        return validar_cotacao(cot)

    @staticmethod
    def _find_col(headers: list[str], candidates: list[str]) -> int | None:
        for i, h in enumerate(headers):
            for c in candidates:
                if c in h:
                    return i
        return None

    @staticmethod
    def _limpar_preco(v: str) -> float | None:
        if not v or v.strip() in ("-", "--", "", "- - -", "n/d", "N/D", "s/ info"):
            return None
        v = v.replace("R$", "").replace("r$", "").replace(" ", "")
        v = v.replace(".", "").replace(",", ".")
        try:
            return float(v)
        except ValueError:
            return None


async def coletar_multiplos_agentic(
    alvos: list[dict],
    max_concorrencia: int = 5,
) -> dict[str, list[CotacaoRegional]]:
    sem = asyncio.Semaphore(max_concorrencia)
    resultados: dict[str, list[CotacaoRegional]] = {}

    async def _coletar(alvo: dict):
        async with sem:
            adapter = AgenticHtmlAdapter(
                url=alvo.get("url", ""),
                url_template=alvo.get("url_template", ""),
                uf=alvo.get("uf", ""),
                municipio=alvo.get("municipio", ""),
                fonte=alvo.get("fonte", ""),
                urls_fallback=alvo.get("urls_fallback", []),
                ano=alvo.get("ano"),
                mes=alvo.get("mes"),
                pagination=alvo.get("pagination"),
                columns=alvo.get("columns"),
            )
            items = await adapter.fetch()
            resultados[alvo.get("url", "") or alvo.get("url_template", "")] = items

    tasks = [_coletar(a) for a in alvos]
    await asyncio.gather(*tasks, return_exceptions=True)
    return resultados
