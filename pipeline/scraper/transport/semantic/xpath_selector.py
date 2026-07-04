from __future__ import annotations

import logging
import re
from typing import Any

from lxml import etree

from pipeline.scraper.transport.semantic.models import PriceEntity, TableCandidate

logger = logging.getLogger(__name__)

_HEADER_TABLE_KEYWORDS = {
    "produto", "preço", "preco", "cotação", "cotacao",
    "valor", "unidade", "embalagem", "quantidade",
    "descrição", "descricao", "código", "codigo",
    "produto", "preço", "preco", "comum", "mínima", "minima",
    "máxima", "maxima", "média", "media", "r$",
}

_RE_NUMERIC_COLUMN = re.compile(r"^\d+[.,]\d+$|^R?\$?\s*\d+")


class DynamicXPathSelector:
    def __init__(self) -> None:
        self._tree: Any = None

    def parse_html(self, html_str: str) -> Any:
        try:
            parser = etree.HTMLParser(recover=True, encoding="utf-8")
            self._tree = etree.fromstring(html_str.encode("utf-8"), parser)
            return self._tree
        except Exception as e:
            logger.warning("[XPathSelector] HTML parse failed: %s", e)
            self._tree = None
            return None

    def find_tables(
        self, html_str: str, product_hints: list[str] | None = None
    ) -> list[TableCandidate]:
        self.parse_html(html_str)
        if self._tree is None:
            return []

        candidates: list[TableCandidate] = []

        table_elements = self._tree.xpath("//table | //div[contains(@class, 'table')] | //div[@role='table']")
        if not table_elements:
            table_elements = self._tree.xpath("//div[contains(@class, 'grid')]")

        if not table_elements:
            candidates.extend(self._find_table_like_divs())

        for idx, elem in enumerate(table_elements):
            xpath = self._build_unique_xpath(elem)
            xpath_alt = self._build_resilient_xpath(elem)
            score = 0.0
            header_text = ""
            columns_list: list[str] = []

            header_cells = elem.xpath(".//th | .//thead//td")
            if not header_cells:
                header_cells = elem.xpath(".//tr[1]//td | .//tr[1]//th")

            if header_cells:
                header_text = " ".join(
                    etree.tostring(c, method="text", encoding="unicode").strip()
                    for c in header_cells
                ).strip()[:200]

                columns_list = [
                    etree.tostring(c, method="text", encoding="unicode").strip()
                    for c in header_cells
                ]

                header_lower = header_text.lower()
                keyword_matches = sum(
                    1 for kw in _HEADER_TABLE_KEYWORDS if kw in header_lower
                )
                if any(kw in header_lower for kw in ("produto", "preço", "preco", "cotação", "valor")):
                    score += 0.4
                score += keyword_matches * 0.05

            rows = elem.xpath(".//tr[position() > 1]") if len(self._get_all_rows(elem)) > 1 else []
            if not rows:
                rows = elem.xpath(".//div[contains(@class, 'row')]")

            row_count = len(rows)

            if row_count >= 2:
                score += 0.2
            if row_count >= 10:
                score += 0.1

            has_price = bool(
                elem.xpath(
                    ".//*[contains(text(), 'R$') or contains(text(), 'r$')]"
                )
            )
            if has_price:
                score += 0.2

            entity_overlap = 0
            if product_hints:
                text_content = etree.tostring(elem, method="text", encoding="unicode").lower()
                for hint in product_hints:
                    if hint.lower() in text_content:
                        entity_overlap += 1
                if entity_overlap:
                    score += min(entity_overlap * 0.1, 0.3)

            best_xpath = xpath_alt if score < 0.5 else xpath

            candidates.append(TableCandidate(
                xpath=best_xpath,
                score=min(score, 1.0),
                row_count=row_count,
                header_hint=header_text[:120],
                entity_overlap=entity_overlap,
                columns=columns_list,
            ))

        candidates.sort(key=lambda c: (-c.score, -c.row_count))
        return candidates

    def extract_rows(self, xpath: str, html_str: str) -> list[list[str]]:
        self.parse_html(html_str)
        if self._tree is None:
            return []

        elements = self._tree.xpath(xpath)
        if not elements:
            elements = self._tree.xpath(f"//{xpath.lstrip('/')}")

        rows: list[list[str]] = []
        seen_texts: set[str] = set()

        for elem in elements[:50]:
            cells: list[str] = []
            for cell_tag in ("th", "td"):
                cell_texts = elem.xpath(f".//{cell_tag}/text()")
                if not cell_texts:
                    cell_texts = elem.xpath(f".//{cell_tag}")
                for ct in cell_texts:
                    text = str(ct).strip()
                    if text and text not in seen_texts:
                        cells.append(text)
                    elif text and text in seen_texts:
                        cells.append(text)
            if not cells:
                text = etree.tostring(elem, method="text", encoding="unicode").strip()
                if text:
                    cells = [text]

            if cells:
                row_key = "|".join(cells)
                if row_key not in seen_texts:
                    seen_texts.add(row_key)
                    rows.append(cells)

        return rows

    def parse_table_to_prices(
        self, html_str: str, tc: TableCandidate
    ) -> list[PriceEntity]:
        if tc.score < 0.4:
            return []
        rows = self.extract_rows(tc.xpath, html_str)
        if len(rows) < 2:
            return []

        prices: list[PriceEntity] = []
        seen: set[str] = set()

        for cells in rows:
            if len(cells) < 2:
                continue
            name = cells[0].strip()
            if not name or len(name) < 2:
                continue

            price_idx = self._find_price_column(cells)
            if price_idx < 0:
                continue

            raw_price = cells[price_idx].strip()
            parsed = self._parse_brl(raw_price)
            if parsed is None:
                continue

            key = f"{name}|{parsed}"
            if key in seen:
                continue
            seen.add(key)

            prices.append(PriceEntity(
                raw=raw_price,
                value=parsed,
                currency="BRL",
                context=name,
            ))

        return prices

    @staticmethod
    def _find_price_column(cells: list[str]) -> int:
        for i, c in enumerate(cells):
            if "R$" in c or "r$" in c or "R$" in c:
                return i
        for i in range(len(cells) - 1, -1, -1):
            val = re.sub(r"[R$\s.]", "", cells[i]).replace(",", ".")
            try:
                v = float(val)
                if 0.01 < v < 10000:
                    return i
            except ValueError:
                continue
        return -1

    @staticmethod
    def _parse_brl(text: str) -> float | None:
        cleaned = text.replace("R$", "").replace("r$", "").replace(" ", "")
        cleaned = re.sub(r"[^\d,.]", "", cleaned)
        if "," in cleaned:
            cleaned = cleaned.replace(".", "").replace(",", ".")
        try:
            v = float(cleaned)
            if 0 < v < 10000:
                return v
            return None
        except ValueError:
            return None

    @staticmethod
    def generate_xpath_from_entity(
        entity_text: str, tag: str = "*"
    ) -> list[str]:
        candidates: list[str] = []
        escaped = entity_text.replace("'", "&apos;")

        candidates.append(f"//{tag}[contains(text(), '{escaped}')]")
        candidates.append(f"//{tag}[contains(., '{escaped}')]")

        words = entity_text.split()[:3]
        if len(words) > 1:
            parts = " and ".join(
                f"contains(., '{w}')" for w in words if len(w) > 2
            )
            if parts:
                candidates.append(f"//{tag}[{parts}]")

        candidates.append(f"//{tag}[@title='{escaped}']")
        candidates.append(f"//{tag}[@alt='{escaped}']")
        candidates.append(f"//{tag}[@aria-label='{escaped}']")

        short = entity_text[:20]
        candidates.append(f"//*[starts-with(text(), '{short}')]")

        return candidates

    @staticmethod
    def score_xpath(xpath: str, html_str: str) -> float:
        try:
            tree = etree.fromstring(html_str.encode("utf-8"), etree.HTMLParser(recover=True))
            matches = tree.xpath(xpath)
            if not matches:
                return 0.0
            return min(len(matches) * 0.1, 1.0)
        except Exception:
            return 0.0

    def _build_unique_xpath(self, element: Any) -> str:
        parts: list[str] = []
        current = element
        while current is not None:
            tag = current.tag if isinstance(current.tag, str) else "?"
            parent = current.getparent() if hasattr(current, "getparent") else None

            if parent is not None:
                siblings = parent.findall(tag)
                if len(siblings) > 1:
                    idx = siblings.index(current) + 1
                    tag = f"{tag}[{idx}]"

            parts.insert(0, tag)

            if hasattr(current, "getparent"):
                current = current.getparent()
            else:
                current = None
                if hasattr(self._tree, "getroottree"):
                    try:
                        current = self._tree.getroottree().getroot().getparent()
                    except Exception:
                        pass

        return "/" + "/".join(parts) if parts else ""

    def _build_resilient_xpath(self, element: Any) -> str:
        class_names = element.get("class", "") if hasattr(element, "get") else ""
        element_id = element.get("id", "") if hasattr(element, "get") else ""

        if element_id:
            return f"//*[@id='{element_id}']"

        classes = class_names.split()
        if len(classes) >= 2:
            return "//" + element.tag + "[contains(@class, '" + classes[0] + "') and contains(@class, '" + classes[1] + "')]"
        elif classes:
            return "//" + element.tag + "[contains(@class, '" + classes[0] + "')]"

        role = element.get("role", "") if hasattr(element, "get") else ""
        if role == "table":
            return "//*[@role='table']"

        return self._build_unique_xpath(element)

    def _get_all_rows(self, table_elem: Any) -> list[Any]:
        rows = table_elem.xpath(".//tr")
        if not rows:
            rows = table_elem.xpath(".//div[contains(@class, 'row')]")
        return rows

    def _find_table_like_divs(self) -> list[TableCandidate]:
        if self._tree is None:
            return []
        candidates: list[TableCandidate] = []

        divs = self._tree.xpath("//div[count(./div) >= 3]")
        for idx, div in enumerate(divs):
            inner_divs = div.xpath("./div")
            if len(inner_divs) < 2:
                continue

            text_content = etree.tostring(div, method="text", encoding="unicode")
            has_price = "R$" in text_content or "r$" in text_content

            if has_price:
                candidates.append(TableCandidate(
                    xpath=self._build_resilient_xpath(div),
                    score=0.35,
                    row_count=len(inner_divs),
                    header_hint="div-table (auto-detected)",
                ))

        return candidates
