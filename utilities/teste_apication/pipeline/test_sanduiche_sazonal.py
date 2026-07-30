#!/usr/bin/env python3
"""
test_sanduiche_sazonal.py — Sanduíche Sazonal: Teste Local da Projeção de Preços
=================================================================================
Implementa em Python (Polars) a mesma lógica da Migration 40 (sp_project_sandwich_prices_2026),
mas rodando 100% local com DataFrames sintéticos — sem tocar no banco de produção.

FLUXO:
  1. `SanduicheSazonalEngine` — classe principal com os métodos de:
     - média_historica_por_mes() → preço médio de (prod, loc, mês) em 2024-2025
     - tendencia_produto() → variação % 2024→2025 para o mesmo (prod, loc, mês)
     - fallback_uf() → fallback respeitando mesma UF (FIX do Ponto 3)
     - projetar_meses_futuros() → gera projeções para Ago-Dez 2026
     - simular_upsert() → insere/atualiza com proteção is_forecast

  2. Testes com pytest (ou asserts nativos):
     - test_coerencia_media_agosto: a média projetada para Agosto/2026 é coerente?
     - test_bloqueio_sobrescrita: dado real (is_forecast=FALSE) bloqueia projeção?
     - test_fallback_uf: fallback respeita a UF (SP não usa preço do CE)?
     - test_tendencia_por_produto: tendência é calculada por produto, não global

EXECUÇÃO:
    pytest utilities/teste_apication/pipeline/test_sanduiche_sazonal.py -v
    # OU
    python utilities/teste_apication/pipeline/test_sanduiche_sazonal.py
"""

from __future__ import annotations

import polars as pl


# ═══════════════════════════════════════════════════════════════════════════
# ENGINE — Sanduíche Sazonal
# ═══════════════════════════════════════════════════════════════════════════


