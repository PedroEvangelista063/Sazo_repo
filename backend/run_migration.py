"""Execute migration 05_recalibracao_baseline_2025.sql on the target database."""

import asyncio
import asyncpg
from app.core.config import get_settings


async def main():
    settings = get_settings()
    db_url = settings.database_url_etl or settings.database_url
    conn = await asyncpg.connect(db_url)
    try:
        sql = open("database/05_recalibracao_baseline_2025.sql", encoding="utf-8").read()
        await conn.execute(sql)
        print("Migration executed successfully.")
    except Exception as e:
        print(f"Migration failed: {e}")
        raise
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
