"""Probe discovered sources for actual parseable pricing data."""
import json, httpx, asyncio
from bs4 import BeautifulSoup

REPORT = json.load(open("logs/fontes_descobertas.json", "r", encoding="utf-8"))

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    "Accept-Language": "pt-BR,pt;q=0.9",
}

# Filter to only accessible sources with potential pricing
alvos = [
    {"nome": f["nome"], "uf": f["uf"], "url": f["url"]}
    for f in REPORT["fontes"]
    if f["status"] == "acessivel"
    and f["nome"] not in ("CEAGESP", "IEA", "SAA-SP", "SEAPA-MG", "SEAB-PR")
]

async def probe(client, alvo):
    try:
        r = await client.get(alvo["url"], timeout=15, follow_redirects=True)
        html = r.text.lower()
        soup = BeautifulSoup(r.text, "html.parser")
        tables = soup.find_all("table")
        # Check for pricing keywords + table
        keywords = ["preco", "cotacao", "produto", "hortifruti", "hortigranjeiro", "r$", "rs ", "kg"]
        has_price_keywords = any(k in html for k in keywords)
        has_tables = len(tables) > 0
        return {
            **alvo,
            "status_code": r.status_code,
            "final_url": str(r.url),
            "tables": len(tables),
            "has_price": has_price_keywords,
            "has_links": len(soup.find_all("a")) > 10,
            "score": (3 if has_price_keywords and has_tables else 2 if has_price_keywords else 1 if has_tables else 0),
            "snippet": html[:200].replace("\n", " ")[:120],
            "redirect": str(r.url) != alvo["url"],
        }
    except Exception as e:
        return {**alvo, "error": str(e)[:80], "score": 0}

async def main():
    async with httpx.AsyncClient(headers=HEADERS, timeout=15) as c:
        tasks = [probe(c, a) for a in alvos]
        sources = await asyncio.gather(*tasks)

    # Sort by score descending
    sources.sort(key=lambda x: x["score"], reverse=True)

    print(f"{'Score':>5} {'Nome':30s} {'UF':3s} {'URL':55s} {'Tabelas':>7} {'Preco':>5} {'Links':>5}")
    print("=" * 120)
    for s in sources:
        if s.get("error"):
            print(f"    0  {s['nome']:30s} {s['uf']:3s} {s['error']}")
        else:
            print(f"{s['score']:5d}  {s['nome']:30s} {s['uf']:3s} {s['final_url'][:54]:55s} {s['tables']:7d} {str(s['has_price']):>5} {s['has_links']!s:>5}")
            if s["score"] >= 2:
                print(f"       snippet: {s['snippet']}")
                print()

asyncio.run(main())
