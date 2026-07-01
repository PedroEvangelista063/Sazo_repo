"""
TÍTULO: Testes de Ingestão de Dados Reais — Trator vs. Tomate (Pipeline)
ESCOPO: Valida sanitização de preço, limpeza de texto, categorização B2C/B2B e filtros de linha
EXECUTA: Funções _sanitize_price, _sanitize_local_text, categorizar_produtos em pipeline.ingestao_conab
"""

import polars as pl
import pytest
from pipeline.ingestao_conab import (
    _sanitize_price,
    _sanitize_local_text,
    categorizar_produtos,
)


TRATOR_ROWS = [
    {
        "produto": "TRATOR",
        "classificao_produto": "150 16X16 JOHN DEERE",
        "id_produto": "14056",
        "uf": "BA",
        "regiao": "NORDESTE",
        "ano": "2025",
        "mes": "7",
        "dsc_nivel_comercializacao": "PREÇO PAGO PELO PRODUTOR",
        "valor_produto_kg": "500000,0",
    },
    {
        "produto": "TRATOR",
        "classificao_produto": "100 4X4",
        "id_produto": "14057",
        "uf": "BA",
        "regiao": "NORDESTE",
        "ano": "2025",
        "mes": "8",
        "dsc_nivel_comercializacao": "PREÇO PAGO PELO PRODUTOR",
        "valor_produto_kg": "350000,00",
    },
]

ZINCO_ROWS = [
    {
        "produto": "ZINCO",
        "classificao_produto": "AGRICHEM",
        "id_produto": "10224",
        "uf": "MT",
        "regiao": "CENTRO-OESTE",
        "ano": "2025",
        "mes": "7",
        "dsc_nivel_comercializacao": "PREÇO PAGO PELO PRODUTOR",
        "valor_produto_kg": "2,27",
    },
    {
        "produto": "ZINCO",
        "classificao_produto": "QUELATIZADO 10%",
        "id_produto": "10225",
        "uf": "MT",
        "regiao": "CENTRO-OESTE",
        "ano": "2025",
        "mes": "8",
        "dsc_nivel_comercializacao": "PREÇO PAGO PELO PRODUTOR",
        "valor_produto_kg": "3,85",
    },
]


def _build_df(rows: list[dict]) -> pl.DataFrame:
    return pl.DataFrame(rows)


def _simulate_local_transform(df: pl.DataFrame) -> pl.DataFrame:
    """Reproduz o pipeline de load_local_file em memória."""
    df = df.with_columns(
        _sanitize_local_text(pl.col("produto")),
        _sanitize_local_text(pl.col("classificao_produto")),
        _sanitize_local_text(pl.col("valor_produto_kg")),
    )

    # Preservar original antes da combinação
    df = df.with_columns(pl.col("produto").alias("_produto_original"))

    # Combinar produto + classificao
    df = df.with_columns(
        (pl.col("produto") + " - " + pl.col("classificao_produto")).alias("produto")
    )

    # Categorizar
    df = categorizar_produtos(df)

    # Preço
    df = df.with_columns(
        _sanitize_price(pl.col("valor_produto_kg")).alias("preco_medio"),
        pl.col("ano").cast(pl.Int32, strict=False),
        pl.col("mes").cast(pl.Int32, strict=False),
    )

    # ATENÇÃO: parênteses em len_chars() == 2 — Python operator precedence
    return df.filter(
        pl.col("preco_medio").is_not_null()
        & (pl.col("preco_medio") > 0)
        & pl.col("produto").is_not_null()
        & (pl.col("uf").str.len_chars() == 2)
        & pl.col("ano").is_not_null()
        & pl.col("mes").is_not_null()
        & pl.col("mes").is_between(1, 12)
    ).select(["produto", "uf", "ano", "mes", "preco_medio", "categoria_b2c"])


