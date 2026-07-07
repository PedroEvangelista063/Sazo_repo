"""Execute migration using the existing pool from the backend app."""

import asyncio
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from backend.app.db.session import get_pool


async def main():
    pool = await get_pool()
    async with pool.acquire() as conn:
        sql = open(
            os.path.join(
                os.path.dirname(os.path.dirname(__file__)),
                "database",
                "05_recalibracao_baseline_2025.sql",
            ),
            encoding="utf-8",
        ).read()
        await conn.execute(sql)
        print("Migration executed successfully.")


if __name__ == "__main__":
    asyncio.run(main())
