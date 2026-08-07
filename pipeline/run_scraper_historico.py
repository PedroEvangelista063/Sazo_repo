from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
import time
import uuid
from datetime import UTC, datetime
from typing import Any

import polars as pl

from pipeline.scraper.adapters import AgrolinkCEASAAdapter, CotacaoRegional
from pipeline.scraper.adapters.smart_router import TODAS_UFS, SmartCrawler2026
from pipeline.scraper.ceasa_spider import (
    LOCALIDADES_ALVO,
    RAW_DIR,
    CotacaoHistorica,
)
from pipeline.scraper.data_normalizer import DataNormalizer
from pipeline.scraper.price_collector import PriceCollector
from pipeline.scraper.transport import (
    BrowserConfig,
    EngineType,
    SelfHealingOrganism,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)

OUTPUT = RAW_DIR / "scraper_hortifruti_historico.parquet"
STAGING_COLUNAS = ["produto", "uf", "municipio", "ano", "mes", "valor_produto_kg"]
STAGING_COLUNAS_FUZZY = [
    "produto",
    "uf",
    "municipio",
    "ano",
    "mes",
    "valor_produto_kg",
    "is_fuzzy",
    "match_score",
]
STAGING_SCHEMA = {
    "produto": pl.String,
    "uf": pl.String,
    "municipio": pl.String,
    "ano": pl.Int32,
    "mes": pl.Int32,
    "valor_produto_kg": pl.Float64,
    "is_fuzzy": pl.Boolean,
    "match_score": pl.Float64,
}

QUALIDADE_MINIMA_PCT = float(os.environ.get("QUALIDADE_MINIMA_PCT", "97.0"))
DATABASE_URL: str = os.environ.get(
    "DATABASE_URL_ETL",
) or os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/quero_comprar",
)
COPY_BATCH_SIZE: int = 50_000
AUDIT_LOG_DIR = RAW_DIR / "audit"


def _iterar_meses(
    ano_inicio: int, mes_inicio: int, ano_fim: int, mes_fim: int
) -> list[tuple[int, int]]:
    meses: list[tuple[int, int]] = []
    a, m = ano_inicio, mes_inicio
    while (a < ano_fim) or (a == ano_fim and m <= mes_fim):
        meses.append((a, m))
        m += 1
        if m > 12:
            m = 1
            a += 1
    return meses


# ── Auditoria JSON ──────────────────────────────────────────────────


def _salvar_audit_mes(ano: int, mes: int, cobertura_pct: float, status: str, linhas: int) -> None:
    AUDIT_LOG_DIR.mkdir(parents=True, exist_ok=True)
    path = AUDIT_LOG_DIR / f"audit_{ano:04d}-{mes:02d}.json"
    registro = {
        "ano": ano,
        "mes": mes,
        "cobertura_pct": round(cobertura_pct, 2),
        "status": status,
        "linhas_carregadas": linhas,
        "timestamp": datetime.now(UTC).isoformat(),
        "batch_id": str(uuid.uuid4()),
    }
    path.write_text(json.dumps(registro, indent=2, ensure_ascii=False), encoding="utf-8")
    logger.debug("Audit: %s", path)


# ── Qualidade do banco ──────────────────────────────────────────────


