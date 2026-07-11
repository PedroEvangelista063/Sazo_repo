"""
test_orchestrator_html.py — Teste controlado do parser HTML
===========================================================
Injeta um payload HTML com tabela de precos no raw.coleta_bruta,
roda o SortingEngine + ciclo medalhao, e verifica se os dados
aparecem em staging.fact_precos_mensais.
"""

from __future__ import annotations

import asyncio
import json
import logging
import sys
import time
import uuid

import asyncpg

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("test_html")

DSN = "postgresql://postgres:postgres@localhost:5432/quero_comprar"

HTML_TABELA = """
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>COTACOES CEAGESP</title></head>
<body>
<div class="content">
<h2>Cotacoes do Atacado</h2>
<table class="table table-striped">
<tr><th>Produto</th><th>Embalagem</th><th>Preco (R$)</th></tr>
<tr><td>ABACATE</td><td>Kg</td><td>R$ 5,50</td></tr>
<tr><td>BANANA NANICA</td><td>Kg</td><td>R$ 3,80</td></tr>
<tr><td>LARANJA PERA</td><td>Kg</td><td>R$ 2,10</td></tr>
<tr><td>MACA FUJI</td><td>Kg</td><td>R$ 8,40</td></tr>
<tr><td>TOMATE</td><td>Kg</td><td>R$ 6,20</td></tr>
<tr><td>CENOURA</td><td>Kg</td><td>R$ 3,90</td></tr>
<tr><td>BATATA</td><td>Kg</td><td>R$ 4,30</td></tr>
<tr><td>Cebola</td><td>Kg</td><td>R$ 2,80</td></tr>
</table>
</div>
</body></html>
"""


async def main() -> int:
    t0 = time.perf_counter()
    logger.info("=" * 60)
    logger.info("TESTE CONTROLADO - Parser HTML no SortingEngine")
    logger.info("Injetando HTML com tabela de 8 produtos em raw.coleta_bruta")
    logger.info("=" * 60)

    pool = await asyncpg.create_pool(DSN, min_size=1, max_size=2)

    # Contagem antes
    raw_antes = await pool.fetchval("SELECT COUNT(*) FROM raw.coleta_bruta") or 0
    stage_antes = await pool.fetchval("SELECT COUNT(*) FROM staging.fact_precos_mensais") or 0
    logger.info("Antes: raw.coleta_bruta=%d | staging.fact=%d", raw_antes, stage_antes)

    # 1. Injetar HTML
    raw_id = uuid.uuid4()
    payload_dict = {"body": HTML_TABELA}
    payload_json = json.dumps(payload_dict, ensure_ascii=False)
    async with pool.acquire() as conn:
        await conn.execute(
            """
            INSERT INTO raw.coleta_bruta (id, fonte_id, payload_bruto, competencia_alvo)
            VALUES ($1, 'CEAGESP-TESTE', $2::jsonb, '2026-06')
            """,
            raw_id,
            payload_json,
        )
    logger.info("[ETAPA 1] HTML injetado em raw.coleta_bruta (id=%s)", raw_id)
    # Debug: ler de volta para ver o tipo
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT payload_bruto, pg_typeof(payload_bruto) FROM raw.coleta_bruta WHERE id = $1", raw_id)
    logger.info("[DEBUG] payload_bruto type=%s | value=%s", type(row["payload_bruto"]), repr(row["payload_bruto"])[:200])

    # 2. Rodar ciclo medalhao
    from pipeline.scraper.persistence import executar_ciclo_medalhao

    logger.info("[ETAPA 2] Executando ciclo medalhao...")
    try:
        await asyncio.wait_for(executar_ciclo_medalhao(pool), timeout=15)
        logger.info("[ETAPA 2] Ciclo medalhao finalizado sem erros")
    except Exception as e:
        logger.error("Falha no ciclo medalhao: %s", e)
        await pool.close()
        return 1

    # 3. Verificar
    raw_depois = await pool.fetchval("SELECT COUNT(*) FROM raw.coleta_bruta") or 0
    stage_depois = await pool.fetchval("SELECT COUNT(*) FROM staging.fact_precos_mensais") or 0
    processados = await pool.fetchval("SELECT COUNT(*) FROM raw.coleta_bruta WHERE processado = TRUE") or 0
    rejeitados = await pool.fetchval("SELECT COUNT(*) FROM ops.quarentena_coleta") or 0

    logger.info("Depois: raw.coleta_bruta=%d | processados=%d | rejeitados=%d | staging.fact=%d",
                raw_depois, processados, rejeitados, stage_depois)

    # Mostrar produtos inseridos na staging
    print()
    print("-- Produtos em staging.fact_precos_mensais (novos) --")
    async with pool.acquire() as conn2:
        rows = await conn2.fetch(
            """
            SELECT p.nome_produto, l.uf, f.ano, f.mes, f.preco_medio
            FROM staging.fact_precos_mensais f
            JOIN staging.dim_produto p ON p.id_produto = f.id_produto
            JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
            ORDER BY f.loaded_at DESC
            LIMIT 15
            """
        )

    if rows:
        for r in rows:
            print(f"  {r['nome_produto']:25s} | {r['uf']} | {r['ano']}-{r['mes']:02d} | R$ {float(r['preco_medio']):.2f}")
    else:
        print("  (nenhum)")

    print()

    # Verificacao
    novo_fact = stage_depois - stage_antes
    if novo_fact > 0:
        logger.info("RESULTADO: SUCESSO - %d registro(s) novo(s) em staging.fact_precos_mensais", novo_fact)
        logger.info("Parser HTML funcionou: HTML com tabela -> produto + preco extraidos")
    elif processados > 0 and novo_fact == 0:
        logger.warning("RESULTADO: PARCIAL - %d registros processados mas 0 em staging", processados)
    else:
        logger.error("RESULTADO: FALHA - nenhum registro processado")

    logger.info("Tempo total: %.1fs", time.perf_counter() - t0)
    await pool.close()
    return 0


if __name__ == "__main__":
    exit_code = asyncio.run(main())
    sys.exit(exit_code)
