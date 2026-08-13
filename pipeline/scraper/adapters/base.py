from __future__ import annotations

import asyncio
import logging
import re
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import date
from typing import Any

from pydantic import ValidationError

from pipeline.scraper.schemas.coleta import CotacaoColeta

logger = logging.getLogger(__name__)

RE_UNIDADE_EMBALAGEM = re.compile(
    r"(?P<quantidade>\d+\.?\d*)\s*(?P<unidade>cx|saco|sc|fardo|pc|pto|dz|duzia|kg|g|ton|un)"
)

# Unidades com fator de conversão DEFINITIVO para R$/kg. Apenas estas podem
# ser convertidas com confiança pelo scraper — as demais (cx/saco/dz/un/maço)
# são AMBÍGUAS: o fator real depende do item (uma "caixa" de pitaya não pesa o
# mesmo que uma de batata). Para as ambíguas, a conversão é DECIDIDA PELO BANCO
# (mart.dim_unidade_medida + staging.normalizar_unidade_sql / backfill da
# migration 82), nunca hardcoded aqui com fator 1.0.
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
    "saco 25 kg": 25.0,
    "saco 25kg": 25.0,
    "saco 50 kg": 50.0,
    "saco 50kg": 50.0,
}

# Nome canônico por chave de UNIDADES_PADRAO — espelha
# mart.dim_unidade_medida.unidade_canonica (migration 82).
UNIDADES_CANONICAS: dict[str, str] = {
    "kg": "kg",
    "quilograma": "kg",
    "quilo": "kg",
    "g": "g",
    "grama": "g",
    "ton": "ton",
    "tonelada": "ton",
    "cx 20kg": "cx20",
    "cx 22kg": "cx22",
    "cx 25kg": "cx25",
    "cx 30kg": "cx30",
    "saco 25 kg": "saco25",
    "saco 25kg": "saco25",
    "saco 50 kg": "saco50",
    "saco 50kg": "saco50",
}

# Unidades AMBÍGUAS: NÃO recebem fator conversor definitivo (fator_kg = NULL
# no banco). Recebem uma unidade canônica CRUA (espelho do dim_unidade_medida)
# para que a agregação NÃO misture grandezas e a conversão real seja decidida
# pelo banco (mart.fator_kg_produto_uf / normalizar_unidade_sql / backfill 82).
UNIDADES_AMBIGUAS: dict[str, str] = {
    "cx": "caixa_generica",
    "caixa": "caixa_generica",
    "cxa": "caixa_generica",
    "saco": "saco_generico",
    "sacaria": "saco_generico",
    "sc": "saco_generico",
    "fardo": "fardo",
    "dz": "dz",
    "duzia": "dz",
    "dúzia": "dz",
    "maço": "maço",
    "maco": "maço",
    "un": "un",
    "und": "un",
    "unidade": "un",
    "pc": "un",
    "pto": "un",
}

# Placeholder de unidade ambígua retornado por normalizar_unidade() para NÃO
# quebrar o contrato float das chamadas existentes (prohort.py/ceasa_standard).
# NÃO é conversão real para kg — apenas marca que a grandeza é desconhecida.
FATOR_AMBIGUO = 1.0


def validar_cotacao(cotacao: CotacaoRegional) -> CotacaoRegional | None:
    dados: dict[str, Any] = {
        "produto_original": cotacao.produto_original,
        "uf": cotacao.uf or "XX",
        "municipio": cotacao.municipio or "desconhecido",
        "ano": cotacao.ano or 0,
        "mes": cotacao.mes or 0,
        "fonte": cotacao.fonte or "desconhecida",
        "preco_bruto": cotacao.preco_bruto,
        "fator_kg": max(cotacao.fator_kg, 0.1),
    }
    try:
        CotacaoColeta.model_validate(dados)
        return cotacao
    except ValidationError as e:
        logger.warning("[LIXO DESCARTADO] %s: %s", cotacao.produto_original[:60], e)
        return None


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

    def _validate_cotacao_coleta(self, cotacao: CotacaoRegional) -> CotacaoRegional | None:
        return validar_cotacao(cotacao)

    def normalizar_unidade(self, descricao: str) -> float:
        """Fator de conversão para R$/kg (float — contrato das chamadas legadas).

        Unidades DEFINITIVAS (kg, g, ton, cx 20kg, saco 50kg...) → fator real.
        Unidades AMBÍGUAS (cx, saco, dz, un, maço...) → 1.0 (placeholder
        marcado, ver FATOR_AMBIGUO): a conversão real depende do item e é
        decidida pelo banco (mart.dim_unidade_medida / normalizar_unidade_sql).
        """
        if not descricao:
            return FATOR_AMBIGUO
        tl = descricao.lower().strip()
        for chave, fator in sorted(UNIDADES_PADRAO.items(), key=lambda x: -len(x[0])):
            if chave in tl:
                return fator
        for token in sorted(UNIDADES_AMBIGUAS, key=lambda x: -len(x)):
            if token in tl:
                return FATOR_AMBIGUO
        m = RE_UNIDADE_EMBALAGEM.search(tl)
        if m:
            un = m.group("unidade")
            if un in UNIDADES_PADRAO:
                return UNIDADES_PADRAO[un]
            qtd = float(m.group("quantidade"))
            for chave in [f"{un} {qtd}kg", f"{qtd}kg"]:
                if chave in UNIDADES_PADRAO:
                    return UNIDADES_PADRAO[chave]
            # 'N cx/saco/dz/...' → contagem de embalagens, NÃO conversão em kg.
            return FATOR_AMBIGUO
        m2 = re.search(r"(\d+)\s*(kg|k)", tl)
        if m2:
            return float(m2.group(1))
        return FATOR_AMBIGUO

    def normalizar_unidade_canonica(self, descricao: str) -> str:
        """Classifica a unidade em um nome canônico CRU para persistência.

        Definitivas → 'kg', 'g', 'ton', 'cx20', 'cx22', 'cx25', 'cx30',
        'saco25', 'saco50'. Ambíguas → 'caixa_generica', 'saco_generico',
        'fardo', 'dz', 'maço', 'un' (espelho de mart.dim_unidade_medida).
        Fallback → texto cru normalizado.
        """
        if not descricao:
            return ""
        tl = descricao.lower().strip()
        for chave, canon in sorted(UNIDADES_CANONICAS.items(), key=lambda x: -len(x[0])):
            if chave in tl:
                return canon
        for token, canon in sorted(UNIDADES_AMBIGUAS.items(), key=lambda x: -len(x[0])):
            if token in tl:
                return canon
        m = RE_UNIDADE_EMBALAGEM.search(tl)
        if m:
            un = m.group("unidade")
            canon = {
                "kg": "kg",
                "g": "g",
                "ton": "ton",
                "cx": "caixa_generica",
                "saco": "saco_generico",
                "sc": "saco_generico",
                "fardo": "fardo",
                "dz": "dz",
                "duzia": "dz",
                "pc": "un",
                "pto": "un",
                "un": "un",
            }.get(un)
            if canon:
                return canon
        m2 = re.search(r"(\d+)\s*(kg|k)", tl)
        if m2:
            return "kg"
        return tl

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
