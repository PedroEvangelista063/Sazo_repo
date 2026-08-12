"""
RED/GREEN — Transparência temporal (Slice 2 / Fase 2).

Cobre:
  - R-MOD-01 (S-L1/S-L2): FlowItem.ano_referencia sem default hardcoded 2024.
  - R-ADD-01 (S4): schemas B2C com campos opcionais de transparência
    (ano_referencia, tipo_dado, mensagem_transparencia, is_dado_legado).
  - R-ADD-03 (S2/S3): mensagem_transparencia sem valor monetário (R$).
  - R-ADD-04: tupla com preço nulo ainda carrega tipo_dado/ano/mensagem.

Sem dependência de banco: puro schema Pydantic + composição de mensagem.
"""

from __future__ import annotations

import pytest

from backend.app.schemas.responses import (
    FlowItem,
    MesSazonalidade,
    SazonalidadeComPrecoResponse,
    SazonalidadeResponse,
)


def _flow_item(**overrides: object) -> FlowItem:
    base = {
        "id": 1,
        "item": "Tomate",
        "origem_uf": "SP",
        "origem_polo": "CEASA Campinas",
        "destino_regiao_id": "sudeste",
        "destino_uf": "RJ",
        "meses": [1, 2, 3],
        "sazonalidade": "Ano inteiro",
        "preco_referencial": "R$ 3,50",
        "tipo": "exportado",
    }
    base.update(overrides)
    return FlowItem(**base)


# ── R-MOD-01: FlowItem.ano_referencia ──────────────────────────────────────


def test_flowitem_serializa_ano_ancora_real() -> None:
    """S-L1: item ancorado em 2025 serializa 2025, nunca o default hardcoded 2024."""
    item = _flow_item(ano_referencia=2025)
    dumped = item.model_dump()
    assert dumped["ano_referencia"] == 2025


def test_flowitem_sem_ancora_serializa_none() -> None:
    """S-L2: sem âncora resolvida, ano_referencia é None (não 2024 enganoso)."""
    item = _flow_item()
    dumped = item.model_dump()
    assert dumped["ano_referencia"] is None


# ── R-ADD-01: campos de transparência opcionais nos schemas B2C ────────────


def test_sazonalidade_response_campos_transparencia_serializam() -> None:
    """S1/S2: SazonalidadeResponse carrega os 4 campos de transparência."""
    item = SazonalidadeResponse(
        id_produto=1,
        nome_produto="Tomate",
        uf="SP",
        ano=2025,
        mes=6,
        data_referencia_atual="2025-06",
        usou_fallback_12m=False,
        status_cor="AMARELO",
        fonte="uf",
        ano_referencia=2025,
        tipo_dado="HISTORICO_BASE",
        mensagem_transparencia=(
            "Dado histórico real — última cotação real da CONAB em 2025 "
            "(defasagem de 1 ano). Não é estimativa sintética."
        ),
        is_dado_legado=True,
    )
    dumped = item.model_dump()
    assert dumped["ano_referencia"] == 2025
    assert dumped["tipo_dado"] == "HISTORICO_BASE"
    assert "2025" in dumped["mensagem_transparencia"]
    assert dumped["is_dado_legado"] is True


def test_sazonalidade_response_campos_ausentes_nao_quebram() -> None:
    """S4: consumidor sem os novos campos deserializa com defaults (additive)."""
    item = SazonalidadeResponse(
        id_produto=1,
        nome_produto="Tomate",
        uf="SP",
        ano=2026,
        mes=1,
        data_referencia_atual="2026-01",
        usou_fallback_12m=False,
        status_cor="VERDE",
        fonte="uf",
    )
    dumped = item.model_dump()
    assert dumped["ano_referencia"] is None
    assert dumped["tipo_dado"] is None
    assert dumped["mensagem_transparencia"] is None
    assert dumped["is_dado_legado"] is False


def test_sazonalidade_com_preco_response_campos_transparencia() -> None:
    """R-ADD-01: schema com-preço (analítico) também expõe transparência."""
    item = SazonalidadeComPrecoResponse(
        id_produto=1,
        nome_produto="Tomate",
        uf="SP",
        ano=2024,
        mes=3,
        data_referencia_atual="2024-03",
        status_cor="VERMELHO",
        ano_referencia=2024,
        tipo_dado="HISTORICO_BASE",
        is_dado_legado=True,
        mensagem_transparencia="Dado histórico real — defasagem de 2 anos.",
    )
    dumped = item.model_dump()
    assert dumped["ano_referencia"] == 2024
    assert dumped["tipo_dado"] == "HISTORICO_BASE"
    assert dumped["is_dado_legado"] is True