async def _meses_com_qualidade_insuficiente(
    conn,
    meses: list[tuple[int, int]],
    limite_pct: float,
) -> list[tuple[int, int]]:
    total = await conn.fetchval(
        "SELECT count(*) FROM staging.dim_produto WHERE status_fonte = 'MAPEADA'"
    )
    if not total or total == 0:
        logger.warning("Nenhum produto MAPEADO (status_fonte) cadastrado — varrendo todos os meses")
        return meses, {m: 0.0 for m in meses}

    coberturas: dict[tuple[int, int], float] = {}
    pendentes: list[tuple[int, int]] = []

    for ano, mes in meses:
        existentes = await conn.fetchval(
            """
            SELECT count(DISTINCT f.id_produto)
            FROM staging.fact_precos_mensais f
            JOIN staging.dim_produto p ON p.id_produto = f.id_produto
            WHERE p.status_fonte = 'MAPEADA'
              AND f.ano = $1 AND f.mes = $2
            """,
            ano,
            mes,
        )
        cobertura = (existentes / total) * 100 if existentes else 0.0
        coberturas[(ano, mes)] = cobertura

        if cobertura >= limite_pct:
            logger.info("  %04d/%02d: %.1f%% cobertura (OK, ignorando)", ano, mes, cobertura)
            _salvar_audit_mes(ano, mes, cobertura, "SKIPPED", 0)
        else:
            logger.info("  %04d/%02d: %.1f%% cobertura (PENDENTE)", ano, mes, cobertura)
            pendentes.append((ano, mes))

    return pendentes, coberturas


# ── Carga no PostgreSQL (atômica por mês) ───────────────────────────


def _get_pg_conn():
    import psycopg2

    conn = psycopg2.connect(DATABASE_URL, options="-c timezone=UTC")
    conn.set_session(autocommit=False)
    return conn


def _ensure_dimensions(
    conn,
    produtos_uf: set[str],
    localidades: set[tuple[str, str | None, str | None]],
) -> dict:
    """Sincroniza dim_produto e dim_localidade (níveis Estado e Município).

    staging.dim_localidade usa índices ÚNICOS PARCIAIS:
      - uq_dim_localidade_uf_nivel_estado  UNIQUE (uf)               WHERE municipio_id IS NULL
      - uq_dim_localidade_municipio        UNIQUE (uf, municipio_id) WHERE municipio_id IS NOT NULL

    Índices parciais NÃO são elegíveis para inferência de conflito em
    ``ON CONFLICT (col...)`` sem o ``index_predicate`` explícito — por isso cada
    nível declara seu próprio ``WHERE`` na cláusula ON CONFLICT.
    Strings vazias ("") são convertidas em None/NULL antes do execute().
    """
    from psycopg2.extras import execute_values

    with conn.cursor() as cur:
        execute_values(
            cur,
            "INSERT INTO staging.dim_produto (nome_produto) VALUES %s ON CONFLICT DO NOTHING",
            [(p,) for p in produtos_uf],
        )
        cur.execute("SELECT id_produto, nome_produto FROM staging.dim_produto")
        produto_map = {row[1]: row[0] for row in cur.fetchall()}

        # Separa as linhas por nível ANTES de montar a query: estado (municipio_id NULL)
        # vs município (municipio_id com código IBGE). "" vira None.
        linhas_estado: list[tuple[str, None, None]] = []
        linhas_municipio: list[tuple[str, str, str | None]] = []
        for uf, municipio_id, municipio_nome in localidades:
            mid = (municipio_id or None) if municipio_id else None
            mnome = (municipio_nome or None) if municipio_nome else None
            if mid is None:
                linhas_estado.append((uf, None, None))
            else:
                linhas_municipio.append((uf, mid, mnome))

        if linhas_estado:
            execute_values(
                cur,
                """
                INSERT INTO staging.dim_localidade (uf, municipio_id, municipio_nome)
                VALUES %s ON CONFLICT (uf) WHERE municipio_id IS NULL DO NOTHING
                """,
                linhas_estado,
            )
        if linhas_municipio:
            execute_values(
                cur,
                """
                INSERT INTO staging.dim_localidade (uf, municipio_id, municipio_nome)
                VALUES %s ON CONFLICT (uf, municipio_id) WHERE municipio_id IS NOT NULL DO NOTHING
                """,
                linhas_municipio,
            )

        # Mapa por nível: (uf) → id_localidade p/ estado; (uf, municipio_id) → id p/ município.
        # uf é CHAR(2) e volta com padding — strip() evita miss no lookup.
        cur.execute("SELECT id_localidade, uf, municipio_id FROM staging.dim_localidade")
        loc_uf_map: dict[str, int] = {}
        loc_mun_map: dict[tuple[str, str], int] = {}
        for id_loc, uf, municipio_id in cur.fetchall():
            uf_clean = uf.strip()
            if municipio_id is None or municipio_id == "":
                loc_uf_map.setdefault(uf_clean, id_loc)
            else:
                loc_mun_map[(uf_clean, municipio_id)] = id_loc

    conn.commit()
    return {
        "produtos": produto_map,
        "localidades_uf": loc_uf_map,
        "localidades_municipio": loc_mun_map,
    }


