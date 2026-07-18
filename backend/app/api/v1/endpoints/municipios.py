from fastapi import APIRouter, Query
from backend.app.schemas.responses import MunicipioListResponse
from backend.app.db.session import fetch

router = APIRouter(prefix="/municipios", tags=["Municipios"])


@router.get("", response_model=MunicipioListResponse)
async def listar_municipios(
    uf: str = Query(min_length=2, max_length=2, description="UF (BR-2)"),
):
    rows = await fetch(
        "SELECT municipio FROM mart.vw_municipios WHERE uf = $1 ORDER BY municipio",
        uf.upper(),
    )

    items = [r["municipio"] for r in rows]
    return MunicipioListResponse(data=items, total=len(items))
