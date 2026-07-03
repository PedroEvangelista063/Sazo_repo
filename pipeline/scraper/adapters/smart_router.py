from __future__ import annotations

import asyncio
import logging
from typing import Any

from pipeline.scraper.adapters.agentic_html import AgenticHtmlAdapter
from pipeline.scraper.adapters.base import CotacaoRegional
from pipeline.scraper.adapters.stealth import (
    BaseTargetAdapter,
    LegacyPostbackAdapter,
    PlaywrightStealthAdapter,
    XhrInterceptorAdapter,
    executar_adapters_playwright,
)

logger = logging.getLogger(__name__)

# Mapa de roteamento: padrao de URL -> tipo de adapter
ROTA_ADAPTERS: list[tuple[str, type[BaseTargetAdapter], dict[str, Any]]] = [
    # Category A: JSON Heist (Pentaho / APIs Ocultas)
    ("pentaho", XhrInterceptorAdapter, {}),
    ("conab.gov.br/prohort/api", XhrInterceptorAdapter, {}),
    ("/api/repos/", XhrInterceptorAdapter, {}),
    ("api/cotacoes", XhrInterceptorAdapter, {}),
    ("pentahoportaldeinformacoes", XhrInterceptorAdapter, {}),
    # Category B: WAF Fortress (Playwright Stealth)
    ("agrolink.com.br", PlaywrightStealthAdapter, {}),
    ("ceagesp.gov.br", PlaywrightStealthAdapter, {}),
    ("calculadorarural.com.br", PlaywrightStealthAdapter, {}),
    # Category C: ASP.NET Dinosaur (Postback)
    ("cepea.org.br", LegacyPostbackAdapter, {}),
    # Category D e fallback: tratado pelo SmartCrawler2026
]


def _classificar_url(url: str) -> tuple[str, dict[str, Any]]:
    """Retorna (categoria, params) para uma dada URL."""
    url_lower = url.lower()

    for padrao, cls, params in ROTA_ADAPTERS:
        if padrao in url_lower:
            if cls == XhrInterceptorAdapter:
                return "a_json", params
            elif cls == PlaywrightStealthAdapter:
                return "b_stealth", params
            elif cls == LegacyPostbackAdapter:
                return "c_postback", params

    # Fallback: Category D (Old Guard)
    return "d_agentic", {}


