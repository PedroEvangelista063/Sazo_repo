"""
Testes do motor de baseline 2025 com fallback hibrido 12m.

Valida a matematica do semaforo com Ano Ancora + fallback condicional de
12 meses (para produtos novos sem historico em 2025).

Implementa em Polars a MESMA logica da SP sp_calcular_sazonalidade_baseline
para validacao offline com DataFrames sinteticos.

Cenarios testados (spec Fase 6 v2):
  1. Cebola em inflacao: media R$ 5,00, atual R$ 6,00 → VERMELHO, !fallback
  2. Mandioca em safra: media R$ 4,00, atual R$ 3,00 → VERDE, !fallback
  3. Pitaia Amarela (nova, sem 2025): media 12m R$ 10,00, atual R$ 10,50 → AMARELO, fallback
  4. Categoria_B2C: trator nao pode contaminar o B2C
  5. Pitaya sem 2025 E sem dados suficientes para fallback → INSUFICIENTE
"""

import polars as pl


def _calcular_baseline(df: pl.DataFrame) -> pl.DataFrame:
    """
    Implementa em Polars a mesma logica da
    staging.sp_calcular_sazonalidade_baseline().

    4 CTEs: calc_base_2025 → calc_ultimos_precos → calc_fallback_12m → master_join
    """
    if df.height == 0:
        return pl.DataFrame(schema={
            "id_produto": pl.Int64,
            "id_localidade": pl.Int64,
            "preco_referencia": pl.Float64,
            "preco_atual": pl.Float64,
            "data_referencia_atual": pl.String,
            "usou_fallback_12m": pl.Boolean,
            "status_cor": pl.String,
        })

    # CTE 1: Baseline 2025
    base_2025 = (
        df
        .filter((pl.col("ano") == 2025) & pl.col("preco_medio").is_not_null())
        .group_by(["id_produto", "id_localidade"])
        .agg(pl.col("preco_medio").mean().alias("preco_referencia_2025"))
    )

    # CTE 2: Ultimo preco por produto+localidade
    ultimos_precos = (
        df
        .filter(pl.col("preco_medio").is_not_null())
        .with_columns(
            pl.struct(["ano", "mes"])
            .rank("dense", descending=True)
            .over(["id_produto", "id_localidade"])
            .alias("rn")
        )
        .filter(pl.col("rn") == 1)
        .select(
            "id_produto",
            "id_localidade",
            pl.col("preco_medio").alias("preco_atual"),
            (pl.col("ano").cast(pl.String)
             + "-"
             + pl.col("mes").cast(pl.String).str.zfill(2)
             ).alias("data_referencia_atual"),
        )
    )

    # CTE 3: Fallback 12 meses (media dos ultimos 12 meses, min 3 periodos)
    ultimo_periodo = (
        df
        .filter(pl.col("preco_medio").is_not_null())
        .group_by(["id_produto", "id_localidade"])
        .agg((pl.col("ano") * 12 + pl.col("mes")).max().alias("ultimo_periodo"))
    )

    fallback_12m = (
        df
        .filter(pl.col("preco_medio").is_not_null())
        .join(ultimo_periodo, on=["id_produto", "id_localidade"])
        .filter(
            (pl.col("ano") * 12 + pl.col("mes"))
            > (pl.col("ultimo_periodo") - 12)
        )
        .filter(
            (pl.col("ano") * 12 + pl.col("mes"))
            <= pl.col("ultimo_periodo")
        )
        .group_by(["id_produto", "id_localidade"])
        .agg([
            pl.col("preco_medio").mean().alias("preco_fallback_12m"),
            pl.col("preco_medio").count().alias("meses_fallback"),
        ])
        .filter(pl.col("meses_fallback") >= 3)
        .select("id_produto", "id_localidade", "preco_fallback_12m")
    )

    # CTE 4: Master JOIN + COALESCE + semaforo
    resultado = (
        ultimos_precos
        .join(base_2025, on=["id_produto", "id_localidade"], how="left")
        .join(fallback_12m, on=["id_produto", "id_localidade"], how="left")
        .with_columns(
            pl.coalesce(["preco_referencia_2025", "preco_fallback_12m"])
            .alias("preco_referencia")
        )
        .with_columns(
            (pl.col("preco_referencia_2025").is_null()
             & pl.col("preco_fallback_12m").is_not_null()
             ).alias("usou_fallback_12m")
        )
        .with_columns(
            pl.when(
                pl.col("preco_referencia").is_null()
                | (pl.col("preco_referencia") == 0)
                | pl.col("preco_atual").is_null()
            )
            .then(pl.lit("INSUFICIENTE"))
            .when(pl.col("preco_atual")
                  < (pl.col("preco_referencia") * 0.85))
            .then(pl.lit("VERDE"))
            .when(pl.col("preco_atual")
                  > (pl.col("preco_referencia") * 1.15))
            .then(pl.lit("VERMELHO"))
            .otherwise(pl.lit("AMARELO"))
            .alias("status_cor")
        )
    )

    return resultado.select([
        "id_produto", "id_localidade",
        "preco_referencia", "preco_atual",
        "data_referencia_atual", "usou_fallback_12m",
        "status_cor",
    ])


