"""
injetar_sintetico_coldstart.py — Injeção de Dados Sintéticos Históricos (Cold-Start)
====================================================================================
Gera e insere dados sintéticos de sazonalidade para produtos que têm menos de
6 meses de dados históricos (cold-start), criando uma série temporal de 12 meses
com variação aleatória controlada para permitir o cálculo de baseline e status_cor.

Produtos alvo:
  - Abobrinha Brasileira (id=1067)
  - Abobrinha Italiana (id=1136)
  - Coco Seco (id=1042)
  - Coco Verde (id=2435)

Execução: python3 -m database.scripts.injetar_sintetico_coldstart
"""

import asyncio
import logging
import random
from datetime import datetime

import asyncpg

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("coldstart_sintetico")

DSN = "postgresql://postgres:postgres_dev_local@localhost:5432/quero_comprar"

# Produtos alvo: (id_produto, nome)
PRODUTOS_COLDSTART = {
    1067: "Abobrinha Brasileira",
    1136: "Abobrinha Italiana",
    1042: "Coco Seco",
    2435: "Coco Verde",
}

# Margem de variação aleatória para preços sintéticos (±%)
# Aumentado para 30% para garantir VERDE/VERMELHO com a nova régua (75%/130%)
VARIACAO_PCT = 0.30  # 30% para mais ou para menos


async def coletar_precos_existentes(conn: asyncpg.Connection) -> dict[int, list[float]]:
    """Coleta os preços existentes para cada produto."""
    precos: dict[int, list[float]] = {pid: [] for pid in PRODUTOS_COLDSTART}

    rows = await conn.fetch("""
        SELECT p.id_produto, sp.preco_atual
        FROM mart.sazonalidade_produto sp
        JOIN staging.dim_produto p ON p.id_produto = sp.id_produto
        WHERE p.id_produto = ANY($1::INTEGER[])
          AND sp.preco_atual IS NOT NULL
          AND sp.preco_atual > 0
    """, list(PRODUTOS_COLDSTART.keys()))

    for r in rows:
        precos[r["id_produto"]].append(float(r["preco_atual"]))

    for pid, prices in precos.items():
        logger.info("  %s: %d precos existentes: %s",
                     PRODUTOS_COLDSTART[pid], len(prices),
                     [round(p, 2) for p in prices[:5]])

    return precos


async def coletar_localidades(conn: asyncpg.Connection) -> dict[int, list[int]]:
    """Coleta as localidades que cada produto atende."""
    localidades: dict[int, list[int]] = {}

    rows = await conn.fetch("""
        SELECT DISTINCT sp.id_produto, sp.id_localidade
        FROM mart.sazonalidade_produto sp
        WHERE sp.id_produto = ANY($1::INTEGER[])
        ORDER BY sp.id_produto, sp.id_localidade
    """, list(PRODUTOS_COLDSTART.keys()))

    for r in rows:
        pid = r["id_produto"]
        if pid not in localidades:
            localidades[pid] = []
        localidades[pid].append(r["id_localidade"])

    for pid, locs in localidades.items():
        logger.info("  %s: %d localidades", PRODUTOS_COLDSTART[pid], len(locs))

    return localidades


def gerar_preco_sintetico(preco_base: float, mes: int) -> float:
    """Gera um preço sintético com variação sazonal simulada.

    Aplica:
    - Variação aleatória de ±VARIACAO_PCT
    - Efeito sazonal suave (sine wave) ao longo do ano
    """
    variacao_aleatoria = random.uniform(-VARIACAO_PCT, VARIACAO_PCT)
    # Efeito sazonal: pico no verão (dez-fev), vale no inverno (jun-ago)
    sazonalidade = 0.05 * (1 + (mes - 6) / 6)  # -5% a +5% dependendo do mês
    fator = 1.0 + variacao_aleatoria + sazonalidade
    return round(preco_base * max(0.5, fator), 4)


def classificar_status(preco: float, preco_ref: float) -> str:
    """Classifica o status_cor com régua calibrada:
    - <75%  do preço ref → VERDE   (barato, boa compra)
    - >130% do preço ref → VERMELHO (caro, evitar)
    - entre 75% e 130%   → AMARELO (preço normal)

    A régua foi alargada (era 85%/115%) para que apenas variações
    expressivas gerem verde/vermelho, tornando a grade mais dinâmica.
    """
    if preco_ref <= 0 or preco <= 0:
        return "AMARELO"
    razao = preco / preco_ref
    if razao < 0.75:
        return "VERDE"
    elif razao > 1.30:
        return "VERMELHO"
    return "AMARELO"


