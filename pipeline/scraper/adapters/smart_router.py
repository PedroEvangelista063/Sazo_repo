from __future__ import annotations

import logging
import re
from typing import Any

import httpx
from bs4 import BeautifulSoup

from pipeline.scraper.circuit_breaker import CircuitBreaker
from pipeline.scraper.adapters.agentic_html import AgenticHtmlAdapter
from pipeline.scraper.adapters.base import CotacaoRegional
from pipeline.scraper.adapters.playwright_html import PlaywrightHtmlAdapter
from pipeline.scraper.adapters.organism_adapter import OrganismAdapter
from pipeline.scraper.adapters.google_drive_adapter import GoogleDriveAdapter
from pipeline.scraper.adapters.santo_graal_adapter import SantoGraalAdapter
from pipeline.scraper.adapters.stealth import (
    BaseTargetAdapter,
    LegacyPostbackAdapter,
    PlaywrightStealthAdapter,
    XhrInterceptorAdapter,
    executar_adapters_playwright,
)
from pipeline.scraper.transport.fingerprint import build_context_kwargs
from pipeline.scraper.url_manager import PaginationConfig

logger = logging.getLogger(__name__)

BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/125.0.0.0 Safari/537.36"
    ),
    "Accept-Language": "pt-BR,pt;q=0.9",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
}

# ── Cascata de Resiliência: Roteamento UF → Fonte ──────────────────────

TODAS_UFS: list[str] = sorted([
    "AC", "AL", "AM", "AP", "BA", "CE", "DF", "ES", "GO", "MA",
    "MG", "MS", "MT", "PA", "PB", "PE", "PI", "PR", "RJ", "RN",
    "RO", "RR", "RS", "SC", "SE", "SP", "TO",
])

UF_ALVOS_DEDICADOS: dict[str, list[str]] = {
    "SP": ["agrolink", "ceagesp", "cepea"],
    "PR": ["ceasa_pr", "ceasa_pr_hoje", "ceasa_pr_2025"],
    "MG": ["ceasa_mg", "ceasa_mg_minas1"],
    "ES": ["ceasa_es"],
    "PE": ["ceasa_pe"],
    "RN": ["ceasa_rn"],
    "MS": ["ceasa_ms"],
    "RS": ["ceasa_rs"],
    "DF": ["ceasa_df"],
    "BA": ["ceasa_ba"],
    "MT": ["imea_mt"],
    "BR": ["conab", "conab_pentaho", "calculadorarural"],
}

MAPA_CEASA_UF: dict[str, str] = {
    "campinas": "SP", "ceagesp": "SP", "saopaulo": "SP", "sao paulo": "SP",
    "belo horizonte": "MG", "contagem": "MG", "minas gerais": "MG",
    "rio de janeiro": "RJ", "rj": "RJ",
    "brasilia": "DF", "bsb": "DF",
    "curitiba": "PR", "parana": "PR",
    "goiania": "GO", "goias": "GO",
    "porto alegre": "RS",
    "florianopolis": "SC", "santa catarina": "SC",
    "salvador": "BA",
    "recife": "PE",
    "fortaleza": "CE",
    "natal": "RN",
    "belem": "PA",
    "manaus": "AM",
    "campo grande": "MS",
    "cuiaba": "MT",
    "vitoria": "ES",
    "sao luis": "MA",
    "teresina": "PI",
    "aracaju": "SE",
    "joao pessoa": "PB",
    "maceio": "AL",
    "palmas": "TO",
}

RE_CEASA_UF = re.compile(r"([A-Z]{2})\s*\)?\s*$")

CATEGORIAS_AGREGADOR = [
    "legumes", "frutas", "verduras",
]


def _extrair_uf_de_ceasa(nome_ceasa: str) -> str | None:
    nome = nome_ceasa.lower().strip()
    nome = nome.replace("ceasa", "").replace("ceagesp", "").replace("-", "").replace("/", " ").strip()
    nome = re.sub(r"\s+", " ", nome)

    if "campinas" in nome or "ceagesp" in nome:
        return "SP"
    if "belo horizonte" in nome or "contagem" in nome:
        return "MG"
    if "rio de janeiro" in nome:
        return "RJ"
    if "brasilia" in nome:
        return "DF"
    if "curitiba" in nome:
        return "PR"
    if "goiania" in nome:
        return "GO"
    if "porto alegre" in nome:
        return "RS"
    if "salvador" in nome:
        return "BA"
    if "recife" in nome:
        return "PE"
    if "fortaleza" in nome:
        return "CE"
    if "natal" in nome:
        return "RN"
    if "belem" in nome:
        return "PA"
    if "campo grande" in nome:
        return "MS"
    if "cuiaba" in nome:
        return "MT"
    if "vitoria" in nome:
        return "ES"
    if "florianopolis" in nome:
        return "SC"

    m = RE_CEASA_UF.search(nome)
    if m:
        uf = m.group(1).upper()
        if uf in TODAS_UFS:
            return uf
    return None