def _load_mes_into_fact(
    conn,
    df_mes: pl.DataFrame,
    mapping: dict,
    mapping_lock: Any,
) -> int:
    """Carrega UM mes em transacao atomica. Se falhar, rollback nao afeta outros meses."""
    from psycopg2.extras import execute_values

    prod_map = mapping["produtos"]
    loc_uf_map = mapping["localidades_uf"]
    loc_mun_map = mapping["localidades_municipio"]
    batch_id = str(uuid.uuid4())

    col_produto = "produto"
    col_uf = "uf"
    col_ano = "ano"
    col_mes = "mes"
    col_preco = "valor_produto_kg"

    rows: list[tuple] = []
    seen: set[tuple] = set()
    descartados_preco = 0
    for row_dict in df_mes.iter_rows(named=True):
        produto = row_dict.get(col_produto, "")
        uf = row_dict.get(col_uf, "")
        ano = row_dict.get(col_ano, 0)
        mes = row_dict.get(col_mes, 0)
        preco = row_dict.get(col_preco, 0.0)

        # FASE 1 — Malha fina: preço nulo/vazio/<= 0 NÃO entra na fato.
        # (o normalizer já descarta, mas esta é a última barreira antes do INSERT)
        if preco is None or not isinstance(preco, (int, float)) or preco <= 0:
            descartados_preco += 1
            continue

        id_prod = prod_map.get(produto)
        # Resolve localidade: nível Município (código IBGE) quando disponível,
        # senão cai no nível Estado (comportamento para parquet sem código).
        id_loc = None
        municipio_id = row_dict.get("municipio_id") or None
        if municipio_id is not None:
            id_loc = loc_mun_map.get((uf, str(municipio_id)))
        if id_loc is None:
            id_loc = loc_uf_map.get(uf)
        if id_prod is None or id_loc is None:
            continue

        key = (id_prod, id_loc, ano, mes)
        if key in seen:
            continue
        seen.add(key)
        rows.append((id_prod, id_loc, ano, mes, preco, batch_id))

    if not rows:
        if descartados_preco:
            logger.warning(
                "_load_mes_into_fact: %d linhas descartadas pela malha fina (preço nulo/inválido)",
                descartados_preco,
            )
        return 0

    with conn.cursor() as cur:
        for i in range(0, len(rows), COPY_BATCH_SIZE):
            batch = rows[i : i + COPY_BATCH_SIZE]
            execute_values(
                cur,
                """
                INSERT INTO staging.fact_precos_mensais
                    (id_produto, id_localidade, ano, mes, preco_medio, batch_id)
                VALUES %s
                ON CONFLICT (id_produto, id_localidade, ano, mes)
                DO UPDATE SET
                    preco_medio = EXCLUDED.preco_medio,
                    batch_id    = EXCLUDED.batch_id,
                    loaded_at   = NOW()
                """,
                batch,
                page_size=COPY_BATCH_SIZE,
            )

    conn.commit()
    return len(rows)


def _executar_ciclo_medalhao(conn) -> None:
    t0 = time.perf_counter()
    logger.info("Ciclo medalhao: CALL sp_executar_carga_completa()...")
    with conn.cursor() as cur:
        cur.execute("CALL staging.sp_executar_carga_completa()")
    conn.commit()
    logger.info("Ciclo medalhao concluido em %.1fs", time.perf_counter() - t0)


