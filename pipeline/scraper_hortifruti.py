from __future__ import annotations

import logging
import re
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

import httpx
from bs4 import BeautifulSoup

logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = PROJECT_ROOT / "database" / "processed_data" / "01_raw"

UNIDADES_PADRAO: dict[str, float] = {
    "cx": 1.0, "cx 20kg": 20.0, "cx 22kg": 22.0, "cx 25kg": 25.0,
    "saco 25 kg": 25.0, "saco 25kg": 25.0, "saco 50 kg": 50.0,
    "kg": 1.0, "dz": 1.0, "dúzia": 1.0, "duzia": 1.0,
}

@dataclass
class CotacaoItem:
    produto_original: str
    preco_medio: float
    preco_min: float | None = None
    preco_max: float | None = None
    unidade: str = "kg"
    fator_kg: float = 1.0
    data_coleta: str = field(default_factory=lambda: date.today().isoformat())
    fonte: str = ""
    uf: str = "SP"
    categoria: str = ""

    @property
    def preco_por_kg(self) -> float:
        return self.preco_medio / self.fator_kg if self.fator_kg > 0 else self.preco_medio

def _extrair_fator_kg(desc: str) -> float:
    desc_lower = desc.lower()
    for chave, fator in UNIDADES_PADRAO.items():
        if chave in desc_lower:
            return fator
    match = re.search(r'(\d+)\s*(kg|k|quilos?)', desc_lower)
    if match:
        return float(match.group(1))
    return 1.0

def _limpar_preco(valor: str) -> float | None:
    if not valor or valor.strip() in ("-", "--", "", "- - -"):
        return None
    valor = valor.strip().replace("R$", "").replace(" ", "")
    valor = valor.replace(".", "").replace(",", ".")
    try:
        return float(valor)
    except ValueError:
        return None

class BaseScraper(ABC):
    def __init__(self, timeout: int = 30):
        self.timeout = timeout

    @abstractmethod
    async def coletar(self) -> list[CotacaoItem]:
        ...

BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/125.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7",
}

