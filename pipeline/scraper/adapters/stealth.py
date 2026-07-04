from __future__ import annotations

import asyncio
import logging
import random
import re
from typing import Any

from bs4 import BeautifulSoup
from playwright.async_api import Page, async_playwright

from pipeline.scraper.adapters.base import CotacaoRegional

logger = logging.getLogger(__name__)


class BaseTargetAdapter:
    url: str = ""

    async def execute(self, page: Page | None = None) -> list[CotacaoRegional]:
        raise NotImplementedError


class XhrInterceptorAdapter(BaseTargetAdapter):
    """Category A: Network intercept for JSON-heavy sites (CONAB Pentaho).

    Opens page, listens on Network tab, captures JSON payload from XHR.
    Immune to layout changes since it reads the API response directly.
    """

    ROUTE_TRIGGERS = ["/api/repos/", "/prohort/api/", "api/cotacoes"]

    def __init__(self, url: str = ""):
        self.url = url

    async def execute(self, page: Page) -> list[CotacaoRegional]:
        logger.info("[XhrInterceptor] Interceptando rede em %s", self.url)
        captured: list[CotacaoRegional] = []

        async def handle_response(response):
            nonlocal captured
            if response.status != 200:
                return
            matched = any(t in response.url for t in self.ROUTE_TRIGGERS)
            if not matched:
                return
            try:
                data = await response.json()
                logger.info("[XhrInterceptor] JSON interceptado: %s", response.url)
                parsed = self._parse_json_payload(data)
                captured.extend(parsed)
            except Exception as e:
                logger.debug("[XhrInterceptor] Parse falhou em %s: %s", response.url, e)

        page.on("response", handle_response)
        await page.goto(self.url, wait_until="networkidle")
        await asyncio.sleep(3)
        return captured

    def _parse_json_payload(self, data: Any) -> list[CotacaoRegional]:
        resultados: list[CotacaoRegional] = []
        registros = data if isinstance(data, list) else data.get("data", data.get("dados", []))
        if isinstance(registros, dict):
            registros = [registros]
        for item in registros:
            if not isinstance(item, dict):
                continue
            produto = (
                item.get("produto")
                or item.get("nome_produto")
                or item.get("descricao")
                or ""
            )
            if not produto:
                continue
            preco = self._parse_valor(
                item.get("preco_medio")
                or item.get("preco")
                or item.get("valor")
            )
            if preco is None:
                continue
            resultados.append(
                CotacaoRegional(
                    produto_original=produto,
                    preco_bruto=preco,
                    fonte="CONAB-Pentaho",
                    status_coleta="sucesso",
                )
            )
        return resultados

    @staticmethod
    def _parse_valor(v: Any) -> float | None:
        if v is None:
            return None
        if isinstance(v, (int, float)):
            return float(v)
        if isinstance(v, str):
            v = v.strip().replace("R$", "").replace(" ", "").replace(".", "").replace(",", ".")
            try:
                return float(v)
            except ValueError:
                return None
        return None


