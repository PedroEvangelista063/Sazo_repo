from __future__ import annotations

import asyncio
import json
import logging
import random
import re
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path
from typing import Any

import httpx
from bs4 import BeautifulSoup

logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
LOG_DIR = PROJECT_ROOT / "logs" / "scraping_failures"
RAW_DIR = PROJECT_ROOT / "database" / "processed_data" / "01_raw"

UNIDADES_PADRAO: dict[str, float] = {
    "cx 20kg": 20.0, "cx 22kg": 22.0, "cx 25kg": 25.0,
    "cx": 1.0,
    "saco 25 kg": 25.0, "saco 25kg": 25.0,
    "saco 50 kg": 50.0, "saco 50kg": 50.0,
    "kg": 1.0, "dz": 1.0, "duzia": 1.0,
}

USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0",
]

LOCALIDADES_ALVO: list[dict] = [
    {"uf": "SP", "municipio": "Sao Paulo",      "fonte": "HF Brasil/CEPEA"},
    {"uf": "SP", "municipio": "Sao Paulo",      "fonte": "CEAGESP"},
    {"uf": "MG", "municipio": "Contagem",       "fonte": "HF Brasil/CEPEA"},
    {"uf": "RJ", "municipio": "Rio de Janeiro", "fonte": "HF Brasil/CEPEA"},
    {"uf": "DF", "municipio": "Brasilia",       "fonte": "HF Brasil/CEPEA"},
    {"uf": "PR", "municipio": "Curitiba",       "fonte": "HF Brasil/CEPEA"},
]


@dataclass
class CotacaoHistorica:
    produto_original: str
    uf: str
    municipio: str
    ano: int
    mes: int
    preco_bruto: float = 0.0
    fator_kg: float = 1.0
    unidade: str = ""
    fonte: str = ""
    data_coleta: str = field(default_factory=lambda: date.today().isoformat())

    @property
    def valor_produto_kg(self) -> float:
        return self.preco_bruto / self.fator_kg if self.fator_kg > 0 else self.preco_bruto


def extrair_fator_kg(texto: str) -> float:
    tl = texto.lower()
    for chave, fator in sorted(UNIDADES_PADRAO.items(), key=lambda x: -len(x[0])):
        if chave in tl:
            return fator
    m = re.search(r"(\d+)\s*(kg|k)", tl)
    return float(m.group(1)) if m else 1.0


def limpar_preco(valor: str) -> float | None:
    if not valor or valor.strip() in ("-", "--", "", "- - -"):
        return None
    v = valor.strip().replace("R$", "").replace(" ", "")
    v = v.replace(".", "").replace(",", ".")
    try:
        return float(v)
    except ValueError:
        return None


def jitter(segundos: float = 1.0, variacao: float = 0.5) -> float:
    return random.uniform(segundos - variacao, segundos + variacao)


def salvar_html_falha(nome_fonte: str, url: str, html: str, xpath_tentado: str) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    slug = re.sub(r"[^a-z0-9]+", "_", nome_fonte.lower())[:30]
    path = LOG_DIR / f"{ts}_{slug}.html"
    path.write_text(html, encoding="utf-8")
    meta = {"fonte": nome_fonte, "url": url, "timestamp": ts, "xpath_tentado": xpath_tentado, "html_path": str(path)}
    meta_path = LOG_DIR / f"{ts}_{slug}.json"
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    logger.warning("HTML de falha salvo: %s (xpath: %s)", path, xpath_tentado)


