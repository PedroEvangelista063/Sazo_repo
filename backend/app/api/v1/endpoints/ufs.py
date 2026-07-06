from fastapi import APIRouter
from backend.app.db.session import fetch

router = APIRouter(prefix="/ufs", tags=["UFs"])


@router.get("")
async def listar_ufs():
    rows = await fetch(
        """
        SELECT DISTINCT v.uf
        FROM mart.vw_api_produtos_sazonalidade v
        WHERE v.uf IS NOT NULL AND v.uf != ''
        ORDER BY v.uf
        """
    )
    return {"data": [r["uf"] for r in rows], "total": len(rows)}