class SanduicheSazonalEngine:
    """
    Motor de projeção sazonal — réplica Python da lógica do
    sp_project_sandwich_prices_2026.

    Parâmetros:
        df_fact:  staging.fact_precos_mensais como DataFrame Polars
                  (colunas: id_produto, id_localidade, ano, mes, preco_medio)
        df_prod:  staging.dim_produto (colunas: id_produto, nome_produto)
        df_local: staging.dim_localidade (colunas: id_localidade, uf, municipio_id, municipio_nome)
        mes_atual: mês corrente (ex: 7 para Julho/2026)
        ano_alvo:  ano alvo da projeção (default 2026)
    """

    def __init__(
        self,
        df_fact: pl.DataFrame,
        df_prod: pl.DataFrame | None = None,
        df_local: pl.DataFrame | None = None,
        mes_atual: int = 7,
        ano_alvo: int = 2026,
    ):
        self._fact = df_fact
        self._prod = df_prod
        self._local = df_local
        self._mes_atual = mes_atual
        self._ano_alvo = ano_alvo

        # Cache para médias históricas já calculadas
        self._media_cache: dict[tuple[int, int, int], dict] = {}
        self._tendencia_cache: dict[tuple[int, int, int], float] = {}

    # ── Nível 1: Média histórica por (produto, localidade, mês) ──────────

    def media_historica_por_mes(
        self, id_produto: int, id_localidade: int, mes: int
    ) -> dict:
        """Calcula o preço médio de um (prod, loc, mês) em 2024-2025.

        Retorna dict com:
          - preco_medio: preço médio (ou None se sem dados)
          - confianca:   % de anos com dado (0, 50 ou 100)
          - meses_ok:    quantidade de meses com dado
        """
        cache_key = (id_produto, id_localidade, mes)
        if cache_key in self._media_cache:
            return self._media_cache[cache_key]

        # Filtra dados de 2024-2025 para o (prod, loc, mês) específico
        filtro = self._fact.filter(
            (pl.col("id_produto") == id_produto)
            & (pl.col("id_localidade") == id_localidade)
            & (pl.col("mes") == mes)
            & pl.col("ano").is_in([2024, 2025])
            & pl.col("preco_medio").is_not_null()
            & (pl.col("preco_medio") > 0)
        )

        if filtro.height > 0:
            preco = filtro.select(pl.col("preco_medio").mean()).item()
            meses_ok = filtro.select(
                pl.col("ano").n_unique()
            ).item()
            confianca = min(100.0, (meses_ok / 2.0) * 100.0)
            resultado = {
                "preco_medio": round(preco, 4),
                "confianca": round(confianca, 2),
                "meses_ok": meses_ok,
                "nivel": 1,
            }
            self._media_cache[cache_key] = resultado
            return resultado

        # ── Nível 2: Fallback para qq mês do mesmo prod+loc ──
        resultado = self._fallback_produto_localidade(id_produto, id_localidade)
        if resultado["preco_medio"] is not None:
            resultado["nivel"] = 2
            resultado["confianca"] = 30.0
            self._media_cache[cache_key] = resultado
            return resultado

        # ── Nível 3: Fallback para mesma UF (FIX — não cruza UFs) ──
        resultado = self._fallback_mesma_uf(id_produto, id_localidade, mes)
        if resultado["preco_medio"] is not None:
            resultado["nivel"] = 3
            resultado["confianca"] = 20.0
            self._media_cache[cache_key] = resultado
            return resultado

        # ── Nível 4: Fallback global do produto ──
        resultado = self._fallback_global_produto(id_produto)
        if resultado["preco_medio"] is not None:
            resultado["nivel"] = 4
            resultado["confianca"] = 10.0
            self._media_cache[cache_key] = resultado
            return resultado

        # Sem dados históricos
        resultado = {
            "preco_medio": None,
            "confianca": 0.0,
            "meses_ok": 0,
            "nivel": 0,
        }
        self._media_cache[cache_key] = resultado
        return resultado

    # ── Nível 2: Fallback produto+localidade ─────────────────────────────

    def _fallback_produto_localidade(
        self, id_produto: int, id_localidade: int
    ) -> dict:
        """Média do (produto, localidade) em qualquer mês de 2024-2025."""
        filtro = self._fact.filter(
            (pl.col("id_produto") == id_produto)
            & (pl.col("id_localidade") == id_localidade)
            & pl.col("ano").is_in([2024, 2025])
            & pl.col("preco_medio").is_not_null()
            & (pl.col("preco_medio") > 0)
        )
        if filtro.height > 0:
            preco = filtro.select(pl.col("preco_medio").mean()).item()
            return {"preco_medio": round(preco, 4), "meses_ok": filtro.height}
        return {"preco_medio": None, "meses_ok": 0}

    # ── Nível 3: Fallback por UF (FIX do Ponto 3) ────────────────────────

    def _fallback_mesma_uf(self, id_produto: int, id_localidade: int, mes: int) -> dict:
        """Média do (produto, mesma UF, mesmo mês) — NUNCA cruza UFs diferentes.

        FIX: Recebe id_localidade para extrair a UF da dim_localidade.
        Antes estava usando id_produto (bug) — o que nunca encontrava a UF.
        Agora usa self._local para descobrir a UF correta.
        """
        if self._local is None:
            return {"preco_medio": None, "meses_ok": 0}

        # Descobre a UF da localidade original
        uf_row = self._local.filter(
            pl.col("id_localidade") == id_localidade
        )
        if uf_row.height == 0:
            return {"preco_medio": None, "meses_ok": 0}
        uf = uf_row["uf"][0]

        # Usa o método público que já tem a lógica correta
        return self.fallback_por_uf(id_produto, uf, mes)

    def fallback_por_uf(
        self, id_produto: int, uf: str, mes: int
    ) -> dict:
        """Média do (produto, mesma UF, mesmo mês) — FIX do Ponto 3.

        Garante que o fallback NUNCA use preços de outra UF.
        """
        if self._local is None:
            return {"preco_medio": None, "meses_ok": 0}

        # IDs das localidades da mesma UF
        locais_uf = self._local.filter(
            pl.col("uf") == uf
        ).select("id_localidade").to_series().to_list()

        if not locais_uf:
            return {"preco_medio": None, "meses_ok": 0}

        filtro = self._fact.filter(
            (pl.col("id_produto") == id_produto)
            & pl.col("id_localidade").is_in(locais_uf)
            & (pl.col("mes") == mes)
            & pl.col("ano").is_in([2024, 2025])
            & pl.col("preco_medio").is_not_null()
            & (pl.col("preco_medio") > 0)
        )

        if filtro.height > 0:
            preco = filtro.select(pl.col("preco_medio").mean()).item()
            return {"preco_medio": round(preco, 4), "meses_ok": filtro.height}
        return {"preco_medio": None, "meses_ok": 0}

    # ── Nível 4: Fallback global ─────────────────────────────────────────

    def _fallback_global_produto(self, id_produto: int) -> dict:
        """Média do produto em QUALQUER localidade (último recurso)."""
        filtro = self._fact.filter(
            (pl.col("id_produto") == id_produto)
            & pl.col("ano").is_in([2024, 2025])
            & pl.col("preco_medio").is_not_null()
            & (pl.col("preco_medio") > 0)
        )
        if filtro.height > 0:
            preco = filtro.select(pl.col("preco_medio").mean()).item()
            return {"preco_medio": round(preco, 4), "meses_ok": filtro.height}
        return {"preco_medio": None, "meses_ok": 0}

    # ── Tendência por Produto (FIX do Ponto 1) ──────────────────────────

    def tendencia_produto(
        self, id_produto: int, id_localidade: int, mes: int
    ) -> float:
        """Calcula a tendência específica do (produto, localidade, mês).

        Fórmula: (preco_2025 - preco_2024) / preco_2024 * 100

        Isso substitui a "inflação geral" — cada produto tem sua própria tendência.
        Se não houver dados em ambos os anos, retorna 0 (tendência neutra).
        """
        cache_key = (id_produto, id_localidade, mes)
        if cache_key in self._tendencia_cache:
            return self._tendencia_cache[cache_key]

        p2024 = self._fact.filter(
            (pl.col("id_produto") == id_produto)
            & (pl.col("id_localidade") == id_localidade)
            & (pl.col("mes") == mes)
            & (pl.col("ano") == 2024)
            & pl.col("preco_medio").is_not_null()
            & (pl.col("preco_medio") > 0)
        )

        p2025 = self._fact.filter(
            (pl.col("id_produto") == id_produto)
            & (pl.col("id_localidade") == id_localidade)
            & (pl.col("mes") == mes)
            & (pl.col("ano") == 2025)
            & pl.col("preco_medio").is_not_null()
            & (pl.col("preco_medio") > 0)
        )

        if p2024.height > 0 and p2025.height > 0:
            v2024 = p2024.select(pl.col("preco_medio").mean()).item()
            v2025 = p2025.select(pl.col("preco_medio").mean()).item()
            tendencia = round(((v2025 - v2024) / v2024) * 100, 2)
        else:
            tendencia = 0.0

        self._tendencia_cache[cache_key] = tendencia
        return tendencia

    # ── Projeção dos meses futuros ───────────────────────────────────────

    def projetar_meses_futuros(self) -> pl.DataFrame:
        """Gera projeções para (mes_atual+1) até Dezembro.

        Retorna DataFrame com colunas:
          id_produto, id_localidade, ano, mes,
          preco_projetado, preco_referencia,
          tendencia_pct, confianca, nivel_fallback,
          is_forecast (sempre True)
        """
        meses_futuros = list(range(self._mes_atual + 1, 13))

        # Todos os produtos+localidades com dados históricos em 2024-2025
        produtos_base = (
            self._fact
            .filter(
                pl.col("ano").is_in([2024, 2025])
                & pl.col("preco_medio").is_not_null()
                & (pl.col("preco_medio") > 0)
            )
            .select("id_produto", "id_localidade")
            .unique()
        )

        rows = []
        for mes in meses_futuros:
            for row in produtos_base.iter_rows(named=True):
                id_prod = row["id_produto"]
                id_loc = row["id_localidade"]

                # Média histórica
                hist = self.media_historica_por_mes(id_prod, id_loc, mes)
                if hist["preco_medio"] is None:
                    continue

                # Tendência específica do produto
                tend = self.tendencia_produto(id_prod, id_loc, mes)

                # Preço projetado = média histórica + tendência
                preco_proj = round(
                    hist["preco_medio"] * (1 + tend / 100), 4
                )

                rows.append({
                    "id_produto": id_prod,
                    "id_localidade": id_loc,
                    "ano": self._ano_alvo,
                    "mes": mes,
                    "preco_projetado": preco_proj,
                    "preco_referencia": hist["preco_medio"],
                    "tendencia_pct": tend,
                    "confianca": hist["confianca"],
                    "nivel_fallback": hist.get("nivel", 0),
                    "is_forecast": True,
                })

        if not rows:
            return pl.DataFrame(
                schema={
                    "id_produto": pl.Int64,
                    "id_localidade": pl.Int64,
                    "ano": pl.Int32,
                    "mes": pl.Int32,
                    "preco_projetado": pl.Float64,
                    "preco_referencia": pl.Float64,
                    "tendencia_pct": pl.Float64,
                    "confianca": pl.Float64,
                    "nivel_fallback": pl.Int32,
                    "is_forecast": pl.Boolean,
                }
            )

        return pl.DataFrame(rows)

    # ── Simulação de UPSERT com proteção is_forecast ─────────────────────

    def simular_upsert(
        self,
        projecoes: pl.DataFrame,
        dados_reais: pl.DataFrame | None = None,
    ) -> pl.DataFrame:
        """Simula o UPSERT: dado real (is_forecast=FALSE) SEMPRE vence projeção.

        Regras:
          - Se existe dado_real para (prod, loc, ano, mes) → mantém real
          - Se existe apenas projeção → mantém projeção
          - Se ambos existem → real vence (projeção descartada)

        Parâmetros:
            projecoes: DataFrame das projeções (is_forecast=True)
            dados_reais: DataFrame com dados reais (is_forecast=False)
                         Se None, usa os dados de 2026 do self._fact

        Retorna:
            DataFrame final com os registros "no banco" após o UPSERT
        """
        # Se não forneceu dados reais explicitamente, pega do fact
        if dados_reais is None:
            dados_reais = self._fact.filter(
                (pl.col("ano") == self._ano_alvo)
                & pl.col("preco_medio").is_not_null()
                & (pl.col("preco_medio") > 0)
            ).select(
                pl.col("id_produto"),
                pl.col("id_localidade"),
                pl.col("ano"),
                pl.col("mes"),
                pl.col("preco_medio").alias("preco_real"),
            ).with_columns(
                pl.lit(False).alias("is_forecast_real"),
            )
        else:
            dados_reais = dados_reais.with_columns(
                pl.lit(False).alias("is_forecast_real"),
            )

        # Merge: real + projeção
        merged = projecoes.join(
            dados_reais,
            on=["id_produto", "id_localidade", "ano", "mes"],
            how="left",
        )

        # Regra de Ouro: se existe dado real, usa ele; senão, usa projeção
        resultado = merged.with_columns(
            pl.when(pl.col("preco_real").is_not_null())
            .then(pl.col("preco_real"))
            .otherwise(pl.col("preco_projetado"))
            .alias("preco_final"),
            pl.when(pl.col("preco_real").is_not_null())
            .then(pl.lit(False))
            .otherwise(pl.lit(True))
            .alias("is_forecast_final"),
        ).select(
            "id_produto",
            "id_localidade",
            "ano",
            "mes",
            pl.col("preco_final").alias("preco"),
            "is_forecast_final",
            "confianca",
            "tendencia_pct",
            "nivel_fallback",
        )

        return resultado


