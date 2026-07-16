from fastapi import APIRouter
from backend.app.schemas.responses import CategoriaResponse, CategoriaListResponse
from backend.app.db.session import fetch
from backend.app.core.cache import cache, safe_set
from backend.app.core.config import get_settings
import hashlib

router = APIRouter(prefix="/categorias", tags=["Categorias"])


@router.get("", response_model=CategoriaListResponse)
async def listar_categorias():
    settings = get_settings()
    cache_key = hashlib.md5(b"categorias").hexdigest()

    cached = await cache.get(cache_key)
    if cached is not None:
        return CategoriaListResponse(**cached)

    rows = await fetch("""
        SELECT
            c.nome_categoria,
            c.descricao,
            COUNT(DISTINCT p.id_produto) AS total_produtos
        FROM staging.dim_categoria c
        LEFT JOIN staging.dim_produto p ON p.id_categoria = c.id_categoria
          AND p.categoria_b2c = 'ALIMENTO_VAREJO'
        GROUP BY c.id_categoria, c.nome_categoria, c.descricao
        ORDER BY c.nome_categoria
    """)

    CATEGORIA_ICONES = {
        "FRUTAS": "\U0001f34e",
        "LEGUMES": "\U0001f954",
        "VERDURAS": "\U0001f96c",
        "FLORES": "\U0001f33c",
        "PESCADOS": "\U0001f41f",
        "PROTEINAS": "\U0001f969",
        "CEREAIS_GRAOS": "\U0001f33e",
        "BEBIDAS": "\U0001f964",
        "ALIMENTO_VAREJO": "\U0001f372",
        "OUTROS": "\U0001f4e6",
    }

    items = [
        CategoriaResponse(
            nome=r["nome_categoria"],
            descricao=r.get("descricao"),
            total_produtos=r["total_produtos"],
            icone=CATEGORIA_ICONES.get(r["nome_categoria"]),
        )
        for r in rows
        if r["total_produtos"] > 0
    ]

    result = CategoriaListResponse(data=items, total=len(items))
    await safe_set(cache_key, result.model_dump(), settings.cache_ttl_seconds)
    return result