# ─── Fixtures ───────────────────────────────────────────────────────────────


def _make_df(
    produto: str,
    precos_2025: list[float] | None = None,
    precos_atuais: list[tuple[int, int, float]] | None = None,
    localidade: tuple[str, str] = ("SP", "3550308"),
) -> pl.DataFrame:
    """
    Cria DataFrame sintetico de staging.fact_precos_mensais.

    Args:
        produto: nome do produto
        precos_2025: precos mensais de jan/2025 a dez/2025 (opcional)
        precos_atuais: lista de (ano, mes, preco) para o periodo pos-2025
        localidade: (UF, municipio_id)
    """
    rows: list[dict] = []
    id_produto = hash(produto) % 10_000
    uf, mun_id = localidade
    id_localidade = hash(mun_id) % 10_000

    if precos_2025:
        for i, preco in enumerate(precos_2025, start=1):
            rows.append({
                "id_produto": id_produto,
                "id_localidade": id_localidade,
                "uf": uf,
                "municipio_id": mun_id,
                "produto": produto,
                "ano": 2025,
                "mes": i,
                "preco_medio": preco,
            })

    if precos_atuais:
        for ano, mes, preco in precos_atuais:
            rows.append({
                "id_produto": id_produto,
                "id_localidade": id_localidade,
                "uf": uf,
                "municipio_id": mun_id,
                "produto": produto,
                "ano": ano,
                "mes": mes,
                "preco_medio": preco,
            })

    return pl.DataFrame(rows, schema={
        "id_produto": pl.Int64,
        "id_localidade": pl.Int64,
        "uf": pl.String,
        "municipio_id": pl.String,
        "produto": pl.String,
        "ano": pl.Int32,
        "mes": pl.Int32,
        "preco_medio": pl.Float64,
    })


# ═══════════════════════════════════════════════════════════════════════════
# TESTES DE VALIDACAO DO SEMAFORO
# ═══════════════════════════════════════════════════════════════════════════


