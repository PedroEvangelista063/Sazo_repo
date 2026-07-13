from __future__ import annotations

import asyncio
import logging
import random
import re

from playwright.async_api import Page, TimeoutError as PwTimeout

from pipeline.scraper.adapters.agentic_html import AgenticHtmlAdapter
from pipeline.scraper.adapters.base import CotacaoRegional
from pipeline.scraper.adapters.stealth import BaseTargetAdapter
from pipeline.scraper.url_manager import (
    ColumnMapping,
    PaginationConfig,
    _is_static_url,
    baixar_arquivo_estatico,
    resolver_url_template,
)

logger = logging.getLogger(__name__)

NAV_TIMEOUT = 60_000
SELECTOR_TIMEOUT = 10_000


class PlaywrightHtmlAdapter(BaseTargetAdapter):
    """Playwright-based generic adapter — replaces httpx AgenticHtmlAdapter.

    Usa Chromium com stealth + human jitter + cookie bypass para QUALQUER URL.
    Arquivos estaticos (.csv/.xls/.xlsx) delegam ao httpx AgenticHtmlAdapter.

    Aceita os mesmos parametros de config que AgenticHtmlAdapter:
      url, url_template, uf, municipio, fonte, urls_fallback, ano, mes,
      pagination, columns.
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

    def _resolve_url(self) -> str:
        if self.url_template:
            return resolver_url_template(
                self.url_template, ano=self.ano, mes=self.mes, uf=self.uf
            )
        return self.url

    async def execute(self, page: Page | None = None) -> list[CotacaoRegional]:
        if page is None:
            return await self._executar_auto()

        return await self._executar_com_page(page)

    async def _executar_auto(self) -> list[CotacaoRegional]:
        from pipeline.scraper.adapters.stealth import async_playwright
        async with async_playwright() as pw:
            browser = await pw.chromium.launch(headless=True)
            context = await browser.new_context(
                viewport={"width": 1280, "height": 720},
                user_agent=(
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/122.0.0.0 Safari/537.36"
                ),
            )
            page = await context.new_page()
            try:
                return await self._executar_com_page(page)
            finally:
                await browser.close()

    async def _executar_com_page(self, page: Page) -> list[CotacaoRegional]:
        url = self._resolve_url()
        if not url:
            logger.warning("[PlaywrightHtml] Nenhuma URL configurada para %s", self.fonte)
            return []

        urls_tentar = [url] + self._urls_fallback

        for tentativa_url in urls_tentar:
            if not tentativa_url:
                continue
            try:
                if _is_static_url(tentativa_url):
                    resultados = await baixar_arquivo_estatico(
                        tentativa_url,
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

                logger.info("[PlaywrightHtml] Navegando %s", tentativa_url)
                await page.add_init_script(
                    "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
                )
                await page.goto(tentativa_url, wait_until="domcontentloaded", timeout=NAV_TIMEOUT)
                await self._bypass_cookie_banners(page)
                await self._human_jitter(page)

                html = await page.content()
                resultados = await self._parse_com_paginacao(page, html, tentativa_url)
                if resultados:
                    return resultados

                logger.debug("[PlaywrightHtml] 0 resultados em %s, tentando fallback...", tentativa_url)
            except PwTimeout:
                logger.debug("[PlaywrightHtml] Timeout em %s, tentando fallback...", tentativa_url)
            except Exception as e:
                logger.debug("[PlaywrightHtml] Falha em %s: %s, tentando fallback...", tentativa_url, e)

        logger.warning("[PlaywrightHtml] Todas as URLs falharam para %s", self.fonte or "desconhecida")
        return []

    async def _parse_com_paginacao(self, page: Page, html: str, base_url: str) -> list[CotacaoRegional]:
        parser = AgenticHtmlAdapter(
            url=base_url,
            uf=self.uf,
            municipio=self.municipio,
            fonte=self.fonte or "CEASA",
            ano=self.ano or 0,
            mes=self.mes or 0,
            pagination=self.pagination,
        )

        resultados = parser._extract(html)
        if not self.pagination or not resultados:
            return resultados

        pagina = self.pagination.page_start + self.pagination.page_step
        min_rows = self.pagination.min_rows_to_paginate

        while len(resultados) >= min_rows and pagina <= (self.pagination.max_pages + self.pagination.page_start - 1):
            page_url = resolver_url_template(
                base_url, ano=self.ano, mes=self.mes, page=pagina, uf=self.uf
            )
            logger.info("[PlaywrightHtml] Pagina %d: %s", pagina, page_url)

            try:
                await page.goto(page_url, wait_until="domcontentloaded", timeout=NAV_TIMEOUT)
                await self._human_jitter(page)
                pagina_html = await page.content()
            except Exception:
                break

            pagina_items = parser._extract(pagina_html)
            if not pagina_items:
                if self.pagination.stop_on_empty:
                    break
                pagina += self.pagination.page_step
                continue

            if self.pagination.stop_on_duplicate:
                existing = {r.produto_original for r in resultados}
                novos = [r for r in pagina_items if r.produto_original not in existing]
                if not novos:
                    break
                resultados.extend(novos)
            else:
                resultados.extend(pagina_items)

            pagina += self.pagination.page_step

        return resultados

    async def _bypass_cookie_banners(self, page: Page):
        cookie_regex = re.compile(
            r"(?i)(aceitar|concordar|entendi|prosseguir|accept all|ok|fechar|permitir)"
        )
        try:
            locators = await page.locator("button, a").filter(has_text=cookie_regex).all()
            for loc in locators:
                if await loc.is_visible():
                    logger.info("[PlaywrightHtml] Cookie banner detectado. Clicando...")
                    await loc.click(timeout=2000)
                    await asyncio.sleep(1)
                    break
        except Exception:
            pass

    async def _human_jitter(self, page: Page):
        x, y = 100, 100
        for _ in range(4):
            x += random.randint(-50, 150)
            y += random.randint(10, 100)
            await page.mouse.move(x, y, steps=10)
            await asyncio.sleep(random.uniform(0.1, 0.4))
        await page.mouse.wheel(0, random.randint(200, 600))
