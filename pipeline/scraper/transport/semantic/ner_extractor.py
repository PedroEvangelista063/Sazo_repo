from __future__ import annotations

import csv
import json
import logging
import re
from pathlib import Path

from pipeline.scraper.transport.semantic.models import (
    DateEntity,
    EntityLabel,
    ExtractedEntity,
    PriceEntity,
)

logger = logging.getLogger(__name__)

RE_CNPJ = re.compile(r"\d{2}\.\d{3}\.\d{3}/\d{4}-\d{2}")
RE_CPF = re.compile(r"\d{3}\.\d{3}\.\d{3}-\d{2}")
RE_PRICE_BRL = re.compile(
    r"(?:R\$\s*|r\$\s*|R\$|r\$)?(\d{1,3}(?:\.\d{3})*,\d{2})"
)
RE_PRICE_USD = re.compile(r"\$\s*(\d{1,3}(?:,\d{3})*\.\d{2})")
RE_DATE_BR = re.compile(r"\b(\d{2})/(\d{2})/(\d{4})\b")
RE_DATE_ISO = re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b")
RE_PERCENT = re.compile(r"(\d+(?:[.,]\d+)?)\s*%")
RE_QUANTITY = re.compile(r"(\d+(?:[.,]\d+)?)\s*(kg|g|ton|t|l|ml|cx|sc|un|dz|pc|pto|saco|fardo)")
RE_UNIT = re.compile(r"\b(cx|sc|kg|g|ton|t|l|ml|un|dz|pc|pto|saco|fardo|duzia|d[úu]zia)\b", re.IGNORECASE)

_ENTITY_BLACKLIST = {
    "produto", "preço", "preco", "descricao", "unidade", "embalagem",
    "total", "subtotal", "página", "pagina", "voltar", "menu",
    "home", "inicio", "início", "contato", "sobre", "ajuda",
    "carrinho", "checkout", "login", "senha", "sair",
}

_PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent.parent.parent
_ALIASES_PATH = _PROJECT_ROOT / "pipeline" / "scraper" / "aliases.json"
_SAZONALIDADE_CSV = (
    _PROJECT_ROOT / "database" / "processed_data" / "01_raw"
    / "Planilha sem título - sazonalidade_produtos.csv"
)

_ACCENT_MAP = str.maketrans({
    "á": "a", "à": "a", "ã": "a", "â": "a",
    "é": "e", "ê": "e",
    "í": "i",
    "ó": "o", "õ": "o", "ô": "o",
    "ú": "u", "ü": "u",
    "ç": "c",
})

# fallback — 42 produtos essenciais caso os arquivos de domínio não existam
_FALLBACK_PRODUCTS: dict[str, str] = {
    "tomate": "TOMATE", "batata": "BATATA", "cebola": "CEBOLA",
    "cenoura": "CENOURA", "alface": "ALFACE", "banana": "BANANA",
    "laranja": "LARANJA", "maçã": "MAÇA", "mamão": "MAMÃO",
    "uva": "UVA", "melancia": "MELANCIA", "morango": "MORANGO",
    "abacate": "ABACATE", "abacaxi": "ABACAXI", "manga": "MANGA",
    "goiaba": "GOIABA", "maracujá": "MARACUJÁ", "limão": "LIMÃO",
    "beterraba": "BETERRABA", "abobrinha": "ABOBRINHA", "pepino": "PEPINO",
    "pimentão": "PIMENTÃO", "repolho": "REPOLHO", "milho": "MILHO",
    "alho": "ALHO", "cebolinha": "CEBOLINHA", "couve": "COUVE",
    "arroz": "ARROZ", "feijão": "FEIJÃO", "frango": "FRANGO",
    "carne": "CARNE", "óleo": "ÓLEO", "açúcar": "AÇÚCAR",
    "farinha": "FARINHA", "leite": "LEITE", "ovo": "OVO",
    "queijo": "QUEIJO", "batata doce": "BATATA DOCE",
    "mandioca": "MANDIOCA", "couve-flor": "COUVE-FLOR",
    "brócolis": "BRÓCOLIS", "espinafre": "ESPINAFRE",
}