class TestLocalFileMapping:
    def test_trator_preco_conversao(self):
        """TRATOR com 500000,0 → 500000.0 (vírgula para ponto)."""
        df = _build_df(TRATOR_ROWS)
        result = _simulate_local_transform(df)
        assert result["preco_medio"][0] == pytest.approx(500000.0)

    def test_zinco_preco_conversao(self):
        """ZINCO com 2,27 → 2.27."""
        df = _build_df(ZINCO_ROWS)
        result = _simulate_local_transform(df)
        assert result["preco_medio"][0] == pytest.approx(2.27)

    def test_produto_combinado_unicidade(self):
        """TRATOR com classificações diferentes geram produtos únicos."""
        df = _build_df(TRATOR_ROWS)
        result = _simulate_local_transform(df)
        produtos = result["produto"].to_list()
        assert "TRATOR - 150 16X16 JOHN DEERE" in produtos
        assert "TRATOR - 100 4X4" in produtos
        assert produtos[0] != produtos[1]

    def test_zinco_classificacoes_isoladas(self):
        """ZINCO AGRICHEM ≠ ZINCO QUELATIZADO 10%."""
        df = _build_df(ZINCO_ROWS)
        result = _simulate_local_transform(df)
        produtos = result["produto"].to_list()
        assert "ZINCO - AGRICHEM" in produtos
        assert "ZINCO - QUELATIZADO 10%" in produtos

    def test_mistura_trator_zinco_nao_se_misturam(self):
        """Trator e Zinco no mesmo DataFrame: produtos distintos."""
        df = _build_df(TRATOR_ROWS + ZINCO_ROWS)
        result = _simulate_local_transform(df)
        assert result.height == 4
        produtos = set(result["produto"].to_list())
        assert len(produtos) == 4

    def test_sanitize_price_invalido_retorna_null(self):
        """String vazia ou inválida retorna null (não quebra)."""
        s = pl.Series("preco", ["", "abc", "500000,0"])
        result = _sanitize_price(s)
        assert result[0] is None
        assert result[1] is None
        assert result[2] == pytest.approx(500000.0)

    def test_sanitize_local_text_strip(self):
        """Strip de padding fixo (espaços à direita)."""
        s = pl.Series("x", ["TRATOR                 ", "   ZINCO   "])
        result = _sanitize_local_text(s)
        assert result[0] == "TRATOR"
        assert result[1] == "ZINCO"

    def test_filtro_mes_invalido(self):
        """Mês fora de 1-12 remove a linha."""
        df = pl.DataFrame({
            "produto": ["TESTE"],
            "classificao_produto": ["X"],
            "id_produto": ["0"],
            "uf": ["SP"],
            "regiao": ["SUDESTE"],
            "ano": ["2025"],
            "mes": ["13"],
            "dsc_nivel_comercializacao": ["PREÇO PAGO PELO PRODUTOR"],
            "valor_produto_kg": ["10,00"],
        })
        result = _simulate_local_transform(df)
        assert result.height == 0

    def test_filtro_uf_invalida(self):
        """UF com != 2 chars remove a linha."""
        df = pl.DataFrame({
            "produto": ["TESTE"],
            "classificao_produto": ["X"],
            "id_produto": ["0"],
            "uf": ["SP--"],
            "regiao": ["SUDESTE"],
            "ano": ["2025"],
            "mes": ["1"],
            "dsc_nivel_comercializacao": ["PREÇO PAGO PELO PRODUTOR"],
            "valor_produto_kg": ["10,00"],
        })
        result = _simulate_local_transform(df)
        assert result.height == 0


class TestCategorizacao:
    def test_trator_e_maquinario(self):
        """TRATOR classificado como MAQUINARIO_FERRAMENTA."""
        df = _build_df(TRATOR_ROWS)
        df = categorizar_produtos(df)
        assert all(c == "MAQUINARIO_FERRAMENTA" for c in df["categoria_b2c"].to_list())

    def test_zinco_e_insumo(self):
        """ZINCO classificado como INSUMO_AGRICOLA."""
        df = _build_df(ZINCO_ROWS)
        df = categorizar_produtos(df)
        assert all(c == "INSUMO_AGRICOLA" for c in df["categoria_b2c"].to_list())

    def test_b2c_b2b_split(self):
        """ALIMENTO_VAREJO vai pro app; MAQUINARIO/INSUMO fica B2B."""
        TOMATE = {
            "produto": "TOMATE",
            "classificao_produto": "SALADA",
            "id_produto": "999",
            "uf": "SP",
            "regiao": "SUDESTE",
            "ano": "2025",
            "mes": "7",
            "dsc_nivel_comercializacao": "PREÇO PAGO PELO PRODUTOR",
            "valor_produto_kg": "6,50",
        }
        rows = TRATOR_ROWS + ZINCO_ROWS + [TOMATE]
        df = _build_df(rows)
        df = categorizar_produtos(df)
        b2c = df.filter(pl.col("categoria_b2c") == "ALIMENTO_VAREJO")
        b2b = df.filter(pl.col("categoria_b2c") != "ALIMENTO_VAREJO")
        assert b2c.height == 1
        assert b2c["produto"][0] == "TOMATE"
        assert b2b.height == 4

    def test_regex_insumo_pattern(self):
        """00-18-18 (fertilizante) classificado como INSUMO_AGRICOLA."""
        df = pl.DataFrame({
            "produto": ["00-18-18"],
            "classificao_produto": ["NÃO INFORMADO"],
        })
        df = categorizar_produtos(df)
        assert df["categoria_b2c"][0] == "INSUMO_AGRICOLA"

    def test_fallback_materia_prima(self):
        """Produto não mapeado cai em MATERIA_PRIMA_B2B."""
        df = pl.DataFrame({
            "produto": ["BORRACHA NATURAL"],
            "classificao_produto": ["LATEX"],
        })
        df = categorizar_produtos(df)
        assert df["categoria_b2c"][0] == "MATERIA_PRIMA_B2B"