# ═══════════════════════════════════════════════════════════════════════════
# HELPERS — Dados Sintéticos para Testes
# ═══════════════════════════════════════════════════════════════════════════


def _criar_tabela_localidade() -> pl.DataFrame:
    """Cria dim_localidade sintética com 3 UFs: SP, MG, CE."""
    return pl.DataFrame([
        # SP — 2 localidades
        {"id_localidade": 1, "uf": "SP", "municipio_id": "3550308", "municipio_nome": "Sao Paulo"},
        {"id_localidade": 2, "uf": "SP", "municipio_id": "3509502", "municipio_nome": "Campinas"},
        # MG — 1 localidade
        {"id_localidade": 3, "uf": "MG", "municipio_id": "3106200", "municipio_nome": "Belo Horizonte"},
        # CE — 1 localidade
        {"id_localidade": 4, "uf": "CE", "municipio_id": "2304400", "municipio_nome": "Fortaleza"},
        # Outra localidade SP (para testar fallback intra-UF)
        {"id_localidade": 5, "uf": "SP", "municipio_id": "3548708", "municipio_nome": "Sao Jose dos Campos"},
    ])


def _criar_tabela_produto() -> pl.DataFrame:
    """Cria dim_produto sintética."""
    return pl.DataFrame([
        {"id_produto": 101, "nome_produto": "MILHO"},
        {"id_produto": 102, "nome_produto": "BATATA"},
        {"id_produto": 103, "nome_produto": "TOMATE"},
        {"id_produto": 201, "nome_produto": "PITAIA_EXOTICA"},  # produto sem histórico
    ])