class AgregadorMercadoAdapter:
    """Camada 2 — Fallback universal via portais agregadores de mercado.

    Fontes (em ordem):
      1. Noticias Agricolas (cotacoes/legumes, frutas, verduras)
      2. HF Brasil (estatistica/{produto}.aspx)

    Usa httpx async, sem Playwright. Tabelas HTML simples com precos
    organizados por CEASA de origem.
    """
    TIMEOUT_S = 25

    def __init__(self, uf: str, municipio: str = "", fonte: str = "AGREGADOR"):
        self.uf = uf.upper()
        self.municipio = municipio or "Nacional"
        self.fonte = fonte or "AGREGADOR-MERCADO"

    async def fetch(self) -> list[CotacaoRegional]:
        resultados: list[CotacaoRegional] = []

        resultados = await self._tentar_noticias_agricolas()
        if resultados:
            logger.info(
                "[Agregador] UF=%s: %d cotacoes via Noticias Agricolas",
                self.uf, len(resultados),
            )
            return resultados

        resultados = await self._tentar_hf_brasil()
        if resultados:
            logger.info(
                "[Agregador] UF=%s: %d cotacoes via HF Brasil",
                self.uf, len(resultados),
            )
            return resultados

        logger.info("[Agregador] UF=%s: sem dados nas fontes disponiveis (graceful degradation)", self.uf)
        return []

    async def _tentar_noticias_agricolas(self) -> list[CotacaoRegional]:
        resultados: list[CotacaoRegional] = []
        seen: set[str] = set()

        async with httpx.AsyncClient(
            headers=BROWSER_HEADERS, timeout=15, follow_redirects=True
        ) as client:
            for categoria in CATEGORIAS_AGREGADOR:
                url = f"https://www.noticiasagricolas.com.br/cotacoes/{categoria}"
                try:
                    r = await client.get(url)
                    if r.status_code != 200:
                        continue
                    soup = BeautifulSoup(r.text, "lxml")
                    items = self._parse_tabela_noticias(soup, seen)
                    resultados.extend(items)
                except Exception as e:
                    logger.debug("[Agregador] Noticias Agricolas %s: %s", categoria, e)

        return resultados

    def _parse_tabela_noticias(self, soup: BeautifulSoup, seen: set[str]) -> list[CotacaoRegional]:
        resultados: list[CotacaoRegional] = []
        ceasa_atual: str | None = None

        for table in soup.find_all("table"):
            rows = table.find_all("tr")
            if len(rows) < 2:
                continue
            header = " ".join(c.get_text(strip=True).lower() for c in rows[0].find_all(["th", "td"]))
            if not any(k in header for k in ("ceasas", "preço", "preco")):
                continue

            for row in rows[1:]:
                cells = [c.get_text(strip=True) for c in row.find_all(["td", "th"])]
                if not cells:
                    continue
                texto = cells[0].strip()

                if any(k in texto.lower() for k in ("ceasa", "ceagesp")):
                    ceasa_atual = texto
                    continue

                if "***" in texto or not texto or len(texto) < 3:
                    continue

                if len(cells) < 2:
                    continue

                preco_raw = cells[1].strip()
                if not preco_raw or "***" in preco_raw or preco_raw in ("-", "--", ""):
                    continue
                preco = self._parse_valor(preco_raw)
                if preco is None:
                    continue

                dedup = f"{texto}|{preco}"
                if dedup in seen:
                    continue
                seen.add(dedup)

                uf_encontrada = None
                if ceasa_atual:
                    uf_encontrada = _extrair_uf_de_ceasa(ceasa_atual)
                if not uf_encontrada:
                    continue
                if uf_encontrada != self.uf and self.uf != "BR":
                    continue

                resultados.append(CotacaoRegional(
                    produto_original=texto,
                    uf=uf_encontrada,
                    municipio=self.municipio,
                    ano=__import__("datetime", fromlist=["date"]).date.today().year,
                    mes=__import__("datetime", fromlist=["date"]).date.today().month,
                    fonte=self.fonte,
                    preco_bruto=preco,
                    preco_medio=preco,
                    status_coleta="sucesso",
                ))

        return resultados

    HF_PRODUTOS = [
        "batata", "tomate", "cebola", "alface", "cenoura", "beterraba",
        "abobrinha", "pepino", "pimentao", "banana", "laranja", "maca",
        "mamao", "uva", "melancia", "morango", "abacate", "abacaxi",
        "manga", "goiaba", "maracuja", "limao",
    ]

    HF_MAPA_REGIAO_UF: dict[str, str] = {
        "sao paulo": "SP",
        "belo horizonte": "MG", "contagem": "MG", "minas gerais": "MG",
        "rio de janeiro": "RJ", "rj": "RJ",
        "brasilia": "DF", "df": "DF",
        "curitiba": "PR", "parana": "PR",
        "santa catarina": "SC",
        "rio grande do sul": "RS",
        "goiania": "GO", "goias": "GO",
        "capital": "SP",
    }

    async def _tentar_hf_brasil(self) -> list[CotacaoRegional]:
        resultados: list[CotacaoRegional] = []
        seen: set[str] = set()

        async with httpx.AsyncClient(
            headers=BROWSER_HEADERS, timeout=15, follow_redirects=True
        ) as client:
            for produto in self.HF_PRODUTOS:
                url = f"https://www.hfbrasil.org.br/br/estatistica/{produto}.aspx"
                try:
                    r = await client.get(url)
                    if r.status_code != 200:
                        continue
                    soup = BeautifulSoup(r.text, "lxml")
                    items = self._parse_tabela_hf(soup, seen, produto)
                    resultados.extend(items)
                except Exception:
                    continue

        return resultados

    def _parse_tabela_hf(self, soup: BeautifulSoup, seen: set[str], produto_base: str) -> list[CotacaoRegional]:
        resultados: list[CotacaoRegional] = []

        for table in soup.find_all("table"):
            rows = table.find_all("tr")
            if len(rows) < 2:
                continue
            header = " ".join(c.get_text(strip=True).lower() for c in rows[0].find_all(["th", "td"]))
            if not any(k in header for k in ("produto", "regi", "preco")):
                continue

            headers = [c.get_text(strip=True).lower() for c in rows[0].find_all(["th", "td"])]

            col_preco = None
            for i, h in enumerate(headers):
                match = re.search(r"(\d{2})/(\d{2})", h)
                if match:
                    col_preco = i

            if col_preco is None:
                for col_idx in range(len(headers) - 1, max(0, len(headers) - 7), -1):
                    col_preco = col_idx
                    break

            col_regiao = None
            for i, h in enumerate(headers):
                if "regi" in h:
                    col_regiao = i
                    break
            if col_regiao is None:
                col_regiao = 1 if len(headers) > 1 else 0

            col_produto = None
            for i, h in enumerate(headers):
                if "produto" in h:
                    col_produto = i
                    break

            if col_preco is None:
                continue

            for row in rows[1:]:
                cells = [c.get_text(strip=True) for c in row.find_all(["td", "th"])]
                if len(cells) <= max(col_regiao, col_preco, col_produto or 0):
                    continue

                regiao = cells[col_regiao].strip().lower()
                if not regiao or regiao in ("regi", "região", ""):
                    continue

                uf_encontrada = self._hf_regiao_para_uf(regiao)
                if not uf_encontrada:
                    continue
                if uf_encontrada != self.uf and self.uf != "BR":
                    continue

                preco_raw = cells[col_preco].strip() if col_preco is not None else ""
                preco = self._parse_valor(preco_raw)
                if preco is None or preco <= 0:
                    continue

                produto_nome = cells[col_produto].strip() if col_produto is not None and len(cells) > col_produto else produto_base
                if not produto_nome or len(produto_nome) < 3:
                    produto_nome = produto_base

                dedup = f"{produto_nome}|{preco}|{uf_encontrada}"
                if dedup in seen:
                    continue
                seen.add(dedup)

                resultados.append(CotacaoRegional(
                    produto_original=produto_nome,
                    uf=uf_encontrada,
                    municipio=self.municipio,
                    ano=__import__("datetime", fromlist=["date"]).date.today().year,
                    mes=__import__("datetime", fromlist=["date"]).date.today().month,
                    fonte=self.fonte,
                    preco_bruto=preco,
                    preco_medio=preco,
                    status_coleta="sucesso",
                ))

        return resultados

    @staticmethod
    def _hf_regiao_para_uf(regiao: str) -> str | None:
        for nome, uf in AgregadorMercadoAdapter.HF_MAPA_REGIAO_UF.items():
            if nome in regiao:
                return uf
        m = re.search(r"\(([A-Z]{2})\)", regiao)
        if m:
            uf = m.group(1).upper()
            if len(uf) == 2 and uf.isalpha():
                return uf
        return None

    @staticmethod
    def _parse_valor(valor: object) -> float | None:
        if valor is None:
            return None
        if isinstance(valor, (int, float)):
            return float(valor)
        if isinstance(valor, str):
            v = valor.strip().replace("R$", "").replace("r$", "").replace(" ", "")
            v = v.replace(".", "").replace(",", ".")
            try:
                return float(v)
            except ValueError:
                return None
        return None


