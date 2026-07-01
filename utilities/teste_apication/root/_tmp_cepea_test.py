"""
TÍTULO: Teste de Coleta CEPEA
ESCOPO: Valida acesso HTTP e parser HTML dos indicadores CEPEA (boi, arroz, frango)
EXECUTA: Requisições HTTP para cepea.esalq.usp.br + BeautifulSoup para extrair tabelas
"""

import httpx
from bs4 import BeautifulSoup

headers = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    "Accept-Language": "pt-BR,pt;q=0.9",
}
urls = [
    "https://www.cepea.esalq.usp.br/br/indicador/boi-gordo.aspx",
    "https://www.cepea.esalq.usp.br/br/indicador/arroz.aspx",
    "https://www.cepea.esalq.usp.br/br/indicador/frango.aspx",
]
for url in urls:
    r = httpx.get(url, headers=headers, timeout=15, follow_redirects=True, verify=False)
    print(f"{url}: {r.status_code}")
    if r.status_code == 200:
        soup = BeautifulSoup(r.text, "html.parser")
        table = soup.find("table", id="imagenet-indicador1")
        if table:
            rows = table.find_all("tr")
            print(f"  Rows: {len(rows)}")
            for row in rows[:3]:
                cells = row.find_all(["td", "th"])
                print(f"  Cells: {[c.get_text(strip=True) for c in cells]}")
        else:
            print("  Table not found")
            tables = soup.find_all("table")
            print(f"  Total tables: {len(tables)}")
            for t in tables[:3]:
                tid = t.get("id", "")
                tcls = t.get("class", "")
                first_rows = t.find_all("tr")[:2]
                if first_rows:
                    print(f"  table id={tid} class={tcls}")
                    for row in first_rows:
                        cells = row.find_all(["td", "th"])
                        print(f"    {[c.get_text(strip=True) for c in cells]}")
    print()