def _build_product_whitelist() -> dict[str, str]:
    whitelist: dict[str, str] = {}
    whitelist.update(_FALLBACK_PRODUCTS)

    # 1. Load aliases.json (alias → normalized)
    if _ALIASES_PATH.exists():
        try:
            with open(_ALIASES_PATH, encoding="utf-8") as f:
                aliases: dict[str, str] = json.load(f)
            for raw_alias, normalized in aliases.items():
                key = raw_alias.strip().lower()
                if key:
                    normalized = normalized.strip().upper()
                    # keep the existing key if already present (aliases override CSV)
                    # but for the same key, aliases override each other (last wins is fine)
                    whitelist[key] = normalized
            logger.info(
                "[Produtos] Carregados %d aliases de %s",
                len(aliases), _ALIASES_PATH.name,
            )
        except Exception as e:
            logger.warning("[Produtos] Falha ao ler aliases.json: %s", e)
    else:
        logger.warning("[Produtos] aliases.json nao encontrado em %s", _ALIASES_PATH)

    # 2. Load sazonalidade CSV (product names → normalized to same name)
    if _SAZONALIDADE_CSV.exists():
        try:
            with open(_SAZONALIDADE_CSV, encoding="utf-8-sig") as f:
                reader = csv.DictReader(f)
                col_produto = None
                for candidate in ("Produto", "produto", "NOME", "nome", "PRODUTO"):
                    if candidate in reader.fieldnames:
                        col_produto = candidate
                        break
                if col_produto:
                    count = 0
                    for row in reader:
                        name = (row.get(col_produto) or "").strip()
                        if not name or len(name) < 2:
                            continue
                        upper = name.upper()
                        # original accented key (matches text_lower which preserves accents)
                        key = name.lower()
                        if key not in whitelist:
                            whitelist[key] = upper
                            count += 1
                        # also add accent-stripped key for partial matches
                        key_flat = key.translate(_ACCENT_MAP)
                        key_flat = re.sub(r"[^\w\s]", " ", key_flat)
                        key_flat = re.sub(r"\s+", " ", key_flat).strip()
                        if key_flat != key and key_flat not in whitelist:
                            whitelist[key_flat] = upper
                            count += 1
                    logger.info(
                        "[Produtos] Adicionados %d entradas do CSV (total: %d)",
                        count, len(whitelist),
                    )
        except Exception as e:
            logger.warning("[Produtos] Falha ao ler CSV de sazonalidade: %s", e)
    else:
        logger.warning(
            "[Produtos] CSV sazonalidade nao encontrado em %s", _SAZONALIDADE_CSV,
        )

    return whitelist


_ENTITY_WHITELIST_PRODUCTS: dict[str, str] = _build_product_whitelist()