class PlaywrightStealthAdapter(BaseTargetAdapter):
    """Category B: Anti-WAF with browser fingerprint masking.

    Handles Agrolink, CEAGESP, Calculadora Rural (Cloudflare/Akamai).
    Injects stealth plugins, randomizes fingerprints, simulates human mouse
    movements, scrolls, and auto-dismisses cookie banners.
    """

    CEAGESP_CATEGORIES = [
        "DIVERSOS", "FRUTAS", "LEGUMES", "VERDURAS", "FLORES", "PESCADOS",
    ]

    def __init__(self, url: str = ""):
        self.url = url

    async def _bypass_cookie_banners(self, page: Page):
        cookie_regex = re.compile(
            r"(?i)(aceitar|concordar|entendi|prosseguir|accept all|ok|fechar|permitir)"
        )
        try:
            locators = await page.locator("button, a").filter(has_text=cookie_regex).all()
            for loc in locators:
                if await loc.is_visible():
                    logger.info("[Stealth] Cookie banner detectado. Clicando...")
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

    async def execute(self, page: Page) -> list[CotacaoRegional]:
        if "ceagesp" in self.url.lower():
            return await self._execute_ceagesp(page)

        logger.info("[Stealth] Modo stealth ativado para %s", self.url)
        await page.add_init_script(
            "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
        )
        await page.goto(self.url, wait_until="domcontentloaded")
        await self._bypass_cookie_banners(page)
        await self._human_jitter(page)
        html = await page.content()
        return self._agentic_parse(html)

    async def _execute_ceagesp(self, page: Page) -> list[CotacaoRegional]:
        logger.info("[CEAGESP] Modo formulario ativado")
        todas: list[CotacaoRegional] = []

        await page.add_init_script(
            "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
        )
        await page.goto(self.url, wait_until="domcontentloaded")
        await self._bypass_cookie_banners(page)
        await self._human_jitter(page)

        await page.wait_for_selector("select#grupo", timeout=10000)
        await page.wait_for_selector("input.cot_data", timeout=10000)

        grupos = await page.evaluate("() => Grupos")
        logger.info("[CEAGESP] Grupos disponiveis: %s", {k: v for k, v in grupos.items() if v})

        for categoria in self.CEAGESP_CATEGORIES:
            datas = grupos.get(categoria)
            if not datas or not isinstance(datas, list) or len(datas) == 0:
                logger.debug("[CEAGESP] %s sem datas, pulando", categoria)
                continue

            await page.select_option("select#grupo", categoria)
            await asyncio.sleep(1.0)

            ultima_data = datas[-1]
            await page.evaluate(
                f'document.querySelector("input.cot_data").value = "{ultima_data}"'
            )
            await asyncio.sleep(0.5)

            async with page.expect_navigation(wait_until="domcontentloaded", timeout=15000):
                await page.click("button:has-text('Consultar')")

            html = await page.content()
            items = self._agentic_parse(html)
            logger.info(
                "[CEAGESP] %s (%s): %d produtos",
                categoria, ultima_data, len(items),
            )
            for item in items:
                item.fonte = "CEAGESP"
            todas.extend(items)

            await asyncio.sleep(1.0)

        logger.info("[CEAGESP] Total: %d cotacoes em %d categorias", len(todas), len(set(i.produto_original for i in todas)))
        return todas

    @staticmethod
    def _is_noise_entry(produto: str) -> bool:
        noise_patterns = [
            r"(?i)\bdownload\b",
            r"(?i)\bpdf\b",
            r"^\d{4}\s*$",
            r"^\d{1,2}\s*$",
            r"(?i)\b(boletim|relatorio|planilha)\b",
        ]
        return any(re.search(p, produto) for p in noise_patterns)

    def _agentic_parse(self, html: str) -> list[CotacaoRegional]:
        soup = BeautifulSoup(html, "lxml")
        resultados: list[CotacaoRegional] = []

        for table in soup.find_all("table"):
            rows = table.find_all("tr")
            if len(rows) < 2:
                continue

            header_text = table.get_text().lower()
            if "produto" not in header_text:
                continue
            if not any(k in header_text for k in ("preço", "preco", "cotacao", "menor", "comum")):
                continue

            header_row_idx = 0
            col_produto = 0
            col_preco = 1

            for i, row in enumerate(rows):
                cells = row.find_all(["th", "td"])
                cell_texts = [c.get_text(strip=True).lower() for c in cells]
                joined = "|".join(cell_texts)

                if "produto" in joined:
                    header_row_idx = i
                    col_produto = next(
                        (j for j, t in enumerate(cell_texts) if "produto" in t), 0
                    )
                    for j, t in enumerate(cell_texts):
                        if t in ("comum", "preço", "preco", "comum (r$)"):
                            col_preco = j
                            break
                        if t == "menor":
                            col_preco = j
                    break

            data_rows = rows[header_row_idx + 1:]
            for row in data_rows:
                cols = row.find_all(["td", "th"])
                if len(cols) <= max(col_produto, col_preco):
                    continue

                produto = cols[col_produto].get_text(strip=True)
                if not produto or self._is_noise_entry(produto):
                    continue

                preco_raw = cols[col_preco].get_text(strip=True)
                preco = self._limpar_preco(preco_raw)
                if preco is None:
                    continue

                resultados.append(
                    CotacaoRegional(
                        produto_original=produto,
                        preco_bruto=preco,
                        status_coleta="sucesso",
                    )
                )

            if resultados:
                break

        logger.info("[Stealth] %d cotacoes extraidas", len(resultados))
        return resultados

    @staticmethod
    def _limpar_preco(v: str) -> float | None:
        if not v or v.strip() in ("-", "--", "", "- - -"):
            return None
        v = v.replace("R$", "").replace(" ", "").replace(".", "").replace(",", ".")
        try:
            return float(v)
        except ValueError:
            return None


