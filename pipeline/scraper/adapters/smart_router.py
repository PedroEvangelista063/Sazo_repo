from __future__ import annotations

import asyncio
import logging
from typing import Any

from pipeline.scraper.circuit_breaker import CircuitBreaker
from pipeline.scraper.adapters.agentic_html import AgenticHtmlAdapter
from pipeline.scraper.adapters.base import CotacaoRegional
from pipeline.scraper.adapters.organism_adapter import OrganismAdapter
from pipeline.scraper.adapters.google_drive_adapter import GoogleDriveAdapter
from pipeline.scraper.adapters.stealth import (
    BaseTargetAdapter,
    LegacyPostbackAdapter,
    PlaywrightStealthAdapter,
    XhrInterceptorAdapter,
    executar_adapters_playwright,
)
from pipeline.scraper.url_manager import PaginationConfig

logger = logging.getLogger(__name__)

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

        return AgenticHtmlAdapter(
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

        return AgenticHtmlAdapter(
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
        agentic_alvos: list[dict] = []
        agentic_nomes: list[str] = []
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
                pagination_config = None
                if config.get("pagination"):
                    pagination_config = PaginationConfig(**config["pagination"])

                columns = None
                if config.get("columns"):
                    from pipeline.scraper.url_manager import ColumnMapping
                    columns = ColumnMapping(**config["columns"])

                agentic_alvos.append(
                    {
                        "url": config.get("url", ""),
                        "url_template": config.get("url_template", ""),
                        "uf": config.get("uf", ""),
                        "municipio": config.get("municipio", ""),
                        "fonte": config.get("fonte", ""),
                        "urls_fallback": config.get("urls_fallback", []),
                        "ano": ano,
                        "mes": mes,
                        "pagination": pagination_config,
                        "columns": columns,
                    }
                )
                agentic_nomes.append(nome)

        if playwright_adapters:
            logger.info(
                "[SmartCrawler] %d adapters Playwright em lote...", len(playwright_adapters)
            )
            try:
                pw_resultados = await executar_adapters_playwright(playwright_adapters)
                resultados.update(pw_resultados)
                for nome in alvos:
                    config = ALVOS_CONHECIDOS.get(nome)
                    if config and config["categoria"] in ("a_json", "b_stealth", "c_postback"):
                        chave = config["url"]
                        items = pw_resultados.get(chave, [])
                        if items:
                            self._get_breaker(nome).registrar_sucesso()
                        else:
                            self._get_breaker(nome).registrar_falha()
            except Exception as e:
                logger.error("[SmartCrawler] Lote Playwright falhou: %s", e)
                for nome in alvos:
                    config = ALVOS_CONHECIDOS.get(nome)
                    if config and config["categoria"] in ("a_json", "b_stealth", "c_postback"):
                        self._get_breaker(nome).registrar_falha()

        if agentic_alvos:
            logger.info("[SmartCrawler] %d adapters Agentic em paralelo...", len(agentic_alvos))
            from pipeline.scraper.adapters.agentic_html import coletar_multiplos_agentic

            try:
                ag_resultados = await coletar_multiplos_agentic(agentic_alvos)
                for nome in agentic_nomes:
                    config = ALVOS_CONHECIDOS.get(nome)
                    if not config:
                        continue
                    chave = config.get("url_template") or config.get("url", "")
                    items = ag_resultados.get(chave, [])
                    if items:
                        self._get_breaker(nome).registrar_sucesso()
                    else:
                        self._get_breaker(nome).registrar_falha()
                resultados.update(ag_resultados)
            except Exception as e:
                logger.error("[SmartCrawler] Lote Agentic falhou: %s", e)
                for nome in agentic_nomes:
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