class NERExtractor:
    def __init__(self, model: str | None = None) -> None:
        self._nlp = None
        self._model = model or "pt_core_news_lg"
        self._model_loaded = False
        self._ner_labels: set[str] = set()

    def _ensure_spacy(self) -> bool:
        if self._model_loaded:
            return True
        try:
            import spacy
            try:
                self._nlp = spacy.load(
                    self._model,
                    disable=["tagger", "parser", "lemmatizer", "morphologizer"],
                )
                self._model_loaded = True
                self._ner_labels = set(self._nlp.get_pipe("ner").labels) if "ner" in self._nlp.pipe_names else set()
                logger.info(
                    "[NERExtractor] SpaCy loaded: %s | %d NER labels",
                    self._model, len(self._ner_labels),
                )
                return True
            except OSError:
                logger.warning(
                    "[NERExtractor] Model '%s' not found. Install: python -m spacy download %s",
                    self._model, self._model,
                )
                return False
        except ImportError:
            logger.info("[NERExtractor] SpaCy not installed. Install: pip install spacy")
            return False
        except Exception as e:
            logger.warning("[NERExtractor] SpaCy load failed: %s", e)
            return False

    @property
    def available(self) -> bool:
        if not self._model_loaded:
            self._ensure_spacy()
        return self._model_loaded

    def extract_all(
        self, html: str, page_url: str = ""
    ) -> tuple[list[ExtractedEntity], list[PriceEntity], list[DateEntity]]:
        clean_text = self._clean_html(html)
        entities: list[ExtractedEntity] = []
        prices: list[PriceEntity] = []
        dates: list[DateEntity] = []

        if self._ensure_spacy() and self._nlp and clean_text:
            doc = self._nlp(clean_text[:50000])
            for ent in doc.ents:
                label = self._map_spacy_label(ent.label_)
                if not label:
                    continue
                if self._is_blacklisted(ent.text):
                    continue
                entities.append(ExtractedEntity(
                    text=ent.text.strip(),
                    label=label,
                    confidence=min(ent._.get("score", 0.9) if hasattr(ent._, "score") else 0.9, 1.0),
                    start_char=max(0, ent.start_char),
                    end_char=ent.end_char,
                ))

        custom_entities = self._extract_custom_entities(clean_text)
        entities.extend(custom_entities)

        prices = self._extract_prices(clean_text)
        dates = self._extract_dates(clean_text)

        product_entities = self._extract_products(clean_text)
        entities.extend(product_entities)

        entities = self._deduplicate(entities)
        return entities, prices, dates

    @staticmethod
    def _clean_html(html: str) -> str:
        text = re.sub(r"<script[^>]*>.*?</script>", "", html, flags=re.IGNORECASE | re.DOTALL)
        text = re.sub(r"<style[^>]*>.*?</style>", "", text, flags=re.IGNORECASE | re.DOTALL)
        text = re.sub(r"<[^>]+>", " ", text)
        text = re.sub(r"&[a-z]+;", " ", text)
        text = re.sub(r"\s+", " ", text)
        text = re.sub(r"[^\w\s.,:;!?/@\-$%()\[\]{}]", " ", text)
        return text.strip()

    @staticmethod
    def _is_blacklisted(text: str) -> bool:
        return text.strip().lower() in _ENTITY_BLACKLIST

    @staticmethod
    def _map_spacy_label(spacy_label: str) -> EntityLabel | None:
        mapping: dict[str, EntityLabel] = {
            "PER": EntityLabel.PERSON,
            "PERSON": EntityLabel.PERSON,
            "ORG": EntityLabel.ORGANIZATION,
            "LOC": EntityLabel.LOCATION,
            "LOCAL": EntityLabel.LOCATION,
            "GPE": EntityLabel.LOCATION,
            "MISC": EntityLabel.MISC,
            "DATE": EntityLabel.DATE,
            "TIME": EntityLabel.TIME,
            "MONEY": EntityLabel.MONEY,
            "QUANTITY": EntityLabel.QUANTITY,
            "PERCENT": EntityLabel.PERCENT,
            "PRODUCT": EntityLabel.PRODUCT,
            "EVENT": EntityLabel.MISC,
        }
        return mapping.get(spacy_label)

    def _extract_custom_entities(self, text: str) -> list[ExtractedEntity]:
        entities: list[ExtractedEntity] = []

        for match in RE_CNPJ.finditer(text):
            entities.append(ExtractedEntity(
                text=match.group(),
                label=EntityLabel.CNPJ,
                confidence=0.95,
                start_char=match.start(),
                end_char=match.end(),
            ))

        for match in RE_CPF.finditer(text):
            entities.append(ExtractedEntity(
                text=match.group(),
                label=EntityLabel.CPF,
                confidence=0.95,
                start_char=match.start(),
                end_char=match.end(),
            ))

        for match in RE_QUANTITY.finditer(text):
            entities.append(ExtractedEntity(
                text=match.group(),
                label=EntityLabel.QUANTITY,
                confidence=0.85,
                start_char=match.start(),
                end_char=match.end(),
                metadata={"value": match.group(1), "unit": match.group(2)},
            ))

        return entities

    @staticmethod
    def _extract_prices(text: str) -> list[PriceEntity]:
        prices: list[PriceEntity] = []

        for match in RE_PRICE_BRL.finditer(text):
            raw = match.group(0)
            val_str = match.group(1).replace(".", "").replace(",", ".")
            try:
                prices.append(PriceEntity(
                    raw=raw,
                    value=float(val_str),
                    currency="BRL",
                ))
            except ValueError:
                pass

        for match in RE_PRICE_USD.finditer(text):
            raw = match.group(0)
            val_str = match.group(1).replace(",", "")
            try:
                prices.append(PriceEntity(
                    raw=raw,
                    value=float(val_str),
                    currency="USD",
                ))
            except ValueError:
                pass

        return prices

    @staticmethod
    def _extract_dates(text: str) -> list[DateEntity]:
        dates: list[DateEntity] = []

        for match in RE_DATE_BR.finditer(text):
            day, month, year = int(match.group(1)), int(match.group(2)), int(match.group(3))
            if 2000 <= year <= 2100 and 1 <= month <= 12 and 1 <= day <= 31:
                dates.append(DateEntity(
                    raw=match.group(),
                    normalized=f"{year:04d}-{month:02d}-{day:02d}",
                    year=year, month=month, day=day,
                ))

        for match in RE_DATE_ISO.finditer(text):
            year, month, day = int(match.group(1)), int(match.group(2)), int(match.group(3))
            if 2000 <= year <= 2100 and 1 <= month <= 12 and 1 <= day <= 31:
                dates.append(DateEntity(
                    raw=match.group(),
                    normalized=match.group(),
                    year=year, month=month, day=day,
                ))

        return dates

    @staticmethod
    def _extract_products(text: str) -> list[ExtractedEntity]:
        entities: list[ExtractedEntity] = []
        text_lower = text.lower()
        found_positions: list[tuple[int, int]] = []

        # Longer keys first so "batata doce" matches before "batata"
        for name, normalized in sorted(
            _ENTITY_WHITELIST_PRODUCTS.items(),
            key=lambda kv: -len(kv[0]),
        ):
            idx = text_lower.find(name)
            if idx < 0:
                continue
            end = idx + len(name)
            # Skip if this position is already covered by a longer match
            if any(s <= idx < e for s, e in found_positions):
                continue
            found_positions.append((idx, end))
            entities.append(ExtractedEntity(
                text=text[idx:end],
                label=EntityLabel.PRODUCT,
                confidence=0.9,
                start_char=idx,
                end_char=end,
                metadata={"normalized": normalized},
            ))

        return entities

    @staticmethod
    def _deduplicate(entities: list[ExtractedEntity]) -> list[ExtractedEntity]:
        seen: set[tuple[str, str]] = set()
        result: list[ExtractedEntity] = []
        for ent in sorted(entities, key=lambda e: -e.confidence):
            key = (ent.text.lower(), ent.label.value)
            if key not in seen:
                seen.add(key)
                result.append(ent)
        return result