def _notificar_backend_etl_fim() -> None:
    """Notifica o backend via POST interno que o ETL terminou."""
    from pipeline.cache_purge import purge_cache_sync

    purge_cache_sync()


# ── Scraper ─────────────────────────────────────────────────────────


def formatar_staging(items: list[CotacaoHistorica], normalizer: DataNormalizer) -> pl.DataFrame:
    if not items:
        logger.warning("formatar_staging: lista vazia, sem dados para processar")
        return pl.DataFrame(schema=STAGING_SCHEMA)

    df_norm = normalizer.normalizar_lote(items, cutoff=0.0)

    total = df_norm.height
    descartados_preco = df_norm.filter(pl.col("valor_produto_kg") <= 0).height
    descartados_nome = df_norm.filter(
        (pl.col("match_score") == 0.0) & (pl.col("produto") == "")
    ).height
    descartados_score = df_norm.filter(
        (pl.col("match_score") > 0.0) & (pl.col("match_score") < 70.0)
    ).height
    df_high = df_norm.filter(pl.col("match_score") >= 70.0)
    df_fuzzy = df_norm.filter((pl.col("match_score") >= 50.0) & (pl.col("match_score") < 70.0))

    logger.info(
        "Normalizer: total=%d | high(>=70)=%d | fuzzy(50-70)=%d | "
        "desc-nome=%d | desc-preco=%d | desc-score=%d",
        total,
        df_high.height,
        df_fuzzy.height,
        descartados_nome,
        descartados_preco,
        descartados_score,
    )

    if df_high.height == 0 and df_fuzzy.height == 0:
        logger.warning("Nenhum item passou no normalizer (score < 50)")
        return pl.DataFrame(schema=STAGING_SCHEMA)

    def _aggregate(df_in: pl.DataFrame, fuzzy: bool) -> pl.DataFrame:
        if df_in.height == 0:
            return pl.DataFrame(schema=STAGING_SCHEMA)
        df_in = df_in.with_columns(
            pl.col("ano").cast(pl.Int32),
            pl.col("mes").cast(pl.Int32),
            pl.col("valor_produto_kg").cast(pl.Float64),
        )
        out = df_in.group_by(["produto", "uf", "municipio", "ano", "mes"]).agg(
            pl.col("valor_produto_kg").mean().round(4).alias("valor_produto_kg"),
        )
        out = out.with_columns(
            pl.lit(fuzzy).alias("is_fuzzy"),
            pl.lit(0.0).cast(pl.Float64).alias("match_score"),
        )
        if fuzzy:
            score_agg = df_in.group_by(["produto", "uf", "municipio", "ano", "mes"]).agg(
                pl.col("match_score").mean().round(1).alias("match_score"),
            )
            out = out.update(score_agg, on=["produto", "uf", "municipio", "ano", "mes"])
        return out.select(STAGING_COLUNAS_FUZZY)

    df_high_agg = _aggregate(df_high, fuzzy=False)
    df_fuzzy_agg = _aggregate(df_fuzzy, fuzzy=True)

    if df_high_agg.height == 0 and df_fuzzy_agg.height == 0:
        return pl.DataFrame(schema=STAGING_SCHEMA)
    resultado = (
        df_high_agg
        if df_fuzzy_agg.height == 0
        else df_fuzzy_agg
        if df_high_agg.height == 0
        else pl.concat([df_high_agg, df_fuzzy_agg])
    ).unique()
    logger.info(
        "Staging: %d high + %d fuzzy = %d total",
        df_high_agg.height,
        df_fuzzy_agg.height,
        resultado.height,
    )
    return resultado


# ── SmartCrawler Bridge ──────────────────────────────────────────────


