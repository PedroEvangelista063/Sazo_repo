"""
Carga dos dados de sazonalidade calculados no PostgreSQL.

Usa UPSERT (INSERT ON CONFLICT DO UPDATE) para ser idempotente:
rodar o pipeline duas vezes não duplica dados.
"""

import logging
import os
from contextlib import contextmanager
from typing import Generator

import polars as pl
import psycopg2
from psycopg2.extras import execute_values

logger = logging.getLogger(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/quero_comprar")

DDL = """
CREATE TABLE IF NOT EXISTS municipios (
    codigo_ibge  VARCHAR(10) PRIMARY KEY,
    nome         VARCHAR(100) NOT NULL,
    uf           CHAR(2) NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_mun_uf ON municipios (uf);

CREATE TABLE IF NOT EXISTS seasonality_index (
    id                  BIGSERIAL PRIMARY KEY,
    municipio_id        VARCHAR(10),
    municipio_nome      VARCHAR(100),
    uf                  CHAR(2) NOT NULL,
    produto             VARCHAR(100) NOT NULL,
    ano                 SMALLINT NOT NULL,
    mes                 SMALLINT NOT NULL,
    preco_medio         NUMERIC(10, 2),
    media_movel_12m     NUMERIC(10, 2),
    indice_sazonalidade NUMERIC(6, 4),
    status_semaforo     VARCHAR(15) NOT NULL,
    dica                TEXT,
    fonte               VARCHAR(10) NOT NULL,
    updated_at          TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT uq_season UNIQUE (municipio_id, produto, ano, mes)
);
CREATE INDEX IF NOT EXISTS idx_season_uf_prod_mes  ON seasonality_index (uf, produto, mes);
CREATE INDEX IF NOT EXISTS idx_season_mun_prod_mes ON seasonality_index (municipio_id, produto, mes);
CREATE INDEX IF NOT EXISTS idx_season_produto_fts  ON seasonality_index
    USING gin(to_tsvector('portuguese', produto));
"""

UPSERT_SQL = """
INSERT INTO seasonality_index
    (municipio_id, municipio_nome, uf, produto, ano, mes,
     preco_medio, media_movel_12m, indice_sazonalidade,
     status_semaforo, dica, fonte, updated_at)
VALUES %s
ON CONFLICT (municipio_id, produto, ano, mes) DO UPDATE SET
    municipio_nome      = EXCLUDED.municipio_nome,
    uf                  = EXCLUDED.uf,
    preco_medio         = EXCLUDED.preco_medio,
    media_movel_12m     = EXCLUDED.media_movel_12m,
    indice_sazonalidade = EXCLUDED.indice_sazonalidade,
    status_semaforo     = EXCLUDED.status_semaforo,
    dica                = EXCLUDED.dica,
    fonte               = EXCLUDED.fonte,
    updated_at          = NOW();
"""


@contextmanager
def get_connection() -> Generator[psycopg2.extensions.connection, None, None]:
    conn = psycopg2.connect(DATABASE_URL)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def ensure_schema() -> None:
    """Cria as tabelas se não existirem (idempotente)."""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(DDL)
    logger.info("Schema verificado/criado.")


def load_seasonality(df: pl.DataFrame, batch_size: int = 5_000) -> int:
    """
    Carrega o DataFrame de sazonalidade no PostgreSQL via UPSERT em lotes.

    Args:
        df: DataFrame resultado de calculate_seasonality_municipio() ou apply_municipio_fallback()
        batch_size: Linhas por INSERT batch (padrão 5.000)

    Returns:
        Total de linhas inseridas/atualizadas.
    """
    records = df.select([
        "municipio_id", "municipio_nome", "uf", "produto", "ano", "mes",
        "preco_medio", "media_movel_12m", "indice_sazonalidade",
        "status_semaforo", "dica", "fonte",
    ]).to_dicts()

    # Converte para tuplas para psycopg2
    rows = [
        (
            r["municipio_id"], r["municipio_nome"], r["uf"], r["produto"],
            r["ano"], r["mes"],
            r["preco_medio"], r["media_movel_12m"], r["indice_sazonalidade"],
            r["status_semaforo"], r["dica"], r["fonte"],
            "NOW()",
        )
        for r in records
    ]

    total = 0
    with get_connection() as conn:
        with conn.cursor() as cur:
            for i in range(0, len(rows), batch_size):
                batch = rows[i : i + batch_size]
                execute_values(cur, UPSERT_SQL, batch, template=None, page_size=batch_size)
                total += len(batch)
                logger.info("Carregados %d/%d registros...", total, len(rows))

    logger.info("Carga concluída: %d registros upsertados.", total)
    return total
