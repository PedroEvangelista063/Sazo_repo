"""
Testes unitários do módulo de transformação (limpeza de dados brutos).
"""


import polars as pl
import pytest

from pipeline.transform import _parse_price_column, _remove_outliers_zscore, _normalize_column_names


class TestNormalizeColumns:
    def test_remove_espacos_e_lowercase(self):
        df = pl.DataFrame({"  Produto  ": ["tomate"], " Preco Medio ": [10.0]})
        result = _normalize_column_names(df)
        assert "produto" in result.columns
        assert "preco_medio" in result.columns

    def test_substitui_hifens_por_underscore(self):
        df = pl.DataFrame({"nome-municipio": ["São Paulo"]})
        result = _normalize_column_names(df)
        assert "nome_municipio" in result.columns


class TestParsePriceColumn:
    def test_converte_virgula_para_ponto(self):
        df = pl.DataFrame({"preco_medio": ["6,50", "12,30", "4,00"]})
        result = _parse_price_column(df, "preco_medio")
        assert result["preco_medio"].dtype == pl.Float64
        assert result["preco_medio"][0] == pytest.approx(6.5)

    def test_nulo_para_valor_invalido(self):
        df = pl.DataFrame({"preco_medio": ["abc", "6,50"]})
        result = _parse_price_column(df, "preco_medio")
        assert result["preco_medio"][0] is None

    def test_ja_float_nao_muda(self):
        df = pl.DataFrame({"preco_medio": [6.5, 12.3]})
        result = _parse_price_column(df, "preco_medio")
        assert result["preco_medio"][0] == pytest.approx(6.5)


class TestRemoveOutliersZscore:
    def test_remove_outlier_extremo(self):
        """Um preço 10x maior que a média deve ser removido (Z > 3)."""
        precos = [10.0] * 20 + [1000.0]  # outlier óbvio
        df = pl.DataFrame({
            "produto": ["TOMATE"] * 21,
            "uf": ["SP"] * 21,
            "preco_medio": precos,
        })
        result = _remove_outliers_zscore(df, "preco_medio")
        assert result.height == 20
        assert result["preco_medio"].max() < 100.0

    def test_nao_remove_variacao_normal(self):
        """Variação de ±20% não deve ser removida."""
        precos = [10.0, 9.0, 11.0, 10.5, 9.5, 10.0, 11.0, 9.0, 10.0, 10.5]
        df = pl.DataFrame({
            "produto": ["BANANA"] * len(precos),
            "uf": ["BA"] * len(precos),
            "preco_medio": precos,
        })
        result = _remove_outliers_zscore(df, "preco_medio")
        assert result.height == len(precos)
