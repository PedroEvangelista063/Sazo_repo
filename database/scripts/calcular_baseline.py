"""
calcular_baseline.py — Fase 2b: Cálculo do Baseline Histórico + Proxy Hierárquico
==================================================================================
Lê dados reais (is_forecast=false) do mart.sazonalidade_produto para
2024 e 2025. Para cada combinação (produto, localidade, mes):
  - Moda do status_cor → status_cor_mode
  - Confiança = (anos com dados / anos analisados) * 100

Cold-Start Proxy (Fase 2d):
  Produtos com baseline esparso (< PROXY_MIN_MESES meses preenchidos) recebem
  um baseline derivado do "Produto Pai" (raiz do nome). A sazonalidade de
  variedades segue o padrão da família — a proxy copia o shape do pai com
  confiança reduzida (penalidade PROXY_CONFIANCA_PENALTY).

  Linhagem: fonte='BASELINE_HIERARQUICO' para registros proxy.

Execução: python -m database.scripts.calcular_baseline
"""

import asyncio
import logging
import re
from collections import Counter, defaultdict

import asyncpg

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("calcular_baseline")

DSN = "postgresql://postgres:postgres_dev_local@localhost:5432/quero_comprar"

ANOS_ANALISE = [2024, 2025]

# ── Cold-Start Proxy thresholds ──────────────────────────────────────────
PROXY_MIN_MESES = 6        # se o produto tiver baseline em < 6 meses, entra na proxy
PROXY_CONFIANCA_PENALTY = 0.7  # confiança do pai * 0.7
PROXY_FONTE = "BASELINE_HIERARQUICO"


def _extrair_raiz(nome_produto: str) -> str:
    """Extrai a raiz do nome: 'Alface Mimosa' → 'ALFACE', 'Alface Crespa Hidropônica' → 'ALFACE'.

    Regras:
      1. Converte para upper
      2. Remove sufixos como 'hidropônica', 'importado', etc. se existirem
      3. Pega a primeira palavra como raiz
    """
    nome = nome_produto.upper().strip()
    # Remove sufixos de variedade conhecidos (qualquer posição)
    sufixos = {r'\bHIDROPONICA\b', r'\bHIDROPÔNICA\b', r'\bIMPORTADO\b',
               r'\bIMPORTADA\b', r'\bNACIONAL\b', r'\bCOMUM\b'}
    for s in sufixos:
        nome = re.sub(s, '', nome)
    # Primeira palavra isolada
    palavras = nome.split()
    if not palavras:
        return nome
    return palavras[0]