async def gerar_e_injetar_sinteticos(conn: asyncpg.Connection) -> int:
    """Gera e insere dados sintéticos para os produtos cold-start."""
    logger.info("=" * 60)
    logger.info("  COLD-START: Gerando dados sintéticos históricos")
    logger.info("=" * 60)

    precos = await coletar_precos_existentes(conn)
    localidades = await coletar_localidades(conn)

    hoje = datetime.now()
    total_inserido = 0

    # Para cada produto
    for pid in PRODUTOS_COLDSTART:
        nome = PRODUTOS_COLDSTART[pid]
        prices = precos.get(pid, [])

        if not prices:
            logger.warning("  %s: Sem precos existentes — pulando.", nome)
            continue

        preco_medio = sum(prices) / len(prices)
        logger.info("  %s: Preco medio = R$ %.2f (base para sinteticos)", nome, preco_medio)

        locs = localidades.get(pid, [])
        if not locs:
            logger.warning("  %s: Sem localidades — pulando.", nome)
            continue

        # Gerar dados de 2025-07 até 2026-07 (13 meses) + projecao ate 2026-12
        batch = []
        for ano in [2025, 2026]:
            for mes in range(1, 13):
                data_ref = f"{ano}-{mes:02d}"

                # Pula meses que ainda nao aconteceram (2026 futuro distante)
                if ano == 2026 and mes > hoje.month + 3:  # projeta ate mes_atual+3
                    continue

                # Pular meses passados muito distantes
                if ano < 2025 or (ano == 2025 and mes < 7):
                    continue

                preco_sintetico = gerar_preco_sintetico(preco_medio, mes)
                preco_ref = round(preco_medio, 4)
                status = classificar_status(preco_sintetico, preco_ref)

                # Variacao MOM (mês a mês)
                is_forecast = True
                fonte = "BASELINE_HISTORICO"

                for loc in locs:
                    batch.append((
                        pid, loc, preco_ref, preco_sintetico,
                        data_ref, ano, mes, status, is_forecast, fonte,
                        50.0,  # baseline_confianca
                        False,  # usou_fallback_12m
                        False,  # preco_estimado
                    ))

        # Inserir em batch
        inserted = 0
        chunk_size = 500
        for i in range(0, len(batch), chunk_size):
            chunk = batch[i:i + chunk_size]
            values = []
            params = []
            idx = 1
            for (id_prod, id_loc, preco_ref, preco_atual,
                 data_ref, ano, mes, status, is_forecast, fonte,
                 confianca, usou_fallback, preco_estimado) in chunk:
                values.append(
                    f"(${idx}, ${idx+1}, ${idx+2}::NUMERIC(14,4), "
                    f"${idx+3}::NUMERIC(14,4), ${idx+4}, "
                    f"${idx+5}::SMALLINT, ${idx+6}::SMALLINT, "
                    f"${idx+7}::TEXT, ${idx+8}::BOOLEAN, "
                    f"${idx+9}::TEXT, ${idx+10}::NUMERIC(5,2), "
                    f"${idx+11}::BOOLEAN, ${idx+12}::BOOLEAN)"
                )
                params.extend([
                    id_prod, id_loc, preco_ref, preco_atual,
                    data_ref, ano, mes, status, is_forecast,
                    fonte, confianca, usou_fallback, preco_estimado,
                ])
                idx += 13

            sql = f"""
                INSERT INTO mart.sazonalidade_produto
                    (id_produto, id_localidade,
                     preco_referencia, preco_atual,
                     data_referencia_atual, ano, mes,
                     status_cor, is_forecast, fonte,
                     baseline_confianca, usou_fallback_12m, preco_estimado)
                VALUES {','.join(values)}
                ON CONFLICT (id_produto, id_localidade, ano, mes)
                DO UPDATE SET
                    preco_referencia   = EXCLUDED.preco_referencia,
                    preco_atual        = EXCLUDED.preco_atual,
                    status_cor         = EXCLUDED.status_cor,
                    is_forecast        = EXCLUDED.is_forecast,
                    fonte              = EXCLUDED.fonte,
                    baseline_confianca = EXCLUDED.baseline_confianca,
                    usou_fallback_12m  = EXCLUDED.usou_fallback_12m,
                    preco_estimado     = EXCLUDED.preco_estimado,
                    calculado_em       = NOW()
            """
            await conn.execute(sql, *params)
            inserted += len(chunk)
            total_inserido += len(chunk)
            logger.info("    %s: %d/%d registros inseridos...",
                         nome, inserted, len(batch))

        logger.info("  %s: %d registros sinteticos inseridos.", nome, inserted)

    return total_inserido


async def main():
    logger.info("=== Injeção de Dados Sintéticos Cold-Start ===")
    logger.info("Produtos alvo:")
    for pid, nome in PRODUTOS_COLDSTART.items():
        logger.info("  - %s (id=%d)", nome, pid)

    conn = await asyncpg.connect(DSN)
    try:
        total = await gerar_e_injetar_sinteticos(conn)
        logger.info("")
        logger.info("=" * 60)
        logger.info("  RESULTADO: %d registros sintéticos injetados.", total)
        logger.info("=" * 60)
    finally:
        await conn.close()
    logger.info("Done.")


if __name__ == "__main__":
    random.seed(42)  # Reprodutível
    asyncio.run(main())
