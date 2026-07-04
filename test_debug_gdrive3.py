import asyncio
import httpx
import traceback
import re

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
            resp.raise_for_status()
            html = resp.text
            print(f"Status: {resp.status_code}, Length: {len(html)}")

            pattern = r'<a[^>]*href="(https://drive\.google\.com/drive/folders/[^"]+)"[^>]*>'
            links = []
            _RE_FILE_ID = re.compile(r"/folders/([a-zA-Z0-9_-]+)")
            for m in re.finditer(pattern, html):
                href = m.group(1)
                fid = _RE_FILE_ID.search(href)
                links.append({"url": href, "fid": fid.group(1) if fid else "?"})
            print(f"Links encontrados: {len(links)}")
            for l in links[:3]:
                print(f"  {l['url']} -> {l['fid']}")

    except Exception as e:
        print(f"Error: {type(e).__name__}: {e}")
        traceback.print_exc()

asyncio.run(test())