def _cotacao_regional_para_historica(
    regionais: dict[str, list[CotacaoRegional]],
) -> list[CotacaoHistorica]:
    historicas: list[CotacaoHistorica] = []
    for url, items in regionais.items():
        for item in items:
            historicas.append(
                CotacaoHistorica(
                    produto_original=item.produto_original,
                    uf=item.uf or "",
                    municipio=item.municipio or "",
                    ano=item.ano or 0,
                    mes=item.mes or 0,
                    preco_bruto=item.preco_bruto,
                    fator_kg=item.fator_kg,
                    fonte=item.fonte or url,
                )
            )
    return historicas


async def _coletar_mes(
    meses: list[tuple[int, int]],
    collector: PriceCollector,
    normalizer: DataNormalizer,
    smartcrawler_ufs: list[str] | None = None,
    organism: SelfHealingOrganism | None = None,
) -> list[pl.DataFrame]:
    blocos: list[pl.DataFrame] = []
    crawler = SmartCrawler2026(organism=organism)
    for ano, mes in meses:
        logger.info("--- Coletando %04d/%02d ---", ano, mes)
        collector.definir_mes_alvo(ano, mes)
        items, metricas = await collector.collect_all()
        df = formatar_staging(items, normalizer)
        metricas.total_apos_fuzzy = df.height
        metricas.taxa_conversao_pct = (
            (df.height / metricas.total_bruto * 100) if metricas.total_bruto > 0 else 0.0
        )
        print(metricas.relatorio())

        # Date fallback: se coletou 0 brutos, tenta mes anterior
        if len(items) == 0:
            mes_fallback = mes - 1 if mes > 1 else 12
            ano_fallback = ano if mes > 1 else ano - 1
            logger.info(
                "FALLBACK DATA: %04d/%02d -> %04d/%02d", ano, mes, ano_fallback, mes_fallback
            )
            collector.definir_mes_alvo(ano_fallback, mes_fallback)
            items_fb, _ = await collector.collect_all()
            if items_fb:
                df_fb = formatar_staging(items_fb, normalizer)
                if df_fb.height > 0:
                    logger.info("Fallback data recuperou %d registros", df_fb.height)
                    df = df_fb if df.height == 0 else pl.concat([df, df_fb]).unique()

        if smartcrawler_ufs:
            logger.info("SmartCrawler: %d UFs com cascata fallback...", len(smartcrawler_ufs))
            sc_resultados = await crawler.executar_para_ufs(smartcrawler_ufs, ano=ano, mes=mes)
            sc_items = _cotacao_regional_para_historica(sc_resultados)
            if sc_items:
                sc_df = formatar_staging(sc_items, normalizer)
                df = pl.concat([df, sc_df]).unique() if df.height > 0 else sc_df
                logger.info("SmartCrawler: +%d registros apos fuzzy", sc_df.height)

        if df.height > 0:
            blocos.append(df)
        logger.info("--- %04d/%02d: %d registros apos fuzzy ---", ano, mes, df.height)
    return blocos


def _extrair_localidades(df: pl.DataFrame) -> set[tuple[str, str | None, str | None]]:
    """Extrai (uf, municipio_id, municipio_nome) distintos do DataFrame.

    Nível Estado: município vazio/ausente → (uf, None, None).
    Nível Município: apenas quando há código IBGE (coluna municipio_id) — o nome
    sozinho não basta, pois o índice parcial exige municipio_id NOT NULL.
    """
    tem_codigo = "municipio_id" in df.columns
    locs: set[tuple[str, str | None, str | None]] = set()
    cols = ["uf", "municipio_id", "municipio"] if tem_codigo else ["uf"]
    for row in df.select(cols).unique().iter_rows():
        uf = row[0]
        if tem_codigo:
            codigo = (row[1] or None) if row[1] else None
            nome = (row[2] or None) if row[2] else None
            if codigo is None:
                locs.add((uf, None, None))
            else:
                locs.add((uf, str(codigo).strip(), nome))
        else:
            # Sem código IBGE no parquet → apenas o nível Estado é carregável.
            locs.add((uf, None, None))
    return locs


def _extrair_produtos(df: pl.DataFrame) -> set[str]:
    return set(df["produto"].unique().to_list())


