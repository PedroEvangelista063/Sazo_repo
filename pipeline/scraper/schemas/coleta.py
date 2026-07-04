from __future__ import annotations

import re
from datetime import date
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator

HEADER_LIXO = {
    "produto", "preço", "preco", "descricao", "unidade",
    "embalagem", "total", "subtotal", "pagina", "página",
    "voltar", "menu principal", "sair", "login", "senha",
    "carrinho", "checkout", "home", "inicio", "contato",
    "sobre", "ajuda", "suporte", "termos", "privacidade",
    "cestabasica", "cesta básica", "produtos", "codigo",
    "código", "ncm", "ncm/sh", "quantidade", "valor total",
    "nenhum registro", "registro", "n/d", "s/ info",
}

RE_EMAIL = re.compile(r'[\w.+-]+@[\w-]+\.[\w.-]+')
RE_TELEFONE = re.compile(r'\(?\d{2,}\)?\s?\d{4,5}-?\d{4}')
RE_SOMENTE_NUMEROS = re.compile(r'^\d+[\s\d]*$')
RE_NUMERO_PAGINA = re.compile(r'^p[aá]gina\s+\d+', re.IGNORECASE)


class CotacaoColeta(BaseModel):
    produto_original: str = Field(..., min_length=1, max_length=200)
    uf: str = Field(..., min_length=2, max_length=2, pattern=r'^[A-Z]{2}$')
    municipio: str = Field(..., min_length=1)
    ano: int = Field(..., ge=2000, le=2100)
    mes: int = Field(..., ge=1, le=12)
    fonte: str = Field(..., min_length=1)
    preco_bruto: float = Field(..., gt=0)
    fator_kg: float = Field(default=1.0, gt=0)
    data_coleta: str = Field(default_factory=lambda: date.today().isoformat())

    @field_validator('produto_original')
    @classmethod
    def rejeitar_lixo_header(cls, v: str) -> str:
        v = v.strip()
        if not v or len(v) < 3:
            raise ValueError(f'produto_original muito curto: "{v}"')

        v_lower = v.lower()

        if v_lower in HEADER_LIXO:
            raise ValueError(f'rejeitado por header_lixo: "{v}"')

        if RE_NUMERO_PAGINA.match(v_lower):
            raise ValueError(f'rejeitado por numero_pagina: "{v}"')

        if RE_SOMENTE_NUMEROS.match(v):
            raise ValueError(f'rejeitado por apenas_numeros: "{v}"')

        if RE_EMAIL.match(v):
            raise ValueError(f'rejeitado por email: "{v}"')

        return v

    @field_validator('preco_bruto')
    @classmethod
    def rejeitar_fora_limite(cls, v: float) -> float:
        if v > 10_000:
            raise ValueError(f'preco_bruto {v} > 10k (provável header/footer)')
        if v < 0.01:
            raise ValueError(f'preco_bruto {v} < 0.01')
        return v

    @field_validator('fonte')
    @classmethod
    def rejeitar_fonte_vazia(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError('fonte vazia')
        return v

    @model_validator(mode='after')
    def validar_mes_ano_fonte(self):
        if self.fonte == 'CEASA' and (self.ano == 0 or self.mes == 0):
            raise ValueError(
                f'ano={self.ano} mes={self.mes} com fonte CEASA não faz sentido'
            )
        return self


class CotacaoNormalizada(CotacaoColeta):
    produto_normalizado: str = Field(..., min_length=1, max_length=200)
    categoria_b2c: str | None = None
    preco_medio: float | None = None
    preco_min: float | None = None
    preco_max: float | None = None


class ResultadoMotor(BaseModel):
    motor: str = Field(..., min_length=1)
    fonte: str = Field(..., min_length=1)
    uf: str = Field(..., min_length=2, max_length=2, pattern=r'^[A-Z]{2}$')
    municipio: str = Field(..., min_length=1)
    cotacoes: list[CotacaoColeta] = Field(default_factory=list)
    status: Literal['sucesso', 'falha', 'circuit_open'] = 'sucesso'
    erro: str = ''
    tempo_s: float = 0.0