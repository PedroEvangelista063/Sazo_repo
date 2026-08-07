"""Hotfix: carga rápida do parquet do scraper histórico — BYPASS de rede.

Lê database/processed_data/01_raw/scraper_hortifruti_historico.parquet
(sem refazer requisições web) e carrega dimensões + staging.fact_precos_mensais,
replicando a lógica CORRIGIDA de run_scraper_historico.py:

- dim_localidade: índices parciais tratados com index_predicate por nível
  (estado: ON CONFLICT (uf) WHERE municipio_id IS NULL; município:
  ON CONFLICT (uf, municipio_id) WHERE municipio_id IS NOT NULL);
  strings vazias viram None/NULL antes do execute().
- malha fina de preço: preço nulo/inválido/<= 0 NÃO entra na fato.

Uso:
    python -m pipeline.load_parquet_to_db [--parquet <path>] [--skip-medalhao]

Requires: polars, psycopg2-binary (venv do pipeline).
"""

from __future__ import annotations

import argparse
import logging
import os
import uuid
from pathlib import Path

import polars as pl

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)

DEFAULT_PARQUET = (
    Path(__file__).resolve().parent.parent
    / "database"
    / "processed_data"
    / "01_raw"
    / "scraper_hortifruti_historico.parquet"
)
DATABASE_URL: str = os.environ.get("DATABASE_URL_ETL") or os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/quero_comprar",
)
COPY_BATCH_SIZE: int = 50_000


def _get_pg_conn():
    import psycopg2

    conn = psycopg2.connect(DATABASE_URL, options="-c timezone=UTC")
    conn.set_session(autocommit=False)
    return conn


def _extrair_localidades(df: pl.DataFrame) -> set[tuple[str, str | None, str | None]]:
    """(uf, municipio_id, municipio_nome) distintos; sem código IBGE -> nível Estado."""
    tem_codigo = "municipio_id" in df.columns
    locs: set[tuple[str, str | None, str | None]] = set()
    cols = ["uf", "municipio_id", "municipio"] if tem_codigo else ["uf"]
    for row in df.select(cols).unique().iter_rows():
        uf = row[0]
        if tem_codigo:
            codigo = (row[1] or None) if row[1] else None
            nome = (row[2] or None) if row[2] else None
            locs.add((uf, str(codigo).strip() if codigo else None, nome))
        else:
            locs.add((uf, None, None))
    return locs


def _ensure_dimensions(
    conn,
    produtos: set[str],
    localidades: set[tuple[str, str | None, str | None]],
) -> dict:
    """Sincroniza dim_produto e dim_localidade respeitando índices parciais."""
    from psycopg2.extras import execute_values

    with conn.cursor() as cur:
        execute_values(
            cur,
            "INSERT INTO staging.dim_produto (nome_produto) VALUES %s ON CONFLICT DO NOTHING",
            [(p,) for p in produtos],
        )
        cur.execute("SELECT id_produto, nome_produto FROM staging.dim_produto")
        produto_map = {row[1]: row[0] for row in cur.fetchall()}

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


def _load_mes_into_fact(conn, df_mes: pl.DataFrame, mapping: dict) -> int:
    """Carrega UM mês em transação atômica (upsert). Malha fina de preço aplicada."""
    from psycopg2.extras import execute_values

    prod_map = mapping["produtos"]
    loc_uf_map = mapping["localidades_uf"]
    loc_mun_map = mapping["localidades_municipio"]
    batch_id = str(uuid.uuid4())

    rows: list[tuple] = []
    seen: set[tuple] = set()
    descartados_preco = 0
    for row_dict in df_mes.iter_rows(named=True):
        produto = row_dict.get("produto", "")
        uf = row_dict.get("uf", "")
        ano = row_dict.get("ano", 0)
        mes = row_dict.get("mes", 0)
        preco = row_dict.get("valor_produto_kg", 0.0)

        # Malha fina: preço nulo/vazio/<= 0 NÃO entra na fato (defesa do ETL).
        if preco is None or not isinstance(preco, (int, float)) or preco <= 0:
            descartados_preco += 1
            continue

        id_prod = prod_map.get(produto)
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


def _separar_por_mes(df: pl.DataFrame) -> dict[tuple[int, int], pl.DataFrame]:
    grupos: dict[tuple[int, int], pl.DataFrame] = {}
    for (ano, mes), sub in df.group_by(["ano", "mes"]):
        grupos[(int(ano), int(mes))] = sub
    return grupos


def _refresh_mv(conn) -> None:
    with conn.cursor() as cur:
        cur.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY mart.vw_api_produtos_sazonalidade")
    conn.commit()
    logger.info("MV mart.vw_api_produtos_sazonalidade atualizada")


def _notificar_backend_etl_fim() -> None:
    """Purge de cache do backend (falha graciosa)."""
    from pipeline.cache_purge import purge_cache_sync

    try:
        ok = purge_cache_sync()
        logger.info(
            "Notificação ETL_FINISHED/cache purge: %s",
            "OK" if ok else "FALHOU (backend indisponível)",
        )
    except Exception:
        logger.exception("Notificação de cache falhou")


def main() -> int:
    parser = argparse.ArgumentParser(description="Carga do parquet histórico (bypass rede)")
    parser.add_argument("--parquet", type=str, default=str(DEFAULT_PARQUET))
    parser.add_argument(
        "--skip-medalhao", action="store_true", help="Não roda sp_executar_carga_completa"
    )
    parser.add_argument(
        "--skip-refresh-mv", action="store_true", help="Não faz REFRESH da MV à parte"
    )
    parser.add_argument("--skip-notify", action="store_true", help="Não notifica/purga cache")
    args = parser.parse_args()

    path = Path(args.parquet)
    if not path.exists():
        logger.error("Parquet não encontrado: %s", path)
        return 2

    df = pl.read_parquet(path)
    logger.info("Parquet: %d registros | %s", df.height, path)
    logger.info("DB: %s", DATABASE_URL)

    conn = _get_pg_conn()
    try:
        localidades = _extrair_localidades(df)
        produtos = set(df["produto"].unique().to_list())
        mapping = _ensure_dimensions(conn, produtos, localidades)
        logger.info(
            "Dimensões: %d produtos | %d UFs | %d municípios",
            len(mapping["produtos"]),
            len(mapping["localidades_uf"]),
            len(mapping["localidades_municipio"]),
        )

        total = 0
        for (ano, mes), df_mes in sorted(_separar_por_mes(df).items()):
            inseridas = _load_mes_into_fact(conn, df_mes, mapping)
            logger.info("  %04d/%02d: %d linhas inseridas/atualizadas", ano, mes, inseridas)
            total += inseridas
        logger.info("TOTAL fato: %d linhas upserted", total)

        if not args.skip_medalhao:
            try:
                t0 = __import__("time").perf_counter()
                with conn.cursor() as cur:
                    cur.execute("CALL staging.sp_executar_carga_completa()")
                conn.commit()
                logger.info(
                    "Ciclo medalhão concluído em %.1fs", __import__("time").perf_counter() - t0
                )
            except Exception:
                conn.rollback()
                logger.exception("Ciclo medalhão falhou — MV será refrescada à parte")

        if not args.skip_refresh_mv:
            _refresh_mv(conn)

        if not args.skip_notify:
            _notificar_backend_etl_fim()
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
