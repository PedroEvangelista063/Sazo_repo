from __future__ import annotations

import asyncio
import logging
import re
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path
from typing import Callable

import httpx
from bs4 import BeautifulSoup

logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
RAW_DIR = PROJECT_ROOT / "database" / "processed_data" / "01_raw"

UNIDADES_PADRAO: dict[str, float] = {
    "cx": 1.0, "cx 20kg": 20.0, "cx 22kg": 22.0, "cx 25kg": 25.0,
    "saco 25 kg": 25.0, "saco 25kg": 25.0, "saco 50 kg": 50.0, "saco 50kg": 50.0,
    "kg": 1.0, "dz": 1.0, "duzia": 1.0,
}

BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/125.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7",
}

LOCALIDADES_ALVO: list[dict] = [
    {"uf": "SP", "municipio": "Sao Paulo",      "fonte": "CEAGESP"},
    {"uf": "SP", "municipio": "Sao Paulo",      "fonte": "HF Brasil/CEPEA"},
    {"uf": "MG", "municipio": "Contagem",       "fonte": "HF Brasil/CEPEA"},
    {"uf": "RJ", "municipio": "Rio de Janeiro", "fonte": "HF Brasil/CEPEA"},
    {"uf": "DF", "municipio": "Brasilia",       "fonte": "HF Brasil/CEPEA"},
    {"uf": "PR", "municipio": "Curitiba",       "fonte": "HF Brasil/CEPEA"},
    {"uf": "GO", "municipio": "Goiania",        "fonte": "CEASA-GO"},
    {"uf": "MG", "municipio": "Contagem",       "fonte": "CEASA-MG"},
    {"uf": "CE", "municipio": "Maracanau",      "fonte": "CEASA-CE"},
]


@dataclass
class CotacaoHistorica:
    produto_original: str
    uf: str
    municipio: str
    ano: int
    mes: int
    data_coleta: str = field(default_factory=lambda: date.today().isoformat())
    fonte: str = ""
    unidade: str = ""
    preco_bruto: float = 0.0
    fator_kg: float = 1.0

    @property
    def valor_produto_kg(self) -> float:
        return self.preco_bruto / self.fator_kg if self.fator_kg > 0 else self.preco_bruto


def extrair_fator_kg(texto: str) -> float:
    tl = texto.lower()
    for chave, fator in UNIDADES_PADRAO.items():
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


def iterar_meses(data_inicio: date, data_fim: date | None = None) -> list[tuple[int, int]]:
    if data_fim is None:
        data_fim = date.today()
    meses: list[tuple[int, int]] = []
    d = data_inicio.replace(day=1)
    while d <= data_fim:
        meses.append((d.year, d.month))
        if d.month == 12:
            d = d.replace(year=d.year + 1, month=1)
        else:
            d = d.replace(month=d.month + 1)
    return meses


class ScraperCEASA(ABC):
    def __init__(self, uf: str, municipio: str, semaforo: asyncio.Semaphore | None = None):
        self.uf = uf
        self.municipio = municipio
        self.semaforo = semaforo or asyncio.Semaphore(2)

    @abstractmethod
    async def coletar_mes(self, ano: int, mes: int) -> list[CotacaoHistorica]:
        ...

    async def coletar_periodo(self, data_inicio: date, data_fim: date | None = None) -> list[CotacaoHistorica]:
        hoje = date.today()
        todas: list[CotacaoHistorica] = []
        for ano, mes in iterar_meses(data_inicio, data_fim):
            async with self.semaforo:
                try:
                    items = await self.coletar_mes(ano, mes)
                    logger.info("%s %s-%s %04d/%02d: %d cotacoes", type(self).__name__, self.uf, self.municipio, ano, mes, len(items))
                    todas.extend(items)
                except Exception as exc:
                    logger.warning("%s %s-%s %04d/%02d falhou: %s", type(self).__name__, self.uf, self.municipio, ano, mes, exc)
        return todas


