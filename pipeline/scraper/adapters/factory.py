from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any

from pipeline.scraper.adapters.base import BaseAdapter, CotacaoRegional
from pipeline.scraper.adapters.hortifrut.ceasa_standard import (
    CEASA_REGISTRY,
    CeasaStandardAdapter,
)
from pipeline.scraper.adapters.hortifrut.prohort import ProHortAdapter

logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent.parent
SOURCES_MAP_PATH = PROJECT_ROOT / "config" / "sources_map.json"


class ScraperFactory:
    _instance: ScraperFactory | None = None
    _sources_map: dict[str, list[dict]] = {}
    _adapters_cache: dict[str, BaseAdapter] = {}

    def __new__(cls) -> ScraperFactory:
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __init__(self) -> None:
        if not self._sources_map:
            self._carregar_sources_map()

    def _carregar_sources_map(self) -> None:
        if SOURCES_MAP_PATH.exists():
            try:
                with open(SOURCES_MAP_PATH, encoding="utf-8") as f:
                    raw = json.load(f)
                    produtos = raw.get("produtos", raw)
                    if isinstance(produtos, list):
                        for entry in produtos:
                            nome = entry.get("produto", "").upper()
                            fontes = entry.get("fontes", [])
                            if nome and fontes:
                                self._sources_map[nome] = fontes
                    elif isinstance(produtos, dict):
                        self._sources_map = {k.upper(): v for k, v in produtos.items()}
                logger.info(
                    "ScraperFactory: %d produtos mapeados em %s",
                    len(self._sources_map), SOURCES_MAP_PATH,
                )
            except Exception as e:
                logger.warning("Erro ao carregar sources_map: %s", e)
        if not self._sources_map:
            self._sources_map = self._sources_map_default()

    @staticmethod
    def _sources_map_default() -> dict[str, list[dict]]:
        return {
            "TOMATE": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
                {"fonte": "CEASA-PR", "uf": "PR", "municipio": "Curitiba"},
                {"fonte": "CEASA-GO", "uf": "GO", "municipio": "Goiania"},
                {"fonte": "CEASA-CE", "uf": "CE", "municipio": "Maracanau"},
                {"fonte": "CEASA-RS", "uf": "RS", "municipio": "Porto Alegre"},
                {"fonte": "CEASA-SC", "uf": "SC", "municipio": "Sao Jose"},
                {"fonte": "CEASA-BA", "uf": "BA", "municipio": "Salvador"},
                {"fonte": "CEASA-MG", "uf": "MG", "municipio": "Contagem"},
                {"fonte": "CEASA-DF", "uf": "DF", "municipio": "Brasilia"},
            ],
            "BATATA": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
                {"fonte": "CEASA-PR", "uf": "PR", "municipio": "Curitiba"},
                {"fonte": "CEASA-GO", "uf": "GO", "municipio": "Goiania"},
            ],
            "CEBOLA": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
                {"fonte": "CEASA-PR", "uf": "PR", "municipio": "Curitiba"},
            ],
            "CENOURA": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
                {"fonte": "CEASA-PR", "uf": "PR", "municipio": "Curitiba"},
            ],
            "ALFACE": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
            ],
            "BANANA": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
                {"fonte": "CEASA-SC", "uf": "SC", "municipio": "Sao Jose"},
            ],
            "LARANJA": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
            ],
            "MACA": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
                {"fonte": "CEASA-RS", "uf": "RS", "municipio": "Porto Alegre"},
            ],
            "MAMAO": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
            ],
            "UVA": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
            ],
            "BETERRABA": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
            ],
            "ABOBRINHA": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
            ],
            "PEPINO": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
            ],
            "PIMENTAO": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
            ],
            "MILHO": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
            ],
            "MANDIOCA": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
            ],
            "MELANCIA": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
            ],
            "MORANGO": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
            ],
            "GOIABA": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
            ],
            "MANGA": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
            ],
            "BATATA DOCE": [
                {"fonte": "CONAB-ProHort", "uf": "BR", "municipio": "Nacional"},
            ],
        }

    def criar_adapter(self, config_fonte: dict) -> BaseAdapter | None:
        fonte = config_fonte.get("fonte", "")
        uf = config_fonte.get("uf", "BR")
        municipio = config_fonte.get("municipio", "")
        cache_key = f"{fonte}|{uf}|{municipio}"

        if cache_key in self._adapters_cache:
            return self._adapters_cache[cache_key]

        adapter: BaseAdapter | None = None

        if fonte == "CONAB-ProHort":
            adapter = ProHortAdapter(uf=uf, municipio=municipio)

        elif fonte in CEASA_REGISTRY:
            adapter = CeasaStandardAdapter.from_registry(fonte)

        else:
            logger.warning(
                "Nenhum adapter registrado para fonte '%s'. "
                "Use register_adapter() para fontes customizadas.",
                fonte,
            )

        if adapter:
            self._adapters_cache[cache_key] = adapter
        return adapter

    def fonte_para_produto(
        self, produto: str, regiao: str | None = None
    ) -> list[dict]:
        produto_key = produto.upper().strip()
        fontes = self._sources_map.get(produto_key, [])
        if regiao:
            regiao_upper = regiao.upper()
            fontes = [
                f for f in fontes
                if f.get("uf", "").upper() == regiao_upper
            ]
        return fontes

    def adapters_para_produto(
        self, produto: str, regiao: str | None = None
    ) -> list[BaseAdapter]:
        fontes = self.fonte_para_produto(produto, regiao)
        adapters: list[BaseAdapter] = []
        for config_fonte in fontes:
            adapter = self.criar_adapter(config_fonte)
            if adapter:
                adapters.append(adapter)
        return adapters

    def produtos_disponiveis(self) -> list[str]:
        return sorted(self._sources_map.keys())

    def register_adapter(
        self,
        nome_fonte: str,
        adapter_cls: type[BaseAdapter],
        **kwargs: Any,
    ) -> None:
        cache_key = f"{nome_fonte}|{kwargs.get('uf', '')}|{kwargs.get('municipio', '')}"
        adapter = adapter_cls(**kwargs)
        adapter.fonte = nome_fonte
        self._adapters_cache[cache_key] = adapter
        logger.info("Adapter registrado: %s (%s-%s)", nome_fonte, kwargs.get("uf", ""), kwargs.get("municipio", ""))

    def limpar_cache(self) -> None:
        self._adapters_cache.clear()
        logger.info("Cache de adapters limpo")
