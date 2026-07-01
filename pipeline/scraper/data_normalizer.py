from __future__ import annotations

import json
import logging
import re
from collections import Counter
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import polars as pl
from rapidfuzz import fuzz, process

from pipeline.scraper.ceasa_spider import CotacaoHistorica

logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
CSV_PATH = PROJECT_ROOT / "dados_sazonliza_dados_bruto" / "Planilha sem t\u00edtulo - sazonalidade_produtos.csv"
ALIASES_PATH = Path(__file__).resolve().parent / "aliases.json"
UNMATCHED_LOG = PROJECT_ROOT / "logs" / "unmatched_items.log"

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
    "primeira",
    "segunda",
}

ABREVIACOES = {
    "batata-doce": "batata doce",
    "b. doce": "batata doce",
    "c. roxa": "cebola roxa",
    "p. de queijo": "pao de queijo",
    "s. jorge": "sao jorge",
    "r. preto": "rio preto",
}

SUFIXOS_QUALIFICADOR = [
    "atacado",
    "produtor",
    "beneficiador",
    "tomate",
]

RE_UNIDADE = re.compile(r"\d+\s?(kg|g|dz|un|l|ml|cx|sc|cx\d+dz|sc\d+kg|cx\d+kg)", re.IGNORECASE)


def _carregar_aliases(path: Path | None = None) -> dict[str, str]:
    path = path or ALIASES_PATH
    if not path.exists():
        logger.warning("aliases.json nao encontrado em %s", path)
        return {}
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    aliases = {}
    for chave, valor in raw.items():
        n = normalizar(limpar_bruto(chave))
        aliases[n] = valor
    logger.info("Aliases carregados: %d entradas", len(aliases))
    return aliases


def limpar_unidades(nome: str) -> str:
    return RE_UNIDADE.sub("", nome).strip()


def normalizar(nome: str | None) -> str:
    if not nome:
        return ""
    n = nome.lower().strip().translate(NORM_TABLE)
    n = RE_UNIDADE.sub("", n)
    n = re.sub(r"[^\w\s]", " ", n)
    n = re.sub(r"\s+", " ", n)
    for abrev, completo in ABREVIACOES.items():
        n = n.replace(abrev, completo)
    return " ".join(t for t in n.split() if t not in STOP_WORDS)


def limpar_bruto(nome: str) -> str:
    n = nome.lower().strip()
    n = limpar_unidades(n)
    n = re.sub(r"\([^)]*\)", "", n)
    n = re.sub(r"[-]\s*(" + "|".join(SUFIXOS_QUALIFICADOR) + r")", "", n)
    n = re.sub(r"\bcat\s*\d+\b", "", n)
    n = re.sub(r"\btipo\s*\d+\b", "", n)
    n = re.sub(r"\b(aa|aaa|aaaa)\b", "", n)
    n = re.sub(r"\s+", " ", n).strip()
    return n


@dataclass
class ResultadoNormalizacao:
    nome_original: str
    nome_padrao: str | None
    categoria: str | None
    score: float
    metodo: str


