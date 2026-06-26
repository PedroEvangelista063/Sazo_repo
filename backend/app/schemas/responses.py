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
from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class MunicipioResponse(BaseModel):
    """Retorno do endpoint ``GET /api/v1/municipios``.

    A API retorna a lista de municípios disponı́veis para uma UF.
    O frontend usa ``municipio_id`` para fazer a query de sazonalidade.
    """

    municipio: str = Field(
        ..., description="Nome do município (ex: 'SÃO PAULO')"
    )
    municipio_id: str | None = Field(
        None, description="Código IBGE do município (7 dígitos)"
    )

    model_config = ConfigDict(from_attributes=True, frozen=True)


class SazonalidadeResponse(BaseModel):
    """Retorno do endpoint ``GET /api/v1/sazonalidade``.

    Este é o contrato central entre a Cozinha e a Sala de Estar.
    **NENHUM CAMPO DE PREÇO EM REAIS DEVE EXISTIR AQUI.**

    O frontend React usa ``status_cor`` para renderizar os cartões:
        - ``VERDE``    → fundo verde + texto "Melhor Época!"
        - ``VERMELHO`` → fundo vermelho + opacidade reduzida (evite)
        - ``AMARELO``  → fundo amarelo + texto "Preço estável"

    Attributes:
        id_sazonalidade: Identificador único do registro.
        produto: Nome do produto (ex: "TOMATE SALADA").
        status_cor: Semáforo — VERDE, AMARELO ou VERMELHO.
        fonte: Origem do dado ("municipio" ou "uf").
    """

    id_sazonalidade: int
    produto: str = Field(..., description="Nome do produto")
    uf: str = Field(..., min_length=2, max_length=2)
    municipio: str | None = Field(None, description="Nome do município")
    ano: int = Field(..., ge=2000, le=2100)
    mes: int = Field(..., ge=1, le=12)
    status_cor: str = Field(
        ..., pattern=r"^(VERDE|AMARELO|VERMELHO)$",
        description="Semáforo: VERDE (safra), AMARELO (estável), VERMELHO (entressafra)",
    )
    fonte: str | None = Field(None, pattern=r"^(municipio|uf)$")

    model_config = ConfigDict(from_attributes=True, frozen=True)


class ErrorResponse(BaseModel):
    """Estrutura padrão de erro HTTP para a API."""

    detail: str = Field(..., description="Mensagem de erro legıvel")
    codigo: str | None = Field(
        None, description="Código interno do erro (ex: 'UF_INVALIDA')"
    )

    model_config = ConfigDict(frozen=True)


# ══════════════════════════════════════════════════════════════════════
# Auditoria interna (não exposto ao frontend B2C)
# ══════════════════════════════════════════════════════════════════════

class SazonalidadeComPreco(SazonalidadeResponse):
    """Schema interno com preço — APENAS PARA USO INTERNO (logs, admin).

    NUNCA retorne este schema para o frontend B2C. Ele existe apenas para
    que a Cozinha possa logar diagnósticos sem expor dados sensı́veis.
    """

    preco_medio: float | None = Field(None, description="APENAS USO INTERNO")
    media_movel_12m: float | None = Field(
        None, description="APENAS USO INTERNO"
    )
    indice_sazonalidade: float | None = Field(
        None, description="APENAS USO INTERNO"
    )