class BaseSpiderCEASA(ABC):
    XPATH_TABELA: list[str] = []
    URL: str = ""

    def __init__(self, uf: str, municipio: str, semaforo: asyncio.Semaphore | None = None):
        self.uf = uf
        self.municipio = municipio
        self.semaforo = semaforo or asyncio.Semaphore(2)

    @abstractmethod
    async def coletar_snapshot(self) -> list[CotacaoHistorica]:
        ...

    def parse_tabela(self, html: str, fonte: str) -> list[CotacaoHistorica]:
        soup = BeautifulSoup(html, "lxml")
        tabela = None

        for xpath in self.XPATH_TABELA:
            tabela = self._xpath_find(soup, xpath)
            if tabela:
                break

        if not tabela:
            salvar_html_falha(fonte, self.URL, html, str(self.XPATH_TABELA))
            return []

        items = self._extrair_linhas(tabela)
        if not items:
            salvar_html_falha(fonte, self.URL, html, str(self.XPATH_TABELA))
        return items

    def _xpath_find(self, soup: BeautifulSoup, xpath: str) -> Any | None:
        for node in soup.find_all(["table", "div", "tbody"]):
            texto = node.get_text(strip=True)
            parts = xpath.lower().split("contains(., '")
            if len(parts) > 1:
                keyword = parts[1].split("'")[0]
                if keyword in texto.lower():
                    return node
        return None

    def _extrair_linhas(self, tabela: Any) -> list[CotacaoHistorica]:
        return []


class HFBrasilSpider(BaseSpiderCEASA):
    URL = "https://www.hfbrasil.org.br/br/estatistica"

    XPATH_TABELA = [
        "//table[contains(., 'Produto')]",
        "//table[contains(., 'Regiao')]",
        "//table",
    ]

    PRODUTOS_HF = [
        "batata", "tomate", "cebola", "alface", "cenoura",
        "beterraba", "abobrinha", "pepino", "pimentao",
        "banana", "laranja", "maca", "mamao", "uva",
        "melancia", "morango", "abacate", "abacaxi", "manga",
        "goiaba", "maracuja", "limao",
    ]

    MAPA_REGIAO_UF = {
        "sao paulo": "SP", "capital": "SP",
        "belo horizonte": "MG", "contagem": "MG", "minas gerais": "MG",
        "rio de janeiro": "RJ",
        "brasilia": "DF",
        "curitiba": "PR", "parana": "PR",
        "goiania": "GO", "goias": "GO",
    }

    async def coletar_snapshot(self) -> list[CotacaoHistorica]:
        from pipeline.scraper.ceasa_engine import HFBrasilRegionalScraper as EngineScraper
        from pipeline.scraper.ceasa_engine import CotacaoHistorica as EngineCotacao

        engine = EngineScraper(self.uf, self.municipio, self.semaforo)
        hoje = date.today()
        items = await engine.coletar_mes(hoje.year, hoje.month)

        return [
            CotacaoHistorica(
                produto_original=i.produto_original,
                uf=i.uf,
                municipio=self.municipio,
                ano=i.ano,
                mes=i.mes,
                preco_bruto=i.preco_bruto,
                fator_kg=i.fator_kg,
                unidade=i.unidade,
                fonte=i.fonte,
            )
            for i in items
            if i.uf == self.uf and i.valor_produto_kg > 0
        ]


HEADERS_CEAGESP = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    "Content-Type": "application/x-www-form-urlencoded",
    "Accept-Language": "pt-BR,pt;q=0.9",
}

RE_GRUPOS = re.compile(r"var Grupos\s*=\s*(\{.*?\});", re.DOTALL)


def _extrair_datas_ceagesp(html: str) -> dict[str, list[str]]:
    m = RE_GRUPOS.search(html)
    if not m:
        return {}
    raw = m.group(1).replace("\\/", "/")
    return json.loads(raw)


