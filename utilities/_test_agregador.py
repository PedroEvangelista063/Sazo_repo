"""Test aggregator portals for CEASA prices."""
import asyncio
import httpx
from bs4 import BeautifulSoup
import re

async def test():
    urls = [
        ("HF Brasil", "https://www.hfbrasil.org.br/br/estatistica/tomate.aspx"),
        ("Noticias Agricolas - Legumes", "https://www.noticiasagricolas.com.br/cotacoes/legumes"),
        ("Noticias Agricolas - Frutas", "https://www.noticiasagricolas.com.br/cotacoes/frutas"),
        ("Noticias Agricolas - Verduras", "https://www.noticiasagricolas.com.br/cotacoes/verduras"),
        ("Noticias Agricolas - CEASA", "https://www.noticiasagricolas.com.br/cotacoes/ceasa"),
    ]
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
        "Accept-Language": "pt-BR,pt;q=0.9",
    }
    async with httpx.AsyncClient(headers=headers, follow_redirects=True, timeout=15) as client:
        for name, url in urls:
            print(f"\n=== {name} ===")
            print(f"URL: {url}")
            try:
                r = await client.get(url)
                soup = BeautifulSoup(r.text, "lxml")
                title = soup.find("title")
                print(f"Status: {r.status_code}, Title: {title.text[:100] if title else 'N/A'}")

                tables = soup.find_all("table")
                print(f"Tables: {len(tables)}")
                for i, table in enumerate(tables):
                    rows = table.find_all("tr")
                    if not rows:
                        continue
                    header = " ".join(c.get_text(strip=True).lower() for c in rows[0].find_all(["th", "td"]))
                    if any(k in header for k in ("produto", "preco", "cotacao", "ceasa", "regiao", "unidade")):
                        print(f"  Table {i}: header='{header[:100]}' rows={len(rows)}")
                        for j, row in enumerate(rows[:6]):
                            cells = [c.get_text(strip=True) for c in row.find_all(["td", "th"])]
                            print(f"    [{j}] {cells}")
                        if len(rows) > 6:
                            print(f"    ... ({len(rows)-6} more)")
            except Exception as e:
                print(f"ERROR: {e}")

asyncio.run(test())