class LegacyPostbackAdapter(BaseTargetAdapter):
    """Category C: ASP.NET WebForms with __VIEWSTATE postback (CEPEA).

    Instead of reverse-engineering the form POST, uses Playwright to
    interact with <select> and Click + expect_navigation() for hard reload.
    """

    def __init__(self, url: str = ""):
        self.url = url

    async def execute(self, page: Page) -> list[CotacaoRegional]:
        logger.info("[LegacyPostback] WebForms em %s", self.url)
        await page.add_init_script(
            "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
        )
        await page.goto(self.url, wait_until="domcontentloaded", timeout=60000)

        try:
            await page.wait_for_selector(
                "select[name*='Produto'], select[id*='Produto'], select",
                timeout=30000,
            )
            await asyncio.sleep(2.0)

            try:
                await page.select_option(
                    "select[name*='Produto'], select[id*='Produto']", label="Tomate"
                )
            except Exception:
                logger.warning("[LegacyPostback] Seletor produto nao encontrado, tentando submit direto")
            await asyncio.sleep(random.uniform(1.0, 2.5))

            async with page.expect_navigation(wait_until="domcontentloaded"):
                await page.click("input[type='submit'], button:has-text('Consultar'), button:has-text('Buscar')")

            html = await page.content()
            return self._parse_result_table(html)
        except Exception as e:
            logger.error("[LegacyPostback] Falha: %s", e)
            return []

    def _parse_result_table(self, html: str) -> list[CotacaoRegional]:
        soup = BeautifulSoup(html, "lxml")
        resultados: list[CotacaoRegional] = []

        for table in soup.find_all("table"):
            rows = table.find_all("tr")
            if len(rows) < 2:
                continue
            header_text = " ".join(
                th.get_text(strip=True).lower() for th in rows[0].find_all(["th", "td"])
            )
            if "produto" not in header_text:
                continue
            for row in rows[1:]:
                cols = row.find_all(["td", "th"])
                if len(cols) < 2:
                    continue
                produto = cols[0].get_text(strip=True)
                vals = [c.get_text(strip=True) for c in cols]
                preco_str = next(
                    (v for v in vals[1:] if self._is_price(v)), vals[-1]
                )
                preco = self._limpar_preco(preco_str)
                if not produto or preco is None:
                    continue
                resultados.append(
                    CotacaoRegional(
                        produto_original=produto,
                        preco_bruto=preco,
                        fonte="CEPEA",
                        status_coleta="sucesso",
                    )
                )
            if resultados:
                break

        return resultados

    @staticmethod
    def _is_price(v: str) -> bool:
        return bool(re.search(r"R?\$?\s*[\d.,]+", v))

    @staticmethod
    def _limpar_preco(v: str) -> float | None:
        if not v or v.strip() in ("-", "--", ""):
            return None
        v = v.replace("R$", "").replace(" ", "").replace(".", "").replace(",", ".")
        try:
            return float(v)
        except ValueError:
            return None


async def executar_adapters_playwright(
    adapters: list[BaseTargetAdapter],
    headless: bool = True,
) -> dict[str, list[CotacaoRegional]]:
    """Executa multiplos adapters Playwright em uma unica sessao do browser."""
    resultados: dict[str, list[CotacaoRegional]] = {}

    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=headless)
        context = await browser.new_context(
            viewport={"width": 1280, "height": 720},
            user_agent=(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/120.0.0.0 Safari/537.36"
            ),
        )
        page = await context.new_page()

        for adp in adapters:
            try:
                items = await adp.execute(page)
                resultados[adp.url] = items
                logger.info("[Playwright] %s: %d itens", adp.url, len(items))
            except Exception as e:
                logger.error("[Playwright] %s falhou: %s", adp.url, e)
                resultados[adp.url] = []

        await browser.close()

    return resultados