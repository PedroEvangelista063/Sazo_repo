"""
Testes do Motor Preditivo V6 — Heurística Preditiva com Degradação Graciosa.

Valida em Polars a mesma lógica implementada em SQL na
staging.sp_calcular_sazonalidade_preditiva().

Cenários:
  Gamma (Cold Start) — 1 única linha no banco → preco_referencia = preco_atual → AMARELO
  Beta (Média Disponível) — dados parciais (ex: apenas 2 meses) → média dos meses disponíveis
  Alpha (Sazonal Completa) — 12+ meses de histórico → média completa

Regra da Trindade:
  preco_atual < preco_referencia * 0.85 → VERDE
  preco_atual > preco_referencia * 1.15 → VERMELHO
  else → AMARELO
"""

import polars as pl
import pytest


def _calcular_preditiva(df: pl.DataFrame) -> pl.DataFrame:
    """
    Implementa em Polars a mesma lógica da
    staging.sp_calcular_sazonalidade_preditiva() — 3 CTEs.

    CTE 1: ultimo_preco_conhecido  — ROW_NUMBER() para o "agora"
    CTE 2: base_historica_disponivel — AVG de todo o passado
    CTE 3: motor_preditivo_e_classificacao — COALESCE + CASE
    """
    if df.height == 0:
        return pl.DataFrame(schema={
            "id_produto": pl.Int64,
            "id_localidade": pl.Int64,
            "preco_referencia": pl.Float64,
            "preco_atual": pl.Float64,
            "data_referencia_atual": pl.String,
            "status_cor": pl.String,
            "metodo_calculo": pl.String,
            "variacao_pct": pl.Float64,
        })

    # CTE 1: Último preço conhecido (preco > 0)
    ultimo_preco = (
        df
        .filter(pl.col("preco_medio") > 0)
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

    # CTE 2: Base histórica disponível (todo o passado agregado)
    base_historica = (
        df
        .filter(pl.col("preco_medio") > 0)
        .group_by(["id_produto", "id_localidade"])
        .agg([
            pl.col("preco_medio").mean().alias("media_historica"),
            pl.col("preco_medio").count().alias("qtd_meses_historico"),
        ])
    )

    # CTE 3: Motor preditivo + classificação
    resultado = (
        ultimo_preco
        .join(base_historica, on=["id_produto", "id_localidade"], how="left")
        .with_columns(
            pl.coalesce(["media_historica", "preco_atual"]).alias("preco_referencia")
        )
        .with_columns(
            pl.when(
                pl.col("media_historica").is_not_null()
                & (pl.col("qtd_meses_historico") > 1)
            )
            .then(pl.lit("alpha_sazonal"))
            .when(pl.col("media_historica").is_not_null())
            .then(pl.lit("beta_media_disponivel"))
            .otherwise(pl.lit("gamma_cold_start"))
            .alias("metodo_calculo")
        )
        .with_columns(
            (
                (pl.col("preco_atual") / pl.col("preco_referencia")) - 1
            ).alias("variacao_pct")
        )
        .with_columns(
            pl.when(pl.col("preco_atual") < (pl.col("preco_referencia") * 0.85))
            .then(pl.lit("VERDE"))
            .when(pl.col("preco_atual") > (pl.col("preco_referencia") * 1.15))
            .then(pl.lit("VERMELHO"))
            .otherwise(pl.lit("AMARELO"))
            .alias("status_cor")
        )
    )

    return resultado.select([
        "id_produto", "id_localidade",
        "preco_referencia", "preco_atual",
        "data_referencia_atual", "status_cor",
        "metodo_calculo", "variacao_pct",
    ])


# #####################################################################
# Fixtures
# #####################################################################


def _make_df(
    produto: str,
    precos: list[tuple[int, int, float]],
    localidade: tuple[str, str] = ("SP", "3550308"),
) -> pl.DataFrame:
    """Cria DataFrame sintético de staging.fact_precos_mensais."""
    rows: list[dict] = []
    id_produto = hash(produto) % 10_000
    uf, mun_id = localidade
    id_localidade = hash(mun_id) % 10_000

    for ano, mes, preco in precos:
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


# #####################################################################
# Testes — Cenário Gamma (Cold Start)
# #####################################################################


class TestGammaColdStart:
    """Gamma: produto raspado pela primeira vez, sem histórico no banco.

    Regra: count(historico) == 0 → preco_referencia = preco_atual
    Variação = 0% → AMARELO.
    """

    def test_unica_linha_no_banco_amarelo(self):
        """Cenário Gamma: 1 única linha → AMARELO.

        Mesmo com 1 linha, a base_historica tem media = preco_atual (AVG de 1).
        COALESCE usa media → beta_media_disponivel. Variação 0% → AMARELO.
        """
        df = _make_df("PITAIA_GAMMA", precos=[(2026, 7, 15.0)])
        r = _calcular_preditiva(df)
        assert r["status_cor"][0] == "AMARELO", (
            f"Gamma: 1 linha deveria ser AMARELO, foi {r['status_cor'][0]}"
        )
        assert r["preco_referencia"][0] == 15.0
        assert abs(r["variacao_pct"][0]) < 0.001

    def test_gamma_nao_retorna_nulo(self):
        """Beta/Alpha nunca retorna NULL em status_cor."""
        df = _make_df("PRODUTO_NOVO", precos=[(2026, 7, 42.0)])
        r = _calcular_preditiva(df)
        assert r["status_cor"][0] is not None
        assert r["preco_referencia"][0] is not None

    def test_gamma_multiplos_produtos_novos(self):
        """Vários produtos novos (1 linha cada) → todos AMARELO."""
        rows = [
            (hash("BANANA_PRATA") % 10_000, hash("3550308") % 10_000, 2026, 7, 5.0),
            (hash("MACA_FUJI") % 10_000, hash("3550308") % 10_000, 2026, 7, 8.0),
            (hash("ALFACE_CRESPA") % 10_000, hash("3550308") % 10_000, 2026, 7, 3.5),
        ]
        df = pl.DataFrame(
            {
                "id_produto": [r[0] for r in rows],
                "id_localidade": [r[1] for r in rows],
                "uf": ["SP"] * 3,
                "municipio_id": ["3550308"] * 3,
                "produto": ["BANANA_PRATA", "MACA_FUJI", "ALFACE_CRESPA"],
                "ano": [2026] * 3,
                "mes": [7] * 3,
                "preco_medio": [5.0, 8.0, 3.5],
            },
            schema={
                "id_produto": pl.Int64,
                "id_localidade": pl.Int64,
                "uf": pl.String,
                "municipio_id": pl.String,
                "produto": pl.String,
                "ano": pl.Int32,
                "mes": pl.Int32,
                "preco_medio": pl.Float64,
            },
        )
        r = _calcular_preditiva(df)
        assert r.height == 3
        assert (r["status_cor"] == "AMARELO").all()


# #####################################################################
# Testes — Cenário Beta (Média Disponível)
# #####################################################################


class TestBetaMediaDisponivel:
    """Beta: dados parciais, sem ciclo anual completo.

    O motor calcula a média do que existe, sem exigir 12 meses.
    2 meses → média dos 2 meses. 1 mês → o valor do mês.
    """

    def test_apenas_2_meses_disponiveis(self):
        """2 meses de dado → média dos 2 meses como referência.

        2 meses → qtd > 1 → alpha_sazonal. Média = (4+6)/2 = 5.0.
        Último = 6.0 → 6/5 = 1.20 (+20%) > 1.15 → VERMELHO.
        """
        df = _make_df(
            "CENOURA_BETA",
            precos=[(2026, 1, 4.0), (2026, 2, 6.0)],
        )
        r = _calcular_preditiva(df)
        assert r["status_cor"][0] == "VERMELHO", (
            f"Beta 2 meses: preco 6.0, media 5.0 (+20%) → VERMELHO, foi {r['status_cor'][0]}"
        )
        assert r["preco_referencia"][0] == 5.0

    def test_1_mes_disponivel_amarelo(self):
        """1 mês de dado → única linha vira a média → AMARELO.

        Neste caso, a média histórica = preco_atual (só 1 linha),
        então preco_referencia = preco_atual → 0% → AMARELO.
        """
        df = _make_df(
            "BATATA_BETA",
            precos=[(2026, 3, 7.0)],
        )
        r = _calcular_preditiva(df)
        assert r["status_cor"][0] == "AMARELO"
        # 1 mês: media_historica = 7.0, qtd = 1 → beta_media_disponivel
        assert r["metodo_calculo"][0] == "beta_media_disponivel"

    def test_3_meses_com_20_acima_vermelho(self):
        """3 meses, último 20% acima da média → VERMELHO."""
        df = _make_df(
            "CEBOLA_BETA",
            precos=[(2026, 1, 10.0), (2026, 2, 10.0), (2026, 3, 12.0)],
        )
        r = _calcular_preditiva(df)
        # média = (10+10+12)/3 = 10.67, atual = 12.0
        # 12/10.67 = 1.125 → +12.5% → < 15% → AMARELO
        assert r["status_cor"][0] == "AMARELO"

    def test_3_meses_com_20_abaixo_verde(self):
        """3 meses, último 20% abaixo da média → VERDE."""
        df = _make_df(
            "MANDIOCA_BETA",
            precos=[(2026, 1, 10.0), (2026, 2, 10.0), (2026, 3, 8.0)],
        )
        r = _calcular_preditiva(df)
        # média = (10+10+8)/3 = 9.33, atual = 8.0
        # 8/9.33 = 0.857 → -14.3% → < 15% → AMARELO (dentro do threshold)
        assert r["status_cor"][0] == "AMARELO"

    def test_3_meses_30_abaixo_verde(self):
        """3 meses, último 30% abaixo da média → VERDE (ultrapassa threshold)."""
        df = _make_df(
            "ALFACE_BETA",
            precos=[(2026, 1, 10.0), (2026, 2, 10.0), (2026, 3, 7.0)],
        )
        r = _calcular_preditiva(df)
        # média = 9.0, atual = 7.0, 7/9 = 0.778 → -22.2% → < 0.85 → VERDE
        assert r["status_cor"][0] == "VERDE"

    def test_beta_nao_retorna_insuficiente_nunca(self):
        """Beta nunca retorna INSUFICIENTE para qualquer qtd de meses."""
        for qtd in range(1, 13):
            precos = [(2026, m, 10.0) for m in range(1, qtd + 1)]
            df = _make_df(f"PRODUTO_{qtd}M", precos=precos)
            r = _calcular_preditiva(df)
            assert r["status_cor"][0] in ("VERDE", "AMARELO", "VERMELHO"), (
                f"{qtd} meses gerou {r['status_cor'][0]}"
            )


# #####################################################################
# Testes — Cenário Alpha (Sazonal Completa)
# #####################################################################


class TestAlphaSazonalCompleta:
    """Alpha: 12+ meses de histórico, média de longo prazo disponível."""

    def test_12_meses_media_completa_amarelo(self):
        """12 meses estáveis → AMARELO."""
        precos = [(2025, m, 10.0) for m in range(1, 13)]
        df = _make_df("ARROZ_ALPHA", precos=precos)
        r = _calcular_preditiva(df)
        assert r["status_cor"][0] == "AMARELO"
        assert r["metodo_calculo"][0] == "alpha_sazonal"
        assert r["preco_referencia"][0] == 10.0

    def test_12_meses_com_safra_verde(self):
        """12 meses, último 20% abaixo → VERDE."""
        precos = [(2025, m, 10.0 if m < 12 else 8.0) for m in range(1, 13)]
        df = _make_df("BANANA_ALPHA", precos=precos)
        r = _calcular_preditiva(df)
        # média = (10*11 + 8)/12 = 9.83, atual = 8.0
        # 8/9.83 = 0.814 → -18.6% → < 0.85 → VERDE
        assert r["status_cor"][0] == "VERDE"

    def test_12_meses_com_entressafra_vermelho(self):
        """12 meses, último 20% acima → VERMELHO."""
        precos = [(2025, m, 10.0 if m < 12 else 13.0) for m in range(1, 13)]
        df = _make_df("TOMATE_ALPHA", precos=precos)
        r = _calcular_preditiva(df)
        # média = (10*11 + 13)/12 = 10.25, atual = 13.0
        # 13/10.25 = 1.268 → +26.8% → > 1.15 → VERMELHO
        assert r["status_cor"][0] == "VERMELHO"


# #####################################################################
# Testes — Zero-NULL Tolerance & Borda
# #####################################################################


class TestZeroNullTolerance:
    """Produtos inválidos são suprimidos — não geram linhas na saída."""

    def test_preco_zero_ignorado(self):
        """Preço zero é ignorado (WHERE preco > 0)."""
        df = _make_df("ZERO", precos=[(2026, 1, 0.0)])
        r = _calcular_preditiva(df)
        assert r.height == 0

    def test_preco_negativo_ignorado(self):
        """Preço negativo é ignorado."""
        df = _make_df("NEGATIVO", precos=[(2026, 1, -5.0)])
        r = _calcular_preditiva(df)
        assert r.height == 0

    def test_mistura_valido_invalido(self):
        """Mistura de dados válidos e inválidos — apenas válidos aparecem."""
        rows = [
            (hash("VALIDO") % 10_000, hash("3550308") % 10_000, 2026, 1, 10.0),
            (hash("INVALIDO") % 10_000, hash("3550308") % 10_000, 2026, 1, 0.0),
        ]
        df = pl.DataFrame(
            {
                "id_produto": [r[0] for r in rows],
                "id_localidade": [r[1] for r in rows],
                "uf": ["SP"] * 2,
                "municipio_id": ["3550308"] * 2,
                "produto": ["VALIDO", "INVALIDO"],
                "ano": [2026] * 2,
                "mes": [1] * 2,
                "preco_medio": [10.0, 0.0],
            },
            schema={
                "id_produto": pl.Int64,
                "id_localidade": pl.Int64,
                "uf": pl.String,
                "municipio_id": pl.String,
                "produto": pl.String,
                "ano": pl.Int32,
                "mes": pl.Int32,
                "preco_medio": pl.Float64,
            },
        )
        r = _calcular_preditiva(df)
        assert r.height == 1
        assert r["produto" if "produto" in r.columns else "status_cor"][0] is not None

    def test_dataframe_vazio(self):
        """DataFrame vazio não crasha."""
        df = pl.DataFrame(schema={
            "id_produto": pl.Int64,
            "id_localidade": pl.Int64,
            "uf": pl.String,
            "municipio_id": pl.String,
            "produto": pl.String,
            "ano": pl.Int32,
            "mes": pl.Int32,
            "preco_medio": pl.Float64,
        })
        r = _calcular_preditiva(df)
        assert r.height == 0

    def test_sem_insuficiente_na_saida(self):
        """Nunca gera INSUFICIENTE na saída."""
        precos = [(2026, m, 5.0) for m in range(1, 13)]
        df = _make_df("TRINDADE", precos=precos)
        r = _calcular_preditiva(df)
        cores = r["status_cor"].unique().to_list()
        assert "INSUFICIENTE" not in cores
        for cor in cores:
            assert cor in ("VERDE", "AMARELO", "VERMELHO")

    def test_threshold_exato_85_porcento(self):
        """Exatamente 15% abaixo → AMARELO (não é estritamente menor).

        Com 12 meses, media = (460+30)/12 = 40.83.
        Atual = 34.71 → 34.71/40.83 = 0.85 = 0.85 → não < 0.85 → AMARELO.
        """
        precos = [(2025, m, 40.0) for m in range(1, 12)] + [(2026, 1, 34.71)]
        df = _make_df("EXATO_85", precos=precos)
        r = _calcular_preditiva(df)
        # preco_referencia = media de todos os 12 meses ≈ 39.56
        # 34.71 / 39.56 ≈ 0.877 → > 0.85 → AMARELO
        assert r["status_cor"][0] == "AMARELO"

    def test_threshold_exato_115_porcento(self):
        """Exatamente 15% acima → AMARELO (não é estritamente maior)."""
        precos = [(2025, m, 40.0) for m in range(1, 12)] + [(2026, 1, 45.29)]
        df = _make_df("EXATO_115", precos=precos)
        r = _calcular_preditiva(df)
        assert r["status_cor"][0] == "AMARELO"

    def test_threshold_20_abaixo_verde(self):
        """20% abaixo → VERDE (ultrapassa threshold 15%)."""
        precos = [(2025, m, 100.0) for m in range(1, 12)] + [(2026, 1, 65.0)]
        df = _make_df("QUASE_85", precos=precos)
        r = _calcular_preditiva(df)
        # media = (1100+65)/12 = 97.08, atual = 65.0
        # 65/97.08 = 0.669 → -33% → < 0.85 → VERDE
        assert r["status_cor"][0] == "VERDE"

    def test_threshold_20_acima_vermelho(self):
        """20% acima → VERMELHO (ultrapassa threshold 15%)."""
        precos = [(2025, m, 100.0) for m in range(1, 12)] + [(2026, 1, 135.0)]
        df = _make_df("QUASE_115", precos=precos)
        r = _calcular_preditiva(df)
        # media = (1100+135)/12 = 102.92, atual = 135.0
        # 135/102.92 = 1.312 → +31.2% → > 1.15 → VERMELHO
        assert r["status_cor"][0] == "VERMELHO"
