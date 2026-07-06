#!/usr/bin/env python3
"""Motor de Previsão ML — Holt-Wings para tendência de preços.

Conecta no PostgreSQL, treina modelos de Exponential Smoothing para cada
par (id_produto, id_localidade) com >= 24 meses de histórico, e persiste
a tendência (QUEDA / ALTA / ESTAVEL) na última linha da mart.

Uso:
    python pipeline/ml_forecast_engine.py
    python pipeline/ml_forecast_engine.py --min-months 36
    python pipeline/ml_forecast_engine.py --dry-run
    python pipeline/ml_forecast_engine.py --uf SP
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import time
import warnings
from pathlib import Path
from typing import Any

import numpy as np

warnings.filterwarnings("ignore", category=UserWarning, module="statsmodels")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("ml_forecast")

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DOT_ENV = PROJECT_ROOT / ".env"
LIMIAR_VARIACAO = 0.05  # 5%

# ── helpers ─────────────────────────────────────────────────────────────────


def _pg_url() -> str:
    url = os.environ.get("DATABASE_URL")
    if url:
        return url
    if DOT_ENV.exists():
        for line in DOT_ENV.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("DATABASE_URL="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    print("ERROR: DATABASE_URL nao encontrada.")
    sys.exit(1)


def _classificar_tendencia(preco_atual: float, preco_previsto: float) -> str | None:
    if preco_atual <= 0 or preco_previsto <= 0:
        return None
    variacao = (preco_previsto - preco_atual) / preco_atual
    if variacao < -LIMIAR_VARIACAO:
        return "QUEDA"
    if variacao > LIMIAR_VARIACAO:
        return "ALTA"
    return "ESTAVEL"


# ── fetch ───────────────────────────────────────────────────────────────────


async def _buscar_series(
    conexao: Any,
    uf: str | None = None,
    meses_min: int = 24,
) -> list[dict[str, Any]]:
    """Retorna [(id_produto, id_localidade, precos[], meses[]), ...]."""
    params: list[Any] = [meses_min]
    where_uf = ""
    if uf:
        where_uf = f"AND l.uf = ${len(params) + 1}"
        params.append(uf.upper())

    rows = await conexao.fetch(
        f"""
        SELECT
            f.id_produto,
            f.id_localidade,
            array_agg(COALESCE(f.preco_curado, f.preco_medio)::numeric::float8 ORDER BY f.ano, f.mes) AS precos,
            array_agg((f.ano::TEXT || '-' || LPAD(f.mes::TEXT, 2, '0')) ORDER BY f.ano, f.mes) AS meses
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_produto p ON p.id_produto = f.id_produto
                                   AND p.categoria_b2c = 'ALIMENTO_VAREJO'
        JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
        WHERE COALESCE(f.preco_curado, f.preco_medio) > 0
          AND f.ano >= 2020
          {where_uf}
        GROUP BY f.id_produto, f.id_localidade
        HAVING COUNT(*) >= $1
        """,
        *params,
    )
    logger.info(
        "Buscadas %d series com >= %d meses%s",
        len(rows), meses_min, f" (UF={uf.upper()})" if uf else "",
    )
    return [dict(r) for r in rows]


# ── treino ──────────────────────────────────────────────────────────────────


def _prever(precos: list[float], meses_min: int = 24) -> tuple[float | None, str | None]:
    """Treina Holt-Winters e retorna (preco_previsto_T1, erro)."""
    y = np.array(precos, dtype=float)
    n = len(y)

    if n < max(12, meses_min) or np.std(y) < 1e-9:
        return None, "std_zero"

    from statsmodels.tsa.holtwinters import ExponentialSmoothing

    for seasonal in (12, 6, 4, None):
        if seasonal and n < seasonal * 2:
            continue
        for init in ("estimated", "heuristic", "legacy-heuristic"):
            try:
                model = ExponentialSmoothing(
                    y,
                    trend="add",
                    seasonal="add" if seasonal else None,
                    seasonal_periods=seasonal,
                    initialization_method=init,
                )
                fit = model.fit(remove_bias=True, use_brute=False)
                forecast = fit.forecast(steps=2)
                return float(forecast[0]), None
            except Exception as exc:
                if n >= 24:
                    logger.debug("fit n=%d seasonal=%s init=%s: %s", n, seasonal, init, exc)
                continue

    return None, "fit_failed"


# ── persistência ────────────────────────────────────────────────────────────


async def _persistir_tendencias(
    conexao: Any,
    resultados: list[dict[str, Any]],
    batch_size: int = 500,
) -> int:
    """Faz UPDATE na última linha (mais recente) de cada par na mart."""
    atualizados = 0
    for i in range(0, len(resultados), batch_size):
        batch = resultados[i : i + batch_size]
        for r in batch:
            if r["tendencia"] is None:
                continue
            await conexao.execute(
                """
                UPDATE mart.sazonalidade_produto
                SET tendencia_futura = $1
                WHERE id_sazonalidade = (
                    SELECT id_sazonalidade
                    FROM mart.sazonalidade_produto s2
                    WHERE s2.id_produto = $2
                      AND s2.id_localidade = $3
                    ORDER BY s2.data_referencia_atual DESC
                    LIMIT 1
                )
                """,
                r["tendencia"],
                r["id_produto"],
                r["id_localidade"],
            )
        atualizados += len([r for r in batch if r["tendencia"] is not None])
        if (i // batch_size) % 5 == 0 and i > 0:
            logger.info("  %d / %d atualizados...", atualizados, len(resultados))
    return atualizados


# ── main ────────────────────────────────────────────────────────────────────


async def _main() -> None:
    import asyncpg

    parser = argparse.ArgumentParser(description="ML Forecast Engine — Holt-Winters")
    parser.add_argument("--min-months", type=int, default=24, help="Meses minimos para treinar (default=24)")
    parser.add_argument("--dry-run", action="store_true", help="So calcula, nao persiste")
    parser.add_argument("--uf", default=None, help="Filtrar por UF (ex: SP)")
    args = parser.parse_args()

    logger.info("=" * 60)
    logger.info("  ML FORECAST ENGINE")
    logger.info("  Min months: %d | Dry-run: %s | UF: %s",
                args.min_months, args.dry_run, args.uf or "TODAS")
    logger.info("=" * 60)

    conn = await asyncpg.connect(_pg_url())
    try:
        series = await _buscar_series(conn, uf=args.uf, meses_min=args.min_months)
        if not series:
            logger.warning("Nenhuma serie atende ao criterio de meses minimos.")
            return

        logger.info("Treinando modelos...")
        t0 = time.perf_counter()
        resultados: list[dict[str, Any]] = []
        ok = 0
        falhas = 0
        for s in series:
            preco_previsto, erro = _prever(s["precos"], meses_min=args.min_months)
            if preco_previsto is not None and s["precos"]:
                preco_atual = s["precos"][-1]
                tendencia = _classificar_tendencia(preco_atual, preco_previsto)
                resultados.append({
                    "id_produto": s["id_produto"],
                    "id_localidade": s["id_localidade"],
                    "tendencia": tendencia,
                })
                ok += 1
            else:
                falhas += 1
                resultados.append({
                    "id_produto": s["id_produto"],
                    "id_localidade": s["id_localidade"],
                    "tendencia": None,
                })

        elapsed = time.perf_counter() - t0
        logger.info(
            "Modelos: %d OK | %d falhas (min meses) | %.1fs",
            ok, falhas, elapsed,
        )

        # distribuição das tendências
        from collections import Counter
        contagem = Counter(r["tendencia"] for r in resultados if r["tendencia"] is not None)
        total_tendencia = sum(contagem.values())
        logger.info("Distribuicao das tendencias (%d):", total_tendencia)
        for label in ("QUEDA", "ESTAVEL", "ALTA"):
            qtd = contagem.get(label, 0)
            logger.info("  %s: %d (%.1f%%)", label, qtd, qtd / total_tendencia * 100 if total_tendencia else 0)

        if args.dry_run:
            logger.info("Dry-run: nada foi persistido.")
        else:
            logger.info("Persistindo tendencias na mart...")
            t1 = time.perf_counter()
            atualizados = await _persistir_tendencias(conn, resultados)
            logger.info("Persistidos %d registros em %.1fs", atualizados, time.perf_counter() - t1)

    finally:
        await conn.close()

    logger.info("ML Forecast Engine concluido.")


def main() -> None:
    import asyncio

    if sys.platform == "win32":
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    asyncio.run(_main())


if __name__ == "__main__":
    main()