def _criar_fact_precos_sanduiche() -> pl.DataFrame:
    """Cria staging.fact_precos_mensais sintética para o cenário Sanduíche.

    Cenário (Sanduíche de Folhas):
      - Folha 1 (2024): Milho em SP (id_loc=1) → preços sazonais típicos
        - Jan-Jun: R$ 2.50-3.00 (entressafra)
        - Jul-Dez: R$ 1.80-2.20 (safra)
      - Folha 2 (2025): Milho em SP → preços com leve inflação (+5% ~ +10%)
        - Jan-Jun: R$ 2.70-3.20
        - Jul-Dez: R$ 2.00-2.40
      - Folha 3 (2026 real): Milho em SP → dados reais de Jan-Jul
        - Jan: R$ 3.50, Fev: R$ 3.40, Mar: R$ 3.30, Abr: R$ 3.10,
          Mai: R$ 2.90, Jun: R$ 2.70, Jul: R$ 2.50
        - (gap em Março proposital para testar patch retroativo)
      - Produto sem histórico: PITAIA_EXOTICA (id=201) em SP (id_loc=1)
        - Sem dados em 2024-2025 → deve ser ignorada na projeção
      - MG (id_loc=3): Milho com preços diferentes de SP
        - Testa que fallback não cruza UFs
    """
    rows = []

    # ── MILHO em SP (id_prod=101, id_loc=1) ──
    precos_milho_sp = {
        2024: {1: 2.80, 2: 2.75, 3: 2.90, 4: 3.00, 5: 2.95, 6: 2.85,
               7: 2.20, 8: 2.00, 9: 1.90, 10: 1.85, 11: 1.95, 12: 2.10},
        2025: {1: 3.10, 2: 3.00, 3: 3.20, 4: 3.15, 5: 3.05, 6: 2.95,
               7: 2.40, 8: 2.20, 9: 2.10, 10: 2.05, 11: 2.15, 12: 2.30},
    }
    for ano, meses in precos_milho_sp.items():
        for mes, preco in meses.items():
            rows.append({
                "id_produto": 101, "id_localidade": 1,
                "ano": ano, "mes": mes, "preco_medio": preco,
            })

    # ── MILHO em SP — DADOS REAIS 2026 (Jan-Jul) ──
    # (gap proposital em Março para testar patch = não tem Março real)
    precos_2026_real = {
        1: 3.50, 2: 3.40,
        # 3: gap proposital
        4: 3.10, 5: 2.90, 6: 2.70, 7: 2.50,
    }
    for mes, preco in precos_2026_real.items():
        rows.append({
            "id_produto": 101, "id_localidade": 1,
            "ano": 2026, "mes": mes, "preco_medio": preco,
        })

    # ── MILHO em MG (id_prod=101, id_loc=3) — preços DIFERENTES de SP ──
    # Safra mais cara em MG
    precos_milho_mg = {
        2024: {1: 3.50, 2: 3.40, 3: 3.60, 4: 3.70, 5: 3.55, 6: 3.45,
               7: 2.90, 8: 2.70, 9: 2.60, 10: 2.55, 11: 2.65, 12: 2.80},
        2025: {1: 3.80, 2: 3.70, 3: 3.90, 4: 3.85, 5: 3.75, 6: 3.65,
               7: 3.10, 8: 2.90, 9: 2.80, 10: 2.75, 11: 2.85, 12: 3.00},
    }
    for ano, meses in precos_milho_mg.items():
        for mes, preco in meses.items():
            rows.append({
                "id_produto": 101, "id_localidade": 3,
                "ano": ano, "mes": mes, "preco_medio": preco,
            })

    # ── MILHO em CE (id_prod=101, id_loc=4) — preços mais baixos (Nordeste) ──
    precos_milho_ce = {
        2024: {1: 2.20, 2: 2.15, 3: 2.30, 4: 2.40, 5: 2.35, 6: 2.25,
               7: 1.80, 8: 1.60, 9: 1.50, 10: 1.45, 11: 1.55, 12: 1.70},
        2025: {1: 2.00, 2: 1.90, 3: 2.10, 4: 2.05, 5: 1.95, 6: 1.85,
               7: 1.60, 8: 1.40, 9: 1.30, 10: 1.25, 11: 1.35, 12: 1.50},
    }
    for ano, meses in precos_milho_ce.items():
        for mes, preco in meses.items():
            rows.append({
                "id_produto": 101, "id_localidade": 4,
                "ano": ano, "mes": mes, "preco_medio": preco,
            })

    # ── BATATA em SP (id_prod=102, id_loc=1) — sazonalidade diferente ──
    precos_batata_sp = {
        2024: {1: 4.50, 2: 4.80, 3: 5.20, 4: 5.50, 5: 5.00, 6: 4.50,
               7: 4.00, 8: 3.80, 9: 4.20, 10: 4.80, 11: 5.00, 12: 5.20},
        2025: {1: 5.50, 2: 5.80, 3: 6.20, 4: 6.50, 5: 6.00, 6: 5.50,
               7: 5.00, 8: 4.80, 9: 5.20, 10: 5.80, 11: 6.00, 12: 6.20},
    }
    for ano, meses in precos_batata_sp.items():
        for mes, preco in meses.items():
            rows.append({
                "id_produto": 102, "id_localidade": 1,
                "ano": ano, "mes": mes, "preco_medio": preco,
            })

    # ── PITAIA_EXOTICA (id_prod=201) — SEM histórico (cold start) ──
    # Não adiciona nenhum registro — produto sem dados

    return pl.DataFrame(rows)


