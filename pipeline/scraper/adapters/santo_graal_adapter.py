"""Santo Graal — Adaptador de retrocesso histórico.

Event-Driven: substitui asyncio.sleep() por expect_navigation/wait_for_selector.

Fontes (cascata):
  1. CEAGESP (SP) — dados históricos via formulário de datas
  2. CEPEA (commodities) — banco de indicadores, NÃO tem hortifrúti
"""

from __future__ import annotations

import asyncio
import logging
import re
from typing import Any

from bs4 import BeautifulSoup
from playwright.async_api import Page, TimeoutError as PwTimeout

from pipeline.scraper.adapters.base import CotacaoRegional
from pipeline.scraper.adapters.stealth import BaseTargetAdapter

logger = logging.getLogger(__name__)

CEAGESP_URL = "https://www.ceagesp.gov.br/cotacoes/"
CEPEA_URL = "https://cepea.org.br/br/consultas-ao-banco-de-dados-do-site.aspx"

# ── Constantes de timeout (evita sleeps hard-coded) ──────────────
NAV_TIMEOUT = 30_000
SELECTOR_TIMEOUT = 10_000


class SantoGraalAdapter(BaseTargetAdapter):
    def __init__(
        self,
        ano: int = 0,
        mes: int = 0,
        uf: str = "",
        fonte: str = "",
    ) -> None:
        self.ano = ano
        self.mes = mes
        self.uf = uf.upper()
        self.fonte = fonte.upper() if fonte else ("CEAGESP" if uf.upper() == "SP" else "CEPEA")
        self.url = CEPEA_URL if self.fonte == "CEPEA" else CEAGESP_URL

    async def execute(self, page: Page) -> list[CotacaoRegional]:
        if self.fonte == "CEAGESP":
            return await self._executar_ceagesp(page)
        return await self._executar_cepea(page)

    # ═══════════════════════════════════════════════════════════════
    # CEAGESP — formulário com grupos + data
    # ═══════════════════════════════════════════════════════════════

    async def _executar_ceagesp(self, page: Page) -> list[CotacaoRegional]:
        logger.info("[SantoGraal:CEAGESP] Coletando %04d/%02d", self.ano, self.mes)

        await page.add_init_script(
            "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
        )
        await page.goto(CEAGESP_URL, wait_until="domcontentloaded", timeout=NAV_TIMEOUT)

        # Event-Driven: espera o formulário renderizar em vez de sleep(2)
        await page.wait_for_selector("select#grupo", state="attached", timeout=SELECTOR_TIMEOUT)
        await page.wait_for_selector("input.cot_data", state="visible", timeout=SELECTOR_TIMEOUT)
        await page.wait_for_function("typeof Grupos !== 'undefined' && Grupos !== null")

        grupos = await page.evaluate("() => Grupos")
        if not grupos:
            logger.warning("[SantoGraal:CEAGESP] Grupos nao encontrados")
            return []

        todas: list[CotacaoRegional] = []
        categorias = ["FRUTAS", "LEGUMES", "VERDURAS", "DIVERSOS", "FLORES", "PESCADOS"]

        for categoria in categorias:
            datas = grupos.get(categoria)
            if not datas or not isinstance(datas, list) or len(datas) == 0:
                continue
            data_alvo = self._encontrar_data_proxima(datas)
            if not data_alvo:
                continue

            try:
                # Event-Driven: select_option já espera o DOM responder
                await page.select_option("select#grupo", categoria)
                await page.wait_for_function(
                    f'document.querySelector("input.cot_data") !== null',
                    timeout=SELECTOR_TIMEOUT,
                )
                await page.evaluate(
                    f'document.querySelector("input.cot_data").value = "{data_alvo}"'
                )

                async with page.expect_navigation(wait_until="domcontentloaded", timeout=NAV_TIMEOUT):
                    await page.click("button:has-text('Consultar')")

                html = await page.content()
                items = self._parse_tabela(html)
                for item in items:
                    item.ano = self.ano
                    item.mes = self.mes
                    item.fonte = "CEAGESP"
                    item.uf = self.uf or "SP"
                    item.municipio = "Sao Paulo"
                todas.extend(items)
                logger.debug("[SantoGraal:CEAGESP] %s: %d produtos", categoria, len(items))

            except PwTimeout:
                logger.debug("[SantoGraal:CEAGESP] %s timeout — pulando", categoria)
                continue

        logger.info("[SantoGraal:CEAGESP] Total: %d cotacoes", len(todas))
        return todas

    def _encontrar_data_proxima(self, datas: list[str]) -> str | None:
        for d in sorted(datas, reverse=True):
            if f"{self.ano:04d}" in d and f"{self.mes:02d}" in d:
                return d
        # fallback: primeira data disponível
        return datas[0] if datas else None

    # ═══════════════════════════════════════════════════════════════
    # CEPEA — banco de indicadores (pickadate.js, sem HF)
    # ═══════════════════════════════════════════════════════════════

    async def _executar_cepea(self, page: Page) -> list[CotacaoRegional]:
        logger.info(
            "[SantoGraal:CEPEA] %s (alvo=%04d/%02d) — CEPEA nao tem HF, apenas indicadores",
            self.url, self.ano, self.mes,
        )
        await page.add_init_script(
            "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
        )
        await page.goto(self.url, wait_until="domcontentloaded", timeout=NAV_TIMEOUT)

        # Event-Driven: espera os inputs de data ficarem disponiveis
        try:
            await page.wait_for_selector("input[name='data_inicial_submit']", state="attached", timeout=SELECTOR_TIMEOUT)
        except PwTimeout:
            logger.warning("[SantoGraal:CEPEA] Formulario nao carregou")
            return []

        # 1. Seleciona periodicidade Mensal via label click
        try:
            await page.wait_for_selector("label[for='periodicidade-3']", timeout=SELECTOR_TIMEOUT)
            await page.click("label[for='periodicidade-3']")
        except PwTimeout:
            logger.debug("[SantoGraal:CEPEA] Radio Mensal nao encontrado")

        # 2. Define período via evaluate (pickadate hidden inputs)
        de_str = f"01/{self.mes:02d}/{self.ano:04d}"
        ate_str = self._ultimo_dia_str()
        await page.evaluate(f"""
            document.querySelector('input[name="data_inicial_submit"]').value = '{de_str}';
            document.querySelector('input[name="data_final_submit"]').value = '{ate_str}';
            var d = document.getElementById('periodo-de');
            if (d) d.value = '{de_str}';
            var a = document.getElementById('periodo-ate');
            if (a) a.value = '{ate_str}';
        """)

        # 3. Dispara download e captura resposta
        try:
            async with page.expect_download(timeout=30000) as dl_info:
                await page.click("a#adicionar")
                download = await dl_info.value
                logger.info("[SantoGraal:CEPEA] Download: %s", download.suggested_filename)
        except PwTimeout:
            logger.debug("[SantoGraal:CEPEA] Download nao disparou — lendo tabela na pagina")
            await page.wait_for_timeout(1500)

        html = await page.content()
        resultados = self._parse_tabela(html)
        for r in resultados:
            r.ano = self.ano
            r.mes = self.mes
            r.fonte = "CEPEA"
            if not r.uf:
                r.uf = self.uf or "SP"
            if not r.municipio:
                r.municipio = "Piracicaba"
        logger.info("[SantoGraal:CEPEA] %d itens", len(resultados))
        return resultados

    def _ultimo_dia_str(self) -> str:
        import calendar
        return f"{calendar.monthrange(self.ano, self.mes)[1]:02d}/{self.mes:02d}/{self.ano:04d}"

    # ═══════════════════════════════════════════════════════════════
    # Parser de tabela compartilhado
    # ═══════════════════════════════════════════════════════════════

    def _parse_tabela(self, html: str) -> list[CotacaoRegional]:
        soup = BeautifulSoup(html, "lxml")
        resultados: list[CotacaoRegional] = []

        for table in soup.find_all("table"):
            rows = table.find_all("tr")
            if len(rows) < 2:
                continue
            header_text = table.get_text(" ", strip=True).lower()
            if "produto" not in header_text:
                continue
            if not any(k in header_text for k in ("pre", "comum", "menor", "valor", "r$")):
                continue

            headers = [c.get_text(strip=True).lower() for c in rows[0].find_all(["th", "td"])]
            col_prod = next((i for i, h in enumerate(headers) if "produto" in h), 0)
            col_preco = next(
                (i for i, h in enumerate(headers)
                 if h in ("preco", "preço", "comum", "valor", "comum (r$)", "preço (r$)")),
                -1,
            )
            if col_preco == -1:
                col_preco = next(
                    (i for i, h in enumerate(headers) if "pre" in h or "r$" in h),
                    len(headers) - 1 if headers else -1,
                )
            if col_preco < 0 or col_preco >= len(headers):
                continue

            for row in rows[1:]:
                cols = row.find_all(["td", "th"])
                if len(cols) <= max(col_prod, col_preco):
                    continue
                produto = cols[col_prod].get_text(strip=True)
                if not produto or len(produto) < 3 or self._is_noise(produto):
                    continue
                preco = self._limpar_preco(cols[col_preco].get_text(strip=True))
                if preco is None or preco <= 0:
                    continue
                resultados.append(CotacaoRegional(
                    produto_original=produto,
                    preco_bruto=preco,
                    status_coleta="sucesso",
                ))
            if resultados:
                break
        return resultados

    @staticmethod
    def _is_noise(p: str) -> bool:
        return bool(re.search(r"(?i)\b(download|pdf|boletim|relatório|planilha|total|média|subtotal)\b", p))

    @staticmethod
    def _limpar_preco(v: str) -> float | None:
        if not v or v.strip() in ("-", "--", "", "- - -", "n/d", "N/D", "s/ info"):
            return None
        v = v.replace("R$", "").replace("r$", "").replace(" ", "").replace(".", "").replace(",", ".")
        try:
            return float(v) if v else None
        except ValueError:
            return None
