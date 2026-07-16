from __future__ import annotations

from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

import httpx
import pytest

from pipeline.scraper.micro_engines.precosiagroweb_engine import PrecosiagrowebEngine

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _load_fixture(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


@pytest.fixture
def engine() -> PrecosiagrowebEngine:
    return PrecosiagrowebEngine()


@pytest.fixture
def mock_response_ok() -> AsyncMock:
    mock = AsyncMock()
    mock.status_code = 200
    mock.text = _load_fixture("precosiagroweb_sample.html")
    mock.raise_for_status = MagicMock()
    return mock


@pytest.fixture
def mock_response_500() -> AsyncMock:
    mock = AsyncMock()
    mock.status_code = 500
    mock.raise_for_status = MagicMock(
        side_effect=httpx.HTTPStatusError(
            "500 Error", request=MagicMock(), response=mock,
        ),
    )
    return mock


@pytest.mark.asyncio
async def test_parse_valid_data(engine: PrecosiagrowebEngine) -> None:
    html = _load_fixture("precosiagroweb_sample.html")
    linhas = await engine.transform(html)

    assert len(linhas) == 5
    for row in linhas:
        assert "nome_produto" in row
        assert "preco_kg" in row
        assert row["preco_kg"] > 0

    tomate = next(r for r in linhas if r["nome_produto"] == "tomate")
    assert tomate["preco_kg"] == 5.0

    maca = next(r for r in linhas if r["nome_produto"] == "maçã")
    assert maca["preco_kg"] == 8.2


@pytest.mark.asyncio
async def test_parse_html_malformed(engine: PrecosiagrowebEngine) -> None:
    linhas = await engine.transform("<div>not a table</div>")
    assert linhas == []


@pytest.mark.asyncio
async def test_parse_html_empty(engine: PrecosiagrowebEngine) -> None:
    linhas = await engine.transform("")
    assert linhas == []


@pytest.mark.asyncio
async def test_circuit_breaker_blocks_after_failures(
    engine: PrecosiagrowebEngine,
    mock_response_500: AsyncMock,
) -> None:
    mock_client = AsyncMock()
    mock_client.post.return_value = mock_response_500
    engine._http_client = mock_client

    for _ in range(5):
        with pytest.raises(httpx.HTTPStatusError):
            await engine._postar("AC", "", "2024-01", "2024-01")

    assert engine._circuit_breaker.esta_aberto

    with pytest.raises(RuntimeError, match="CircuitBreaker aberto"):
        await engine._postar("AC", "", "2024-01", "2024-01")


@pytest.mark.asyncio
async def test_circuit_breaker_records_failures_only_on_exhaustion(
    engine: PrecosiagrowebEngine,
    mock_response_500: AsyncMock,
) -> None:
    mock_client = AsyncMock()
    mock_client.post.return_value = mock_response_500
    engine._http_client = mock_client

    failures_before = len(engine._circuit_breaker._failures)
    with pytest.raises(httpx.HTTPStatusError):
        await engine._postar("AC", "", "2024-01", "2024-01")

    assert len(engine._circuit_breaker._failures) == failures_before + 1


@pytest.mark.asyncio
async def test_rate_limiting_semaphore(engine: PrecosiagrowebEngine) -> None:
    assert engine._semaphore is not None
    assert engine._semaphore._value == 3


@pytest.mark.asyncio
async def test_fallback_500(
    engine: PrecosiagrowebEngine,
    mock_response_500: AsyncMock,
) -> None:
    mock_client = AsyncMock()
    mock_client.post.return_value = mock_response_500
    engine._http_client = mock_client

    result = await engine._processar_com_fallback("AC", "2024-01")

    assert result["pendente"] is True
    assert "erro" in result
    assert result["fonte_id"] == "precosiagroweb"
    assert result["payload_bruto"]["linhas"] == []


@pytest.mark.asyncio
async def test_extract_all(engine: PrecosiagrowebEngine, mock_response_ok: AsyncMock) -> None:
    mock_client = AsyncMock()
    mock_client.post.return_value = mock_response_ok
    engine._http_client = mock_client

    results = await engine.extract_all(2024, 1)

    assert len(results) == 1
    r = results[0]
    assert r["fonte_id"] == "precosiagroweb"
    assert r["competencia"] == "2024-01"
    assert len(r["payload_bruto"]["linhas"]) == 40
    assert r["payload_bruto"]["ufs"] == ["AC", "AM", "AP", "MS", "PI", "RO", "RR", "SE"]


@pytest.mark.asyncio
async def test_process_all_ufs(engine: PrecosiagrowebEngine, mock_response_ok: AsyncMock) -> None:
    mock_client = AsyncMock()
    mock_client.post.return_value = mock_response_ok
    engine._http_client = mock_client

    results = await engine.process_all_ufs()

    assert len(results) == 96
    for r in results:
        assert r["fonte_id"] == "precosiagroweb"
        assert r["payload_bruto"]["total_linhas"] == 5


@pytest.mark.asyncio
async def test_extract_returns_complete_payload(
    engine: PrecosiagrowebEngine,
    mock_response_ok: AsyncMock,
) -> None:
    mock_client = AsyncMock()
    mock_client.post.return_value = mock_response_ok
    engine._http_client = mock_client

    result = await engine.extract("", 2024, 1)

    assert result["fonte_id"] == "precosiagroweb"
    assert result["competencia"] == "2024-01"
    assert len(result["payload_bruto"]["linhas"]) == 40
    assert "ufs" in result["payload_bruto"]
    assert "periodo" in result["payload_bruto"]