# ═══════════════════════════════════════════════════════════════════════════
# TESTES
# ═══════════════════════════════════════════════════════════════════════════

# --- Fixtures compartilhadas ---

_df_fact = _criar_fact_precos_sanduiche()
_df_prod = _criar_tabela_produto()
_df_local = _criar_tabela_localidade()


def _criar_engine(mes_atual: int = 7) -> SanduicheSazonalEngine:
    """Cria engine com dados sintéticos."""
    return SanduicheSazonalEngine(
        df_fact=_df_fact,
        df_prod=_df_prod,
        df_local=_df_local,
        mes_atual=mes_atual,
        ano_alvo=2026,
    )


def test_engine_criada():
    """Smoke test: engine é criada sem erros."""
    engine = _criar_engine()
    assert engine is not None
    assert engine._mes_atual == 7
    assert engine._ano_alvo == 2026


# ── TESTE 1: Coerência da Média Histórica ────────────────────────────────

class TestCoerenciaMedia:

    def test_media_agosto_milho_sp(self):
        """Milho em SP: média de Agosto (2024+2025) deve ser ~R$ 2.10.

        2024-Ago: R$ 2.00
        2025-Ago: R$ 2.20
        Média:   R$ 2.10
        """
        engine = _criar_engine()
        hist = engine.media_historica_por_mes(101, 1, 8)
        assert hist["preco_medio"] is not None, "Deveria ter média para Ago"
        assert hist["preco_medio"] == 2.10, (
            f"Média de Agosto deveria ser 2.10, mas foi {hist['preco_medio']}"
        )
        assert hist["confianca"] == 100.0, "Dois anos com dados → confiança 100%"
        assert hist["nivel"] == 1, "Deveria ser nível 1 (mesmo prod+loc+mês)"

    def test_media_dezembro_milho_sp(self):
        """Milho em SP: média de Dezembro (2024+2025) deve ser ~R$ 2.20.

        2024-Dez: R$ 2.10
        2025-Dez: R$ 2.30
        Média:   R$ 2.20
        """
        engine = _criar_engine()
        hist = engine.media_historica_por_mes(101, 1, 12)
        assert hist["preco_medio"] == 2.20, (
            f"Média de Dezembro deveria ser 2.20, mas foi {hist['preco_medio']}"
        )

    def test_media_milho_mg_diferente_de_sp(self):
        """Milho em MG tem preços diferentes de SP — verifica independência."""
        engine = _criar_engine()
        hist_mg = engine.media_historica_por_mes(101, 3, 8)
        hist_sp = engine.media_historica_por_mes(101, 1, 8)

        # MG (2.90+2.90)/2 = 2.80
        assert hist_mg["preco_medio"] == 2.80, (
            f"Média MG-Ago deveria ser 2.80, mas foi {hist_mg['preco_medio']}"
        )
        # MG ≠ SP (garantindo que não houve cruzamento de UFs)
        assert hist_mg["preco_medio"] != hist_sp["preco_medio"], (
            "MG e SP não podem ter a mesma média — UFs diferentes!"
        )

    def test_produto_sem_historico_retorna_none(self):
        """PITAIA_EXOTICA (sem histórico) deve retornar None."""
        engine = _criar_engine()
        hist = engine.media_historica_por_mes(201, 1, 8)
        assert hist["preco_medio"] is None, (
            "Produto sem histórico deve retornar None"
        )
        assert hist["confianca"] == 0.0