def get_estrategia(uf: str, ano: int | None = None, mes: int | None = None) -> dict:
    """Cascata de Resiliencia: retorna a melhor estrategia para uma UF.

    Camada 0 (HISTORICO): ano < ano corrente -> SantoGraalAdapter (CEPEA/CEAGESP).
    Camada 1 (DEDICADO): UF tem CEASA mapeada -> adapter especifico.
    Camada 2 (FALLBACK): UF sem CEASA -> AgregadorMercadoAdapter.
    """
    uf = uf.upper()
    if ano is not None and mes is not None:
        hoje = __import__("datetime", fromlist=["date"]).date.today()
        if ano < hoje.year or (ano == hoje.year and mes < hoje.month - 1):
            return {
                "tipo": "HISTORICO",
                "alvos": None,
                "uf": uf,
                "ano": ano,
                "mes": mes,
            }
    if uf in UF_ALVOS_DEDICADOS:
        return {"tipo": "DEDICADO", "alvos": UF_ALVOS_DEDICADOS[uf], "uf": uf}
    return {"tipo": "FALLBACK", "alvos": None, "uf": uf}


ROTA_ADAPTERS: list[tuple[str, type[BaseTargetAdapter], dict[str, Any]]] = [
    ("pentaho", XhrInterceptorAdapter, {}),
    ("conab.gov.br/prohort/api", XhrInterceptorAdapter, {}),
    ("/api/repos/", XhrInterceptorAdapter, {}),
    ("api/cotacoes", XhrInterceptorAdapter, {}),
    ("pentahoportaldeinformacoes", XhrInterceptorAdapter, {}),
]

