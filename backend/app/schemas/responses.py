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

from datetime import datetime
from typing import Literal

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

    """

    id_produto: int = Field(..., description="Identificador único do produto")
    nome_produto: str = Field(..., description="Nome do produto")
    icone_url: str | None = Field(None, description="URL do ícone do produto")
    uf: str = Field(..., min_length=2, max_length=12)
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
    preco_estimado: bool = Field(
        False, description="True se o preço atual foi estimado por interpolação (gap de coleta)"
    )
    usou_fallback_12m: bool = Field(
        ..., description="True se a âncora veio do fallback 12m (produto sem 2025)"
    )
    status_cor: Literal["VERDE", "AMARELO", "VERMELHO"] = Field(
        ...,
        description="Semáforo: VERDE (safra), AMARELO (estável), VERMELHO (entressafra) - Trindade Estrita",
    )
    fonte: str | None = Field(None, pattern=r"^(municipio|uf|BASELINE_HISTORICO|regiao)$")
    categoria: str | None = Field(
        None, description="Nome da categoria do produto (FRUTAS, LEGUMES, etc.)"
    )
    tendencia_futura: Literal["QUEDA", "ALTA", "ESTAVEL"] | None = Field(
        None, description="Previsão ML (Holt-Winters) para o próximo mês: QUEDA/ALTA/ESTAVEL"
    )
    is_forecast: bool = Field(
        False,
        description="True se o dado foi projetado pelo modelo de baseline histórico (fallback para meses sem coleta)",
    )
    confianca_baseline: float | None = Field(
        None,
        description="Percentual de confiança do baseline histórico (ex: 100 se 2024 e 2025 têm dados para este mês)",
    )
    forecast_method: str | None = Field(
        None,
        description="Método de geração da projeção: NULL para dado real, SANDUICHE_MEDIA_24_25 para média histórica, beta_weighted_25_24 para baseline ponderado, etc.",
    )
    regiao: str | None = Field(
        None,
        min_length=4,
        max_length=20,
        description="Nome da região quando o dado é agregado regional (ex: SUDESTE). None quando é município/UF.",
    )
    # ── Transparência temporal (V17 — ano âncora real) ──
    ano_referencia: int | None = Field(
        None,
        description="Ano âncora do dado exibido (última cotação real). None p/ FALLBACK_DIMENSAO.",
    )
    tipo_dado: str | None = Field(
        None, description="REAL_ATUAL | HISTORICO_BASE | FALLBACK_DIMENSAO"
    )
    mensagem_transparencia: str | None = Field(None, description="Texto de proveniência (sem R$).")
    is_dado_legado: bool = Field(False, description="True quando ano_referencia < ano corrente.")

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


class SazonalidadeComPrecoResponse(BaseModel):
    """Schema com preço — para endpoints analíticos (tabela/gráficos).
    NUNCA deve ser usado no endpoint B2C /sazonalidade."""

    id_produto: int
    nome_produto: str
    categoria: str | None = None
    uf: str
    municipio: str | None = None
    municipio_id: str | None = None
    ano: int
    mes: int
    data_referencia_atual: str
    preco_referencia: float | None = None
    preco_atual: float | None = None
    variacao_pct: float | None = None
    preco_estimado: bool = False
    usou_fallback_12m: bool = False
    status_cor: Literal["VERDE", "AMARELO", "VERMELHO"]
    fonte: str | None = None
    tendencia_futura: Literal["QUEDA", "ALTA", "ESTAVEL"] | None = None
    is_forecast: bool = False
    confianca_baseline: float | None = None
    forecast_method: str | None = Field(
        None,
        description="Método de geração da projeção: NULL para dado real, SANDUICHE_MEDIA_24_25 para sanduíche sazonal, etc.",
    )
    preco_mes_anterior: float | None = None
    # ── Transparência temporal (V17 — ano âncora real) ──
    ano_referencia: int | None = Field(
        None,
        description="Ano âncora do dado exibido (última cotação real). None p/ FALLBACK_DIMENSAO.",
    )
    tipo_dado: str | None = Field(
        None, description="REAL_ATUAL | HISTORICO_BASE | FALLBACK_DIMENSAO"
    )
    mensagem_transparencia: str | None = Field(None, description="Texto de proveniência (sem R$).")
    is_dado_legado: bool = Field(False, description="True quando ano_referencia < ano corrente.")

    model_config = ConfigDict(from_attributes=True, frozen=True)


class SazonalidadeComPrecoListResponse(BaseModel):
    """Retorno paginado do endpoint /sazonalidade/com-preco."""

    data: list[SazonalidadeComPrecoResponse]
    total: int
    pagina: int
    por_pagina: int

    model_config = ConfigDict(frozen=True)


# ── Regional ──
class PoloInfo(BaseModel):
    nome: str
    uf: str
    municipio: str
    fonte_id: str | None = None
    papel: str | None = None

    model_config = ConfigDict(frozen=True)


class RegiaoInfo(BaseModel):
    id: str
    nome: str
    papel: str | None = None
    ufs: list[str]
    polos: list[PoloInfo]
    total_ufs: int

    model_config = ConfigDict(frozen=True)


class RegioesResponse(BaseModel):
    regioes: list[RegiaoInfo]

    model_config = ConfigDict(frozen=True)


class MesSazonalidade(BaseModel):
    """Status de um mês específico na sazonalidade BR Nacional."""

    mes: int = Field(..., ge=1, le=12)
    status_cor: Literal["VERDE", "AMARELO", "VERMELHO"]
    is_forecast: bool = False
    baseline_confianca: float | None = None
    forecast_method: str | None = None
    calculado_em: datetime | None = None
    # ── Transparência temporal (V17 — ano âncora real) ──
    ano_referencia: int | None = Field(
        None,
        description="Ano âncora do dado exibido (última cotação real). None p/ FALLBACK_DIMENSAO.",
    )
    tipo_dado: str | None = Field(
        None, description="REAL_ATUAL | HISTORICO_BASE | FALLBACK_DIMENSAO"
    )
    mensagem_transparencia: str | None = Field(None, description="Texto de proveniência (sem R$).")
    is_dado_legado: bool = Field(False, description="True quando ano_referencia < ano corrente.")


class SazonalidadeNacionalResponse(BaseModel):
    """Produto com 12 meses de sazonalidade — endpoint BR Nacional."""

    produto: str
    classificao_produto: str | None = None
    categoria: str | None = None
    meses: list[MesSazonalidade]
    total_ufs: int = Field(..., ge=0)

    model_config = ConfigDict(frozen=True)


class SazonalidadeNacionalListResponse(BaseModel):
    """Retorno paginado do endpoint /sazonalidade/br-sazonalidade."""

    data: list[SazonalidadeNacionalResponse]
    total: int
    pagina: int
    por_pagina: int

    model_config = ConfigDict(frozen=True)


# ── Fluxos de Abastecimento ──
class FlowItem(BaseModel):
    """Um fluxo de abastecimento logístico entre origem e destino.

    Lido da view ``staging.vw_abastecimento_logistico``, que faz JOIN entre
    ``dim_fluxo_abastecimento`` e ``dim_produto`` para trazer o nome
    canônico do produto.
    """

    id: int = Field(..., description="ID do fluxo (id_fluxo)")
    item: str = Field(..., description="Nome do produto (canônico)")
    origem_uf: str = Field(..., min_length=2, max_length=2)
    origem_polo: str = Field(..., description="Polo/CEASA de origem")
    destino_regiao_id: str = Field(..., description="ID da região destino (ex: norte, nordeste)")
    destino_uf: str = Field(..., min_length=2, max_length=2)
    meses: list[int] = Field(..., description="Meses de ocorrência do fluxo")
    sazonalidade: str = Field(..., description="Descrição da sazonalidade")
    preco_referencial: str = Field(..., description="Preço referencial (string)")
    tipo: str = Field(..., description="exportado / importado / autossuficiente")
    descricao_tipo: str | None = Field(
        None, description="🟢 Envia para fora / 🔴 Recebe de fora / 🟡 Produção local"
    )
    periodicidade: str | None = Field(None, description="'Ano inteiro' ou 'N meses'")
    regiao_destino_nome: str | None = Field(
        None, description="Nome da região destino (ex: Norte, Nordeste)"
    )
    # Campos de compatibilidade com o frontend (padrões seguros)
    categoria: str = "HORTIFRUTI"
    cor_indicadora: str = "#6366F1"
    ano_referencia: int | None = Field(
        None,
        description="Ano âncora do dado exibido (última cotação real). None quando sem âncora.",
    )

    model_config = ConfigDict(frozen=True)


class FlowListResponse(BaseModel):
    """Retorno do endpoint ``GET /api/v1/fluxos``."""

    data: list[FlowItem]
    total: int

    model_config = ConfigDict(frozen=True)