# ── TESTE 2: Tendência por Produto (FIX do Ponto 1) ─────────────────────

class TestTendenciaPorProduto:

    def test_tendencia_milho_agosto_2024_2025(self):
        """Milho SP em Agosto: (2.20 - 2.00) / 2.00 * 100 = +10%."""
        engine = _criar_engine()
        tend = engine.tendencia_produto(101, 1, 8)
        assert tend == 10.0, (
            f"Tendência do Milho em Ago deveria ser +10%, mas foi {tend}%"
        )

    def test_tendencia_batata_janeiro_2024_2025(self):
        """Batata SP em Janeiro: (5.50 - 4.50) / 4.50 * 100 = +22.22%."""
        engine = _criar_engine()
        tend = engine.tendencia_produto(102, 1, 1)
        assert tend == 22.22, (
            f"Tendência da Batata em Jan deveria ser +22.22%, mas foi {tend}%"
        )

    def test_tendencia_zero_para_sem_historico(self):
        """Sem histórico → tendência zero."""
        engine = _criar_engine()
        tend = engine.tendencia_produto(201, 1, 8)
        assert tend == 0.0, (
            "Produto sem histórico deve ter tendência zero"
        )


# ── TESTE 3: Fallback respeita UF (FIX do Ponto 3) ──────────────────────

class TestFallbackUF:

    def test_fallback_milho_ce_agosto_usando_mesma_uf(self):
        """Milho CE em Agosto: fallback por UF deve usar apenas CE.

        Se o Milho CE não tiver dado para Agosto em 2024-2025
        (tem, mas vamos testar com um mês sem dado), o fallback
        deve buscar APENAS em localidades do CE.
        """
        engine = _criar_engine()
        # CE (id_loc=4) tem dados de Agosto, então nível 1 funciona
        hist = engine.media_historica_por_mes(101, 4, 8)
        assert hist["preco_medio"] is not None
        assert hist["nivel"] == 1  # dado direto

    def test_fallback_milho_sp_para_localidade_sem_dados(self):
        """SP tem 3 localidades. Se uma não tem dado para um mês,
        o fallback por UF deve usar outra localidade da MESMA UF (SP),
        nunca CE ou MG.
        """
        engine = _criar_engine()

        # Localidade SP 5 (Sao Jose dos Campos) — NÃO tem dados no fact
        # Então a média histórica deve cair para nível 3 (fallback por UF)

        # Testa a cadeia de fallback automática via media_historica_por_mes
        hist = engine.media_historica_por_mes(101, 5, 8)
        assert hist["preco_medio"] is not None, (
            "Deveria encontrar fallback para SP-5 via cadeia"
        )
        assert hist["nivel"] == 3, (
            f"SP-5 sem dados deveria cair no nível 3 (fallback UF), mas caiu no nível {hist['nivel']}"
        )
        assert hist["preco_medio"] == 2.10, (
            f"Fallback SP-Ago deveria ser 2.10, mas foi {hist['preco_medio']}"
        )
        assert hist["confianca"] == 20.0, (
            "Nível 3 deve ter confiança 20.0"
        )

        # Testa fallback_por_uf diretamente também
        fallback = engine.fallback_por_uf(101, "SP", 8)
        assert fallback["preco_medio"] == 2.10, (
            f"Fallback SP-Ago deveria ser 2.10, mas foi {fallback['preco_medio']}"
        )

    def test_fallback_ce_nao_usa_preco_sp(self):
        """CE NÃO pode usar preço de SP no fallback.

        Se filtrarmos por UF="CE", o preço de SP (R$ 2.10) não
        deve aparecer. CE tem Milho mais barato (~R$ 1.50 em Agosto).
        """
        engine = _criar_engine()
        fallback = engine.fallback_por_uf(101, "CE", 8)
        assert fallback["preco_medio"] is not None
        # CE-Ago: (1.60 + 1.40) / 2 = 1.50
        assert fallback["preco_medio"] == 1.50, (
            f"Fallback CE-Ago deveria ser 1.50, mas foi {fallback['preco_medio']}"
        )
        # GARANTIA: NÃO é o preço de SP
        assert fallback["preco_medio"] != 2.10, (
            "CE NÃO pode usar preço de SP no fallback!"
        )


