from __future__ import annotations

import logging
import re
from pathlib import Path

import polars as pl
from rapidfuzz import fuzz, process, utils as fuzz_utils

logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
CSV_PATH = PROJECT_ROOT / "docs" / "Planilha sem título - sazonalidade_produtos.csv"

ABREVIACOES: dict[str, str] = {
    "batata-doce": "batata doce",
    "batata doce": "batata doce",
    "b. doce": "batata doce",
    "c. roxa": "cebola roxa",
    "p. de queijo": "pao de queijo",
    "s. jorge": "sao jorge",
    "a. jordao": "antonio jordao",
    "p. alegre": "porto alegre",
    "r. preto": "rio preto",
    "s. jose": "sao jose",
}

STOP_WORDS = {
    "da", "de", "do", "das", "dos", "em", "para", "com",
    "tipo", "variedade", "grupo", "extra", "especial",
}

NORMALIZAR_ACENTOS = str.maketrans({
    "á": "a", "à": "a", "ã": "a", "â": "a",
    "é": "e", "ê": "e", "í": "i", "ó": "o",
    "ô": "o", "õ": "o", "ú": "u", "ü": "u",
    "ç": "c",
    "Á": "A", "À": "A", "Ã": "A", "Â": "A",
    "É": "E", "Ê": "E", "Í": "I", "Ó": "O",
    "Ô": "O", "Õ": "O", "Ú": "U", "Ü": "U",
    "Ç": "C",
})

def normalizar(nome: str | None) -> str:
    if not nome:
        return ""
    nome = nome.lower().strip()
    nome = nome.translate(NORMALIZAR_ACENTOS)
    nome = re.sub(r"[^\w\s]", " ", nome)
    nome = re.sub(r"\s+", " ", nome)
    for abrev, completo in ABREVIACOES.items():
        nome = nome.replace(abrev, completo)
    tokens = [t for t in nome.split() if t not in STOP_WORDS]
    return " ".join(tokens)


class EntityMatcher:
    def __init__(self, score_cutoff: float = 85.0):
        self.score_cutoff = score_cutoff
        self._df: pl.DataFrame | None = None
        self._master_names: list[str] = []
        self._master_names_norm: list[str] = []

    def carregar_master(self) -> pl.DataFrame:
        df = pl.read_csv(
            CSV_PATH,
            encoding="utf-8-sig",
            null_values=["", "-", "--"],
        )
        colunas = df.columns
        col_nome = next((c for c in colunas if "produto" in c.lower() or "nome" in c.lower() or "item" in c.lower()), colunas[0])
        self._df = df.unique(subset=[col_nome])
        self._master_names = [n for n in self._df[col_nome].to_list() if n]
        self._master_names_norm = [normalizar(n) for n in self._master_names]
        logger.info("EntityMatcher: %d itens únicos carregados", len(self._master_names))
        return df

    @property
    def df(self) -> pl.DataFrame:
        if self._df is None:
            self.carregar_master()
        return self._df

    def buscar(self, termo: str, top_n: int = 3) -> list[tuple[str, float]]:
        if not self._master_names_norm:
            self.carregar_master()
        termo_norm = normalizar(termo)
        resultados = process.extract(
            termo_norm,
            self._master_names_norm,
            scorer=fuzz.WRatio,
            limit=top_n,
            score_cutoff=self.score_cutoff,
        )
        return [(self._master_names[idx], score) for _, score, idx in resultados]

    def melhor_match(self, termo: str) -> tuple[str | None, float]:
        pares = self.buscar(termo, top_n=1)
        return pares[0] if pares else (None, 0.0)
