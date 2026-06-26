"""
Testes unitários do módulo de sazonalidade.

Verifica a matemática do semáforo sem precisar de dados reais da CONAB.
"""

import polars as pl

from pipeline.seasonality import (
    apply_municipio_fallback,
    calculate_seasonality_municipio,
    calculate_seasonality_uf,
)


def _make_municipio_df(produto: str, mun_id: str, uf: str, precos: list[float]) -> pl.DataFrame:
    """Cria DataFrame de município com 12 meses de histórico sintético."""
    n = len(precos)
    return pl.DataFrame({
        "produto": [produto] * n,
        "municipio_id": [mun_id] * n,
        "municipio_nome": ["Cidade Teste"] * n,
        "uf": [uf] * n,
        "ano": [2024] * n,
        "mes": list(range(1, n + 1)),
        "preco_medio": precos,
    })


class TestSeasonalityMunicipio:
    def test_verde_quando_preco_abaixo_da_media(self):
        """Preço 20% abaixo da média → deve ser VERDE."""
        # Média dos primeiros 11 meses = 10.0; mês 12 = 8.0 → IS = 0.80
        precos = [10.0] * 11 + [8.0]
        df = _make_municipio_df("TOMATE", "3550308", "SP", precos)
        result = calculate_seasonality_municipio(df)
        last = result.filter((pl.col("mes") == 12))
        assert last["status_semaforo"][0] == "VERDE"

    def test_vermelho_quando_preco_acima_da_media(self):
        """Preço 20% acima da média → deve ser VERMELHO."""
        precos = [10.0] * 11 + [12.0]
        df = _make_municipio_df("TOMATE", "3550308", "SP", precos)
        result = calculate_seasonality_municipio(df)
        last = result.filter(pl.col("mes") == 12)
        assert last["status_semaforo"][0] == "VERMELHO"

    def test_amarelo_quando_preco_na_media(self):
        """Preço estável → deve ser AMARELO."""
        precos = [10.0] * 12
        df = _make_municipio_df("BANANA", "3550308", "SP", precos)
        result = calculate_seasonality_municipio(df)
        last = result.filter(pl.col("mes") == 12)
        assert last["status_semaforo"][0] == "AMARELO"

    def test_insuficiente_com_menos_de_6_meses(self):
        """Menos de 6 meses de histórico → INSUFICIENTE."""
        precos = [10.0] * 5
        df = _make_municipio_df("ALFACE", "3550308", "SP", precos)
        result = calculate_seasonality_municipio(df)
        assert (result["status_semaforo"] == "INSUFICIENTE").all()

    def test_dica_preenchida_para_todos_status(self):
        """Campo dica nunca deve ser nulo."""
        precos = [10.0] * 12
        df = _make_municipio_df("CEBOLA", "3550308", "SP", precos)
        result = calculate_seasonality_municipio(df)
        assert result["dica"].null_count() == 0

    def test_indice_calculado_corretamente(self):
        """IS = preco_medio / media_movel_12m deve ser ~1.0 com preços estáveis."""
        precos = [10.0] * 12
        df = _make_municipio_df("BATATA", "3550308", "SP", precos)
        result = calculate_seasonality_municipio(df)
        last = result.filter(pl.col("mes") == 12)
        assert abs(last["indice_sazonalidade"][0] - 1.0) < 0.01


class TestFallback:
    def test_fallback_aplica_dado_uf_para_insuficiente(self):
        """Municípios com INSUFICIENTE devem receber dado de UF como fallback."""
        # 3 meses apenas (insuficiente)
        mun_df_raw = _make_municipio_df("TOMATE", "9999999", "TO", [10.0] * 3)
        from pipeline.seasonality import calculate_seasonality_municipio, calculate_seasonality_uf

        # Construir df_mun com status INSUFICIENTE
        mun_season = calculate_seasonality_municipio(mun_df_raw)
        assert (mun_season["status_semaforo"] == "INSUFICIENTE").all()

        # Construir df_uf com 12 meses de histórico (suficiente)
        uf_raw = pl.DataFrame({
            "produto": ["TOMATE"] * 12,
            "uf": ["TO"] * 12,
            "ano": [2024] * 12,
            "mes": list(range(1, 13)),
            "preco_medio": [9.0] * 12,  # IS ~ 1.0 → AMARELO
        })
        uf_season = calculate_seasonality_uf(uf_raw)

        result = apply_municipio_fallback(mun_season, uf_season)
        # Após fallback, nenhum deve ser INSUFICIENTE (tem dado de UF)
        remaining_insuf = result.filter(pl.col("status_semaforo") == "INSUFICIENTE")
        assert remaining_insuf.height == 0

    def test_fonte_atualizada_apos_fallback(self):
        """Linhas com fallback devem ter fonte='uf'."""
        mun_df_raw = _make_municipio_df("CEBOLA", "8888888", "BA", [5.0] * 3)
        mun_season = calculate_seasonality_municipio(mun_df_raw)

        uf_raw = pl.DataFrame({
            "produto": ["CEBOLA"] * 12,
            "uf": ["BA"] * 12,
            "ano": [2024] * 12,
            "mes": list(range(1, 13)),
            "preco_medio": [5.0] * 12,
        })
        uf_season = calculate_seasonality_uf(uf_raw)
        result = apply_municipio_fallback(mun_season, uf_season)

        uf_rows = result.filter(pl.col("fonte") == "uf")
        assert uf_rows.height > 0
