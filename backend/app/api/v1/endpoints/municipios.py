from fastapi import APIRouter, Query
from backend.app.schemas.responses import MunicipioListResponse
from backend.app.db.session import fetch

router = APIRouter(prefix="/municipios", tags=["Municipios"])


@router.get("", response_model=MunicipioListResponse)
async def listar_municipios(
    uf: str = Query(min_length=2, max_length=2, description="UF (BR-2)"),
):
    rows = await fetch(
        """
        SELECT DISTINCT l.municipio_nome AS municipio
        FROM staging.dim_localidade l
        WHERE l.uf = $1
          AND l.municipio_nome IS NOT NULL
          AND l.municipio_nome != ''
        ORDER BY l.municipio_nome
        """,
        uf.upper(),
    )

    items = [r["municipio"] for r in rows]
    return MunicipioListResponse(data=items, total=len(items))