class HFBrasilRegionalScraper(ScraperCEASA):
    BASE_URL = "https://www.hfbrasil.org.br/br/estatistica"

    PRODUTOS_HF = [
        "batata", "tomate", "cebola", "alface", "cenoura",
        "beterraba", "abobrinha", "pepino", "pimentao",
        "banana", "laranja", "maca", "mamao", "uva",
        "melancia", "morango", "abacate", "abacaxi", "manga",
        "goiaba", "maracuja", "limao",
    ]

    MAPA_CATEGORIA: dict[str, str] = {
        "batata": "LEGUMES", "tomate": "LEGUMES", "cebola": "DIVERSOS",
        "alface": "VERDURAS", "cenoura": "LEGUMES", "beterraba": "LEGUMES",
        "abobrinha": "LEGUMES", "pepino": "LEGUMES", "pimentao": "LEGUMES",
        "banana": "FRUTAS", "laranja": "FRUTAS", "maca": "FRUTAS",
        "mamao": "FRUTAS", "uva": "FRUTAS", "melancia": "FRUTAS",
        "morango": "FRUTAS", "abacate": "FRUTAS", "abacaxi": "FRUTAS",
        "manga": "FRUTAS", "goiaba": "FRUTAS", "maracuja": "FRUTAS",
        "limao": "FRUTAS",
    }

    MAPA_UF_MUNICIPIO: dict[str, tuple[str, str]] = {
        "SP": ("Sao Paulo", "SP"),
        "MG": ("Belo Horizonte", "MG"),
        "RJ": ("Rio de Janeiro", "RJ"),
        "DF": ("Brasilia", "DF"),
        "PR": ("Curitiba", "PR"),
    }

    MAPA_REGIAO_UF: dict[str, str] = {
        "sao paulo": "SP", "capital": "SP",
        "belo horizonte": "MG", "contagem": "MG", "minas gerais": "MG",
        "rio de janeiro": "RJ", "rj": "RJ",
        "brasilia": "DF", "df": "DF",
        "curitiba": "PR", "parana": "PR",
        "santa catarina": "SC", "rio grande do sul": "RS",
        "goiania": "GO", "goias": "GO",
    }

    async def coletar_periodo(self, data_inicio: date, data_fim: date | None = None) -> list[CotacaoHistorica]:
        hoje = date.today()
        ano_mes_unico = (hoje.year, hoje.month)
        async with self.semaforo:
            try:
                items = await self.coletar_mes(*ano_mes_unico)
                logger.info("%s %s-%s %04d/%02d: %d cotacoes (snapshot unico)", type(self).__name__, self.uf, self.municipio, *ano_mes_unico, len(items))
                return items
            except Exception as exc:
                logger.warning("%s %s-%s falhou: %s", type(self).__name__, self.uf, self.municipio, exc)
                return []

    async def coletar_mes(self, ano: int, mes: int) -> list[CotacaoHistorica]:
        resultados: list[CotacaoHistorica] = []
        async with httpx.AsyncClient(timeout=30, follow_redirects=True, headers=BROWSER_HEADERS) as client:
            sem = asyncio.Semaphore(3)
            async def _raspar(produto: str):
                async with sem:
                    try:
                        return await self._raspar_produto(client, produto, ano, mes)
                    except Exception:
                        return []
            tasks = [_raspar(p) for p in self.PRODUTOS_HF]
            blocos = await asyncio.gather(*tasks)
            for bloco in blocos:
                resultados.extend(bloco)
        return [r for r in resultados if r.uf == self.uf and r.valor_produto_kg > 0]

    async def _raspar_produto(self, client: httpx.AsyncClient, produto: str, ano: int, mes: int) -> list[CotacaoHistorica]:
        url = f"{self.BASE_URL}/{produto}.aspx"
        r = await client.get(url)
        r.raise_for_status()
        soup = BeautifulSoup(r.text, "html.parser")
        tabela = soup.find("table")
        if not tabela:
            return []
        linhas = tabela.find_all("tr")
        if len(linhas) < 2:
            return []

        cabecalhos = [th.get_text(strip=True) for th in linhas[0].find_all("th")]
        data_idx = None
        meses_pt = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]
        alvo = f"{mes:02d}/{meses_pt[mes-1]}"
        for i, h in enumerate(cabecalhos):
            if alvo in h.lower():
                data_idx = i
                break
        if data_idx is None:
            for i in range(len(cabecalhos) - 1, 0, -1):
                if cabecalhos[i] not in ("", "Unidade", "Produto", "Regiao", "Metodologia"):
                    data_idx = i
                    break
        if data_idx is None:
            return []

        items: list[CotacaoHistorica] = []
        for linha in linhas[1:]:
            cols = linha.find_all("td")
            if len(cols) < data_idx + 1:
                continue
            cells = [c.get_text(strip=True) for c in cols]

            desc = cells[0]
            regiao = cells[1] if len(cells) > 1 else ""
            unid = cells[2] if len(cells) > 2 else ""
            preco_str = cells[data_idx] if data_idx < len(cells) else ""

            preco = limpar_preco(preco_str)
            if preco is None or preco <= 0:
                continue

            uf_encontrada = self._extrair_uf(regiao)
            if uf_encontrada != self.uf:
                continue

            fator = extrair_fator_kg(unid)
            items.append(CotacaoHistorica(
                produto_original=desc,
                preco_bruto=preco,
                fator_kg=fator,
                unidade=unid,
                uf=self.uf,
                municipio=self.municipio,
                ano=ano,
                mes=mes,
                fonte=f"HF Brasil/CEPEA",
            ))
        return items

    def _extrair_uf(self, regiao: str) -> str:
        rl = regiao.lower()
        for nome, sigla in self.MAPA_REGIAO_UF.items():
            if nome in rl:
                return sigla
        m = re.search(r"\(([A-Z]{2})\)", regiao)
        return m.group(1) if m else "SP"