class CEAGESPSpider(BaseSpiderCEASA):
    URL = "https://ceagesp.gov.br/cotacoes/"

    CATEGORIAS = ["DIVERSOS", "FLORES", "FRUTAS", "LEGUMES", "PESCADOS", "VERDURAS"]

    def __init__(self, uf: str, municipio: str, semaforo: asyncio.Semaphore | None = None):
        super().__init__(uf, municipio, semaforo)
        self._datas_disponiveis: dict[str, list[str]] = {}

    async def coletar_snapshot(self) -> list[CotacaoHistorica]:
        resultados: list[CotacaoHistorica] = []
        async with httpx.AsyncClient(headers=HEADERS_CEAGESP, follow_redirects=True, timeout=30) as client:
            r = await client.get(self.URL)
            self._datas_disponiveis = _extrair_datas_ceagesp(r.text)

            for categoria in self.CATEGORIAS:
                try:
                    items = await self._raspar_categoria(client, categoria)
                    resultados.extend(items)
                except Exception as exc:
                    logger.warning("CEAGESP %s falhou: %s", categoria, exc)

        return resultados

    def _melhor_data(self, categoria: str) -> str | None:
        datas = self._datas_disponiveis.get(categoria)
        if not datas:
            logger.warning("CEAGESP %s: nenhuma data disponivel", categoria)
            return None
        # datas vem ordenadas cronologicamente; pegar a mais recente
        return datas[-1]

    async def _raspar_categoria(self, client: httpx.AsyncClient, categoria: str) -> list[CotacaoHistorica]:
        if categoria == "ORGÂNICOS":
            return []

        data_val = self._melhor_data(categoria)
        if data_val is None:
            return []

        r = await client.post(self.URL, data={"cot_grupo": categoria, "cot_data": data_val})
        r.raise_for_status()

        return self._extrair_ceagesp(r.text, categoria, data_val)

    def _extrair_ceagesp(self, html: str, categoria: str, data_val: str) -> list[CotacaoHistorica]:
        soup = BeautifulSoup(html, "lxml")
        tabela = soup.find("table", class_="contacao_lista")
        if not tabela:
            salvar_html_falha(f"CEAGESP/{categoria}", self.URL, html, str(["contacao_lista"]))
            return []

        rows = tabela.find_all("tr")
        if len(rows) < 2:
            return []

        hoje = date.today()
        parts = data_val.split("/")
        try:
            dia, mes, ano = int(parts[0]), int(parts[1]), int(parts[2])
        except (ValueError, IndexError):
            dia, mes, ano = hoje.day, hoje.month, hoje.year

        items: list[CotacaoHistorica] = []
        for row in rows[2:]:
            cells = [c.get_text(strip=True) for c in row.find_all("td")]
            if len(cells) < 5:
                continue
            nome = cells[0]
            if not nome or nome.lower() in ("produto", ""):
                continue

            menor = limpar_preco(cells[3]) if len(cells) > 3 else None
            comum = limpar_preco(cells[4]) if len(cells) > 4 else None
            maior = limpar_preco(cells[5]) if len(cells) > 5 else None
            preco = comum or menor or maior or 0.0
            if preco <= 0:
                continue

            unidade = cells[2] if len(cells) > 2 else "kg"
            fator = extrair_fator_kg(unidade)

            items.append(CotacaoHistorica(
                produto_original=nome,
                uf=self.uf,
                municipio=self.municipio,
                ano=ano,
                mes=mes,
                preco_bruto=preco,
                fator_kg=fator,
                unidade=unidade,
                fonte="CEAGESP",
            ))

        logger.info("CEAGESP %s (%s): %d cotacoes", categoria, data_val, len(items))
        return items


async def executar_spider_regional(
    localidades: list[dict] | None = None,
    max_concorrencia: int = 3,
) -> list[CotacaoHistorica]:
    if localidades is None:
        localidades = LOCALIDADES_ALVO

    semaforo = asyncio.Semaphore(max_concorrencia)

    mapa_fonte: dict[str, type[BaseSpiderCEASA]] = {
        "HF Brasil/CEPEA": HFBrasilSpider,
        "CEAGESP": CEAGESPSpider,
    }

    todas: list[CotacaoHistorica] = []
    for loc in localidades:
        cls = mapa_fonte.get(loc["fonte"])
        if not cls:
            continue
        spider = cls(loc["uf"], loc["municipio"], semaforo)
        try:
            items = await spider.coletar_snapshot()
            logger.info("Spider %s %s-%s: %d cotacoes", loc["fonte"], loc["uf"], loc["municipio"], len(items))
            todas.extend(items)
        except Exception as exc:
            logger.error("Spider %s %s-%s falhou: %s", loc["fonte"], loc["uf"], loc["municipio"], exc)

    logger.info("Spider regional concluido: %d cotacoes", len(todas))
    return todas
