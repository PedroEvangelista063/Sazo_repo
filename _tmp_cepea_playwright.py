import asyncio
from playwright.async_api import async_playwright

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context(
            user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            locale="pt-BR",
        )
        page = await context.new_page()

        urls = [
            "https://www.cepea.esalq.usp.br/br/indicador/boi-gordo.aspx",
            "https://www.cepea.esalq.usp.br/br/indicador/arroz.aspx",
            "https://www.cepea.esalq.usp.br/br/indicador/frango.aspx",
        ]
        for url in urls:
            try:
                await page.goto(url, timeout=30000, wait_until="networkidle")
                # Extract text from the indicator table
                table = await page.query_selector("table#imagenet-indicador1")
                if table:
                    rows = await table.query_selector_all("tr")
                    for row in rows[:5]:
                        cells = await row.query_selector_all("td, th")
                        texts = [await cell.inner_text() for cell in cells]
                        print(f"  {url}: {texts}")
                else:
                    # Try finding any table
                    tables = await page.query_selector_all("table")
                    print(f"  {url}: no table found, {len(tables)} other tables")
                    for t in tables[:2]:
                        tid = await t.get_attribute("id")
                        tcls = await t.get_attribute("class")
                        rows = await t.query_selector_all("tr")
                        first_texts = []
                        for row in rows[:2]:
                            cells = await row.query_selector_all("td, th")
                            texts = [await cell.inner_text() for cell in cells]
                            first_texts.append(texts)
                        print(f"    table id={tid} class={tcls}: {first_texts}")
            except Exception as e:
                print(f"  {url}: ERROR {e}")
            print()

        await browser.close()

asyncio.run(main())