class CEAGESPScraper(ScraperCEASA):
    BASE_URL = "https://ceagesp.gov.br/cotacoes/"
    CATEGORIAS = ["diversos", "flores", "frutas", "legumes", "pescados", "verduras"]

    async def coletar_mes(self, ano: int, mes: int) -> list[CotacaoHistorica]:
        return []  # tabela JS-renderizada — requer Playwright


class CEASAGOScraper(ScraperCEASA):
    URL = "https://www.ceasa.go.gov.br/cotacao"

    async def coletar_mes(self, ano: int, mes: int) -> list[CotacaoHistorica]:
        return []  # site com redirect + JS


class CEASAMGScraper(ScraperCEASA):
    URL = "https://www.ceasa.mg.gov.br/cotacoes"

    async def coletar_mes(self, ano: int, mes: int) -> list[CotacaoHistorica]:
        return []  # host inacessivel via rede externa


def _resolver_scraper(uf: str, municipio: str, fonte: str, semaforo: asyncio.Semaphore) -> ScraperCEASA | None:
    mapa: dict[str, type[ScraperCEASA]] = {
        "HF Brasil/CEPEA": HFBrasilRegionalScraper,
        "CEAGESP": CEAGESPScraper,
        "CEASA-GO": CEASAGOScraper,
        "CEASA-MG": CEASAMGScraper,
    }
    cls = mapa.get(fonte)
    return cls(uf, municipio, semaforo) if cls else None


async def executar_coleta_regional(
    localidades: list[dict] | None = None,
    max_concorrencia: int = 3,
) -> list[CotacaoHistorica]:
    if localidades is None:
        localidades = LOCALIDADES_ALVO

    semaforo = asyncio.Semaphore(max_concorrencia)
    scrapers = [_resolver_scraper(**loc, semaforo=semaforo) for loc in localidades]
    scrapers = [s for s in scrapers if s]

    todas: list[CotacaoHistorica] = []
    for sc in scrapers:
        try:
            items = await sc.coletar_periodo(date.today(), date.today())
            todas.extend(items)
        except Exception as exc:
            logger.error("Scraper %s %s-%s falhou: %s", type(sc).__name__, sc.uf, sc.municipio, exc)

    logger.info("Coleta regional concluida: %d cotacoes no total", len(todas))
    return todas