class DataNormalizer:
    def __init__(self, fuzzy_cutoff: float = 75.0):
        self.fuzzy_cutoff = fuzzy_cutoff
        self._master: dict[str, dict] = {}
        self._token_index: dict[str, list[str]] = {}
        self._nomes_csv: list[str] = []
        self._nomes_norm: list[str] = []
        self._aliases: dict[str, str] = {}
        self._carregado = False
        self._unmatched_counter: Counter = Counter()

    @property
    def aliases(self) -> dict[str, str]:
        if not self._aliases:
            self._aliases = _carregar_aliases()
        return self._aliases

    def carregar_csv(self, path: str | Path | None = None) -> None:
        path = path or CSV_PATH
        df = pl.read_csv(path, encoding="utf-8-sig", null_values=["", "-", "--"])
        col_nome = next(
            (c for c in df.columns if "produto" in c.lower() or "nome" in c.lower()),
            df.columns[0],
        )
        col_cat = next(
            (c for c in df.columns if "categoria" in c.lower()),
            None,
        )

        df = df.filter(pl.col(col_nome).is_not_null()).unique(subset=[col_nome])

        for row in df.iter_rows():
            nome = str(row[df.columns.index(col_nome)])
            if not nome:
                continue
            cat = str(row[df.columns.index(col_cat)]) if col_cat else ""
            if cat.startswith("---"):
                continue
            n = normalizar(nome)
            self._master[n] = {"nome": nome, "categoria": cat}
            self._nomes_csv.append(nome)
            self._nomes_norm.append(n)
            for tok in n.split():
                if len(tok) > 2:
                    self._token_index.setdefault(tok, []).append(n)

        self._carregado = True
        logger.info(
            "DataNormalizer: %d itens carregados, %d tokens indexados, %d aliases",
            len(self._master),
            len(self._token_index),
            len(self.aliases),
        )

    def _ensure_loaded(self) -> None:
        if not self._carregado:
            self.carregar_csv()

    def _log_unmatched(self, nome_bruto: str) -> None:
        self._unmatched_counter[nome_bruto] += 1

    def _flush_unmatched(self) -> None:
        if not self._unmatched_counter:
            return
        UNMATCHED_LOG.parent.mkdir(parents=True, exist_ok=True)
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(UNMATCHED_LOG, "a", encoding="utf-8") as f:
            f.write(f"\n--- {ts} ---\n")
            for prod, count in self._unmatched_counter.most_common(50):
                f.write(f"{count:4d}x {prod}\n")
        self._unmatched_counter.clear()

    def normalizar(self, nome_bruto: str) -> ResultadoNormalizacao:
        self._ensure_loaded()

        # Clean units from raw name first
        nome_sem_unidade = limpar_unidades(nome_bruto)
        n = normalizar(nome_sem_unidade)
        limpo = limpar_bruto(nome_sem_unidade)
        n_limpo = normalizar(limpo)

        if not n:
            self._log_unmatched(nome_bruto)
            return ResultadoNormalizacao(
                nome_original=nome_bruto,
                nome_padrao=None,
                categoria=None,
                score=0.0,
                metodo="vazio",
            )

        # E0: alias match
        alias_key = n_limpo or n
        if alias_key in self.aliases:
            alias_target = self.aliases[alias_key]
            target_norm = normalizar(alias_target)
            m = self._master.get(target_norm)
            if m is None:
                prefix = target_norm + " "
                sorted_keys = sorted(self._master)
                for mkey in sorted_keys:
                    if mkey.startswith(prefix):
                        m = self._master[mkey]
                        break
            if m is not None:
                return ResultadoNormalizacao(
                    nome_original=nome_bruto,
                    nome_padrao=m["nome"],
                    categoria=m["categoria"],
                    score=100.0,
                    metodo="alias",
                )

        # E1: exact match
        if n in self._master:
            m = self._master[n]
            return ResultadoNormalizacao(
                nome_original=nome_bruto,
                nome_padrao=m["nome"],
                categoria=m["categoria"],
                score=100.0,
                metodo="exact",
            )
        if n_limpo in self._master:
            m = self._master[n_limpo]
            return ResultadoNormalizacao(
                nome_original=nome_bruto,
                nome_padrao=m["nome"],
                categoria=m["categoria"],
                score=100.0,
                metodo="exact_clean",
            )

        # E2: token key — first meaningful token >= 4 chars
        if n_limpo:
            tokens = [t for t in n_limpo.split() if len(t) > 3]
            first_tok = next(iter(tokens), None)
            if first_tok:
                candidates = self._token_index.get(first_tok, [])
                if len(candidates) == 1:
                    m = self._master[candidates[0]]
                    return ResultadoNormalizacao(
                        nome_original=nome_bruto,
                        nome_padrao=m["nome"],
                        categoria=m["categoria"],
                        score=90.0,
                        metodo="token_key",
                    )
                if len(candidates) > 1:
                    best_tok = process.extractOne(
                        n_limpo, candidates, scorer=fuzz.WRatio, score_cutoff=70.0
                    )
                    if best_tok:
                        m = self._master[best_tok[0]]
                        return ResultadoNormalizacao(
                            nome_original=nome_bruto,
                            nome_padrao=m["nome"],
                            categoria=m["categoria"],
                            score=best_tok[1],
                            metodo="token_key_fuzzy",
                        )

        # E3: WRatio 85 on original normalized
        if self._nomes_norm:
            best = process.extractOne(n, self._nomes_norm, scorer=fuzz.WRatio, score_cutoff=85.0)
            if best:
                m = self._master[best[0]]
                return ResultadoNormalizacao(
                    nome_original=nome_bruto,
                    nome_padrao=m["nome"],
                    categoria=m["categoria"],
                    score=best[1],
                    metodo="fuzzy_85",
                )

        # E4: WRatio 75 on cleaned
        if n_limpo and n_limpo != n:
            best_clean = process.extractOne(
                n_limpo, self._nomes_norm, scorer=fuzz.WRatio, score_cutoff=self.fuzzy_cutoff
            )
            if best_clean:
                m = self._master[best_clean[0]]
                return ResultadoNormalizacao(
                    nome_original=nome_bruto,
                    nome_padrao=m["nome"],
                    categoria=m["categoria"],
                    score=best_clean[1],
                    metodo="fuzzy_clean",
                )

        # E5: token_set_ratio 70
        best_ts = process.extractOne(
            n_limpo or n, self._nomes_norm, scorer=fuzz.token_set_ratio, score_cutoff=70.0
        )
        if best_ts:
            m = self._master[best_ts[0]]
            return ResultadoNormalizacao(
                nome_original=nome_bruto,
                nome_padrao=m["nome"],
                categoria=m["categoria"],
                score=best_ts[1],
                metodo="token_set",
            )

        # E6: WRatio 70 fallback
        best_low = process.extractOne(n, self._nomes_norm, scorer=fuzz.WRatio, score_cutoff=70.0)
        if best_low:
            m = self._master[best_low[0]]
            return ResultadoNormalizacao(
                nome_original=nome_bruto,
                nome_padrao=m["nome"],
                categoria=m["categoria"],
                score=best_low[1],
                metodo="fuzzy_low",
            )

        # E7: partial_ratio 75 — better for short names with suffix differences (e.g. "ovos" → "ovo")
        best_partial = process.extractOne(
            n, self._nomes_norm, scorer=fuzz.partial_ratio, score_cutoff=75.0
        )
        if best_partial:
            m = self._master[best_partial[0]]
            return ResultadoNormalizacao(
                nome_original=nome_bruto,
                nome_padrao=m["nome"],
                categoria=m["categoria"],
                score=best_partial[1],
                metodo="partial_75",
            )

        self._log_unmatched(nome_bruto)
        return ResultadoNormalizacao(
            nome_original=nome_bruto,
            nome_padrao=None,
            categoria=None,
            score=0.0,
            metodo="none",
        )

    def normalizar_lote(self, items: list[CotacaoHistorica], cutoff: float = 70.0) -> pl.DataFrame:
        registros = []
        for item in items:
            r = self.normalizar(item.produto_original)
            registros.append(
                {
                    "produto_original": item.produto_original,
                    "produto": r.nome_padrao or "",
                    "categoria": r.categoria or "",
                    "match_score": r.score,
                    "metodo": r.metodo,
                    "uf": item.uf,
                    "municipio": item.municipio,
                    "ano": item.ano,
                    "mes": item.mes,
                    "valor_produto_kg": round(item.valor_produto_kg, 4),
                }
            )
        self._flush_unmatched()
        df = pl.DataFrame(registros)
        return df.filter(pl.col("match_score") >= cutoff)
