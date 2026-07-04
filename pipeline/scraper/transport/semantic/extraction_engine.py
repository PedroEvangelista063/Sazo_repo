from __future__ import annotations

import logging
import time
from typing import Any

from pipeline.scraper.transport.semantic.block_detector import BlockDetector
from pipeline.scraper.transport.semantic.models import ExtractionResult, PriceEntity
from pipeline.scraper.transport.semantic.ner_extractor import NERExtractor
from pipeline.scraper.transport.semantic.xpath_selector import DynamicXPathSelector

logger = logging.getLogger(__name__)


class SemanticExtractionEngine:
    """Orchestrator for semantic analysis of scraped pages.

    Pipeline:
      1. Get page content (HTML) from browser engine or raw string
      2. Block detection via VADER + sentiment heuristics
      3. HTML cleaning and text extraction
      4. NER via SpaCy (entities, prices, dates, products)
      5. Dynamic XPath table candidate identification
      6. Return structured ExtractionResult
    """

    def __init__(
        self,
        spacy_model: str | None = None,
        use_vader: bool = True,
    ) -> None:
        self._block_detector = BlockDetector(use_vader=use_vader)
        self._ner = NERExtractor(model=spacy_model)
        self._xpath = DynamicXPathSelector()

    @property
    def vader_available(self) -> bool:
        return self._block_detector.vader_available

    @property
    def spacy_available(self) -> bool:
        return self._ner.available

    async def analyze_from_engine(self, engine: Any) -> ExtractionResult:
        t0 = time.perf_counter()

        html = ""
        page_url = ""
        title = ""

        try:
            html = await engine.content()
        except Exception as e:
            logger.warning("[SemanticEngine] Failed to get content: %s", e)

        try:
            page_url = await engine.evaluate("window.location.href")
        except Exception:
            pass

        try:
            title = await engine.evaluate("document.title")
        except Exception:
            pass

        result = self._run_pipeline(html, page_url, title)
        result.extraction_time_ms = int((time.perf_counter() - t0) * 1000)
        return result

    def analyze(self, html: str, url: str = "", title: str = "") -> ExtractionResult:
        t0 = time.perf_counter()
        result = self._run_pipeline(html, url, title)
        result.extraction_time_ms = int((time.perf_counter() - t0) * 1000)
        return result

    def _run_pipeline(self, html: str, url: str, title: str) -> ExtractionResult:
        result = ExtractionResult(
            url=url,
            title=title,
            spaCy_available=self._ner.available,
            vader_available=self._block_detector.vader_available,
        )

        result.block_detection = self._block_detector.analyze(html, url)
        result.clean_text = self._ner._clean_html(html)

        entities, prices, dates = self._ner.extract_all(html, url)
        result.entities = entities
        result.prices = prices
        result.dates = dates

        product_hints = [
            e.text for e in entities
            if e.label.value == "PRODUCT"
        ]
        orgs = set()
        locs = set()
        persons = set()
        for e in entities:
            if e.label.value == "ORG":
                orgs.add(e.text)
            elif e.label.value == "LOC":
                locs.add(e.text)
            elif e.label.value == "PERSON":
                persons.add(e.text)
        result.organizations = sorted(orgs)
        result.locations = sorted(locs)
        result.persons = sorted(persons)

        result.table_candidates = self._xpath.find_tables(html, product_hints)

        for tc in result.table_candidates[:5]:
            logger.info(
                "[SemanticEngine] Table candidate (score=%.2f, rows=%d, cols=%d): xpath=%s",
                tc.score, tc.row_count, len(tc.columns),
                tc.xpath[:100],
            )

        top_tables = [tc for tc in result.table_candidates if tc.score >= 0.4]
        if top_tables:
            table_prices: list[PriceEntity] = []
            for tc in top_tables[:2]:
                parsed = self._xpath.parse_table_to_prices(html, tc)
                if parsed:
                    logger.info(
                        "[SemanticEngine] Tabela extraiu %d precos de %s",
                        len(parsed), tc.xpath[:80],
                    )
                    table_prices.extend(parsed)

            if table_prices:
                result.prices.extend(table_prices)
                result.table_rows = [[p.context, p.raw] for p in table_prices]

        return result

    def find_entity_context(
        self, entity_text: str, html: str, window_chars: int = 200
    ) -> str:
        clean = self._ner._clean_html(html)
        idx = clean.lower().find(entity_text.lower())
        if idx < 0:
            return ""
        start = max(0, idx - window_chars // 2)
        end = min(len(clean), idx + len(entity_text) + window_chars // 2)
        context = clean[start:end]
        if start > 0:
            context = "..." + context
        if end < len(clean):
            context = context + "..."
        return context

    def extract_values_near_entity(
        self, entity_text: str, html: str, radius_lines: int = 3
    ) -> list[dict[str, Any]]:
        rows = html.split("\n")
        results: list[dict[str, Any]] = []

        for idx, line in enumerate(rows):
            if entity_text.lower() in line.lower():
                start = max(0, idx - radius_lines)
                end = min(len(rows), idx + radius_lines + 1)
                context_block = "\n".join(rows[start:end])
                from pipeline.scraper.transport.semantic.ner_extractor import (
                    RE_PRICE_BRL,
                    RE_DATE_BR,
                    RE_QUANTITY,
                )

                prices = [m.group() for m in RE_PRICE_BRL.finditer(context_block)]
                dates = [m.group() for m in RE_DATE_BR.finditer(context_block)]
                quantities = [m.group() for m in RE_QUANTITY.finditer(context_block)]

                results.append({
                    "line": idx,
                    "entity": entity_text,
                    "prices": prices,
                    "dates": dates,
                    "quantities": quantities,
                    "context": context_block.strip()[:300],
                })

        return results

    async def extract_from_engine_near_entity(
        self, engine: Any, entity_text: str
    ) -> list[dict[str, Any]]:
        html = ""
        try:
            html = await engine.content()
        except Exception:
            return []
        return self.extract_values_near_entity(entity_text, html)
