from __future__ import annotations

import logging
import re
from typing import Any

from pipeline.scraper.adapters.base import CotacaoRegional, validar_cotacao
from pipeline.scraper.adapters.stealth import BaseTargetAdapter
from pipeline.scraper.transport.semantic.models import InteractionStep

logger = logging.getLogger(__name__)

_CONTEXT_WINDOW = 150


class OrganismAdapter(BaseTargetAdapter):
    """Adapter bridge between SelfHealingOrganism and the BaseTargetAdapter interface.

    Wraps the autonomous Organism (Phases 1-4) into a standard adapter so
    SmartCrawler2026 can route WAF-heavy targets through it without changing
    the existing pipeline contract.

    The Organism manages its own browser engine, challenge resolution, identity
    rotation, and spaCy-based extraction internally. This adapter maps the
    HarvestResult (``extraction.prices``) into ``list[CotacaoRegional]`` by
    associating each price with the nearest PRODUCT entity in clean_text, then
    runs the Pydantic guardrail on each item.
    """

    def __init__(
        self,
        organism: Any | None = None,
        url: str = "",
        uf: str = "",
        municipio: str = "",
        fonte: str = "",
        ano: int = 0,
        mes: int = 0,
        pre_actions: list[InteractionStep] | None = None,
    ):
        self.url = url
        self.uf = uf
        self.municipio = municipio
        self.fonte = fonte
        self.ano = ano
        self.mes = mes
        self._pre_actions = pre_actions
        self._organism = organism

    async def execute(self, page: Any = None) -> list[CotacaoRegional]:
        if not self._organism:
            logger.error("[OrganismAdapter] SelfHealingOrganism nao fornecido")
            return []

        result = await self._organism.harvest(url=self.url, pre_actions=self._pre_actions)
        return self._converter(result)

    def _converter(self, result: Any) -> list[CotacaoRegional]:
        if not result.success or not result.extraction:
            logger.warning(
                "[OrganismAdapter] harvest falhou para %s — %s",
                self.url, result.error,
            )
            return []

        ext = result.extraction
        items: list[CotacaoRegional] = []
        seen: set[str] = set()

        products = self._build_product_index(ext)

        for price in ext.prices:
            nome = self._resolve_product_name(price, products, ext.clean_text)
            key = f"{nome}|{price.value}|{price.unit}"
            if key in seen:
                continue
            seen.add(key)

            cot = CotacaoRegional(
                produto_original=nome,
                preco_bruto=price.value,
                unidade_medida=price.unit,
                uf=self.uf,
                municipio=self.municipio,
                fonte=self.fonte or result.url,
                status_coleta="sucesso",
                ano=self.ano,
                mes=self.mes,
            )
            validated = validar_cotacao(cot)
            if validated:
                items.append(validated)

        if not items:
            logger.info(
                "[OrganismAdapter] Nenhum price entity — "
                "tentando fallback por entidades PRODUCT/PRICE"
            )
            items = self._fallback_entity_pairing(ext)

        return items

    @staticmethod
    def _build_product_index(
        ext: Any,
    ) -> list[tuple[int, int, str]]:
        products: list[tuple[int, int, str]] = []
        for ent in ext.entities:
            label = ent.label.value if hasattr(ent.label, "value") else str(ent.label)
            if label == "PRODUCT":
                products.append((ent.start_char, ent.end_char, ent.text.strip()))
        return products

    def _resolve_product_name(
        self,
        price: Any,
        products: list[tuple[int, int, str]],
        clean_text: str,
    ) -> str:
        if price.context and price.context.strip():
            return price.context.strip()

        if not clean_text or not price.raw:
            return "produto_desconhecido"

        pos = clean_text.find(price.raw)
        if pos < 0:
            return "produto_desconhecido"

        best: str | None = None
        best_dist = _CONTEXT_WINDOW
        for start, end, name in products:
            if start <= pos <= end:
                best = name
                break
            dist = min(abs(pos - end), abs(start - pos))
            if dist < best_dist:
                best_dist = dist
                best = name

        return best or "produto_desconhecido"

    def _fallback_entity_pairing(self, ext: Any) -> list[CotacaoRegional]:
        items: list[CotacaoRegional] = []
        products: list[str] = []
        prices: list[float] = []

        for ent in ext.entities:
            label = ent.label.value if hasattr(ent.label, "value") else str(ent.label)
            if label in ("PRODUCT", "PRODUTO") and ent.confidence >= 0.5:
                products.append(ent.text.strip())
            elif label in ("PRICE", "MONEY", "QUANTITY") and ent.confidence >= 0.5:
                try:
                    prices.append(float(ent.text.replace("R$", "").replace(",", ".").strip()))
                except ValueError:
                    pass

        for prod, prec in zip(products, prices):
            cot = CotacaoRegional(
                produto_original=prod,
                preco_bruto=prec,
                uf=self.uf,
                municipio=self.municipio,
                fonte=self.fonte or "organism-entity",
                status_coleta="sucesso",
                ano=self.ano,
                mes=self.mes,
            )
            validated = validar_cotacao(cot)
            if validated:
                items.append(validated)

        return items