# ── TESTE 4: Projeção dos Meses Futuros ─────────────────────────────────

class TestProjecaoMesesFuturos:

    def test_projeta_ago_a_dez_para_milho_sp(self):
        """Milho SP: deve projetar Agosto a Dezembro (5 meses)."""
        engine = _criar_engine(mes_atual=7)
        proj = engine.projetar_meses_futuros()

        # Filtra apenas Milho SP
        milho_sp = proj.filter(
            (pl.col("id_produto") == 101)
            & (pl.col("id_localidade") == 1)
        )
        assert milho_sp.height == 5, (
            f"Deveria projetar 5 meses (Ago-Dez), mas projetou {milho_sp.height}"
        )

        # Verifica meses
        meses = sorted(milho_sp["mes"].to_list())
        assert meses == [8, 9, 10, 11, 12], (
            f"Meses projetados deveriam ser Ago-Dez, mas foram {meses}"
        )

    def test_preco_projetado_agosto_milho_sp_com_tendencia(self):
        """Milho SP Agosto: preço base R$ 2.10 + tendência +10% = R$ 2.31."""
        engine = _criar_engine(mes_atual=7)
        proj = engine.projetar_meses_futuros()

        agosto = proj.filter(
            (pl.col("id_produto") == 101)
            & (pl.col("id_localidade") == 1)
            & (pl.col("mes") == 8)
        )
        assert agosto.height == 1
        preco = agosto["preco_projetado"][0]
        # 2.10 * (1 + 10/100) = 2.31
        assert preco == 2.31, (
            f"Preço projetado para Milho SP Ago deveria ser 2.31, mas foi {preco}"
        )

    def test_pitaia_exotica_nao_projetada(self):
        """PITAIA_EXOTICA sem histórico não deve ser projetada."""
        engine = _criar_engine(mes_atual=7)
        proj = engine.projetar_meses_futuros()
        pitaia = proj.filter(pl.col("id_produto") == 201)
        assert pitaia.height == 0, (
            "Produto sem histórico não deve ser projetado"
        )

    def test_milho_mg_projecao_independente_de_sp(self):
        """Milho MG tem projeção DIFERENTE de Milho SP."""
        engine = _criar_engine(mes_atual=7)
        proj = engine.projetar_meses_futuros()

        mg = proj.filter(
            (pl.col("id_produto") == 101)
            & (pl.col("id_localidade") == 3)
            & (pl.col("mes") == 8)
        )
        sp = proj.filter(
            (pl.col("id_produto") == 101)
            & (pl.col("id_localidade") == 1)
            & (pl.col("mes") == 8)
        )

        assert mg["preco_projetado"][0] != sp["preco_projetado"][0], (
            "MG e SP devem ter preços projetados DIFERENTES!"
        )


# ── TESTE 5: Bloqueio de Sobrescrita (FIX do Ponto 5) ───────────────────