def _montar_proxy_cache(baseline_entries: list[dict]) -> dict[str, dict]:
    """Constrói cache de 'Produtos Pai': raiz → {mes: (status_cor_mode, confianca)}.

    Para cada produto no baseline, extrai a raiz e guarda a distribuição
    completa de 12 meses. Produtos com 12 meses são candidatos preferenciais a pai.
    """
    pai_raw: dict[str, dict[int, list[tuple[str, float]]]] = defaultdict(
        lambda: defaultdict(list)
    )
    nomes_por_raiz: dict[str, set[str]] = defaultdict(set)

    for entry in baseline_entries:
        raiz = _extrair_raiz(entry["nome_produto"])
        mes = entry["mes"]
        nomes_por_raiz[raiz].add(entry["nome_produto"])
        pai_raw[raiz][mes].append((entry["status_cor_mode"], entry["confianca"]))

    # Para cada raiz, calcular a moda do status_cor e confiança mediana por mês
    proxy_cache: dict[str, dict] = {}
    for raiz, meses_dict in pai_raw.items():
        shape: dict[int, dict] = {}
        for mes, values in meses_dict.items():
            status_list = [v[0] for v in values]
            conf_list = [v[1] for v in values]
            # Moda do status_cor
            mode_count = Counter(status_list).most_common(1)
            status_mode = mode_count[0][0] if mode_count else "AMARELO"
            # Confiança mediana
            conf_list.sort()
            median_conf = conf_list[len(conf_list) // 2]
            shape[mes] = {"status_cor_mode": status_mode, "confianca": median_conf}

        # Determinar se esta raiz é um pai confiável (≥ 8 meses cobertos)
        cobertura = len(shape)
        proxy_cache[raiz] = {
            "shape": shape,
            "cobertura": cobertura,
            "nomes": nomes_por_raiz[raiz],
            "is_confiavel": cobertura >= 8,
        }

    return proxy_cache


# ── fim cold-start helpers ──────────────────────────────────────────────


async def calcular_baseline(conn: asyncpg.Connection) -> int:
    logger.info("Lendo dados reais (is_forecast=false) de %s-%s...",
                ANOS_ANALISE[0], ANOS_ANALISE[-1])

    rows = await conn.fetch("""
        SELECT s.id_produto, s.id_localidade,
               EXTRACT(YEAR FROM TO_DATE(s.data_referencia_atual, 'YYYY-MM'))::INTEGER AS ano,
               EXTRACT(MONTH FROM TO_DATE(s.data_referencia_atual, 'YYYY-MM'))::INTEGER AS mes,
               s.status_cor
        FROM mart.sazonalidade_produto s
        WHERE NOT s.is_forecast
          AND s.data_referencia_atual >= '2024-01'
          AND s.data_referencia_atual <= '2025-12'
    """)
    logger.info("Total registros reais 2024-2025: %d", len(rows))

    if not rows:
        logger.warning("Nenhum dado real encontrado — execute backfill_2024 primeiro.")
        return 0

    # Agrupa por (id_produto, id_localidade, mes)
    groups: dict[tuple[int, int, int], list[str]] = {}
    anos_por_grupo: dict[tuple[int, int, int], set[int]] = {}

    for r in rows:
        key = (r["id_produto"], r["id_localidade"], r["mes"])
        if key not in groups:
            groups[key] = []
            anos_por_grupo[key] = set()
        groups[key].append(r["status_cor"])
        anos_por_grupo[key].add(r["ano"])

    logger.info("Combinações únicas (prod, loc, mes): %d", len(groups))

    # Limpa baseline anterior para este dataset
    await conn.execute("TRUNCATE mart.sazonalidade_baseline RESTART IDENTITY CASCADE")
    logger.info("Baseline anterior truncado.")

    batch = []
    for key, statuses in groups.items():
        id_prod, id_loc, mes = key
        anos_presentes = len(anos_por_grupo[key])
        confianca = round((anos_presentes / len(ANOS_ANALISE)) * 100, 2)

        mode_count = Counter(statuses).most_common(1)
        status_mode = mode_count[0][0] if mode_count else "AMARELO"

        batch.append((id_prod, id_loc, mes, status_mode, confianca))

    # Batch insert
    total = 0
    chunk_size = 500
    for i in range(0, len(batch), chunk_size):
        chunk = batch[i:i + chunk_size]
        values = []
        params = []
        idx = 1
        for id_prod, id_loc, mes, status_mode, confianca in chunk:
            values.append(f"(${idx}, ${idx+1}, ${idx+2}, ${idx+3}::TEXT, ${idx+4}::NUMERIC(5,2))")
            params.extend([id_prod, id_loc, mes, status_mode, confianca])
            idx += 5

        sql = f"""
            INSERT INTO mart.sazonalidade_baseline
                (id_produto, id_localidade, mes, status_cor_mode, confianca)
            VALUES {','.join(values)}
            ON CONFLICT (id_produto, id_localidade, mes)
            DO UPDATE SET
                status_cor_mode = EXCLUDED.status_cor_mode,
                confianca       = EXCLUDED.confianca,
                fonte           = 'BASELINE_HISTORICO',
                atualizado_em   = NOW()
        """
        await conn.execute(sql, *params)
        total += len(chunk)
        logger.info("  %d/%d linhas inseridas...", total, len(batch))

    logger.info("Baseline calculado: %d combinações inseridas.", total)

    # ── Fase 2d: Cold-Start Proxy Hierárquico ─────────────────────────
    logger.info("=" * 60)
    logger.info("  Fase 2d: Cold-Start Proxy Hierárquico")
    logger.info("=" * 60)

    # Carregar baseline com nomes dos produtos
    baseline_com_nome = await conn.fetch("""
        SELECT b.id_produto, b.id_localidade, b.mes,
               b.status_cor_mode, b.confianca,
               dp.nome_produto
        FROM mart.sazonalidade_baseline b
        JOIN staging.dim_produto dp ON dp.id_produto = b.id_produto
        WHERE dp.categoria_b2c = 'ALIMENTO_VAREJO'
    """)
    logger.info("Total registros no baseline com nome: %d", len(baseline_com_nome))

    if not baseline_com_nome:
        logger.warning("Baseline vazio — pulando proxy.")
        return total

    # Construir cache de proxies (agregação por raiz do nome)
    proxy_cache = _montar_proxy_cache([dict(r) for r in baseline_com_nome])

    # Identificar produtos com baseline esparso
    coverage: dict[int, dict] = {}  # id_produto -> {nome, meses_set, raiz}
    for r in baseline_com_nome:
        pid = r["id_produto"]
        if pid not in coverage:
            coverage[pid] = {
                "nome": r["nome_produto"],
                "meses": set(),
            }
        coverage[pid]["meses"].add(r["mes"])

    produtos_esparsos = [
        (pid, info) for pid, info in coverage.items()
        if len(info["meses"]) < PROXY_MIN_MESES
    ]
    logger.info(
        "Produtos com baseline esparso (< %d meses): %d",
        PROXY_MIN_MESES, len(produtos_esparsos),
    )

    # Carregar localidades que o produto frio atende
    cold_localidades: dict[int, list[int]] = defaultdict(list)
    cold_rows = await conn.fetch("""
        SELECT DISTINCT s.id_produto, s.id_localidade
        FROM mart.sazonalidade_produto s
        WHERE NOT s.is_forecast
          AND s.data_referencia_atual >= '2024-01'
        ORDER BY s.id_produto, s.id_localidade
    """)
    for r in cold_rows:
        cold_localidades[r["id_produto"]].append(r["id_localidade"])

    proxy_batch: list[tuple] = []
    proxy_skipped = 0

    for pid, info in produtos_esparsos:
        nome = info["nome"]
        raiz = _extrair_raiz(nome)
        meses_existentes = info["meses"]

        # Encontrar proxy pai
        pai_info = proxy_cache.get(raiz)
        if not pai_info or not pai_info["is_confiavel"]:
            # Fallback: tentar match exato com primeira palavra
            primeira_palavra = nome.upper().split()[0] if nome.upper().split() else None
            if primeira_palavra and primeira_palavra != raiz:
                pai_info = proxy_cache.get(primeira_palavra)

        if not pai_info or not pai_info["is_confiavel"]:
            proxy_skipped += 1
            logger.debug("  Proxy nao encontrado para '%s' (raiz='%s')", nome, raiz)
            continue

        shape = pai_info["shape"]
        localidades = cold_localidades.get(pid, [])

        if not localidades:
            logger.debug("  '%s' sem localidades — pulando proxy.", nome)
            proxy_skipped += 1
            continue

        for mes in range(1, 13):
            if mes in meses_existentes:
                continue  # já tem baseline real
            if mes not in shape:
                continue  # pai também não tem este mês

            pai_status = shape[mes]["status_cor_mode"]
            pai_conf = shape[mes]["confianca"]
            conf_proxy = round(float(pai_conf) * PROXY_CONFIANCA_PENALTY, 2)

            for loc in localidades:
                proxy_batch.append((pid, loc, mes, pai_status, conf_proxy))

    # Inserir registros proxy em batch
    if not proxy_batch:
        logger.info("  Nenhum registro proxy para inserir.")
        return total

    inserted_proxy = 0
    chunk_size = 500
    for i in range(0, len(proxy_batch), chunk_size):
        chunk = proxy_batch[i:i + chunk_size]
        values = []
        params = []
        idx = 1
        for pid, loc, mes, status, conf in chunk:
            values.append(
                f"(${idx}, ${idx+1}, ${idx+2}, ${idx+3}::TEXT, ${idx+4}::NUMERIC(5,2))"
            )
            params.extend([pid, loc, mes, status, conf])
            idx += 5

        sql = f"""
            INSERT INTO mart.sazonalidade_baseline
                (id_produto, id_localidade, mes, status_cor_mode, confianca)
            VALUES {','.join(values)}
            ON CONFLICT (id_produto, id_localidade, mes)
            DO UPDATE SET
                status_cor_mode = EXCLUDED.status_cor_mode,
                confianca       = EXCLUDED.confianca,
                fonte           = '{PROXY_FONTE}',
                atualizado_em   = NOW()
        """
        await conn.execute(sql, *params)
        inserted_proxy += len(chunk)
        logger.info("  Proxy: %d/%d inseridos...", inserted_proxy, len(proxy_batch))

    logger.info(
        "Proxy Hierarquico: %d registros inseridos para %d produtos | %d sem proxy",
        inserted_proxy,
        len(produtos_esparsos) - proxy_skipped,
        proxy_skipped,
    )

    return total + inserted_proxy


async def main():
    logger.info("=== Cálculo do Baseline Histórico ===")
    conn = await asyncpg.connect(DSN)
    try:
        total = await calcular_baseline(conn)
        logger.info("Total: %d linhas em mart.sazonalidade_baseline", total)
    finally:
        await conn.close()
    logger.info("Done.")


if __name__ == "__main__":
    asyncio.run(main())
