"""Grant execute permissions on new function overloads."""
import asyncio
import asyncpg

SQL = """
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_por_mes(INTEGER, INTEGER, TEXT, INTEGER, INTEGER) TO role_api_reader;
GRANT EXECUTE ON FUNCTION mart.fn_br_nacional_snapshot(TEXT, INTEGER, INTEGER) TO role_api_reader;
GRANT EXECUTE ON FUNCTION mart.fn_regional_por_mes(TEXT[], INTEGER, INTEGER, INTEGER, TEXT, INTEGER, INTEGER) TO role_api_reader;
GRANT EXECUTE ON FUNCTION mart.fn_regional_snapshot(TEXT[], INTEGER, TEXT, INTEGER, INTEGER) TO role_api_reader;
"""

async def main():
    conn = await asyncpg.connect("postgresql://postgres:postgres@localhost:5432/quero_comprar")
    try:
        await conn.execute(SQL)
        print("Permissions granted OK")
    finally:
        await conn.close()

asyncio.run(main())
