from __future__ import annotations

import json
import logging
import re

import httpx

from pipeline.scraper.adapters.base import BaseAdapter, CotacaoRegional
from pipeline.scraper.retry import retry_request

logger = logging.getLogger(__name__)

PROHORT_API_BASE = "https://www.conab.gov.br"
PROHORT_URLS = {
    "dashboard": f"{PROHORT_API_BASE}/prohort/api/cotacoes",
    "dashboard_v1": f"{PROHORT_API_BASE}/prohort/api/v1/cotacoes",
    "precos_v1": f"{PROHORT_API_BASE}/prohort/api/v1/precos",
    "dados_abertos": f"{PROHORT_API_BASE}/prohort/dados_abertos.json",
    "consulta": f"{PROHORT_API_BASE}/prohort/consulta",
    "precos": f"{PROHORT_API_BASE}/prohort/precos",
    "gov_ptbr": f"{PROHORT_API_BASE}/pt-br",
    "gov_prohort": f"{PROHORT_API_BASE}/pt-br/prohort",
}

PRODUTOS_PROHORT = [
    "ABACATE",
    "ABACAXI",
    "ALFACE",
    "BANANA",
    "BATATA",
    "BATATA DOCE",
    "BETERRABA",
    "CENOURA",
    "CEBOLA",
    "COUVE",
    "COUVE-FLOR",
    "ESPINAFRE",
    "FEIJAO",
    "GOIABA",
    "LARANJA",
    "LIMAO",
    "MACA",
    "MAMAO",
    "MANDIOCA",
    "MANGA",
    "MELANCIA",
    "MILHO",
    "MORANGO",
    "PEPINO",
    "PIMENTAO",
    "REPOLHO",
    "TOMATE",
    "UVA",
    "VAGEM",
]

UF_LIST = [
    "AC",
    "AL",
    "AM",
    "AP",
    "BA",
    "CE",
    "DF",
    "ES",
    "GO",
    "MA",
    "MG",
    "MS",
    "MT",
    "PA",
    "PB",
    "PE",
    "PI",
    "PR",
    "RJ",
    "RN",
    "RO",
    "RR",
    "RS",
    "SC",
    "SE",
    "SP",
    "TO",
]


