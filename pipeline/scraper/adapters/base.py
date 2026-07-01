from __future__ import annotations

import asyncio
import logging
import re
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import date

logger = logging.getLogger(__name__)

RE_UNIDADE_EMBALAGEM = re.compile(
    r"(?P<quantidade>\d+\.?\d*)\s*(?P<unidade>cx|saco|sc|fardo|pc|pto|dz|duzia|kg|g|ton|un)"
)

UNIDADES_PADRAO: dict[str, float] = {
    "kg": 1.0,
    "quilograma": 1.0,
    "quilo": 1.0,
    "g": 0.001,
    "grama": 0.001,
    "ton": 1000.0,
    "tonelada": 1000.0,
    "cx 20kg": 20.0,
    "cx 22kg": 22.0,
    "cx 25kg": 25.0,
    "cx 30kg": 30.0,
    "cx": 1.0,
    "caixa": 1.0,
    "saco 25 kg": 25.0,
    "saco 25kg": 25.0,
    "saco 50 kg": 50.0,
    "saco 50kg": 50.0,
    "saco": 1.0,
    "sacaria": 1.0,
    "fardo": 1.0,
    "dz": 1.0,
    "duzia": 1.0,
    "dúzia": 1.0,
    "pc": 1.0,
    "pto": 1.0,
    "un": 1.0,
    "und": 1.0,
    "unidade": 1.0,
}


@dataclass
class CotacaoRegional:
    produto_original: str
    produto_normalizado: str = ""
    uf: str = ""
    municipio: str = ""
    ano: int = 0
    mes: int = 0
    data_cotacao: str = ""
    fonte: str = ""
    unidade_medida: str = ""
    preco_min: float | None = None
    preco_max: float | None = None
    preco_medio: float | None = None
    preco_bruto: float = 0.0
    fator_kg: float = 1.0
    volume_referencia: str = ""
    status_coleta: str = "pendente"
    erro: str = ""
    data_coleta: str = field(default_factory=lambda: date.today().isoformat())

    @property
    def valor_produto_kg(self) -> float:
        return self.preco_bruto / self.fator_kg if self.fator_kg > 0 else self.preco_bruto


class BaseAdapter(ABC):
    nome: str = ""
    fonte: str = ""
    uf: str = ""
    municipio: str = ""
    semaforo: asyncio.Semaphore | None = None
    ano: int | None = None
    mes: int | None = None

    @abstractmethod
    async def fetch(self) -> list[CotacaoRegional]: ...

    def normalizar_unidade(self, descricao: str) -> float:
        if not descricao:
            return 1.0
        tl = descricao.lower().strip()
        for chave, fator in sorted(UNIDADES_PADRAO.items(), key=lambda x: -len(x[0])):
            if chave in tl:
                return fator
        m = RE_UNIDADE_EMBALAGEM.search(tl)
        if m:
            qtd = float(m.group("quantidade"))
            un = m.group("unidade")
            for chave in [f"{un} {qtd}kg", f"{qtd}kg", f"{un}"]:
                if chave in UNIDADES_PADRAO:
                    return UNIDADES_PADRAO[chave]
            return qtd
        m2 = re.search(r"(\d+)\s*(kg|k)", tl)
        if m2:
            return float(m2.group(1))
        return 1.0

    def limpar_valor(self, valor: str) -> float | None:
        if not valor:
            return None
        v = valor.strip()
        if v in ("-", "--", "", "- - -", "n/d", "N/D", "ND", "s/ info"):
            return None
        v = v.replace("R$", "").replace("r$", "").replace(" ", "")
        v = v.replace(".", "").replace(",", ".")
        m = re.search(r"(\d+\.?\d*)", v)
        if not m:
            return None
        try:
            return float(m.group(1))
        except ValueError:
            return None

    def extrair_periodo(self, data_str: str) -> tuple[int, int] | None:
        if not data_str:
            return None
        parts = data_str.split("/")
        if len(parts) == 3:
            try:
                return int(parts[2]), int(parts[1])
            except ValueError:
                return None
        parts = data_str.split("-")
        if len(parts) == 3:
            try:
                return int(parts[0]), int(parts[1])
            except ValueError:
                return None
        m = re.search(r"(\d{4})", data_str)
        if m:
            return int(m.group(1)), 1
        return None

    def normalizar_produto(self, nome: str) -> str:
        if not nome:
            return ""
        nome = nome.strip().upper()
        nome = re.sub(r"\s+\d+[A-Za-z].*$", "", nome)
        nome = re.sub(r"\s+", " ", nome)
        nome = nome.strip()
        conhecidos = {
            "TOMATE": "TOMATE",
            "BATATA": "BATATA",
            "CEBOLA": "CEBOLA",
            "CENOURA": "CENOURA",
            "ALFACE": "ALFACE",
            "BANANA": "BANANA",
            "LARANJA": "LARANJA",
            "MACA": "MAÇA",
            "MAÇA": "MAÇA",
            "MAMÃO": "MAMÃO",
            "MAMAO": "MAMÃO",
            "UVA": "UVA",
            "MELANCIA": "MELANCIA",
            "MORANGO": "MORANGO",
            "ABACATE": "ABACATE",
            "ABACAXI": "ABACAXI",
            "MANGA": "MANGA",
            "GOIABA": "GOIABA",
            "MARACUJA": "MARACUJÁ",
            "LIMÃO": "LIMÃO",
            "LIMAO": "LIMÃO",
            "BETERRABA": "BETERRABA",
            "ABOBRINHA": "ABOBRINHA",
            "PEPINO": "PEPINO",
            "PIMENTAO": "PIMENTÃO",
            "PIMENTÃO": "PIMENTÃO",
            "REPOLHO": "REPOLHO",
            "VAGEM": "VAGEM",
            "MILHO": "MILHO",
            "BATATA DOCE": "BATATA DOCE",
            "MANDIOCA": "MANDIOCA",
            "ALHO": "ALHO",
            "CEBOLINHA": "CEBOLINHA",
            "COUVE": "COUVE",
            "COUVE-FLOR": "COUVE-FLOR",
            "BROCOLIS": "BRÓCOLIS",
            "ESPINAFRE": "ESPINAFRE",
            "ARROZ": "ARROZ",
            "FEIJAO": "FEIJÃO",
            "FEIJÃO": "FEIJÃO",
            "FRANGO": "FRANGO",
            "CARNE": "CARNE",
            "OLEO": "ÓLEO",
            "OLEO DE SOJA": "ÓLEO DE SOJA",
            "ACUCAR": "AÇÚCAR",
            "FARINHA": "FARINHA",
            "LEITE": "LEITE",
            "OVO": "OVO",
            "QUEIJO": "QUEIJO",
        }
        return conhecidos.get(nome, nome)
