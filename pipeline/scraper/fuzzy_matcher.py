from __future__ import annotations

import logging
import re
from pathlib import Path

import polars as pl
from rapidfuzz import fuzz, process

logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
CSV_PATH = PROJECT_ROOT / "dados_sazonliza_dados_bruto" / "Planilha sem t\u00edtulo - sazonalidade_produtos.csv"

ABREVIACOES = {
    "batata-doce": "batata doce",
    "b. doce": "batata doce",
    "c. roxa": "cebola roxa",
    "p. de queijo": "pao de queijo",
    "s. jorge": "sao jorge",
    "r. preto": "rio preto",
}

STOP_WORDS = {
    "da",
    "de",
    "do",
    "das",
    "dos",
    "em",
    "para",
    "com",
    "tipo",
    "variedade",
    "grupo",
    "extra",
    "especial",
}

NORM_TABLE = str.maketrans(
    {
        "\u00e1": "a",
        "\u00e0": "a",
        "\u00e3": "a",
        "\u00e2": "a",
        "\u00e9": "e",
        "\u00ea": "e",
        "\u00ed": "i",
        "\u00f3": "o",
        "\u00f4": "o",
        "\u00f5": "o",
        "\u00fa": "u",
        "\u00fc": "u",
        "\u00e7": "c",
    }
)


def normalizar(nome: str | None) -> str:
    if not nome:
        return ""
    n = nome.lower().strip().translate(NORM_TABLE)
    n = re.sub(r"[^\w\s]", " ", n)
    n = re.sub(r"\s+", " ", n)
    for abrev, completo in ABREVIACOES.items():
        n = n.replace(abrev, completo)
    return " ".join(t for t in n.split() if t not in STOP_WORDS)


class ConciliadorSemantico:
    def __init__(self, score_cutoff: float = 85.0):
        self.score_cutoff = score_cutoff
        self._df: pl.DataFrame | None = None
        self._nomes_csv: list[str] = []
        self._nomes_norm: list[str] = []

    def carregar_csv(self) -> pl.DataFrame:
        df = pl.read_csv(CSV_PATH, encoding="utf-8-sig", null_values=["", "-", "--"])
        col_nome = next(
            (c for c in df.columns if "produto" in c.lower() or "nome" in c.lower()),
            df.columns[0],
        )
        df = df.filter(pl.col(col_nome).is_not_null()).unique(subset=[col_nome])
        self._df = df
        self._nomes_csv = [n for n in df[col_nome].to_list() if n]
        self._nomes_norm = [normalizar(n) for n in self._nomes_csv]
        logger.info("Conciliador: %d itens carregados do CSV", len(self._nomes_csv))
        return df

    def conciliar(self, nome_bruto: str) -> tuple[str | None, float]:
        if not self._nomes_norm:
            self.carregar_csv()
        termo = normalizar(nome_bruto)
        if not termo:
            return None, 0.0
        resultado = process.extractOne(
            termo, self._nomes_norm, scorer=fuzz.WRatio, score_cutoff=self.score_cutoff
        )
        if resultado:
            idx = self._nomes_norm.index(resultado[0])
            return self._nomes_csv[idx], resultado[1]
        return None, 0.0

    def conciliar_lote(self, nomes_brutos: list[str]) -> pl.DataFrame:
        registros = []
        for nb in nomes_brutos:
            match, score = self.conciliar(nb)
            registros.append({"produto_original": nb, "produto": match or "", "match_score": score})
        return pl.DataFrame(registros)
