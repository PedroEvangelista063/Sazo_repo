import asyncio
from pipeline.scraper.adapters.google_drive_adapter import GoogleDriveAdapter

async def test():
    adp = GoogleDriveAdapter(max_sheets=3)
    items = await adp.execute()
    print(f"Total: {len(items)} cotacoes")
    for i, c in enumerate(items[:15]):
        print(f"  {c.produto_original}: R${c.preco_bruto:.2f}/{c.unidade_medida} ({c.ano}-{c.mes})")
    if items:
        ufs = set(c.uf for c in items)
        fontes = set(c.fonte for c in items)
        produtos = set(c.produto_original for c in items)
        print(f"UF: {ufs}")
        print(f"Fonte: {fontes}")
        print(f"Produtos unicos: {len(produtos)}")

asyncio.run(test())