DOMINIOS_ORGANISM: list[str] = [
    "agrolink.com.br",
    "ceagesp.gov.br",
    "calculadorarural.com.br",
    "cepea.org.br",
]


def _classificar_url(url: str) -> tuple[str, dict[str, Any]]:
    url_lower = url.lower()
    if "ceasa.rs.gov.br" in url_lower or "drive.google.com" in url_lower:
        return "f_gdrive", {}
    for padrao, cls, params in ROTA_ADAPTERS:
        if padrao in url_lower:
            if cls == XhrInterceptorAdapter:
                return "a_json", params
            elif cls == PlaywrightStealthAdapter:
                return "b_stealth", params
            elif cls == LegacyPostbackAdapter:
                return "c_postback", params
    for dominio in DOMINIOS_ORGANISM:
        if dominio in url_lower:
            return "e_organism", {}
    return "d_agentic", {}


ALVOS_CONHECIDOS: dict[str, dict[str, Any]] = {
    "conab": {
        "url": "https://www.conab.gov.br/prohort/api/cotacoes",
        "categoria": "a_json",
        "uf": "BR",
        "municipio": "Nacional",
        "fonte": "CONAB-ProHort",
    },
    "conab_pentaho": {
        "url": "https://pentahoportaldeinformacoes.conab.gov.br/pentaho/api/repos/:home:PROHORT:precoDia.wcdf/generatedContent?userid=pentaho&password=password",
        "categoria": "a_json",
        "uf": "BR",
        "municipio": "Nacional",
        "fonte": "CONAB-Pentaho",
    },
    "agrolink": {
        "url": "https://www.agrolink.com.br/cotacoes/ceasa/ceasa---sp",
        "categoria": "e_organism",
        "uf": "SP",
        "municipio": "Sao Paulo",
        "fonte": "Agrolink CEASA",
    },
    "ceagesp": {
        "url": "https://www.ceagesp.gov.br/cotacoes/",
        "categoria": "e_organism",
        "uf": "SP",
        "municipio": "Sao Paulo",
        "fonte": "CEAGESP",
    },
    "calculadorarural": {
        "url": "https://calculadorarural.com.br/ceasa",
        "categoria": "e_organism",
        "uf": "BR",
        "municipio": "Nacional",
        "fonte": "Calculadora Rural",
    },
    "cepea": {
        "url": "https://cepea.org.br/br/consultas-ao-banco-de-dados-do-site.aspx",
        "categoria": "e_organism",
        "uf": "SP",
        "municipio": "Piracicaba",
        "fonte": "CEPEA",
    },
    "ceasa_pr": {
        "url": "https://www.ceasa.pr.gov.br/cotacao",
        "categoria": "d_agentic",
        "uf": "PR",
        "municipio": "Curitiba",
        "fonte": "CEASA-PR",
        "urls_fallback": [
            "https://www.ceasa.pr.gov.br/cotacoes",
            "https://www.agricultura.pr.gov.br/cotacao",
        ],
    },
    "ceasa_pr_hoje": {
        "url": "https://celepar7.pr.gov.br/ceasa/hoje.asp",
        "categoria": "d_agentic",
        "uf": "PR",
        "municipio": "Curitiba",
        "fonte": "CEASA-PR",
        "urls_fallback": [],
    },
    "ceasa_pr_2025": {
        "url_template": "https://www.ceasa.pr.gov.br/Pagina/Cotacao-Diaria-de-Precos-{YYYY}",
        "categoria": "d_agentic",
        "uf": "PR",
        "municipio": "Curitiba",
        "fonte": "CEASA-PR",
        "urls_fallback": [],
    },
    "ceasa_mg": {
        "url": "https://www.ceasa.mg.gov.br/cotacoes",
        "categoria": "d_agentic",
        "uf": "MG",
        "municipio": "Contagem",
        "fonte": "CEASA-MG",
        "urls_fallback": [],
    },
    "ceasa_mg_minas1": {
        "url": "https://minas1.ceasa.mg.gov.br/ceasainternet/cst_precosmaiscomumEstados/cst_precosmaiscomumEstados.php",
        "categoria": "d_agentic",
        "uf": "MG",
        "municipio": "Contagem",
        "fonte": "CEASA-MG",
        "urls_fallback": [],
    },
    "ceasa_es": {
        "url": "http://200.198.51.71/detec/filtro_boletim_es/filtro_boletim_es.php",
        "categoria": "d_agentic",
        "uf": "ES",
        "municipio": "Vitoria",
        "fonte": "CEASA-ES",
        "urls_fallback": [
            "http://200.198.51.71/detec/boletim_completo_es/boletim_completo_es.php",
        ],
    },
    "ceasa_pe": {
        "url_template": "https://www.ceasape.org.br/cotacao/hortalicas?data={DATA}",
        "categoria": "d_agentic",
        "uf": "PE",
        "municipio": "Recife",
        "fonte": "CEASA-PE",
        "urls_fallback": [],
    },
    "ceasa_rn": {
        "url": "https://transparencia.ceasa.rn.gov.br/cotacoes",
        "categoria": "d_agentic",
        "uf": "RN",
        "municipio": "Natal",
        "fonte": "CEASA-RN",
        "urls_fallback": [],
        "pagination": {"page_param": "pagina", "page_start": 1, "max_pages": 5},
    },
    "ceasa_ms": {
        "url_template": "https://www.ceasa.ms.gov.br/boletim-{YYYY}/",
        "categoria": "d_agentic",
        "uf": "MS",
        "municipio": "Campo Grande",
        "fonte": "CEASA-MS",
        "urls_fallback": ["https://www.ceasa.ms.gov.br/boletim-2025/"],
    },
    "ceasa_rs": {
        "url": "https://ceasa.rs.gov.br/cotacoes-de-precos",
        "categoria": "f_gdrive",
        "uf": "RS",
        "municipio": "Porto Alegre",
        "fonte": "CEASA-RS",
        "urls_fallback": [],
    },
    "ceasa_df": {
        "url": "https://www.ceasa.df.gov.br/cotacoes",
        "categoria": "d_agentic",
        "uf": "DF",
        "municipio": "Brasilia",
        "fonte": "CEASA-DF",
        "urls_fallback": [
            "https://www.ceasa.df.gov.br",
            "https://ceasa.df.gov.br/precos",
        ],
    },
    "ceasa_ba": {
        "url": "https://www.ceasa.ba.gov.br/cotacoes",
        "categoria": "d_agentic",
        "uf": "BA",
        "municipio": "Salvador",
        "fonte": "CEASA-BA",
        "urls_fallback": [
            "https://ceasa.ba.gov.br/precos",
            "https://sde.ba.gov.br/ceasa",
        ],
    },
    "imea_mt": {
        "url": "http://www.imea.com.br",
        "categoria": "d_agentic",
        "uf": "MT",
        "municipio": "Cuiaba",
        "fonte": "IMEA-MT",
        "urls_fallback": [
            "https://www.imea.com.br/boletim",
        ],
    },
}


