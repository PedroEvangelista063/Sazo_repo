import asyncio
import importlib
import pipeline.scraper.adapters.google_drive_adapter as gda
importlib.reload(gda)

async def test():
    adp = gda.GoogleDriveAdapter(max_sheets=1)
    items = await adp.execute()
    print(f"\n=== RESULTADOS: {len(items)} cotacoes ===")
    for c in items[:5]:
        print(f"  {c.produto_original}: R${c.preco_bruto:.2f}/{c.unidade_medida} ({c.ano}-{c.mes})")

asyncio.run(test())
