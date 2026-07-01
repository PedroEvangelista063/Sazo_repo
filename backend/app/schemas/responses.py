"""
Schemas Pydantic V2 — Contrato da Cozinha (Cômodo 3: FastAPI).

Estes modelos definem exatamente o que a API B2C entrega para a Sala de
Estar (Frontend React PWA).

Regra da Sala de Estar:
    O preço em REAIS (R$) É PROIBIDO na resposta da API. O frontend B2C
    nunca exibe valores monetários. Apenas o ``status_cor`` do semáforo
    (VERDE / AMARELO / VERMELHO) e o nome do produto são transmitidos.
    Se um campo ``preco_medio`` vazar aqui, é um bug de segurança.
"""

from __future__ import annotations


from pydantic import BaseModel, ConfigDict, Field


class CacheClearResponse(BaseModel):
    success: bool
    message: str

    model_config = ConfigDict(frozen=True)


class MunicipioListResponse(BaseModel):
    """Retorno do endpoint ``GET /api/v1/municipios``."""

    data: list[str]
    total: int

    model_config = ConfigDict(frozen=True)


class SazonalidadeResponse(BaseModel):
    """Retorno do endpoint ``GET /api/v1/sazonalidade``.

    O frontend React usa ``status_cor`` para renderizar os cartões:
        - ``VERDE``    → fundo verde + texto "Melhor Época!"
        - ``VERMELHO`` → fundo vermelho + opacidade reduzida (evite)
        - ``AMARELO``  → fundo amarelo + texto "Preço estável"

    Nota: O campo ``preco_referencia_2025`` permite ao frontend calcular
    a variação percentual ("X% mais barato que em 2025") sem expor
    preços em reais como valor principal.
    """

    id_produto: int = Field(..., description="Identificador único do produto")
    nome_produto: str = Field(..., description="Nome do produto")
    icone_url: str | None = Field(None, description="URL do ícone do produto")
    uf: str = Field(..., min_length=2, max_length=2)
    municipio: str | None = Field(None, description="Nome do município")
    municipio_id: str | None = Field(None, description="Código IBGE do município")
    ano: int = Field(
        ..., ge=2000, le=2100, description="Ano do preço atual (derivado de data_referencia_atual)"
    )
    mes: int = Field(
        ..., ge=1, le=12, description="Mês do preço atual (derivado de data_referencia_atual)"
    )
    data_referencia_atual: str = Field(
        ...,
        pattern=r"^\d{4}-\d{2}$",
        description="Data do último preço registrado (YYYY-MM)",
    )
    preco_referencia: float | None = Field(
        None, description="Preço âncora: COALESCE(media 2025, fallback 12m)"
    )
    preco_atual: float | None = Field(
        None, description="Último preço registrado do produto na localidade"
    )
    usou_fallback_12m: bool = Field(
        ..., description="True se a âncora veio do fallback 12m (produto sem 2025)"
    )
    status_cor: str = Field(
        ...,
        pattern=r"^(VERDE|AMARELO|VERMELHO|INSUFICIENTE)$",
        description="Semáforo: VERDE (safra), AMARELO (estável), VERMELHO (entressafra)",
    )
    fonte: str | None = Field(None, pattern=r"^(municipio|uf)$")
    categoria: str | None = Field(
        None, description="Nome da categoria do produto (FRUTAS, LEGUMES, etc.)"
    )

    model_config = ConfigDict(from_attributes=True, frozen=True)


class CategoriaResponse(BaseModel):
    """Categoria com contagem de produtos disponiveis."""

    nome: str = Field(..., description="Nome da categoria")
    descricao: str | None = Field(None, description="Descricao da categoria")
    total_produtos: int = Field(..., ge=0, description="Total de produtos na categoria")
    icone: str | None = Field(None, description="Emoji/icone sugestivo para o frontend")

    model_config = ConfigDict(frozen=True)


class CategoriaListResponse(BaseModel):
    """Retorno do endpoint ``GET /api/v1/categorias``."""

    data: list[CategoriaResponse]
    total: int

    model_config = ConfigDict(frozen=True)


class SazonalidadeListResponse(BaseModel):
    """Retorno paginado do endpoint ``GET /api/v1/sazonalidade``."""

    data: list[SazonalidadeResponse]
    total: int
    pagina: int
    por_pagina: int

    model_config = ConfigDict(frozen=True)


class ErrorResponse(BaseModel):
    """Estrutura padrão de erro HTTP para a API."""

    detail: str = Field(..., description="Mensagem de erro legıvel")
    codigo: str | None = Field(None, description="Código interno do erro (ex: 'UF_INVALIDA')")

    model_config = ConfigDict(frozen=True)


class SazonalidadeComPreco(SazonalidadeResponse):
    """Schema interno com preço — APENAS PARA USO INTERNO (logs, admin)."""

    model_config = ConfigDict(from_attributes=True, frozen=True)