class SmartCrawler2026:
    """Orquestrador inteligente que roteia URLs para o adapter correto.

    Categorias:
      A (JSON)     -> XhrInterceptorAdapter  (Playwright, network intercept)
      B (Stealth)  -> PlaywrightStealthAdapter (Playwright, anti-WAF)
      C (Postback) -> LegacyPostbackAdapter   (Playwright, ASP.NET forms)
      D (Agentic)  -> AgenticHtmlAdapter      (httpx async, regex heuristico)
    """

    def __init__(self, organism: Any | None = None) -> None:
        self._organism = organism
        self.breakers: dict[str, CircuitBreaker] = {}

    def _get_breaker(self, nome_alvo: str) -> CircuitBreaker:
        if nome_alvo not in self.breakers:
            self.breakers[nome_alvo] = CircuitBreaker(
                nome=nome_alvo, failure_threshold=3, recovery_timeout_s=120.0
            )
        return self.breakers[nome_alvo]

    @staticmethod
    def criar_adapter_para_url(
        url: str,
        uf: str = "",
        municipio: str = "",
        fonte: str = "",
        urls_fallback: list[str] | None = None,
        ano: int | None = None,
        mes: int | None = None,
    ) -> BaseTargetAdapter | AgenticHtmlAdapter:
        url_lower = url.lower()
        for padrao, cls, _ in ROTA_ADAPTERS:
            if padrao in url_lower:
                if cls == AgenticHtmlAdapter:
                    return cls(
                        url=url, uf=uf, municipio=municipio, fonte=fonte,
                        urls_fallback=urls_fallback or [], ano=ano, mes=mes,
                    )
                adapter = cls()
                adapter.url = url
                return adapter

        return PlaywrightHtmlAdapter(
            url=url, uf=uf, municipio=municipio, fonte=fonte,
            urls_fallback=urls_fallback or [], ano=ano, mes=mes,
        )

    def criar_adapter_para_alvo(
        self,
        nome_alvo: str,
        ano: int | None = None,
        mes: int | None = None,
    ) -> BaseTargetAdapter | AgenticHtmlAdapter | OrganismAdapter | None:
        config = ALVOS_CONHECIDOS.get(nome_alvo)
        if not config:
            return None

        cat = config.get("categoria", "d_agentic")
        if cat == "f_gdrive":
            return GoogleDriveAdapter(
                url=config.get("url", ""),
                uf=config.get("uf", ""),
                municipio=config.get("municipio", ""),
                fonte=config.get("fonte", ""),
                ano=ano or 0,
                mes=mes or 0,
            )

        if cat == "e_organism":
            url = config.get("url", "")
            if config.get("url_template"):
                from pipeline.scraper.url_manager import resolver_url_template
                url = resolver_url_template(config["url_template"], ano=ano or 0, mes=mes or 0)
            return OrganismAdapter(
                organism=self._organism,
                url=url,
                uf=config.get("uf", ""),
                municipio=config.get("municipio", ""),
                fonte=config.get("fonte", ""),
            )

        if cat in ("a_json", "b_stealth", "c_postback"):
            adp = SmartCrawler2026.criar_adapter_para_url(
                url=config["url"],
                uf=config.get("uf", ""),
                municipio=config.get("municipio", ""),
                fonte=config.get("fonte", ""),
                urls_fallback=config.get("urls_fallback", []),
                ano=ano,
                mes=mes,
            )
            return adp

        pagination_config = None
        if config.get("pagination"):
            pagination_config = PaginationConfig(**config["pagination"])

        columns = None
        if config.get("columns"):
            from pipeline.scraper.url_manager import ColumnMapping
            columns = ColumnMapping(**config["columns"])

        return PlaywrightHtmlAdapter(
            url=config.get("url", ""),
            url_template=config.get("url_template", ""),
            uf=config.get("uf", ""),
            municipio=config.get("municipio", ""),
            fonte=config.get("fonte", ""),
            urls_fallback=config.get("urls_fallback", []),
            ano=ano,
            mes=mes,
            pagination=pagination_config,
            columns=columns,
        )

    async def executar_alvos(
        self,
        alvos: list[str],
        ano: int | None = None,
        mes: int | None = None,
    ) -> dict[str, list[CotacaoRegional]]:
        playwright_adapters: list[BaseTargetAdapter] = []
        organism_adapters: list[OrganismAdapter] = []
        gdrive_adapters: list[GoogleDriveAdapter] = []
        resultados: dict[str, list[CotacaoRegional]] = {}

        for nome in alvos:
            config = ALVOS_CONHECIDOS.get(nome)
            if not config:
                logger.warning("Alvo desconhecido: %s", nome)
                continue

            breaker = self._get_breaker(nome)
            if breaker.esta_aberto:
                logger.warning(
                    "[CIRCUIT OPEN] Pulando %s (%s) — recuperacao em %.0fs",
                    nome, config.get("fonte", nome), breaker.recovery_timeout_s,
                )
                resultados[nome] = []
                continue

            cat = config["categoria"]

            if cat == "f_gdrive":
                adp = self.criar_adapter_para_alvo(nome, ano=ano, mes=mes)
                if adp and isinstance(adp, GoogleDriveAdapter):
                    gdrive_adapters.append(adp)
            elif cat == "e_organism":
                adp = self.criar_adapter_para_alvo(nome, ano=ano, mes=mes)
                if adp and isinstance(adp, OrganismAdapter):
                    organism_adapters.append(adp)
            elif cat in ("a_json", "b_stealth", "c_postback"):
                adp = self.criar_adapter_para_alvo(nome, ano=ano, mes=mes)
                if adp:
                    playwright_adapters.append(adp)
            elif cat == "d_agentic":
                adp = self.criar_adapter_para_alvo(nome, ano=ano, mes=mes)
                if adp:
                    playwright_adapters.append(adp)

        if playwright_adapters:
            logger.info(
                "[SmartCrawler] %d adapters Playwright em lote...", len(playwright_adapters)
            )
            try:
                pw_resultados = await executar_adapters_playwright(playwright_adapters)
                resultados.update(pw_resultados)
                for nome in alvos:
                    config = ALVOS_CONHECIDOS.get(nome)
                    if config and config["categoria"] in ("a_json", "b_stealth", "c_postback", "d_agentic"):
                        chave = config.get("url_template") or config.get("url", "")
                        items = pw_resultados.get(chave, [])
                        if items:
                            self._get_breaker(nome).registrar_sucesso()
                        else:
                            self._get_breaker(nome).registrar_falha()
            except Exception as e:
                logger.error("[SmartCrawler] Lote Playwright falhou: %s", e)
                for nome in alvos:
                    config = ALVOS_CONHECIDOS.get(nome)
                    if config and config["categoria"] in ("a_json", "b_stealth", "c_postback", "d_agentic"):
                        self._get_breaker(nome).registrar_falha()

        if organism_adapters:
            logger.info("[SmartCrawler] %d adapters Organism...", len(organism_adapters))
            for adp in organism_adapters:
                nome = next(
                    (n for n in alvos if ALVOS_CONHECIDOS.get(n, {}).get("url", "") == adp.url),
                    adp.url,
                )
                try:
                    items = await adp.execute()
                    resultados[nome] = items
                    if items:
                        self._get_breaker(nome).registrar_sucesso()
                    else:
                        self._get_breaker(nome).registrar_falha()
                    logger.info("[Organism] %s: %d cotacoes", nome, len(items))
                except Exception as e:
                    logger.error("[Organism] %s falhou: %s", nome, e)
                    resultados[nome] = []
                    self._get_breaker(nome).registrar_falha()

        if gdrive_adapters:
            logger.info(
                "[SmartCrawler] %d adapters GoogleDrive...", len(gdrive_adapters)
            )
            for adp in gdrive_adapters:
                nome = next(
                    (n for n in alvos if ALVOS_CONHECIDOS.get(n, {}).get("url", "") == adp.url),
                    adp.url,
                )
                try:
                    items = await adp.execute()
                    resultados[nome] = items
                    if items:
                        self._get_breaker(nome).registrar_sucesso()
                    else:
                        self._get_breaker(nome).registrar_falha()
                    logger.info("[GDrive] %s: %d cotacoes", nome, len(items))
                except Exception as e:
                    logger.error("[GDrive] %s falhou: %s", nome, e)
                    resultados[nome] = []
                    self._get_breaker(nome).registrar_falha()

        return resultados

    async def executar_para_ufs(
        self,
        ufs: list[str],
        ano: int | None = None,
        mes: int | None = None,
    ) -> dict[str, list[CotacaoRegional]]:
        """Executa coleta para UFs com cascata de fallback.
        Camada 1 (DEDICADO): UFs com CEASA -> executar_alvos() em lote.
        Camada 2 (FALLBACK): UFs sem CEASA -> AgregadorMercadoAdapter httpx.
        Retorna dict[uf_str, list[CotacaoRegional]].
        """
        import time as _time

        resultados: dict[str, list[CotacaoRegional]] = {}
        ufs_dedicadas: dict[str, list[str]] = {}
        ufs_fallback: list[str] = []

        for uf in ufs:
            uf = uf.upper()
            est = get_estrategia(uf, ano=ano, mes=mes)
            t = est["tipo"]
            if t == "HISTORICO":
                ufs_dedicadas.setdefault(uf, "__santo_graal__")
            elif t == "DEDICADO":
                ufs_dedicadas[uf] = est["alvos"]
            else:
                ufs_fallback.append(uf)

        # Camada 0 — Histórico profundo via SantoGraalAdapter
        ufs_santo_graal = [
            uf for uf, alvos in ufs_dedicadas.items()
            if alvos == "__santo_graal__"
        ]
        if ufs_santo_graal:
            logger.info(
                "[CASCATA] Camada 0: %d UFs via SantoGraal (CEPEA) historico=%04d/%02d",
                len(ufs_santo_graal), ano or 0, mes or 0,
            )
            try:
                adp = SantoGraalAdapter(ano=ano or 0, mes=mes or 0)
                fp_kwargs = {}
                if self._organism is not None:
                    fp_cfg = getattr(self._organism, "_base_config", None)
                    if fp_cfg is not None:
                        fp_cfg = getattr(fp_cfg, "fingerprint", None)
                    if fp_cfg is not None:
                        fp_kwargs = build_context_kwargs(fp_cfg)
                pw_resultados = await executar_adapters_playwright([adp], **fp_kwargs)
                for chave_url, items in pw_resultados.items():
                    for item in items:
                        uf_item = item.uf or ufs_santo_graal[0] if ufs_santo_graal else ""
                        resultados.setdefault(uf_item, []).append(item)
                        for uf in ufs_santo_graal:
                            if uf_item == uf or not uf_item:
                                resultados.setdefault(uf, []).append(item)
                    logger.info(
                        "[SantoGraal] %d cotacoes via %s", len(items), chave_url
                    )
                for uf in ufs_santo_graal:
                    ufs_dedicadas.pop(uf, None)
            except Exception as e:
                logger.error("[SantoGraal] Falha: %s", e)
                for uf in ufs_santo_graal:
                    ufs_dedicadas.pop(uf, None)
                    ufs_fallback.append(uf)

        # Camada 1 — alvos dedicados em lote (reutiliza browsers)
        if ufs_dedicadas:
            todos_alvos: list[str] = []
            for alvos in ufs_dedicadas.values():
                todos_alvos.extend(a for a in alvos if a not in todos_alvos)
            logger.info(
                "[CASCATA] Camada 1: %d UFs dedicadas, %d alvos unicos",
                len(ufs_dedicadas), len(todos_alvos),
            )
            sc_resultados = await self.executar_alvos(todos_alvos, ano=ano, mes=mes)
            for uf, alvos in ufs_dedicadas.items():
                items_uf: list[CotacaoRegional] = []
                for alvo in alvos:
                    for chave, items in sc_resultados.items():
                        if alvo == chave or alvo in chave:
                            items_uf.extend(items)
                            break
                if items_uf:
                    resultados[uf] = items_uf

        # Camada 2 — fallback via agregadores de mercado (httpx rapido, por UF)
        if ufs_fallback:
            logger.info(
                "[CASCATA] Camada 2: %d UFs sem CEASA, via Agregadores de Mercado",
                len(ufs_fallback),
            )
            for uf in ufs_fallback:
                t0 = _time.perf_counter()
                try:
                    proxy = AgregadorMercadoAdapter(uf=uf)
                    items = await proxy.fetch()
                    if items:
                        resultados[uf] = items
                        logger.info(
                            "[CASCATA] UF=%s via Agregador: %d cotacoes (%.1fs)",
                            uf, len(items), _time.perf_counter() - t0,
                        )
                    else:
                        logger.warning(
                            "[CASCATA] UF=%s via Agregador: 0 cotacoes — grace. degradation (%.1fs)",
                            uf, _time.perf_counter() - t0,
                        )
                except Exception as e:
                    logger.error(
                        "[CASCATA] UF=%s Agregador fallback falhou (%.1fs): %s",
                        uf, _time.perf_counter() - t0, e,
                    )

        return resultados

    async def executar_url_direta(self, url: str) -> list[CotacaoRegional]:
        cat, _ = _classificar_url(url)

        if cat == "f_gdrive":
            adp = GoogleDriveAdapter(url=url)
            return await adp.execute()

        if cat == "e_organism":
            adp = OrganismAdapter(organism=self._organism, url=url)
            return await adp.execute()

        adp = SmartCrawler2026.criar_adapter_para_url(url)

        if isinstance(adp, AgenticHtmlAdapter):
            return await adp.fetch()

        from pipeline.scraper.adapters.stealth import async_playwright

        async with async_playwright() as pw:
            browser = await pw.chromium.launch(headless=True)
            context = await browser.new_context(
                viewport={"width": 1280, "height": 720},
                user_agent=(
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/120.0.0.0 Safari/537.36"
                ),
            )
            page = await context.new_page()
            items = await adp.execute(page)
            await browser.close()
            return items