class HFBrasilScraper(BaseScraper):
    BASE_URL = "https://www.hfbrasil.org.br/br/estatistica"

    PRODUTOS_HF = [
        "batata", "tomate", "cebola", "alface", "cenoura",
        "beterraba", "abobrinha", "pepino", "pimentao",
        "banana", "laranja", "maca", "mamao", "uva",
        "melancia", "morango", "abacate", "abacaxi", "manga",
        "goiaba", "maracuja", "limao",
    ]

    CATEGORIA_MAP: dict[str, str] = {
        "batata": "LEGUMES", "tomate": "LEGUMES", "cebola": "DIVERSOS",
        "alface": "VERDURAS", "cenoura": "LEGUMES", "beterraba": "LEGUMES",
        "abobrinha": "LEGUMES", "pepino": "LEGUMES", "pimentao": "LEGUMES",
        "banana": "FRUTAS", "laranja": "FRUTAS", "maca": "FRUTAS",
        "mamao": "FRUTAS", "uva": "FRUTAS", "melancia": "FRUTAS",
        "morango": "FRUTAS", "abacate": "FRUTAS", "abacaxi": "FRUTAS",
        "manga": "FRUTAS", "goiaba": "FRUTAS", "maracuja": "FRUTAS",
        "limao": "FRUTAS",
    }

    async def coletar(self) -> list[CotacaoItem]:
        resultados: list[CotacaoItem] = []
        async with httpx.AsyncClient(
            timeout=self.timeout, follow_redirects=True, headers=BROWSER_HEADERS,
        ) as client:
            for produto in self.PRODUTOS_HF:
                try:
                    items = await self._raspar_produto(client, produto)
                    resultados.extend(items)
                    logger.info("HF Brasil: %s -> %d cotações", produto, len(items))
                except Exception as exc:
                    logger.warning("HF Brasil: falha em '%s': %s", produto, exc)
        return resultados

    async def _raspar_produto(self, client: httpx.AsyncClient, produto: str) -> list[CotacaoItem]:
        url = f"{self.BASE_URL}/{produto}.aspx"
        response = await client.get(url)
        response.raise_for_status()
        soup = BeautifulSoup(response.text, "html.parser")

        tabela = soup.find("table")
        if not tabela:
            return []

        linhas = tabela.find_all("tr")
        if not linhas:
            return []

        cabecalhos = [th.get_text(strip=True) for th in linhas[0].find_all("th")]
        if len(cabecalhos) < 3:
            return []

        data_idx = None
        for i, h in enumerate(cabecalhos):
            if re.search(r'\d{2}/jun|\d{2}/mai|\d{2}/abr', h):
                data_idx = i
                break
        if data_idx is None:
            for i in range(len(cabecalhos) - 1, 0, -1):
                if cabecalhos[i] not in ("", "Unidade", "Produto", "Região", "Metodologia"):
                    data_idx = i
                    break
        if data_idx is None:
            return []

        items: list[CotacaoItem] = []
        for linha in linhas[1:]:
            cols = linha.find_all("td")
            if len(cols) < data_idx + 1:
                continue

            cells_text = [c.get_text(strip=True) for c in cols]
            descricao = cells_text[0] if len(cells_text) > 0 else ""
            regiao = cells_text[1] if len(cells_text) > 1 else ""
            unidade_txt = cells_text[2] if len(cells_text) > 2 else ""

            preco_str = cells_text[data_idx] if data_idx < len(cells_text) else ""
            preco = _limpar_preco(preco_str)
            if preco is None or preco <= 0:
                continue

            fator = _extrair_fator_kg(unidade_txt)
            uf = self._extrair_uf(regiao)
            cat = self.CATEGORIA_MAP.get(produto, "LEGUMES")

            items.append(CotacaoItem(
                produto_original=descricao,
                preco_medio=preco,
                unidade=unidade_txt,
                fator_kg=fator,
                data_coleta=date.today().isoformat(),
                fonte="HF Brasil/CEPEA",
                uf=uf,
                categoria=cat,
            ))
        return items

    @staticmethod
    def _extrair_uf(regiao: str) -> str:
        uf_map = {
            "são paulo": "SP", "rio de janeiro": "RJ",
            "belo horizonte": "MG", "minas gerais": "MG",
            "brasília": "DF", "curitiba": "PR", "paraná": "PR",
            "santa catarina": "SC", "rio grande do sul": "RS",
            "bahia": "BA", "pernambuco": "PE", "ceará": "CE",
            "goiás": "GO", "mato grosso": "MT", "mato grosso do sul": "MS",
            "espírito santo": "ES",
        }
        rl = regiao.lower()
        for nome, sigla in uf_map.items():
            if nome in rl:
                return sigla
        match = re.search(r'\(([A-Z]{2})\)', regiao)
        if match:
            return match.group(1)
        return "SP"

class CEAGESPScraper(BaseScraper):
    """CEAGESP cotacoes — tabela renderizada via JS no WordPress.
    O scraper tenta httpx simples; para dados reais é necessário
    usar Playwright ou identificar o endpoint AJAX interno.
    """
    BASE_URL = "https://ceagesp.gov.br/cotacoes/"
    CATEGORIAS = ["diversos", "flores", "frutas", "legumes", "pescados", "verduras"]
    CATEGORIA_MAP: dict[str, str] = {
        "diversos": "DIVERSOS", "flores": "FLORES", "frutas": "FRUTAS",
        "legumes": "LEGUMES", "pescados": "PESCADOS", "verduras": "VERDURAS",
    }

    async def coletar(self) -> list[CotacaoItem]:
        resultados: list[CotacaoItem] = []
        async with httpx.AsyncClient(timeout=self.timeout, headers=BROWSER_HEADERS, follow_redirects=True) as client:
            for cat in self.CATEGORIAS:
                try:
                    items = await self._raspar_categoria(client, cat)
                    resultados.extend(items)
                except Exception:
                    pass
        return resultados

    async def _raspar_categoria(self, client: httpx.AsyncClient, cat: str) -> list[CotacaoItem]:
        r = await client.get(self.BASE_URL, params={"cot_grupo": cat.upper()})
        r.raise_for_status()
        return []  # tabela é JS — subclasse com Playwright para dados reais


async def coletar_todas_fontes() -> list[CotacaoItem]:
    todos: list[CotacaoItem] = []
    scrapers: list[BaseScraper] = [HFBrasilScraper(), CEAGESPScraper()]
    for scraper in scrapers:
        try:
            items = await scraper.coletar()
            todos.extend(items)
        except Exception as exc:
            logger.error("Scraper %s falhou: %s", type(scraper).__name__, exc)
    logger.info("Total coletado: %d cotações", len(todos))
    return todos
