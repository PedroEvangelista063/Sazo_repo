import re
import httpx

resp = httpx.get(
    "https://ceasa.rs.gov.br/cotacoes-de-precos",
    timeout=15.0,
    follow_redirects=True,
    headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
)
html = resp.text
print(f"Status: {resp.status_code}, Length: {len(html)}")

pattern = r'<a[^>]*href="(https://drive\.google\.com/drive/folders/[^"]+)"[^>]*>'
matches = list(re.finditer(pattern, html))
print(f"Regex matches: {len(matches)}")
for m in matches[:5]:
    print(f"  href={m.group(1)} at pos={m.start()}")

# Try case insensitive
matches2 = list(re.finditer(pattern, html, re.IGNORECASE))
print(f"Case-insensitive matches: {len(matches2)}")

# Look at what links exist near drive.google
for m in re.finditer(r'drive\.google\.com', html):
    start = max(0, m.start() - 200)
    end = min(len(html), m.end() + 200)
    snippet = html[start:end]
    a_match = re.search(r'href="([^"]+)"', snippet)
    if a_match:
        print(f"  Link near drive.google: {a_match.group(1)}")
