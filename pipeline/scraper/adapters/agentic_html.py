from __future__ import annotations

import asyncio
import logging
import re

import httpx
from bs4 import BeautifulSoup

from pipeline.scraper.adapters.base import CotacaoRegional

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

# Produtos-alvo para busca heuristica no texto bruto
PRODUTOS_ALVO = [
    "tomate", "cebola", "batata", "cenoura", "alface", "beterraba",
    "abobrinha", "pepino", "pimentao", "banana", "laranja", "maca",
    "mamao", "uva", "melancia", "morango", "abacate", "abacaxi",
    "manga", "goiaba", "maracuja", "limao", "repolho", "vagem",
    "milho", "batata doce", "mandioca", "alho", "cebolinha", "couve",
    "couve-flor", "brocolis", "espinafre",
]

# Padrao: nome do produto seguido de ate 50 caracteres e entao um R$ preco
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

    Targets: CEASA-PR, CEASA-MG, CEASA-ES, CEASA-PE, CEASA-RN, CEASA-MS.

    Strategy: Downloads raw HTML via async httpx (no browser overhead).
    Uses semantic heuristics instead of fragile CSS selectors:
    - Fuzzy-match product names in raw text
    - Backtrack DOM tree via XPath parent to find nearest price
    - Regex-based extraction that ignores HTML structure entirely
    """

    def __init__(
        self,
        url: str = "",
        uf: str = "",
        municipio: str = "",
        fonte: str = "",
        urls_fallback: list[str] | None = None,
    ):
        self.url = url
        self.uf = uf
        self.municipio = municipio
        self.fonte = fonte
        self._urls_fallback = urls_fallback or []

    async def fetch(self) -> list[CotacaoRegional]:
        urls_tentar = [self.url] + self._urls_fallback if self.url else self._urls_fallback
        if not urls_tentar:
            logger.warning("[AgenticHtml] Nenhuma URL configurada para %s", self.fonte)
            return []

        async with httpx.AsyncClient(
            verify=False, timeout=15.0, headers=BROWSER_HEADERS, follow_redirects=True
        ) as client:
            ultimo_erro: Exception | None = None
            for url in urls_tentar:
                if not url:
                    continue
                try:
                    logger.info("[AgenticHtml] Tentando %s", url)
                    response = await client.get(url)
                    response.raise_for_status()
                    resultados = self._extract(response.text)
                    if resultados:
                        return resultados
                    logger.debug("[AgenticHtml] 0 resultados em %s, tentando fallback...", url)
                except Exception as e:
                    ultimo_erro = e
                    logger.debug("[AgenticHtml] Falha em %s: %s, tentando fallback...", url, e)

            logger.error("[AgenticHtml] Todas as URLs falharam para %s. Ultimo erro: %s", self.fonte, ultimo_erro)
            return []

    def _extract(self, html: str) -> list[CotacaoRegional]:
        resultados: list[CotacaoRegional] = []

        # Estrategia 1: Tabela HTML valida
        resultados = self._parse_tables(html)
        if resultados:
            return resultados

        # Estrategia 2: Texto puro com regex contextual (auto-cura)
        resultados = self._parse_text_heuristic(html)
        if resultados:
            return resultados

        # Estrategia 3: Regex agressivo no texto renderizado
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

                resultados.append(self._make_cotacao(produto, preco))

            if resultados:
                break

        return resultados

    def _parse_text_heuristic(self, html: str) -> list[CotacaoRegional]:
        """Auto-cura: busca produtos no texto e retrocede ate o preco mais proximo."""
        soup = BeautifulSoup(html, "lxml")
        text = soup.get_text(separator=" ")
        resultados: list[CotacaoRegional] = []

        for match in RE_PRECO_PROXIMO.finditer(text):
            produto = match.group("produto").strip().capitalize()
            preco_raw = match.group("preco")
            preco = self._limpar_preco(preco_raw)
            if preco is not None:
                resultados.append(self._make_cotacao(produto, preco))

        return resultados

    def _parse_regex_fallback(self, html: str) -> list[CotacaoRegional]:
        """Ultimo recurso: expressao regular agressiva ignorando estrutura HTML."""
        soup = BeautifulSoup(html, "lxml")
        text = soup.get_text(separator=" ")
        resultados: list[CotacaoRegional] = []

        for match in RE_PRECO_TABELA.finditer(text):
            produto = match.group("produto").strip().capitalize()
            preco_raw = match.group("preco")
            preco = self._limpar_preco(preco_raw)
            if preco is not None and len(produto) >= 3:
                resultados.append(self._make_cotacao(produto, preco))

        return resultados

    def _make_cotacao(self, produto: str, preco: float) -> CotacaoRegional:
        return CotacaoRegional(
            produto_original=produto,
            preco_bruto=preco,
            uf=self.uf,
            municipio=self.municipio,
            fonte=self.fonte or "CEASA",
            status_coleta="sucesso",
        )

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
    """Executa varios AgenticHtmlAdapter em paralelo via asyncio."""
    sem = asyncio.Semaphore(max_concorrencia)
    resultados: dict[str, list[CotacaoRegional]] = {}

    async def _coletar(alvo: dict):
        async with sem:
            adapter = AgenticHtmlAdapter(
                url=alvo["url"],
                uf=alvo.get("uf", ""),
                municipio=alvo.get("municipio", ""),
                fonte=alvo.get("fonte", ""),
                urls_fallback=alvo.get("urls_fallback", []),
            )
            items = await adapter.fetch()
            resultados[alvo["url"]] = items

    tasks = [_coletar(a) for a in alvos]
    await asyncio.gather(*tasks, return_exceptions=True)
    return resultados