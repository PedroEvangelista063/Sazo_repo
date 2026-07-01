"""Database maintenance — the "Gari" (street cleaner) for quero_comprar.

Runs ops.sp_limpeza_diaria_scraper() for upsert + garbage collection,
then logs results. Idempotent — safe to run daily via cron or CI/CD.

Usage:
    python -m pipeline.db_maintenance
    python -m pipeline.db_maintenance --dry-run          # simulate only
    python -m pipeline.db_maintenance --retention 60     # keep 60 days
    python -m pipeline.db_maintenance --db-url postgresql://user:pass@host/db
"""

from __future__ import annotations

import argparse
import asyncio
import sys
import time

import asyncpg

if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())


async def main() -> None:
    parser = argparse.ArgumentParser(
        description="DB maintenance — garbage collector for scraper data"
    )
    parser.add_argument(
        "--db-url",
        default="postgresql://postgres:postgres@localhost:5432/quero_comprar",
        help="PostgreSQL connection URI",
    )
    parser.add_argument(
        "--retention",
        type=int,
        default=30,
        help="Days to keep raw scraper data (default: 30)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Simulate without modifying data",
    )
    args = parser.parse_args()

    conn = await asyncpg.connect(args.db_url)
    try:
        label = "DRY RUN" if args.dry_run else "EXECUTADO"
        print(f"[INFO] Iniciando limpeza diária ({label}) — retenção: {args.retention}d")

        t0 = time.monotonic()

        # Call the stored procedure
        async with conn.transaction():
            result = await conn.execute(
                "CALL ops.sp_limpeza_diaria_scraper($1, $2)",
                args.retention,
                args.dry_run,
            )

        elapsed = time.monotonic() - t0

        # Gather final stats
        counts = await conn.fetchrow("""
            SELECT
                (SELECT count(*) FROM raw.scraper_data) AS raw_atual,
                (SELECT count(*) FROM staging.fact_precos_mensais) AS staging_atual,
                (SELECT count(*) FROM staging.precos_rejeitados) AS rejeitados
        """)

        print(f"[INFO] Limpeza diária concluída em {elapsed:.2f}s")
        print(f"  Raw atual        : {counts['raw_atual']}")
        print(f"  Staging atual    : {counts['staging_atual']}")
        print(f"  Rejeitados       : {counts['rejeitados']}")
        print("[INFO] Status: OK")

    except asyncpg.PostgresError as e:
        print(f"[ERROR] Falha na limpeza diária: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"[ERROR] Erro inesperado: {e}", file=sys.stderr)
        sys.exit(2)
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
