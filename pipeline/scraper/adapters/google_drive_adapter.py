from __future__ import annotations

import asyncio
import csv
import io
import logging
import re
from typing import Any

import httpx

from pipeline.scraper.adapters.base import CotacaoRegional, validar_cotacao
from pipeline.scraper.adapters.stealth import BaseTargetAdapter

logger = logging.getLogger(__name__)

CEASA_RS_URL = "https://ceasa.rs.gov.br/cotacoes-de-precos"
DRIVE_EXPORT = "https://docs.google.com/spreadsheets/d/{file_id}/export?format=csv"
_RE_FILE_ID = re.compile(r"/folders/([a-zA-Z0-9_-]+)")
_RE_DATE = re.compile(r"(\d{2})/(\d{2})/(\d{4})")


class GoogleDriveAdapter(BaseTargetAdapter):
    """Adapter for CEASA RS: scrapes Google Drive spreadsheets via CSV export.

    Workflow:
      1. httpx GET → CEASA RS page → extract year/month → Drive folder links
      2. Playwright → Drive folder → extract file IDs from data-id attributes
      3. httpx GET → export CSV → parse rows into CotacaoRegional

    The spreadsheets are publicly shared Google Sheets with format:
      Produto, UND, MAX, MAIS FREQUENTE, MÍNIMO
    grouped under category headers (VERDURAS E LEGUMES, FRUTAS, …).
    """

    def __init__(
        self,
        url: str = CEASA_RS_URL,
        uf: str = "RS",
        municipio: str = "Porto Alegre",
        fonte: str = "CEASA-RS",
        ano: int = 0,
        mes: int = 0,
        max_sheets: int = 5,
    ):
        self.url = url
        self.uf = uf
        self.municipio = municipio
        self.fonte = fonte
        self.ano = ano
        self.mes = mes
        self.max_sheets = max_sheets

    async def execute(self, page: Any | None = None) -> list[CotacaoRegional]:
        logger.info("[GoogleDriveAdapter] Iniciando para %s", self.url)

        folder_links = await self._get_drive_folder_links()
        if not folder_links:
            logger.warning("[GoogleDriveAdapter] Nenhum link de pasta Drive encontrado")
            return []

        logger.info("[GoogleDriveAdapter] %d pastas Drive encontradas", len(folder_links))

        if page is None:
            from playwright.async_api import async_playwright

            async with async_playwright() as pw:
                browser = await pw.chromium.launch(headless=True)
                ctx = await browser.new_context(
                    viewport={"width": 1280, "height": 720},
                    user_agent=(
                        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                        "AppleWebKit/537.36 (KHTML, like Gecko) "
                        "Chrome/120.0.0.0 Safari/537.36"
                    ),
                )
                p = await ctx.new_page()
                items = await self._process_folders(folder_links, p)
                await browser.close()
                return items
        else:
            return await self._process_folders(folder_links, page)

    async def _get_drive_folder_links(self) -> list[dict[str, Any]]:
        links: list[dict[str, Any]] = []
        headers = {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/120.0.0.0 Safari/537.36"
            ),
        }
        try:
            async with httpx.AsyncClient(timeout=60.0, follow_redirects=True) as client:
                resp = await client.get(self.url, headers=headers)
                resp.raise_for_status()
                html = resp.text
        except Exception as e:
            logger.error(
                "[GoogleDriveAdapter] Falha ao acessar %s: %s",
                self.url, repr(e),
            )
            return links

        for a_match in re.finditer(
            r'<a[^>]*href="(https://drive\.google\.com/drive/folders/[^"]+)"[^>]*>',
            html,
        ):
            href = a_match.group(1)
            folder_id_m = _RE_FILE_ID.search(href)
            if not folder_id_m:
                continue
            folder_id = folder_id_m.group(1)
            month_text = self._extract_month_label(html, a_match.start())
            links.append({
                "url": href,
                "folder_id": folder_id,
                "month_label": month_text or "desconhecido",
            })

        seen = set()
        unique: list[dict[str, Any]] = []
        for link in links:
            if link["folder_id"] not in seen:
                seen.add(link["folder_id"])
                unique.append(link)
        return unique

    @staticmethod
    def _extract_month_label(html: str, pos: int) -> str:
        before = html[max(0, pos - 300) : pos]
        m = re.search(r"<strong[^>]*>(\w+)</strong>", before[::-1])
        if m:
            return m.group(1)[::-1]
        m2 = re.search(r">(\w{4,10})<", before)
        if m2:
            return m2.group(1)
        return ""

    async def _process_folders(
        self,
        folder_links: list[dict[str, Any]],
        page: Any,
    ) -> list[CotacaoRegional]:
        all_items: list[CotacaoRegional] = []

        for link in folder_links:
            folder_url = link["url"]
            logger.info(
                "[GoogleDriveAdapter] Pasta: %s (%s)",
                link["month_label"], folder_url,
            )
            try:
                file_items = await self._get_file_ids_from_folder(folder_url, page)
            except Exception as e:
                logger.warning(
                    "[GoogleDriveAdapter] Falha ao listar %s: %s", folder_url, e
                )
                continue

            count = 0
            for fid, fname in file_items:
                if self.max_sheets and count >= self.max_sheets:
                    break
                try:
                    csv_text = await self._download_csv(fid)
                    items = await asyncio.to_thread(
                        self._parse_csv, csv_text, fname, fid,
                    )
                    all_items.extend(items)
                    count += 1
                    logger.debug(
                        "[GoogleDriveAdapter] Sheet %s (%s): %d cotacoes",
                        fid[:12], fname[:40], len(items),
                    )
                except Exception as e:
                    logger.warning(
                        "[GoogleDriveAdapter] Falha sheet %s: %s", fid, e
                    )

        return all_items

    async def _get_file_ids_from_folder(
        self, folder_url: str, page: Any,
    ) -> list[tuple[str, str]]:
        await page.goto(folder_url, wait_until="domcontentloaded")
        await asyncio.sleep(2)

        items: list[tuple[str, str]] = await page.evaluate(
            """
            () => {
                const results = [];
                const grid = document.querySelector('[role="grid"]');
                if (!grid) return [];
                const rows = grid.querySelectorAll('[role="row"]');
                rows.forEach(row => {
                    const idEl = row.querySelector('[data-id]');
                    if (!idEl) return;
                    const id = idEl.getAttribute('data-id');
                    if (!id || id.length < 30 || !id.includes('_')) return;
                    const text = row.textContent.trim();
                    if (!text.includes('Cotação') && !text.includes('COTAÇÃO')) return;
                    results.push([id, text]);
                });
                return results;
            }
            """
        )
        logger.debug(
            "[GoogleDriveAdapter] %d arquivos encontrados em %s",
            len(items), folder_url,
        )
        return items[: self.max_sheets] if self.max_sheets else items

    async def _download_csv(self, file_id: str) -> str:
        url = DRIVE_EXPORT.format(file_id=file_id)
        headers = {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/120.0.0.0 Safari/537.36"
            ),
        }
        async with httpx.AsyncClient(timeout=30.0, follow_redirects=True) as client:
            resp = await client.get(url, headers=headers)
            resp.raise_for_status()
            return resp.text

    def _parse_csv(
        self, csv_text: str, file_name: str, file_id: str,
    ) -> list[CotacaoRegional]:
        items: list[CotacaoRegional] = []
        reader = csv.reader(io.StringIO(csv_text))
        current_category = ""

        sheet_ano = self.ano or 2026
        sheet_mes = self.mes or 0
        data_parts = _RE_DATE.search(file_name)
        if data_parts:
            _, mes_str, ano_str = data_parts.groups()
            sheet_ano = int(ano_str)
            sheet_mes = int(mes_str)

        seen: set[str] = set()

        for row in reader:
            if not row or len(row) < 6:
                continue

            col0 = (row[0] or "").strip()
            col1 = (row[1] or "").strip()

            if col1 == "Produto":
                continue

            if not col0 and col1:
                maybe_cat = col1.upper()
                if maybe_cat in (
                    "VERDURAS E LEGUMES",
                    "VERDURAS E LEGUMES ",
                    "FRUTAS",
                    "FRUTAS ",
                    "CARNES",
                    "CARNES ",
                    "FRUTOS DO MAR",
                    "PESCADOS",
                    "PESCADOS E FRUTOS DO MAR",
                    "DIVERSOS",
                    "DIVERSOS ",
                    "CENTRAL DAS FLORES",
                    "FLORES",
                    "HORTALIÇAS",
                    "HORTALICAS",
                    "LEGUMES",
                ):
                    current_category = maybe_cat
                    continue

            produto = col1.strip().upper()
            unidade = (row[2] or "").strip()

            preco_max_str = (row[3] or "").strip()
            preco_medio_str = (row[4] or "").strip()
            preco_min_str = (row[5] or "").strip()

            preco_medio = self._parse_brl(preco_medio_str)
            preco_max = self._parse_brl(preco_max_str)
            preco_min = self._parse_brl(preco_min_str)

            preco_bruto = preco_medio or preco_max or preco_min or 0.0

            if preco_bruto <= 0:
                continue

            key = f"{produto}|{sheet_ano}-{sheet_mes}"
            if key in seen:
                continue
            seen.add(key)

            cot = CotacaoRegional(
                produto_original=produto,
                unidade_medida=unidade,
                preco_bruto=preco_bruto,
                preco_medio=preco_medio,
                preco_max=preco_max,
                preco_min=preco_min,
                uf=self.uf,
                municipio=self.municipio,
                fonte=self.fonte,
                ano=sheet_ano,
                mes=sheet_mes,
                status_coleta="sucesso",
            )
            validated = validar_cotacao(cot)
            if validated:
                items.append(validated)

        logger.info(
            "[GoogleDriveAdapter] Sheet %s: %d itens de %d linhas (cat=%s)",
            file_name[:40], len(items), len(list(csv.reader(io.StringIO(csv_text)))),
            current_category,
        )
        return items

    @staticmethod
    def _parse_brl(val: str) -> float | None:
        if not val:
            return None
        v = val.strip()
        if v in ("-", "--", "", "- - -", "n/d", "N/D", "ND", "s/ info", "null", "None"):
            return None
        v = v.replace("R$", "").replace("r$", "").replace(" ", "")
        v = v.replace(".", "").replace(",", ".")
        m = re.search(r"(\d+\.?\d*)", v)
        if not m:
            return None
        try:
            return round(float(m.group(1)), 2)
        except ValueError:
            return None