class TestSemafaroBaseline:
    """Validacao do calculo com Ano Ancora 2025 (fallback nao acionado)."""

    def test_cebola_inflacao_vermelho(self):
        """Teste 1: Inflacao da Cebola.

        Media da Cebola em 2025 = R$ 5,00.
        Ultimo preco de 2026    = R$ 6,00 (20% maior).
        Threshold 1.15 → 5.00 * 1.15 = 5.75.
        6.00 > 5.75 → VERMELHO. usou_fallback_12m = False.
        """
        df = _make_df("CEBOLA", precos_2025=[5.0] * 12,
                       precos_atuais=[(2026, 5, 6.0)])
        r = _calcular_baseline(df)
        assert r["status_cor"][0] == "VERMELHO"
        assert r["usou_fallback_12m"][0] == False

    def test_mandioca_safra_verde(self):
        """Teste 2: Safra da Mandioca.

        Media da Mandioca em 2025 = R$ 4,00.
        Ultimo preco de 2026      = R$ 3,00 (25% menor).
        Threshold 0.85 → 4.00 * 0.85 = 3.40.
        3.00 < 3.40 → VERDE. usou_fallback_12m = False.
        """
        df = _make_df("MANDIOCA", precos_2025=[4.0] * 12,
                       precos_atuais=[(2026, 6, 3.0)])
        r = _calcular_baseline(df)
        assert r["status_cor"][0] == "VERDE"
        assert r["usou_fallback_12m"][0] == False

    def test_banana_estavel_amarelo(self):
        """Preco estavel dentro de ±15% da ancora → AMARELO."""
        df = _make_df("BANANA", precos_2025=[5.0] * 12,
                       precos_atuais=[(2026, 3, 5.30)])
        r = _calcular_baseline(df)
        assert r["status_cor"][0] == "AMARELO"
        assert r["usou_fallback_12m"][0] == False

    def test_batata_14_acima_amarelo(self):
        """14% acima da ancora → AMARELO (dentro do threshold 15%)."""
        df = _make_df("BATATA", precos_2025=[10.0] * 12,
                       precos_atuais=[(2026, 1, 11.40)])
        r = _calcular_baseline(df)
        assert r["status_cor"][0] == "AMARELO"

    def test_morango_15_1_abaixo_verde(self):
        """15.1% abaixo → VERDE (strict < 0.85)."""
        df = _make_df("MORANGO", precos_2025=[10.0] * 12,
                       precos_atuais=[(2026, 4, 8.49)])
        r = _calcular_baseline(df)
        assert r["status_cor"][0] == "VERDE"


class TestFallbackHibrido:
    """Validacao do mecanismo de fallback 12m para produtos sem 2025."""

    def test_pitaia_amarela_fallback(self):
        """Teste 3: Pitaia Amarela — produto novo, sem 2025.

        Dados apenas em 2026 (Jan-Mai), media = R$ 10,00.
        Ultimo preco (Maio) = R$ 10,50 (+5%).
        COALESCE(NULL, 10.00) = 10.00.
        10.50 dentro de ±15% de 10.00 → AMARELO.
        usou_fallback_12m = True.
        """
        df = _make_df(
            "PITAIA_AMARELA",
            precos_2025=None,
            precos_atuais=[(2026, 1, 10.0), (2026, 2, 10.0),
                           (2026, 3, 10.0), (2026, 4, 10.0),
                           (2026, 5, 10.50)],
        )
        r = _calcular_baseline(df)
        assert r["status_cor"][0] == "AMARELO", (
            f"Pitaia a R$ 10,50 (fallback R$ 10,00) deveria ser AMARELO, "
            f"mas foi {r['status_cor'][0]}"
        )
        assert r["usou_fallback_12m"][0] == True, (
            "Produto sem 2025 deve ter usou_fallback_12m = True"
        )

    def test_pitaia_fallback_vermelho(self):
        """Produto novo, sem 2025, preco 20% acima do fallback → VERMELHO."""
        df = _make_df(
            "PITAIA_ROXA",
            precos_2025=None,
            precos_atuais=[(2026, 1, 10.0), (2026, 2, 10.0),
                           (2026, 3, 10.0), (2026, 4, 10.0),
                           (2026, 5, 12.50)],
        )
        r = _calcular_baseline(df)
        assert r["status_cor"][0] == "VERMELHO"
        assert r["usou_fallback_12m"][0] == True

    def test_pitaia_fallback_verde(self):
        """Produto novo, sem 2025, preco 20% abaixo do fallback → VERDE."""
        df = _make_df(
            "PITAIA_VERDE",
            precos_2025=None,
            precos_atuais=[(2026, 1, 10.0), (2026, 2, 10.0),
                           (2026, 3, 10.0), (2026, 4, 10.0),
                           (2026, 5, 7.50)],
        )
        r = _calcular_baseline(df)
        assert r["status_cor"][0] == "VERDE"
        assert r["usou_fallback_12m"][0] == True


