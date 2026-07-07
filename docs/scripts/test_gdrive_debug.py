import asyncio
import logging
logging.basicConfig(level=logging.DEBUG)

async def test():
    from pipeline.scraper.adapters.google_drive_adapter import GoogleDriveAdapter
    adp = GoogleDriveAdapter(max_sheets=2)
    items = await adp.execute()
    print(f"Total: {len(items)} cotacoes")

asyncio.run(test())