class ProHortAdapter(BaseAdapter):
    nome = "ProHort CONAB"
    fonte = "CONAB-ProHort"

    def __init__(
        self,
        uf: str = "BR",
        municipio: str = "Nacional",
    ):
        self.uf = uf
        self.municipio = municipio

    @retry_request(retries=3, delay=5)
    async def fetch(self) -> list[CotacaoRegional]:
        resultados: list[CotacaoRegional] = []
        seen = set()

        async with httpx.AsyncClient(
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/125.0.0.0 Safari/537.36"
                ),
                "Accept": "application/json, text/html",
                "Accept-Language": "pt-BR,pt;q=0.9",
            },
            timeout=45,
            follow_redirects=True,
        ) as client:
            json_data = await self._fetch_api_json(client)
            if json_data:
                resultados.extend(self._parse_json_response(json_data, seen))
            if not resultados:
                logger.info("ProHort API JSON vazio, tentando parse HTML...")
                html_data = await self._fetch_html_page(client)
                resultados.extend(self._parse_html_response(html_data, seen))

        logger.info("ProHortAdapter: %d cotacoes para UF=%s", len(resultados), self.uf)
        return resultados

    async def _fetch_api_json(self, client: httpx.AsyncClient) -> list[dict] | dict | None:
        urls_tentativa = [
            PROHORT_URLS["dashboard"],
            PROHORT_URLS["dashboard_v1"],
            PROHORT_URLS["precos_v1"],
            PROHORT_URLS["dados_abertos"],
        ]
        for url in urls_tentativa:
            try:
                r = await client.get(url)
                if r.status_code == 200 and r.text.strip():
                    content_type = r.headers.get("Content-Type", "")
                    if "json" in content_type or r.text.strip().startswith("{"):
                        return r.json()
                    if r.text.strip().startswith("["):
                        return json.loads(r.text)
            except Exception as e:
                logger.debug("ProHort JSON %s falhou: %s", url, e)
                continue
        return None

    async def _fetch_html_page(self, client: httpx.AsyncClient) -> str:
        urls = [
            PROHORT_URLS["consulta"],
            PROHORT_URLS["precos"],
            PROHORT_URLS["gov_ptbr"],
            PROHORT_URLS["gov_prohort"],
        ]
        for url in urls:
            try:
                r = await client.get(url)
                if r.status_code == 200:
                    return r.text
            except Exception:
                continue
        return ""

    def _parse_json_response(self, data: list[dict] | dict, seen: set) -> list[CotacaoRegional]:
        resultados: list[CotacaoRegional] = []
        registros = data if isinstance(data, list) else data.get("data", data.get("dados", []))

        if isinstance(registros, dict):
            registros = [registros]

        for item in registros:
            if not isinstance(item, dict):
                continue
            try:
                cotacao = self._json_item_para_cotacao(item, seen)
                if cotacao:
                    resultados.append(cotacao)
            except Exception as e:
                logger.debug("ProHort parse item falhou: %s", e)
                continue

        return resultados

    def _json_item_para_cotacao(self, item: dict, seen: set) -> CotacaoRegional | None:
        produto_raw = item.get("produto") or item.get("nome_produto") or item.get("descricao") or ""
        if not produto_raw:
            return None

        preco_medio = (
            self._parse_valor(item.get("preco_medio"))
            or self._parse_valor(item.get("preco"))
            or self._parse_valor(item.get("valor"))
        )
        if preco_medio is None:
            return None

        preco_min = (
            self._parse_valor(item.get("preco_min"))
            or self._parse_valor(item.get("preco_minimo"))
            or self._parse_valor(item.get("menor_preco"))
        )
        preco_max = (
            self._parse_valor(item.get("preco_max"))
            or self._parse_valor(item.get("preco_maximo"))
            or self._parse_valor(item.get("maior_preco"))
        )

        data_raw = (
            item.get("data")
            or item.get("data_cotacao")
            or item.get("data_referencia")
            or item.get("periodo")
            or ""
        )
        periodo = self.extrair_periodo(data_raw)

        uf_item = item.get("uf") or item.get("estado") or item.get("sigla_uf") or self.uf
        municipio_item = (
            item.get("municipio")
            or item.get("cidade")
            or item.get("municipio_nome")
            or self.municipio
        )
        unidade = item.get("unidade") or item.get("unidade_medida") or item.get("und") or ""
        fator = self.normalizar_unidade(unidade)

        if self.uf != "BR" and uf_item.upper() != self.uf:
            return None

        produto_norm = self.normalizar_produto(produto_raw)

        dedup_key = f"{produto_norm}|{uf_item}|{preco_medio}|{data_raw}"
        if dedup_key in seen:
            return None
        seen.add(dedup_key)

        return CotacaoRegional(
            produto_original=produto_raw,
            produto_normalizado=produto_norm,
            uf=uf_item,
            municipio=municipio_item,
            ano=periodo[0] if periodo else 0,
            mes=periodo[1] if periodo else 0,
            data_cotacao=data_raw,
            fonte=self.fonte,
            unidade_medida=unidade,
            preco_min=preco_min,
            preco_max=preco_max,
            preco_medio=preco_medio,
            preco_bruto=preco_medio,
            fator_kg=fator,
            status_coleta="sucesso",
        )

    def _parse_html_response(self, html: str, seen: set) -> list[CotacaoRegional]:
        from bs4 import BeautifulSoup

        resultados: list[CotacaoRegional] = []
        if not html:
            return resultados

        soup = BeautifulSoup(html, "html.parser")
        script_tags = soup.find_all("script")
        for script in script_tags:
            if script.string and "data" in script.string.lower():
                m = re.search(
                    r"(data|dados|datasets)\s*[=:]\s*(\[.*?\])\s*[;,\n]", script.string, re.DOTALL
                )
                if m:
                    try:
                        raw = m.group(2)
                        raw = re.sub(r"(?<!\w)(\w+)(?=\s*:)", r'"\1"', raw)
                        raw = raw.replace("'", '"')
                        dados = json.loads(raw)
                        if isinstance(dados, list):
                            for item in dados:
                                c = self._json_item_para_cotacao(
                                    item if isinstance(item, dict) else {}, seen
                                )
                                if c:
                                    resultados.append(c)
                    except (json.JSONDecodeError, Exception):
                        continue

        if not resultados:
            tabelas = soup.find_all("table")
            for tabela in tabelas:
                rows = tabela.find_all("tr")
                for row in rows[1:]:
                    cells = row.find_all(["td", "th"])
                    if len(cells) < 3:
                        continue
                    vals = [c.get_text(strip=True) for c in cells]
                    produto_raw = vals[0]
                    preco_str = vals[-2] if len(vals) >= 3 else vals[-1]
                    preco = self.limpar_valor(preco_str)
                    if not preco:
                        continue

                    produto_norm = self.normalizar_produto(produto_raw)
                    dedup_key = f"{produto_norm}|BR|{preco}"
                    if dedup_key in seen:
                        continue
                    seen.add(dedup_key)

                    resultados.append(
                        CotacaoRegional(
                            produto_original=produto_raw,
                            produto_normalizado=produto_norm,
                            uf=self.uf,
                            municipio=self.municipio,
                            fonte=self.fonte,
                            preco_medio=preco,
                            preco_bruto=preco,
                            status_coleta="sucesso",
                        )
                    )

        logger.info("ProHort HTML parse: %d cotacoes", len(resultados))
        return resultados

    @staticmethod
    def _parse_valor(valor: object) -> float | None:
        if valor is None:
            return None
        if isinstance(valor, (int, float)):
            return float(valor)
        if isinstance(valor, str):
            v = valor.strip().replace("R$", "").replace(" ", "")
            v = v.replace(".", "").replace(",", ".")
            try:
                return float(v)
            except ValueError:
                return None
        return None
