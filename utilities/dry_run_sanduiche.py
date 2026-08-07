#!/usr/bin/env python3
"""
dry_run_sanduiche.py — Dry-Run do Sanduíche Sazonal contra dados REAIS
=======================================================================
Conecta no banco PostgreSQL (local ou remoto), carrega os dados REAIS de
staging.fact_precos_mensais, executa a lógica do Sanduíche Sazonal e
MOSTRA as projeções que seriam geradas para Ago-Dez 2026.

⚠️  READ-ONLY: NADA é escrito no banco. Apenas SELECTs.

Uso:
    # Local (padrão)
    python3 utilities/dry_run_sanduiche.py

    # Remoto (Aiven)
    DATABASE_URL="postgresql://..." python3 utilities/dry_run_sanduiche.py

Dependências:
    pip install polars asyncpg python-dotenv
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys
from datetime import datetime
from pathlib import Path

import polars as pl

# ── Forçando UTF-8 ──
if sys.stdout.encoding != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("dry_run_sanduiche")

# ── Carrega .env se existir ──
_ENV_PATH = Path(__file__).resolve().parent.parent / "backend" / ".env"
if _ENV_PATH.exists():
    from dotenv import load_dotenv
    load_dotenv(_ENV_PATH)
    logger.info("Variáveis carregadas de: %s", _ENV_PATH)

# ── DSN: prioriza env var, fallback para local ──
DEFAULT_DSN = "postgresql://postgres:postgres_dev_local@localhost:5432/quero_comprar"
DATABASE_URL = os.environ.get("DATABASE_URL_LOCAL_BACKUP") or os.environ.get("DATABASE_URL") or DEFAULT_DSN


# ═══════════════════════════════════════════════════════════════════════════
# ENGINE — Sanduíche Sazonal (replicada do test_sanduiche_sazonal.py)
# ═══════════════════════════════════════════════════════════════════════════


class SanduicheSazonalEngine:
    """
    Motor de projeção sazonal — réplica Python da lógica do
    sp_project_sandwich_prices_2026.

    Parâmetros:
        df_fact:  staging.fact_precos_mensais como DataFrame Polars
        df_prod:  staging.dim_produto (opcional)
        df_local: staging.dim_localidade (opcional)
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
        self._media_cache: dict[tuple[int, int, int], dict] = {}
        self._tendencia_cache: dict[tuple[int, int, int], float] = {}

    # ── Nível 1: Média histórica por (produto, localidade, mês) ──────────

    def media_historica_por_mes(self, id_produto: int, id_localidade: int, mes: int) -> dict:
        cache_key = (id_produto, id_localidade, mes)
        if cache_key in self._media_cache:
            return self._media_cache[cache_key]

        # Nível 1: mesmo (prod, loc, mês)
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
            meses_ok = filtro.select(pl.col("ano").n_unique()).item()
            confianca = min(100.0, (meses_ok / 2.0) * 100.0)
            resultado = {"preco_medio": round(preco, 4), "confianca": round(confianca, 2), "meses_ok": meses_ok, "nivel": 1}
            self._media_cache[cache_key] = resultado
            return resultado

        # Nível 2: mesmo (prod, loc) qq mês
        resultado = self._fallback_produto_localidade(id_produto, id_localidade)
        if resultado["preco_medio"] is not None:
            resultado.update({"nivel": 2, "confianca": 30.0})
            self._media_cache[cache_key] = resultado
            return resultado

        # Nível 3: mesma UF (não cruza UFs)
        resultado = self._fallback_mesma_uf(id_produto, id_localidade, mes)
        if resultado["preco_medio"] is not None:
            resultado.update({"nivel": 3, "confianca": 20.0})
            self._media_cache[cache_key] = resultado
            return resultado

        # Nível 4: fallback global do produto
        resultado = self._fallback_global_produto(id_produto)
        if resultado["preco_medio"] is not None:
            resultado.update({"nivel": 4, "confianca": 10.0})
            self._media_cache[cache_key] = resultado
            return resultado

        resultado = {"preco_medio": None, "confianca": 0.0, "meses_ok": 0, "nivel": 0}
        self._media_cache[cache_key] = resultado
        return resultado

    def _fallback_produto_localidade(self, id_produto: int, id_localidade: int) -> dict:
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

    def _fallback_mesma_uf(self, id_produto: int, id_localidade: int, mes: int) -> dict:
        """FIX: Extrai UF da localidade e busca APENAS na mesma UF."""
        if self._local is None:
            return {"preco_medio": None, "meses_ok": 0}
        uf_row = self._local.filter(pl.col("id_localidade") == id_localidade)
        if uf_row.height == 0:
            return {"preco_medio": None, "meses_ok": 0}
        uf = uf_row["uf"][0]
        return self.fallback_por_uf(id_produto, uf, mes)

    def fallback_por_uf(self, id_produto: int, uf: str, mes: int) -> dict:
        if self._local is None:
            return {"preco_medio": None, "meses_ok": 0}
        locais_uf = self._local.filter(pl.col("uf") == uf).select("id_localidade").to_series().to_list()
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

    def _fallback_global_produto(self, id_produto: int) -> dict:
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

    # ── Tendência por Produto (não global) ──────────────────────────────

    def tendencia_produto(self, id_produto: int, id_localidade: int, mes: int) -> float:
        cache_key = (id_produto, id_localidade, mes)
        if cache_key in self._tendencia_cache:
            return self._tendencia_cache[cache_key]

        p2024 = self._fact.filter(
            (pl.col("id_produto") == id_produto)
            & (pl.col("id_localidade") == id_localidade)
            & (pl.col("mes") == mes)
            & (pl.col("ano") == 2024)
            & pl.col("preco_medio").is_not_null() & (pl.col("preco_medio") > 0)
        )
        p2025 = self._fact.filter(
            (pl.col("id_produto") == id_produto)
            & (pl.col("id_localidade") == id_localidade)
            & (pl.col("mes") == mes)
            & (pl.col("ano") == 2025)
            & pl.col("preco_medio").is_not_null() & (pl.col("preco_medio") > 0)
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
        meses_futuros = list(range(self._mes_atual + 1, 13))
        produtos_base = (
            self._fact
            .filter(pl.col("ano").is_in([2024, 2025]) & pl.col("preco_medio").is_not_null() & (pl.col("preco_medio") > 0))
            .select("id_produto", "id_localidade").unique()
        )
        rows = []
        for mes in meses_futuros:
            for row in produtos_base.iter_rows(named=True):
                id_prod, id_loc = row["id_produto"], row["id_localidade"]
                hist = self.media_historica_por_mes(id_prod, id_loc, mes)
                if hist["preco_medio"] is None:
                    continue
                tend = self.tendencia_produto(id_prod, id_loc, mes)
                preco_proj = round(hist["preco_medio"] * (1 + tend / 100), 4)
                rows.append({
                    "id_produto": id_prod, "id_localidade": id_loc,
                    "ano": self._ano_alvo, "mes": mes,
                    "preco_projetado": preco_proj, "preco_referencia": hist["preco_medio"],
                    "tendencia_pct": tend, "confianca": hist["confianca"],
                    "nivel_fallback": hist.get("nivel", 0), "is_forecast": True,
                })
        if not rows:
            return pl.DataFrame(schema={
                "id_produto": pl.Int64, "id_localidade": pl.Int64, "ano": pl.Int32,
                "mes": pl.Int32, "preco_projetado": pl.Float64, "preco_referencia": pl.Float64,
                "tendencia_pct": pl.Float64, "confianca": pl.Float64,
                "nivel_fallback": pl.Int32, "is_forecast": pl.Boolean,
            })
        return pl.DataFrame(rows)

    def resumo_uf_produto(self, projecoes: pl.DataFrame) -> pl.DataFrame:
        """Agrupa projeções por UF, produto, mês para relatório."""
        if self._prod is None or self._local is None or projecoes.height == 0:
            return projecoes
        return (
            projecoes
            .join(self._local, on="id_localidade")
            .join(self._prod, on="id_produto")
            .select("uf", "nome_produto", "mes", "preco_projetado", "preco_referencia", "tendencia_pct", "confianca", "nivel_fallback")
            .sort("uf", "nome_produto", "mes")
        )


# ═══════════════════════════════════════════════════════════════════════════
# CARGA DO BANCO
# ═══════════════════════════════════════════════════════════════════════════


async def _fetch_df(conn, query: str) -> pl.DataFrame:
    """Executa query assíncrona e retorna Polars DataFrame."""
    rows = await conn.fetch(query)
    if not rows:
        return pl.DataFrame()
    return pl.DataFrame([dict(r) for r in rows])


async def _carregar_dados(dsn: str) -> tuple[pl.DataFrame, pl.DataFrame, pl.DataFrame, dict]:
    import asyncpg

    logger.info("Conectando ao banco: %s", dsn.replace("postgres://", "postgres://***:***@"))
    conn = await asyncpg.connect(dsn, timeout=15)
    logger.info("Conexão estabelecida.")

    # Metadados do banco
    meta = {}
    row = await conn.fetchrow("SELECT version() AS v;")
    meta["versao"] = row["v"] if row else "desconhecida"

    # 1. Carregar dim_localidade
    logger.info("Carregando dim_localidade...")
    df_local = await _fetch_df(conn, """
        SELECT id_localidade, uf, COALESCE(municipio_id, '') AS municipio_id,
               COALESCE(municipio_nome, '') AS municipio_nome
        FROM staging.dim_localidade
    """)
    logger.info("  → %d localidades carregadas", df_local.height)

    # 2. Carregar dim_produto (apenas ALIMENTO_VAREJO)
    logger.info("Carregando dim_produto (ALIMENTO_VAREJO)...")
    df_prod = await _fetch_df(conn, """
        SELECT id_produto, nome_produto, classificao_produto, categoria_b2c
        FROM staging.dim_produto
        WHERE categoria_b2c = 'ALIMENTO_VAREJO'
           OR categoria_b2c IS NULL
    """)
    logger.info("  → %d produtos carregados", df_prod.height)

    # 3. Carregar fact_precos_mensais (anos base: 2024, 2025, 2026)
    #    Filtra apenas ALIMENTO_VAREJO para consistência com a MV
    logger.info("Carregando fact_precos_mensais (2024-2026 + ALIMENTO_VAREJO)...")
    df_fact = await _fetch_df(conn, """
        SELECT f.id_produto, f.id_localidade, f.ano, f.mes, f.preco_medio
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_produto p ON p.id_produto = f.id_produto
        WHERE f.ano IN (2024, 2025, 2026)
          AND f.preco_medio IS NOT NULL AND f.preco_medio > 0
          AND (p.categoria_b2c = 'ALIMENTO_VAREJO' OR p.categoria_b2c IS NULL)
    """)
    logger.info("  → %d registros de preço carregados", df_fact.height)

    # 4. Estatísticas de cobertura
    anos = df_fact.select("ano").unique().sort("ano").to_series().to_list()
    produtos_unicos = df_fact.select("id_produto").n_unique()
    ufs = df_local.select("uf").unique().sort("uf").to_series().to_list()
    meta["anos"] = anos
    meta["produtos_unicos"] = produtos_unicos
    meta["ufs"] = len(ufs)
    meta["ufs_lista"] = ufs

    await conn.close()
    logger.info("Conexão fechada.")

    return df_fact, df_prod, df_local, meta


# ═══════════════════════════════════════════════════════════════════════════
# RELATÓRIO
# ═══════════════════════════════════════════════════════════════════════════


def _gerar_relatorio(
    df_fact: pl.DataFrame,
    df_prod: pl.DataFrame,
    df_local: pl.DataFrame,
    meta: dict,
    projecoes: pl.DataFrame,
    engine: SanduicheSazonalEngine,
):
    print()
    print("=" * 85)
    print("  🥪  SANDUÍCHE SAZONAL — DRY-RUN CONTRA DADOS REAIS")
    print("=" * 85)
    print(f"  Banco:          {DATABASE_URL.split('@')[0].split('://')[0]}://***@{DATABASE_URL.split('@')[1] if '@' in DATABASE_URL else 'local'}")
    print(f"  Versão:         {meta.get('versao', 'N/A')}")
    print(f"  Anos na base:   {meta.get('anos', [])}")
    print(f"  Produtos únicos: {meta.get('produtos_unicos', 0)}")
    print(f"  UFs na base:    {meta.get('ufs', 0)} ({', '.join(meta.get('ufs_lista', []))})")
    print(f"  Linhas no fact: {df_fact.height:,}")
    print(f"  Mês atual:      {engine._mes_atual} (Julho/2026)")
    print(f"  Meses alvo:     {engine._mes_atual + 1} a 12 (Ago-Dez 2026)")
    print("=" * 85)

    if projecoes.height == 0:
        print("\n  ❌ NENHUMA PROJEÇÃO GERADA.")
        print("     Verifique se há dados de 2024-2025 no banco.")
        return

    # ── Tabela Resumo ──
    resumo = engine.resumo_uf_produto(projecoes)
    print(f"\n  📊  {projecoes.height} PROJEÇÕES GERADAS")
    print(f"      {resumo.select('uf').n_unique()} UFs | {resumo.select('nome_produto').n_unique()} produtos")
    print()

    # ── Totais por nível de fallback ──
    print("  ┌─────────────────────────────────────────────────────────────────┐")
    print("  │ DISTRIBUIÇÃO POR NÍVEL DE FALLBACK                              │")
    print("  ├─────────────────────────────────────────────────────────────────┤")
    for nivel in sorted(projecoes["nivel_fallback"].unique().to_list()):
        qtd = projecoes.filter(pl.col("nivel_fallback") == nivel).height
        pct = qtd / projecoes.height * 100
        if nivel == 1:
            desc = "Mesmo (prod, loc, mês) → confiança alta"
        elif nivel == 2:
            desc = "Mesmo (prod, loc) qq mês → confiança média"
        elif nivel == 3:
            desc = "Mesma UF (não cruza!)     → confiança baixa"
        elif nivel == 4:
            desc = "Fallback global do produto → confiança muito baixa"
        else:
            desc = "Sem dados → não projetado"
        print(f"  │ Nível {nivel} ({pct:5.1f}%) {desc:<44s} │")
    print("  └─────────────────────────────────────────────────────────────────┘")
    print()

    # ── Por UF ──
    print("  ┌─────────────────────────────────────────────────────────────────┐")
    print("  │ PROJEÇÕES POR UF                                                │")
    print("  ├──────┬──────────┬──────────┬──────────┬──────────┬──────────────┤")
    print("  │  UF  │ Produtos │  Média   │  Mínimo  │  Máximo  │ Confiança    │")
    print("  ├──────┼──────────┼──────────┼──────────┼──────────┼──────────────┤")
    for uf in sorted(resumo["uf"].unique().to_list()):
        grp = resumo.filter(pl.col("uf") == uf)
        prods = grp.select("nome_produto").n_unique()
        media = grp.select(pl.col("preco_projetado").mean()).item()
        minimo = grp.select(pl.col("preco_projetado").min()).item()
        maximo = grp.select(pl.col("preco_projetado").max()).item()
        conf = grp.select(pl.col("confianca").mean()).item()
        print(f"  │ {uf:<4s} │ {prods:>6d}  │ R${media:>6.2f} │ R${minimo:>6.2f} │ R${maximo:>6.2f} │ {conf:>5.1f}%      │")
    print("  ├──────┴──────────┴──────────┴──────────┴──────────┴──────────────┤")
    print()

    # ── Top 20 produtos mais projetados (por volume de projeções) ──
    print("  │ TOP 20 PRODUTOS COM MAIS PROJEÇÕES                             │")
    print("  ├──────┬──────────────────────────────────┬──────────┬───────────┤")
    print("  │  UF  │ Produto                          │ Projeções│ Conf. mé │")
    print("  ├──────┼──────────────────────────────────┼──────────┼───────────┤")
    top_prod = (
        resumo
        .group_by(["uf", "nome_produto"])
        .agg([pl.len().alias("qtd"), pl.col("confianca").mean().alias("conf_media")])
        .sort("qtd", descending=True)
        .head(20)
    )
    for row in top_prod.iter_rows(named=True):
        nome = row["nome_produto"][:32]
        print(f"  │ {row['uf']:<4s} │ {nome:<32s} │ {row['qtd']:>7d}  │ {row['conf_media']:>5.1f}%   │")
    print("  └──────┴──────────────────────────────────┴──────────┴───────────┘")
    print()

    # ── Amostra: 10 linhas detalhadas ──
    print("  ┌─────────────────────────────────────────────────────────────────┐")
    print("  │ AMOSTRA (10 primeiras projeções detalhadas)                     │")
    print("  ├──────┬──────────────────────────────────┬────┬────────┬───────┤")
    print("  │  UF  │ Produto                          │ Mês│ Projet │ Ref.  │")
    print("  ├──────┼──────────────────────────────────┼────┼────────┼───────┤")
    for row in resumo.head(10).iter_rows(named=True):
        nome = row["nome_produto"][:32]
        print(f"  │ {row['uf']:<4s} │ {nome:<32s} │ {row['mes']:>2d}  │ R${row['preco_projetado']:>5.2f} │ R${row['preco_referencia']:>5.2f} │")
    print("  └──────┴──────────────────────────────────┴────┴────────┴───────┘")
    print()

    # ── Gaps atuais (2026 real × projetado para meses passados) ──
    print("  ┌─────────────────────────────────────────────────────────────────┐")
    print("  │ GAPS EM 2026 (Meses PASSADOS sem dado real)                     │")
    print("  ├─────────────────────────────────────────────────────────────────┤")
    df_2026_real = df_fact.filter(
        (pl.col("ano") == 2026) & pl.col("preco_medio").is_not_null() & (pl.col("preco_medio") > 0)
    )
    for mes in range(1, engine._mes_atual + 1):
        presentes = df_2026_real.filter(pl.col("mes") == mes).select("id_produto").n_unique()
        total = df_fact.filter(
            pl.col("ano").is_in([2024, 2025])
        ).select("id_produto").n_unique()
        pct = presentes / total * 100 if total > 0 else 0
        barra = "█" * int(pct / 5) + "░" * (20 - int(pct / 5))
        print(f"  │ {mes:>2d}/{2026}  {barra}  {presentes:>4d}/{total:<4d} ({pct:>5.1f}%)      │")
    print("  └─────────────────────────────────────────────────────────────────┘")
    print()

    print("=" * 85)
    print("  ✅ DRY-RUN CONCLUÍDO — NADA FOI ESCRITO NO BANCO.")
    print("=" * 85)


# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════


async def main():
    hoje = datetime.now()
    mes_atual = hoje.month  # 7 para Julho

    # 1. Carregar dados do banco
    df_fact, df_prod, df_local, meta = await _carregar_dados(DATABASE_URL)

    # 2. Criar engine
    engine = SanduicheSazonalEngine(
        df_fact=df_fact,
        df_prod=df_prod,
        df_local=df_local,
        mes_atual=mes_atual,
        ano_alvo=2026,
    )

    # 3. Projetar meses futuros (Dry-Run)
    logger.info("Calculando projeções para Ago-Dez 2026...")
    projecoes = engine.projetar_meses_futuros()

    # 4. Relatório
    _gerar_relatorio(df_fact, df_prod, df_local, meta, projecoes, engine)


if __name__ == "__main__":
    asyncio.run(main())
