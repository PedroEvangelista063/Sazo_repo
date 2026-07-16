from __future__ import annotations

from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest

from pipeline.scraper.micro_engines.prohort_mensal_engine import ProhortMensalEngine

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _load_fixture(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


@pytest.fixture
def engine() -> ProhortMensalEngine:
    return ProhortMensalEngine()


@pytest.mark.asyncio
async def test_parse_valid_data(engine: ProhortMensalEngine) -> None:
    raw = _load_fixture("prohort_mensal_sample.csv")
    linhas = engine._transform(raw, 2025, 1)

    assert len(linhas) == 4
    for row in linhas:
        assert "nome_produto" in row
        assert "preco_medio" in row or "preco_kg" in row
        assert "uf" in row
        assert "data_referencia" in row or "competencia" in row

    tomatinho = next(r for r in linhas if r.get("nome_produto") == "tomate")
    assert tomatinho["preco_medio"] == 5.0
    assert tomatinho["uf"] == "SP"
    assert tomatinho.get("data_referencia") == "2025-01"


@pytest.mark.asyncio
async def test_filter_zero_qtd(engine: ProhortMensalEngine) -> None:
    raw = _load_fixture("prohort_mensal_sample.csv")
    linhas = engine._transform(raw, 2025, 1)

    nomes = {r.get("nome_produto") for r in linhas}
    assert "cebola" not in nomes
    assert "alface" not in nomes


@pytest.mark.asyncio
async def test_encoding_iso8859(engine: ProhortMensalEngine) -> None:
    raw = "dsc_produto;uf_ceasa;id_ano_comercializacao;id_mes_comercializacao;valor_comercializado;qtd_comercializada_kg\n"
    raw_iso = raw + "Maca;SP;2025;1;5000.00;1000.00\nCebola;MG;2025;1;3000.00;600.00\n"
    raw_bytes = raw_iso.encode("iso-8859-1")
    linhas = engine._transform(raw_bytes, 2025, 1)

    assert len(linhas) == 2
    maca = next(r for r in linhas if "ma" in (r.get("nome_produto") or ""))
    assert maca["preco_medio"] == 5.0


@pytest.mark.asyncio
async def test_parse_filename_detects_columns(engine: ProhortMensalEngine) -> None:
    raw = "dsc_produto;uf_ceasa;id_ano_comercializacao;id_mes_comercializacao;valor_comercializado;qtd_comercializada_kg\n"
    raw += "Tomate;SP;2026;6;60000.00;12000.00\n"
    linhas = engine._transform(raw, 2026, 6)

    assert len(linhas) == 1
    assert linhas[0]["nome_produto"] == "tomate"
    assert linhas[0]["preco_medio"] == 5.0
    assert linhas[0]["uf"] == "SP"


@pytest.mark.asyncio
async def test_filter_by_ano_mes(engine: ProhortMensalEngine) -> None:
    raw = "dsc_produto;uf_ceasa;id_ano_comercializacao;id_mes_comercializacao;valor_comercializado;qtd_comercializada_kg\n"
    raw += "Tomate;SP;2025;1;10000.00;2000.00\n"
    raw += "Batata;MG;2025;2;20000.00;4000.00\n"
    raw += "Cebola;PR;2025;3;30000.00;6000.00\n"

    linhas = engine._transform(raw, 2025, 2)
    assert len(linhas) == 1
    assert linhas[0]["nome_produto"] == "batata"


@pytest.mark.asyncio
async def test_extract_full_flow_success(engine: ProhortMensalEngine) -> None:
    raw_csv = _load_fixture("prohort_mensal_sample.csv")
    raw_bytes = raw_csv.encode("utf-8-sig")

    mock_resp = AsyncMock(spec=httpx.Response)
    mock_resp.status_code = 200
    mock_resp.content = raw_bytes
    mock_resp.text = raw_csv
    mock_resp.raise_for_status = MagicMock()

    mock_client = AsyncMock(spec=httpx.AsyncClient)
    mock_client.__aenter__.return_value = mock_client
    mock_client.get.return_value = mock_resp

    with patch("httpx.AsyncClient", return_value=mock_client):
        result = await engine.extract("", 2025, 1)

    assert result["fonte_id"] == "conab-prohort-mensal"
    assert result["competencia"] == "2025-01"
    linhas = result["payload_bruto"]["linhas"]
    assert len(linhas) == 4
    assert result["payload_bruto"]["total_linhas"] == 4
    assert sorted(result["payload_bruto"]["ufs_abrangidas"]) == ["ES", "MG", "SC", "SP"]
    assert result["payload_bruto"]["periodo_inicial"] == "2025-01"
    assert result["payload_bruto"]["periodo_final"] == "2025-01"


@pytest.mark.asyncio
async def test_circuit_breaker_on_timeout(engine: ProhortMensalEngine) -> None:
    mock_client = AsyncMock(spec=httpx.AsyncClient)
    mock_client.__aenter__.return_value = mock_client
    mock_client.get.side_effect = httpx.TimeoutException("timeout")

    with patch("httpx.AsyncClient", return_value=mock_client):
        for _ in range(5):
            with pytest.raises(httpx.TimeoutException):
                await engine.extract("", 2025, 1)

    assert engine._circuit_breaker.esta_aberto
    assert len(engine._circuit_breaker._failures) >= 5


@pytest.mark.asyncio
async def test_extract_all(engine: ProhortMensalEngine) -> None:
    raw_csv = _load_fixture("prohort_mensal_sample.csv")
    raw_bytes = raw_csv.encode("utf-8-sig")

    mock_resp = AsyncMock(spec=httpx.Response)
    mock_resp.status_code = 200
    mock_resp.content = raw_bytes
    mock_resp.text = raw_csv
    mock_resp.raise_for_status = MagicMock()

    mock_client = AsyncMock(spec=httpx.AsyncClient)
    mock_client.__aenter__.return_value = mock_client
    mock_client.get.return_value = mock_resp

    with patch("httpx.AsyncClient", return_value=mock_client):
        results = await engine.extract_all(2025, 1)

    assert len(results) == 1
    assert results[0]["fonte_id"] == "conab-prohort-mensal"