def test_mes_sazonalidade_campos_transparencia() -> None:
    """R-ADD-01: MesSazonalidade (grade BR nacional) carrega transparência."""
    item = MesSazonalidade(
        mes=6,
        status_cor="AMARELO",
        ano_referencia=2025,
        tipo_dado="HISTORICO_BASE",
        mensagem_transparencia="Dado histórico real — CONAB 2025.",
        is_dado_legado=True,
    )
    dumped = item.model_dump()
    assert dumped["ano_referencia"] == 2025
    assert dumped["tipo_dado"] == "HISTORICO_BASE"
    assert dumped["is_dado_legado"] is True


# ── R-ADD-03/04: sem R$ e sinalização de nulo ──────────────────────────────


def test_payload_b2c_sem_r_dolar() -> None:
    """S3: payload B2C serializado não contém 'R$' em campos de transparência."""
    item = SazonalidadeResponse(
        id_produto=1,
        nome_produto="Tomate",
        uf="SP",
        ano=2025,
        mes=6,
        data_referencia_atual="2025-06",
        usou_fallback_12m=False,
        status_cor="AMARELO",
        fonte="uf",
        ano_referencia=2025,
        tipo_dado="HISTORICO_BASE",
        mensagem_transparencia=(
            "Dado histórico real — última cotação real da CONAB em 2025 "
            "(defasagem de 1 ano). Não é estimativa sintética."
        ),
        is_dado_legado=True,
    )
    raw = item.model_dump_json()
    assert "R$" not in raw
    assert "R$" not in (item.mensagem_transparencia or "")


def test_flowitem_preco_referencial_eh_excecao_administrativa() -> None:
    """Fluxos (admin) mantêm preco_referencial textual; transparência não soma R$."""
    item = _flow_item()
    # Fluxos são painel interno — o texto de preço é esperado aí; o que NÃO pode
    # vazar é mensagem_transparencia com R$. Campo ainda não existe no FlowItem.
    assert "preco_referencial" in item.model_dump()


def test_ano_referencia_nulo_mas_sinalizado() -> None:
    """R-ADD-04: tupla sem preço ainda sinaliza tipo_dado/ano/mensagem."""
    item = SazonalidadeResponse(
        id_produto=2,
        nome_produto="Cebola",
        uf="MG",
        ano=2026,
        mes=1,
        data_referencia_atual="2026-01",
        usou_fallback_12m=True,
        status_cor="AMARELO",
        fonte="regiao",
        ano_referencia=None,
        tipo_dado="FALLBACK_DIMENSAO",
        mensagem_transparencia=(
            "Sem histórico real para este período — valor de referência da dimensão (fallback)."
        ),
        is_dado_legado=False,
    )
    dumped = item.model_dump()
    assert dumped["tipo_dado"] == "FALLBACK_DIMENSAO"
    assert dumped["mensagem_transparencia"] is not None
    assert "fallback" in dumped["mensagem_transparencia"].lower()


@pytest.mark.parametrize(
    ("tipo_dado", "ano_referencia", "esperado_fragmento"),
    [
        ("REAL_ATUAL", 2026, "Coleta efetiva"),
        ("HISTORICO_BASE", 2025, "Dado histórico real"),
        ("HISTORICO_BASE", 2024, "Dado histórico real"),
        # FASE 79 (P1-1): sem metadado e sem ano_referencia, a mensagem do
        # Deep Fallback V22 é "baseline de dimensao" (sem histórico real).
        ("FALLBACK_DIMENSAO", None, "baseline de dimensao"),
    ],
)
def test_compor_mensagem_transparencia(
    tipo_dado: str, ano_referencia: int | None, esperado_fragmento: str
) -> None:
    """R-ADD-03: composição pt-BR por tipo de dado, sempre sem R$."""
    from backend.app.api.v1.endpoints.produtos import _compor_mensagem_transparencia

    idade = 2026 - ano_referencia if ano_referencia is not None else None
    msg = _compor_mensagem_transparencia(tipo_dado, ano_referencia, idade)
    assert msg is not None
    assert esperado_fragmento in msg
    assert "R$" not in msg
    assert "R $".lower() not in msg.lower()


def test_compor_mensagem_transparencia_deriva_idade_quando_ausente() -> None:
    """fn_br_nacional_sazonalidade não projeta idade_dado_anos — a defasagem
    é derivada de ANO_ATUAL - ano_referencia (nunca "defasagem de None ano")."""
    from backend.app.api.v1.endpoints.produtos import _compor_mensagem_transparencia

    msg = _compor_mensagem_transparencia("HISTORICO_BASE", 2025)
    assert msg is not None
    assert "defasagem de 1 ano" in msg
    assert "None" not in msg

    msg_2024 = _compor_mensagem_transparencia("HISTORICO_BASE", 2024)
    assert msg_2024 is not None
    assert "defasagem de 2 anos" in msg_2024
    assert "None" not in msg_2024