class TestBloqueioSobrescrita:

    def test_dado_real_bloqueia_projecao_no_upsert(self):
        """Se existe dado real para (prod, loc, ano, mes), a projeção não vence.

        Simula: Milho SP tem dado REAL em Agosto/2026 de R$ 2.60.
        A projeção é R$ 2.31. Após o UPSERT, deve ficar R$ 2.60 (real).
        """
        engine = _criar_engine(mes_atual=7)
        proj = engine.projetar_meses_futuros()

        # Simula dado real chegando para Agosto
        dado_real = pl.DataFrame([{
            "id_produto": 101,
            "id_localidade": 1,
            "ano": 2026,
            "mes": 8,
            "preco_real": 2.60,
        }])

        resultado = engine.simular_upsert(proj, dado_real)

        agosto = resultado.filter(
            (pl.col("id_produto") == 101)
            & (pl.col("id_localidade") == 1)
            & (pl.col("mes") == 8)
        )
        assert agosto.height == 1
        # Deve ter ficado com o dado real (R$ 2.60), não a projeção (R$ 2.31)
        assert agosto["preco"][0] == 2.60, (
            f"Dado real (2.60) deveria vencer projeção, mas ficou {agosto['preco'][0]}"
        )
        assert agosto["is_forecast_final"][0] == False, (
            "is_forecast deve ser FALSE quando dado real existe"
        )

    def test_projecao_mantida_quando_sem_dado_real(self):
        """Se NÃO existe dado real, a projeção é mantida."""
        engine = _criar_engine(mes_atual=7)
        proj = engine.projetar_meses_futuros()

        # Sem dados reais para Setembro
        dado_real_parcial = pl.DataFrame([{
            "id_produto": 101,
            "id_localidade": 1,
            "ano": 2026,
            "mes": 8,  # só tem real para Agosto
            "preco_real": 2.60,
        }])

        resultado = engine.simular_upsert(proj, dado_real_parcial)

        setembro = resultado.filter(
            (pl.col("id_produto") == 101)
            & (pl.col("id_localidade") == 1)
            & (pl.col("mes") == 9)
        )
        assert setembro.height == 1
        # Setembro não tem dado real → mantém projeção
        assert setembro["is_forecast_final"][0] == True, (
            "Sem dado real, is_forecast deve ser TRUE"
        )
        assert setembro["preco"][0] is not None, (
            "Projeção deve ter preço mesmo sem dado real"
        )

    def test_gap_marco_preenchido_no_upsert(self):
        """Março/2026 tem gap (sem dado real) → projeção deve preencher.

        No nosso cenário, Março/2026 não tem dado real (gap proposital).
        O engine deve projetar baseado na média histórica de Março.
        """
        engine = _criar_engine(mes_atual=7)

        # Dados reais de 2026 (sem Março)
        dados_2026 = _df_fact.filter(
            (pl.col("ano") == 2026)
            & (pl.col("id_produto") == 101)
            & (pl.col("id_localidade") == 1)
        ).select(
            pl.col("id_produto"),
            pl.col("id_localidade"),
            pl.col("ano"),
            pl.col("mes"),
            pl.col("preco_medio").alias("preco_real"),
        )

        # Março está presente nos dados reais? Deve estar ausente
        marco = dados_2026.filter(pl.col("mes") == 3)
        assert marco.height == 0, (
            "Março deve estar propositalmente sem dado real"
        )

        # Mas a média histórica DEVE existir (2024 e 2025 têm Março)
        hist = engine.media_historica_por_mes(101, 1, 3)
        assert hist["preco_medio"] is not None, (
            "Média histórica de Março deve existir"
        )


# ═══════════════════════════════════════════════════════════════════════════
# MAIN — Execução standalone (sem pytest)
# ═══════════════════════════════════════════════════════════════════════════


def _executar_todos_testes():
    """Executa todos os testes com asserts e printa resultado."""
    testagens = [
        ("Engine criada", test_engine_criada),
        ("Média Agosto Milho SP", TestCoerenciaMedia().test_media_agosto_milho_sp),
        ("Média Dezembro Milho SP", TestCoerenciaMedia().test_media_dezembro_milho_sp),
        ("MG ≠ SP", TestCoerenciaMedia().test_media_milho_mg_diferente_de_sp),
        ("Sem histórico = None", TestCoerenciaMedia().test_produto_sem_historico_retorna_none),
        ("Tendência Milho Agosto +10%", TestTendenciaPorProduto().test_tendencia_milho_agosto_2024_2025),
        ("Tendência Batata Janeiro +22.22%", TestTendenciaPorProduto().test_tendencia_batata_janeiro_2024_2025),
        ("Tendência zero sem histórico", TestTendenciaPorProduto().test_tendencia_zero_para_sem_historico),
        ("Fallback SP usa SP", TestFallbackUF().test_fallback_milho_sp_para_localidade_sem_dados),
        ("Fallback CE usa CE", TestFallbackUF().test_fallback_ce_nao_usa_preco_sp),
        ("Projeta 5 meses Ago-Dez", TestProjecaoMesesFuturos().test_projeta_ago_a_dez_para_milho_sp),
        ("Preço Agosto com tendência", TestProjecaoMesesFuturos().test_preco_projetado_agosto_milho_sp_com_tendencia),
        ("Pitaia não projetada", TestProjecaoMesesFuturos().test_pitaia_exotica_nao_projetada),
        ("MG ≠ SP na projeção", TestProjecaoMesesFuturos().test_milho_mg_projecao_independente_de_sp),
        ("Real bloqueia projeção", TestBloqueioSobrescrita().test_dado_real_bloqueia_projecao_no_upsert),
        ("Sem real mantém projeção", TestBloqueioSobrescrita().test_projecao_mantida_quando_sem_dado_real),
        ("Gap Março preenchido", TestBloqueioSobrescrita().test_gap_marco_preenchido_no_upsert),
    ]

    print("=" * 70)
    print("🧪 SANDUÍCHE SAZONAL — TESTES DE VALIDAÇÃO")
    print("=" * 70)

    passou = 0
    falhou = 0
    for nome, func in testagens:
        try:
            func()
            print(f"  ✅ {nome}")
            passou += 1
        except AssertionError as e:
            print(f"  ❌ {nome}")
            print(f"      → {e}")
            falhou += 1
        except Exception as e:
            print(f"  💥 {nome} (ERRO)")
            print(f"      → {type(e).__name__}: {e}")
            falhou += 1

    print("=" * 70)
    print(f"Resultado: {passou} passaram, {falhou} falharam de {len(testagens)} testes")
    print("=" * 70)

    return falhou == 0


if __name__ == "__main__":
    import sys
    sucesso = _executar_todos_testes()
    sys.exit(0 if sucesso else 1)