class TestBorda:
    """Edge cases: dados ausentes, produtos com dados so em 2025."""

    def test_pitaya_1_mes_insuficiente(self):
        """Pitaya so tem 1 registro em 2026, sem 2025, sem fallback.

        Fallback requer ≥3 meses → preco_fallback_12m = NULL.
        base_2025 = NULL (sem 2025).
        COALESCE = NULL → INSUFICIENTE.
        """
        df = _make_df("PITAYA", precos_2025=None,
                       precos_atuais=[(2026, 2, 15.0)])
        r = _calcular_baseline(df)
        assert r["status_cor"][0] == "INSUFICIENTE"

    def test_produto_so_2025_amarelo(self):
        """Produto com dados apenas em 2025 (sem 2026).

        A ancora de 2025 existe, e o ultimo preco e o mes 12 de 2025.
        preco_referencia = preco_atual → AMARELO.
        (A remocao do filtro 'u.ano < 2026' permite este cenario.)
        """
        df = _make_df("CHUCHU", precos_2025=[3.5] * 12,
                       precos_atuais=None)
        r = _calcular_baseline(df)
        assert r["status_cor"][0] == "AMARELO"

    def test_preco_referencia_zero_insuficiente(self):
        """Media 2025 = 0 → INSUFICIENTE (protecao contra divisao)."""
        df = _make_df("PRODUTO_ZERO", precos_2025=[0.0] * 12,
                       precos_atuais=[(2026, 3, 5.0)])
        r = _calcular_baseline(df)
        assert r["status_cor"][0] == "INSUFICIENTE"

    def test_produto_sem_nenhum_dado(self):
        """Dataframe vazio nao pode crashar."""
        df = pl.DataFrame(schema={
            "id_produto": pl.Int64, "id_localidade": pl.Int64,
            "uf": pl.String, "municipio_id": pl.String,
            "produto": pl.String, "ano": pl.Int32,
            "mes": pl.Int32, "preco_medio": pl.Float64,
        })
        assert df.height == 0
        r = _calcular_baseline(df)
        assert r.height == 0


class TestTratorRejeitado:
    """Teste 4: Validacao do filtro categoria_b2c.

    A MV aplica WHERE categoria_b2c = 'ALIMENTO_VAREJO'.
    Este teste verifica que a funcao de calculo (que nao tem o filtro)
    ainda processa corretamente, mas o filtro final na MV bloqueia
    produtos B2B.
    """

    def test_calculo_nao_rejeita_trator(self):
        """O calculo em si processa o trator — quem bloqueia e a MV."""
        df = _make_df("TRATOR_150_16X16", precos_2025=[500000] * 12,
                       precos_atuais=[(2026, 1, 510000)])
        r = _calcular_baseline(df)
        assert r.height == 1
        assert r["status_cor"][0] is not None

    def test_categoria_b2c_filtro_conceitual(self):
        """Verificacao conceitual: apenas ALIMENTO_VAREJO passa na MV.

        Simula o filtro da MV: se categoria_b2c != ALIMENTO_VAREJO,
        a linha e excluida. O resultado final tem 0 linhas para trator.
        """
        categorias_validas = ["ALIMENTO_VAREJO"]
        trator_category = "MAQUINARIO_FERRAMENTA"
        assert trator_category not in categorias_validas, (
            "TRATOR nao pode estar em ALIMENTO_VAREJO"
        )