def _separar_por_mes(df: pl.DataFrame) -> dict[tuple[int, int], pl.DataFrame]:
    grupos: dict[tuple[int, int], pl.DataFrame] = {}
    for (ano, mes), sub in df.group_by(["ano", "mes"]):
        grupos[(ano, mes)] = sub
    return grupos


# ── Main ────────────────────────────────────────────────────────────


async def main() -> None:
    parser = argparse.ArgumentParser(description="Scraper + Carga Medalhao — Qualidade Progressiva")
    parser.add_argument(
        "--descobrir",
        action="store_true",
        help="Executa descoberta de novas fontes antes da coleta",
    )
    parser.add_argument(
        "--concorrencia", type=int, default=4, help="Maximo de requisicoes simultaneas"
    )
    parser.add_argument(
        "--desde", type=str, default=None, help="Mes inicial (YYYY-MM). Omitir = mes corrente"
    )
    parser.add_argument(
        "--ate", type=str, default=None, help="Mes final (YYYY-MM). Omitir = mes corrente"
    )
    parser.add_argument(
        "--qualidade-minima",
        type=float,
        default=QUALIDADE_MINIMA_PCT,
        help="%% minima de cobertura para ignorar mes (0-100)",
    )
    parser.add_argument(
        "--forcar", action="store_true", help="Ignora qualidade e raspa todos os meses do range"
    )
    parser.add_argument("--db-url", type=str, default=DATABASE_URL, help="PostgreSQL URL")
    parser.add_argument(
        "--skip-load", action="store_true", help="So salva parquet, nao carrega no banco"
    )
    parser.add_argument(
        "--uf",
        type=str,
        default=None,
        help="Lista de UFs separadas por virgula (ex: AC,AM,AP). Padrao = todas",
    )
    args = parser.parse_args()

    logger.info("=== SCRAPER REGIONAL + CARGA MEDALHAO (w/ SelfHealingOrganism) ===")
    logger.info("Qualidade minima: %.1f%% | DB: %s", args.qualidade_minima, args.db_url)

    hoje = datetime.now(UTC).date()
    if args.desde:
        ano_inicio, mes_inicio = (int(x) for x in args.desde.split("-"))
        ano_fim, mes_fim = (int(x) for x in (args.ate or args.desde).split("-"))
        meses_planejados = _iterar_meses(ano_inicio, mes_inicio, ano_fim, mes_fim)
        logger.info(
            "Range: %d meses (%s a %s)",
            len(meses_planejados),
            args.desde,
            f"{ano_fim:04d}-{mes_fim:02d}",
        )
    else:
        meses_planejados = [(hoje.year, hoje.month)]

    # ── 1. Filtrar meses por qualidade do banco ──────────────────
    coberturas_conhecidas: dict[tuple[int, int], float] = {}
    if args.forcar:
        meses_para_raspar = meses_planejados
    else:
        try:
            import asyncpg

            if sys.platform == "win32":
                asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
            conn = await asyncpg.connect(args.db_url)
            try:
                meses_para_raspar, coberturas_conhecidas = await _meses_com_qualidade_insuficiente(
                    conn, meses_planejados, args.qualidade_minima
                )
            finally:
                await conn.close()
        except Exception as e:  # noqa: BLE001 — banco pode estar indisponível; fallback raspa todos os meses
            logger.warning("Nao foi possivel consultar qualidade (%s) — raspando todos os meses", e)
            meses_para_raspar = meses_planejados

    if not meses_para_raspar:
        logger.info(
            "Nenhum mes precisa de raspagem (todos acima de %.1f%%).", args.qualidade_minima
        )
        return

    logger.info("Meses para raspar: %d de %d", len(meses_para_raspar), len(meses_planejados))

    # ── 2. Montar scrapers ───────────────────────────────────────
    localidades = list(LOCALIDADES_ALVO)

    if args.descobrir:
        from pipeline.scraper.buscador_fontes import descobrir_fontes, fontes_para_localidades

        rel = await descobrir_fontes()
        novas = fontes_para_localidades(rel.fontes)
        logger.info("Descoberta: %d novas fontes", len(novas))
        localidades.extend(novas)

    collector = PriceCollector()
    collector.register_from_localidades(localidades)
    collector.register_adapter("Agrolink CEASA (todas UFs)", AgrolinkCEASAAdapter())

    normalizer = DataNormalizer(fuzzy_cutoff=75.0)
    normalizer.carregar_csv()

    smartcrawler_ufs: list[str] = TODAS_UFS
    logger.info("SmartCrawler: %d UFs com cascata fallback dedicada+CONAB", len(smartcrawler_ufs))

    # ── Organism singleton (criado UMA vez — evita N browsers paralelos) ──
    organism: SelfHealingOrganism | None = None
    try:
        organism = SelfHealingOrganism(
            base_browser_config=BrowserConfig(
                engine=EngineType.PATCHRIGHT,
                headless=True,
            ),
            identity_pool_size=3,
            max_retries_per_url=3,
            cooldown_after_failure_s=30,
        )
        logger.info("SelfHealingOrganism inicializado (pool=%d retries=%d)", 3, 3)

        # ── 3. Raspar ────────────────────────────────────────────
        blocos = await _coletar_mes(
            meses_para_raspar, collector, normalizer, smartcrawler_ufs, organism
        )

        if not blocos:
            logger.warning("Nenhum dado coletado em nenhum mes.")
            return

        df_final = pl.concat(blocos).unique()
        RAW_DIR.mkdir(parents=True, exist_ok=True)
        df_final.write_parquet(OUTPUT)
        logger.info("Output parquet: %d registros -> %s", df_final.height, OUTPUT)

        if args.skip_load:
            logger.info("--skip-load ativo: parquet salvo, banco nao alterado.")
            return

        # ── 4. Carga atomica por mes ─────────────────────────────────
        conn = _get_pg_conn()
        meses_por_mes = _separar_por_mes(df_final)

        try:
            todos_produtos = _extrair_produtos(df_final)
            localidades = _extrair_localidades(df_final)
            mapping = _ensure_dimensions(conn, todos_produtos, localidades)

            total_inseridas = 0
            meses_ok = 0
            meses_falha = 0

            for (ano, mes), df_mes in sorted(meses_por_mes.items()):
                logger.info("--- Carregando %04d/%02d (%d linhas) ---", ano, mes, df_mes.height)
                try:
                    inseridas = _load_mes_into_fact(conn, df_mes, mapping, None)
                    linhas_pos = inseridas
                    cobertura_pos = coberturas_conhecidas.get((ano, mes), 0.0)
                    status = "LOADED"
                    logger.info("  %04d/%02d: %d linhas inseridas/atualizadas", ano, mes, inseridas)
                    meses_ok += 1
                except Exception:
                    conn.rollback()
                    linhas_pos = 0
                    cobertura_pos = 0.0
                    status = "FAILED"
                    logger.exception("  %04d/%02d: FALHA NA CARGA", ano, mes)
                    meses_falha += 1

                _salvar_audit_mes(ano, mes, cobertura_pos, status, linhas_pos)
                total_inseridas += linhas_pos

            if meses_ok > 0 and not meses_falha > meses_ok:
                try:
                    _executar_ciclo_medalhao(conn)
                    _notificar_backend_etl_fim()
                except Exception:
                    conn.rollback()
                    logger.exception("Ciclo medalhao falhou")

            logger.info(
                "=== RESUMO: %d meses OK, %d falha, %d linhas ===",
                meses_ok,
                meses_falha,
                total_inseridas,
            )

        except Exception:
            conn.rollback()
            logger.exception("Erro fatal na preparacao — nenhum mes carregado")
        finally:
            conn.close()

    finally:
        if organism:
            await organism.close()
            logger.info("SelfHealingOrganism resources released")


if __name__ == "__main__":
    asyncio.run(main())
