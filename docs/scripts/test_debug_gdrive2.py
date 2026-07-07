import httpx
import asyncio
import traceback

async def test():
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/120.0.0.0 Safari/537.36"
        ),
    }
    try:
        async with httpx.AsyncClient(timeout=30.0, follow_redirects=True) as client:
            resp = await client.get(
                "https://ceasa.rs.gov.br/cotacoes-de-precos",
                headers=headers,
            )
            print(f"Status: {resp.status_code}")
            print(f"Length: {len(resp.text)}")
    except Exception as e:
        print(f"Error: {type(e).__name__}: {e}")
        traceback.print_exc()

asyncio.run(test())
