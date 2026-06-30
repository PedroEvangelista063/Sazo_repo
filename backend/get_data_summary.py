"""Ad-hoc: data health summary for quero_comprar database.

Usage:
    python backend/get_data_summary.py
    python backend/get_data_summary.py --db-url postgresql://user:pass@host/db
    python backend/get_data_summary.py --verbose
"""
from __future__ import annotations

import argparse
import asyncio
import sys

import asyncpg

if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())


async def _fetch(conn: asyncpg.Connection, label: str, query: str, *args: object) -> None:
    try:
        row = await conn.fetchrow(query, *args)
        if row:
            print(f"  {label}: {row[0]}")
        else:
            print(f"  {label}: (no data)")
    except Exception as e:
        print(f"  {label}: ERROR — {e}")


async def main() -> None:
    parser = argparse.ArgumentParser(description="Data health summary for quero_comprar")
    parser.add_argument(
        "--db-url",
        default="postgresql://postgres:postgres@localhost:5432/quero_comprar",
        help="PostgreSQL connection URI",
    )
    parser.add_argument("--verbose", "-v", action="store_true", help="Show detailed counts")
    args = parser.parse_args()

    conn = await asyncpg.connect(args.db_url)
    try:
        print("=" * 60)
        print("  QUERO COMPRAR — Database Health Summary")
        print("=" * 60)

        # ── Schema overview ──────────────────────────────────────────
        print(f"\n{'=' * 60}")
        print("  SCHEMA OVERVIEW")
        print(f"{'=' * 60}")
        await _fetch(conn, "raw tables",
                      "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'raw'")
        await _fetch(conn, "staging tables",
                      "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'staging'")
        await _fetch(conn, "mart tables",
                      "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'mart'")
        await _fetch(conn, "ops tables",
                      "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'ops'")

        # ── Row counts ───────────────────────────────────────────────
        print(f"\n{'=' * 60}")
        print("  ROW COUNTS")
        print(f"{'=' * 60}")
        await _fetch(conn, "raw.precos_mensais_uf",
                      "SELECT count(*) FROM raw.precos_mensais_uf")
        await _fetch(conn, "raw.precos_mensais_municipio",
                      "SELECT count(*) FROM raw.precos_mensais_municipio")
        await _fetch(conn, "staging.fact_precos_mensais",
                      "SELECT count(*) FROM staging.fact_precos_mensais")
        await _fetch(conn, "staging.precos_rejeitados",
                      "SELECT count(*) FROM staging.precos_rejeitados")
        await _fetch(conn, "staging.dim_produto",
                      "SELECT count(*) FROM staging.dim_produto")
        await _fetch(conn, "staging.dim_localidade",
                      "SELECT count(*) FROM staging.dim_localidade")
        await _fetch(conn, "mart.sazonalidade_produto",
                      "SELECT count(*) FROM mart.sazonalidade_produto")

        # ── Seasonality distribution ─────────────────────────────────
        print(f"\n{'=' * 60}")
        print("  SEASONALITY DISTRIBUTION (mart.sazonalidade_produto)")
        print(f"{'=' * 60}")
        rows = await conn.fetch("""
            SELECT status_cor, count(*) as cnt
            FROM mart.sazonalidade_produto
            GROUP BY status_cor
            ORDER BY cnt DESC
        """)
        for r in rows:
            print(f"  {r['status_cor']:>16s}: {r['cnt']:>6d}")

        # ── Fallback usage ───────────────────────────────────────────
        fallback = await conn.fetchrow("""
            SELECT
                count(*) FILTER (WHERE usou_fallback_12m) as usando_fallback,
                count(*) FILTER (WHERE NOT usou_fallback_12m) as com_baseline_2025
            FROM mart.sazonalidade_produto
        """)
        if fallback:
            print(f"\n  Baseline 2025     : {fallback['com_baseline_2025']}")
            print(f"  Fallback 12m       : {fallback['usando_fallback']}")

        # ── Coverage ─────────────────────────────────────────────────
        print(f"\n{'=' * 60}")
        print("  COVERAGE")
        print(f"{'=' * 60}")
        await _fetch(conn, "UF with data",
                      "SELECT count(DISTINCT l.uf) FROM staging.fact_precos_mensais f JOIN staging.dim_localidade l ON f.id_localidade = l.id_localidade")
        await _fetch(conn, "Municipios with data",
                      "SELECT count(DISTINCT l.municipio_nome) FROM staging.fact_precos_mensais f JOIN staging.dim_localidade l ON f.id_localidade = l.id_localidade WHERE l.municipio_nome IS NOT NULL")
        total_mapeado = await conn.fetchval(
            "SELECT count(*) FROM staging.dim_produto WHERE status_fonte = 'MAPEADA'")
        total_cat = await conn.fetchval(
            "SELECT count(*) FROM staging.dim_produto WHERE categoria_b2c = 'ALIMENTO_VAREJO'")
        print(f"  Total MAPEADO (status_fonte): {total_mapeado}")
        print(f"  Total ALIMENTO_VAREJO (categoria_b2c): {total_cat}")
        await _fetch(conn, "Products (B2B/other)",
                      "SELECT count(*) FROM staging.dim_produto WHERE categoria_b2c != 'ALIMENTO_VAREJO' OR categoria_b2c IS NULL")

        # ── Monthly Coverage Matrix (MAPEADOS apenas) ──────────────────
        print(f"\n{'=' * 60}")
        print("  MONTHLY COVERAGE MATRIX  (status_fonte = MAPEADA)")
        print(f"{'=' * 60}")
        cov_rows = await conn.fetch("""
            SELECT
                f.ano,
                f.mes,
                count(DISTINCT f.id_produto) AS cnt
            FROM staging.fact_precos_mensais f
            JOIN staging.dim_produto p ON p.id_produto = f.id_produto
            WHERE p.status_fonte = 'MAPEADA'
            GROUP BY f.ano, f.mes
            ORDER BY f.ano, f.mes
        """)
        for r in cov_rows:
            pct = r['cnt'] / total_mapeado * 100
            print(f"  {r['ano']}-{r['mes']:02d}: {r['cnt']:>3d}/{total_mapeado} ({pct:5.1f}%)")

        # ── Orphan Products (MAPEADOS): have 2025 data but ZERO in 2026 ──
        print(f"\n{'=' * 60}")
        print("  TOP 20 ORPHAN PRODUCTS  (MAPEADOS — present in 2025, absent in 2026)")
        print(f"{'=' * 60}")
        orphan_rows = await conn.fetch("""
            WITH produtos_2025 AS (
                SELECT DISTINCT f.id_produto, p.nome_produto
                FROM staging.fact_precos_mensais f
                JOIN staging.dim_produto p ON p.id_produto = f.id_produto
                WHERE p.status_fonte = 'MAPEADA'
                  AND f.ano = 2025
            ),
            produtos_2026 AS (
                SELECT DISTINCT f.id_produto
                FROM staging.fact_precos_mensais f
                JOIN staging.dim_produto p ON p.id_produto = f.id_produto
                WHERE p.status_fonte = 'MAPEADA'
                  AND f.ano = 2026
            )
            SELECT p25.id_produto, p25.nome_produto
            FROM produtos_2025 p25
            LEFT JOIN produtos_2026 p26 ON p26.id_produto = p25.id_produto
            WHERE p26.id_produto IS NULL
            ORDER BY p25.nome_produto
            LIMIT 20
        """)
        if orphan_rows:
            for i, r in enumerate(orphan_rows, 1):
                print(f"  {i:2d}. id_produto={r['id_produto']:>4d}  {r['nome_produto']}")
        else:
            print("  (none — all 2025 MAPEADOS also appear in 2026)")

        # ── SEM_FONTE summary ─────────────────────────────────────────
        n_sem_fonte = await conn.fetchval(
            "SELECT count(*) FROM staging.dim_produto WHERE status_fonte = 'SEM_FONTE_MAPEDADA'")
        n_sf_2025 = await conn.fetchval("""
            SELECT count(DISTINCT f.id_produto)
            FROM staging.fact_precos_mensais f
            JOIN staging.dim_produto p ON p.id_produto = f.id_produto
            WHERE p.status_fonte = 'SEM_FONTE_MAPEDADA' AND f.ano = 2025
        """)
        n_sf_2026 = await conn.fetchval("""
            SELECT count(DISTINCT f.id_produto)
            FROM staging.fact_precos_mensais f
            JOIN staging.dim_produto p ON p.id_produto = f.id_produto
            WHERE p.status_fonte = 'SEM_FONTE_MAPEDADA' AND f.ano = 2026
        """)
        print(f"\n  SEM_FONTE_MAPEDADA (total): {n_sem_fonte}")
        print(f"  SEM_FONTE with 2025 data:    {n_sf_2025}")
        print(f"  SEM_FONTE with 2026 data:    {n_sf_2026}")

        # ── Data freshness ───────────────────────────────────────────
        print(f"\n{'=' * 60}")
        print("  DATA FRESHNESS")
        print(f"{'=' * 60}")
        await _fetch(conn, "Latest data (staging)",
                      "SELECT max(ano::text || '-' || lpad(mes::text, 2, '0')) FROM staging.fact_precos_mensais")
        await _fetch(conn, "Earliest data (staging)",
                      "SELECT min(ano::text || '-' || lpad(mes::text, 2, '0')) FROM staging.fact_precos_mensais")
        await _fetch(conn, "Latest sazonalidade calc",
                      "SELECT max(data_referencia_atual) FROM mart.sazonalidade_produto")

        # ── Anomalies / rejected ─────────────────────────────────────
        print(f"\n{'=' * 60}")
        print("  ANOMALIES / REJECTED")
        print(f"{'=' * 60}")
        await _fetch(conn, "Rows in precos_rejeitados",
                      "SELECT count(*) FROM staging.precos_rejeitados")
        if args.verbose:
            await _fetch(conn, "  >500% anomaly (rollback suspect)",
                          "SELECT count(*) FROM staging.precos_rejeitados WHERE motivo LIKE '%500%' OR motivo LIKE '%anomalia%'")

        # ── Top 10 locations by data volume ──────────────────────────
        print(f"\n{'=' * 60}")
        print("  TOP 10 LOCATIONS BY DATA VOLUME")
        print(f"{'=' * 60}")
        rows = await conn.fetch("""
            SELECT l.uf, l.municipio_nome, count(*) as cnt
            FROM staging.fact_precos_mensais f
            JOIN staging.dim_localidade l ON f.id_localidade = l.id_localidade
            GROUP BY l.uf, l.municipio_nome
            ORDER BY cnt DESC
            LIMIT 10
        """)
        for r in rows:
            print(f"  {r['uf']}  {r['municipio_nome'] or '(None)':>25s}  {r['cnt']:>6d} records")

        # ── Products with insufficient data ──────────────────────────
        print(f"\n{'=' * 60}")
        print("  PRODUCTS WITH INSUFFICIENT DATA")
        print(f"{'=' * 60}")
        await _fetch(conn, "INSUFICIENTE in mart",
                      "SELECT count(*) FROM mart.sazonalidade_produto WHERE status_cor = 'INSUFICIENTE'")

        # ── Audit log (if exists) ────────────────────────────────────
        try:
            await _fetch(conn, "Audit log entries",
                          "SELECT count(*) FROM ops.audit_logs")
        except Exception:
            print("  Audit log entries: (ops.audit_logs not found)")

        print(f"\n{'=' * 60}")
        print("  Done.")
        print(f"{'=' * 60}")

    except Exception as e:
        print(f"Fatal: {e}")
        sys.exit(1)
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