ALVOS_CONHECIDOS: dict[str, dict[str, Any]] = {
    # Category A: JSON Heist
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
    # Category B: WAF Fortress
    "agrolink": {
        "url": "https://www.agrolink.com.br/cotacoes/ceasa/ceasa---sp",
        "categoria": "b_stealth",
        "uf": "SP",
        "municipio": "Sao Paulo",
        "fonte": "Agrolink CEASA",
    },
    "ceagesp": {
        "url": "https://www.ceagesp.gov.br/cotacoes/",
        "categoria": "b_stealth",
        "uf": "SP",
        "municipio": "Sao Paulo",
        "fonte": "CEAGESP",
    },
    "calculadorarural": {
        "url": "https://calculadorarural.com.br/ceasa",
        "categoria": "b_stealth",
        "uf": "BR",
        "municipio": "Nacional",
        "fonte": "Calculadora Rural",
    },
    # Category C: ASP.NET
    "cepea": {
        "url": "https://www.cepea.org.br/estatisticas/",
        "categoria": "c_postback",
        "uf": "SP",
        "municipio": "Piracicaba",
        "fonte": "CEPEA",
    },
    "cepea_banco": {
        "url": "https://cepea.org.br/br/consultas-ao-banco-de-dados-do-site.aspx",
        "categoria": "c_postback",
        "uf": "SP",
        "municipio": "Piracicaba",
        "fonte": "CEPEA",
    },
    # Category D: CEASAs estaduais
    "ceasa_pr": {
        "url": "https://www.ceasa.pr.gov.br/cotacao",
        "categoria": "d_agentic",
        "uf": "PR",
        "municipio": "Curitiba",
        "fonte": "CEASA-PR",
        "urls_fallback": ["https://www.ceasa.pr.gov.br/cotacoes", "https://www.agricultura.pr.gov.br/cotacao"],
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
        "url": "https://www.ceasa.pr.gov.br/Pagina/Cotacao-Diaria-de-Precos-2025",
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
        "url": "http://200.198.51.71/detec/boletim_completo_es/boletim_completo_es.php",
        "categoria": "d_agentic",
        "uf": "ES",
        "municipio": "Vitoria",
        "fonte": "CEASA-ES",
        "urls_fallback": [],
    },
    "ceasa_pe": {
        "url": "https://www.ceasape.org.br/cotacao/hortalicas",
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
    },
    "ceasa_ms": {
        "url": "https://www.ceasa.ms.gov.br/boletim-2026/",
        "categoria": "d_agentic",
        "uf": "MS",
        "municipio": "Campo Grande",
        "fonte": "CEASA-MS",
        "urls_fallback": ["https://www.ceasa.ms.gov.br/boletim-2025/"],
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

    @staticmethod
    def criar_adapter_para_url(
        url: str,
        uf: str = "",
        municipio: str = "",
        fonte: str = "",
        urls_fallback: list[str] | None = None,
    ) -> BaseTargetAdapter | AgenticHtmlAdapter:
        url_lower = url.lower()

        for padrao, cls, _ in ROTA_ADAPTERS:
            if padrao in url_lower:
                if cls == AgenticHtmlAdapter:
                    return cls(url=url, uf=uf, municipio=municipio, fonte=fonte, urls_fallback=urls_fallback or [])
                adapter = cls()
                adapter.url = url
                return adapter

        return AgenticHtmlAdapter(url=url, uf=uf, municipio=municipio, fonte=fonte, urls_fallback=urls_fallback or [])

    @staticmethod
    def criar_adapter_para_alvo(nome_alvo: str) -> BaseTargetAdapter | AgenticHtmlAdapter | None:
        config = ALVOS_CONHECIDOS.get(nome_alvo)
        if not config:
            return None
        return SmartCrawler2026.criar_adapter_para_url(
            url=config["url"],
            uf=config.get("uf", ""),
            municipio=config.get("municipio", ""),
            fonte=config.get("fonte", ""),
            urls_fallback=config.get("urls_fallback", []),
        )

    async def executar_alvos(
        self,
        alvos: list[str],
    ) -> dict[str, list[CotacaoRegional]]:
        """Executa uma lista de alvos conhecidos, roteando cada um para o adapter correto."""

        playwright_adapters: list[BaseTargetAdapter] = []
        agentic_alvos: list[dict] = []
        resultados: dict[str, list[CotacaoRegional]] = {}

        for nome in alvos:
            config = ALVOS_CONHECIDOS.get(nome)
            if not config:
                logger.warning("Alvo desconhecido: %s", nome)
                continue

            cat = config["categoria"]

            if cat in ("a_json", "b_stealth", "c_postback"):
                adp = SmartCrawler2026.criar_adapter_para_alvo(nome)
                if adp:
                    playwright_adapters.append(adp)
            elif cat == "d_agentic":
                agentic_alvos.append(
                    {
                        "url": config["url"],
                        "uf": config.get("uf", ""),
                        "municipio": config.get("municipio", ""),
                        "fonte": config.get("fonte", ""),
                        "urls_fallback": config.get("urls_fallback", []),
                    }
                )

        # Executa Playwright adapters em lote (mesma sessao de browser)
        if playwright_adapters:
            logger.info(
                "[SmartCrawler] %d adapters Playwright em lote...", len(playwright_adapters)
            )
            pw_resultados = await executar_adapters_playwright(playwright_adapters)
            resultados.update(pw_resultados)

        # Executa Agentic adapters em paralelo via httpx
        if agentic_alvos:
            logger.info("[SmartCrawler] %d adapters Agentic em paralelo...", len(agentic_alvos))
            from pipeline.scraper.adapters.agentic_html import coletar_multiplos_agentic

            ag_resultados = await coletar_multiplos_agentic(agentic_alvos)
            resultados.update(ag_resultados)

        return resultados

    async def executar_url_direta(self, url: str) -> list[CotacaoRegional]:
        """Roteia uma URL unica para o adapter correto e executa."""
        adp = SmartCrawler2026.criar_adapter_para_url(url)

        if isinstance(adp, AgenticHtmlAdapter):
            return await adp.fetch()

        # Playwright adapter: cria sessao, executa, fecha
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