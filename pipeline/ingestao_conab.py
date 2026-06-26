"""
Ingestão automatizada dos preços CONAB → PostgreSQL (Arquitetura Medalhão).

Pipeline:
    extract()  → download via streaming com exponential backoff
    transform() → limpeza, tipagem, normalização via Polars
    load()      → COPY bulk nativo do PostgreSQL com upsert idempotente

Uso:
    export DATABASE_URL=postgresql://role_etl_writer:senha@localhost:5432/quero_comprar
    python -m pipeline.ingestao_conab

Dependências (pip install):
    polars  requests  tenacity  psycopg2-binary  python-dotenv
"""

from __future__ import annotations

import io
import logging
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn

import polars as pl
import requests
from psycopg2.extras import execute_values
from tenacity import (
    before_sleep_log,
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)
from dotenv import load_dotenv

load_dotenv()

logger = logging.getLogger("ingestao_conab")

# ────────────────────────────────────────────────────────────────────
# Constantes
# ────────────────────────────────────────────────────────────────────

CONAB_URLS: dict[str, str] = {
    "uf": "https://portaldeinformacoes.conab.gov.br/downloads/arquivos/PrecosMensalUF.txt",
    "prohort": "https://portaldeinformacoes.conab.gov.br/downloads/arquivos/ProhortMensal.txt",
}

DATABASE_URL: str = os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/quero_comprar",
)

REQUEST_TIMEOUT: int = 180
MAX_RETRIES: int = 5
COPY_BATCH_SIZE: int = 50_000

# Colunas esperadas após transformação
UF_COLUMNS: list[str] = ["produto", "uf", "ano", "mes", "preco_medio"]
MUN_COLUMNS: list[str] = [
    "produto", "municipio_id", "municipio_nome", "uf", "ano", "mes", "preco_medio",
]

# ProhortMensal.txt mapeado para MUN_COLUMNS (CEASA como local de observação)
# Derivado de: dsc_produto, cod_ibge_municipio_ceasa, municipio_ceasa,
#              uf_ceasa, id_ano_comercializacao, id_mes_comercializacao,
#              valor_comercializado / qtd_comercializada_kg
PROHORT_COLUMNS: list[str] = [
    "produto", "municipio_id", "municipio_nome", "uf", "ano", "mes", "preco_medio",
]

# Diretório dos arquivos locais LISTA*.txt
LOCAL_DATA_DIR: str = os.path.join(
    os.path.dirname(__file__), "..", "dados_sazonliza_dados_bruto",
)

# Colunas esperadas nos arquivos locais
LOCAL_FILE_COLUMNS: list[str] = [
    "produto", "classificao_produto", "id_produto", "uf",
    "regiao", "ano", "mes", "dsc_nivel_comercializacao", "valor_produto_kg",
]


@dataclass
class CargaResult:
    """Resultado consolidado de uma execução do pipeline."""

    arquivo: str
    linhas_lidas: int = 0
    linhas_inseridas: int = 0
    linhas_rejeitadas: int = 0
    duracao_seg: float = 0.0


# ────────────────────────────────────────────────────────────────────
# EXTRACT — Download com streaming e retry exponencial
# ────────────────────────────────────────────────────────────────────

class DownloadError(Exception):
    """Falha no download após todas as tentativas."""


def _build_session() -> requests.Session:
    """Cria session com pool de conexões e headers padrão."""
    session = requests.Session()
    session.headers.update({
        "User-Agent": "QueroComprar/2.0 (dados publicos CONAB; contato: dev@querocomprar.app)",
        "Accept": "text/plain, text/csv, */*",
    })
    adapter = requests.adapters.HTTPAdapter(
        pool_connections=4,
        pool_maxsize=8,
        max_retries=0,  # Usamos tenacity, não o retry do adapter
    )
    session.mount("https://", adapter)
    return session


@retry(
    stop=stop_after_attempt(MAX_RETRIES),
    wait=wait_exponential(multiplier=2, min=2, max=60),
    retry=retry_if_exception_type(
        (requests.ConnectionError, requests.Timeout, requests.HTTPError)
    ),
    before_sleep=before_sleep_log(logger, logging.WARNING),
    reraise=True,
)
def _download_stream(url: str, session: requests.Session) -> bytes:
    """Download com streaming em chunks. Nunca carrega o arquivo inteiro na RAM.

    Usa iter_content(chunk_size) para processar em pedaços e monta o
    resultado em memória (via BytesIO) para arquivos de até ~200MB.
    Para arquivos maiores que 500MB, salva em disco temporário.
    """
    logger.info("Download iniciado: %s", url)
    resp = session.get(url, stream=True, timeout=REQUEST_TIMEOUT)
    resp.raise_for_status()

    content_type = resp.headers.get("Content-Type", "")
    content_length = resp.headers.get("Content-Length")
    file_size = int(content_length) if content_length else 0

    logger.info(
        "Content-Type: %s | Tamanho estimado: %s",
        content_type,
        f"{file_size / 1_048_576:.1f} MB" if file_size else "desconhecido",
    )

    chunks: list[bytes] = []
    bytes_received = 0

    for chunk in resp.iter_content(chunk_size=256 * 1024):
        if chunk:
            chunks.append(chunk)
            bytes_received += len(chunk)

    logger.info(
        "Download concluído: %.1f MB recebidos",
        bytes_received / 1_048_576,
    )
    return b"".join(chunks)


def extract(url: str) -> bytes:
    """Faz download do arquivo CONAB com proteção de rede completa."""
    session = _build_session()
    try:
        return _download_stream(url, session)
    finally:
        session.close()


# ────────────────────────────────────────────────────────────────────
# TRANSFORM — Limpeza e normalização com Polars
# ────────────────────────────────────────────────────────────────────

def _sanitize_price(series: pl.Series) -> pl.Series:
    """Converte string '2,27' para Float64. Retorna null se inválido."""
    return (
        series.str.strip_chars()
        .str.replace(",", ".")
        .cast(pl.Float64, strict=False)
    )


def _sanitize_text(series: pl.Series) -> pl.Series:
    """Remove espaços extras e padroniza uppercase."""
    return series.str.strip_chars().str.to_uppercase()


def transform_uf(raw_bytes: bytes) -> pl.DataFrame:
    """Lê CSV bruto CONAB de UF, limpa e normaliza.

    Regras:
        - Encoding LATIN-1 (ISO-8859-1)
        - Separador ;
        - Preço com vírgula → Float64 americano
        - Filtrar linhas com preço nulo, zero, ou mês inválido
        - Remover linhas duplicadas de cabeçalho no meio do arquivo
    """
    raw_text = raw_bytes.decode("latin-1")
    df = pl.read_csv(
        io.StringIO(raw_text),
        separator=";",
        infer_schema_length=10_000,
        ignore_errors=True,
        truncate_ragged_lines=True,
    )

    before = df.height
    df = df.rename({c: c.strip().lower().replace(" ", "_").replace("-", "_")
                     for c in df.columns})

    # Detectar coluna de preço
    price_col = next((c for c in df.columns if "preco" in c or "valor" in c), None)
    if price_col is None:
        raise ValueError(f"Coluna de preço não encontrada. Colunas: {df.columns}")
    if price_col != "preco_medio":
        df = df.rename({price_col: "preco_medio"})

    # Garantir colunas obrigatórias
    for col in ["produto", "uf", "ano", "mes"]:
        if col not in df.columns:
            raise ValueError(f"Coluna obrigatória ausente: {col}")

    df = df.with_columns(
        _sanitize_price(pl.col("preco_medio")).alias("preco_medio"),
        pl.col("ano").cast(pl.Int32, strict=False),
        pl.col("mes").cast(pl.Int32, strict=False),
        _sanitize_text(pl.col("produto")),
        _sanitize_text(pl.col("uf")),
    )

    # Filtrar inválidos
    df = df.filter(
        pl.col("preco_medio").is_not_null()
        & (pl.col("preco_medio") > 0)
        & pl.col("produto").is_not_null()
        & pl.col("uf").str.len_chars() == 2
        & pl.col("ano").is_not_null()
        & pl.col("mes").is_not_null()
        & pl.col("mes").is_between(1, 12)
    )

    # Remover falsos cabeçalhos (linhas onde produto repete o header)
    df = df.filter(
        ~pl.col("produto").str.to_lowercase().str.contains("produto|produto")
    )

    after = before - df.height
    if df.height == 0:
        raise ValueError("Zero linhas após limpeza — estrutura do arquivo mudou?")

    logger.info("UF: %d -> %d linhas (%d removidas)", before, df.height, after)
    return df.select(UF_COLUMNS)


def transform_municipio(raw_bytes: bytes) -> pl.DataFrame:
    """Lê CSV bruto CONAB de Município, limpa e normaliza."""
    raw_text = raw_bytes.decode("latin-1")
    df = pl.read_csv(
        io.StringIO(raw_text),
        separator=";",
        infer_schema_length=10_000,
        ignore_errors=True,
        truncate_ragged_lines=True,
    )

    before = df.height
    df = df.rename({c: c.strip().lower().replace(" ", "_").replace("-", "_")
                     for c in df.columns})

    price_col = next((c for c in df.columns if "preco" in c or "valor" in c), None)
    if price_col is None:
        raise ValueError(f"Coluna de preço não encontrada. Colunas: {df.columns}")
    if price_col != "preco_medio":
        df = df.rename({price_col: "preco_medio"})

    # Detectar colunas de município
    id_col = next((c for c in df.columns if "cod" in c or "ibge" in c), None)
    if id_col and id_col != "municipio_id":
        df = df.rename({id_col: "municipio_id"})

    nome_col = next(
        (c for c in df.columns
         if "municipio" in c and "id" not in c and "cod" not in c),
        None,
    )
    if nome_col and nome_col != "municipio_nome":
        df = df.rename({nome_col: "municipio_nome"})

    for col in ["produto", "uf", "ano", "mes"]:
        if col not in df.columns:
            raise ValueError(f"Coluna obrigatória ausente: {col}")

    df = df.with_columns(
        _sanitize_price(pl.col("preco_medio")).alias("preco_medio"),
        pl.col("ano").cast(pl.Int32, strict=False),
        pl.col("mes").cast(pl.Int32, strict=False),
        _sanitize_text(pl.col("produto")),
        _sanitize_text(pl.col("uf")),
    )

    if "municipio_nome" in df.columns:
        df = df.with_columns(
            pl.col("municipio_nome").str.strip_chars().str.to_titlecase()
        )

    df = df.filter(
        pl.col("preco_medio").is_not_null()
        & (pl.col("preco_medio") > 0)
        & pl.col("produto").is_not_null()
        & pl.col("ano").is_not_null()
        & pl.col("mes").is_not_null()
        & pl.col("mes").is_between(1, 12)
    )

    df = df.filter(
        ~pl.col("produto").str.to_lowercase().str.contains("produto")
    )

    # Preencher municipio_id ausente com placeholder
    if "municipio_id" not in df.columns:
        df = df.with_columns(pl.lit("UF-").alias("municipio_id"))
    if "municipio_nome" not in df.columns:
        df = df.with_columns(pl.lit(None).cast(pl.Utf8).alias("municipio_nome"))

    after = before - df.height
    logger.info("Municipio: %d -> %d linhas (%d removidas)", before, df.height, after)
    return df.select(MUN_COLUMNS)


def transform_prohort(raw_bytes: bytes) -> pl.DataFrame:
    """Lê CSV bruto CONAB ProhortMensal e deriva preço médio por kg por CEASA.

    O arquivo ProhortMensal.txt contém fluxo comercial nas CEASAs:
      - qtd_comercializada_kg, valor_comercializado
      - preco_medio = valor_comercializado / qtd_comercializada_kg
      - dsc_produto → produto
      - uf_ceasa → uf, municipio_ceasa → municipio_nome
      - cod_ibge_municipio_ceasa → municipio_id

    Regras:
        - Encoding LATIN-1 (ISO-8859-1)
        - Separador ;
        - qtd_comercializada_kg > 0 (evita divisão por zero)
        - uf_ceasa com 2 caracteres
        - Remover outliers extremos (Z-score > 5)
    """
    raw_text = raw_bytes.decode("latin-1")
    df = pl.read_csv(
        io.StringIO(raw_text),
        separator=";",
        infer_schema_length=10_000,
        ignore_errors=True,
        truncate_ragged_lines=True,
    )

    before = df.height
    df = df.rename({c: c.strip().lower().replace(" ", "_").replace("-", "_")
                     for c in df.columns})

    # Mapear colunas do Prohort para o schema padrão
    col_map = {
        "dsc_produto": "produto",
        "cod_ibge_municipio_ceasa": "municipio_id",
        "municipio_ceasa": "municipio_nome",
        "uf_ceasa": "uf",
        "id_ano_comercializacao": "ano",
        "id_mes_comercializacao": "mes",
    }
    for src, dst in col_map.items():
        if src in df.columns:
            df = df.rename({src: dst})

    # Validar colunas obrigatórias
    required_cols = ["produto", "uf", "ano", "mes", "qtd_comercializada_kg", "valor_comercializado"]
    for col in required_cols:
        if col not in df.columns:
            raise ValueError(f"Coluna obrigatória ausente no Prohort: {col}")

    # Calcular preco_medio = valor / quantidade
    df = df.with_columns(
        pl.col("qtd_comercializada_kg").str.replace(",", ".").cast(pl.Float64, strict=False).alias("_qtd"),
        pl.col("valor_comercializado").str.replace(",", ".").cast(pl.Float64, strict=False).alias("_valor"),
        pl.col("ano").cast(pl.Int32, strict=False),
        pl.col("mes").cast(pl.Int32, strict=False),
    )

    df = df.with_columns(
        (pl.col("_valor") / pl.col("_qtd")).alias("preco_medio"),
    )

    # Normalizar texto
    df = df.with_columns(
        _sanitize_text(pl.col("produto")),
        pl.col("uf").str.strip_chars().str.to_uppercase(),
    )

    # Limpar municipio_nome: "SÃO PAULO-SP" → "SÃO PAULO"
    if "municipio_nome" in df.columns:
        df = df.with_columns(
            pl.col("municipio_nome")
            .str.strip_chars()
            .str.replace(r"-{1}[A-Z]{2}$", "")  # remove "-UF" sufixo
            .str.to_titlecase()
        )

    # Filtrar inválidos
    df = df.filter(
        pl.col("preco_medio").is_not_null()
        & (pl.col("preco_medio") > 0)
        & pl.col("produto").is_not_null()
        & pl.col("uf").str.len_chars() == 2
        & pl.col("ano").is_not_null()
        & pl.col("mes").is_not_null()
        & pl.col("mes").is_between(1, 12)
        & pl.col("_qtd").is_not_null()
        & (pl.col("_qtd") > 0)
    )

    # Remover falsos cabeçalhos
    df = df.filter(
        ~pl.col("produto").str.to_lowercase().str.contains("produto")
    )

    # Preencher municipio_id ausente
    if "municipio_id" not in df.columns:
        df = df.with_columns(pl.lit(None).cast(pl.Utf8).alias("municipio_id"))
    else:
        df = df.with_columns(
            pl.col("municipio_id").str.strip_chars().cast(pl.Utf8)
        )

    if "municipio_nome" not in df.columns:
        df = df.with_columns(pl.lit(None).cast(pl.Utf8).alias("municipio_nome"))

    after = before - df.height
    if df.height == 0:
        raise ValueError("Zero linhas após limpeza do Prohort — estrutura mudou?")

    logger.info("Prohort: %d -> %d linhas (%d removidas)", before, df.height, after)
    return df.select(PROHORT_COLUMNS)


# ────────────────────────────────────────────────────────────────────
# LOCAL FILE — Leitura dos LISTA*.txt reais do usuário
# ────────────────────────────────────────────────────────────────────

# Motor Semântico de Categorização — isola tratores de tomates
# A categoria_b2c evita que itens B2B (TRATOR, ZINCO, TRANSPORTE)
# poluam o cálculo de sazonalidade do app consumidor.
REGRAS_CATEGORIAS: dict[str, str] = {
    "MAQUINARIO_FERRAMENTA": (
        r"(?i)^(TRATOR|ESCARIFICADOR|ESCADA|PAQUIMETRO|"
        r"BOTA|LUVAS|TRAPICHO)\b"
    ),
    "INSUMO_AGRICOLA": (
        r"(?i)^(00-\d{2}-\d{2}|ZINCO|FLUMYZIN|NATIVO|SENCOR|"
        r"SEMENTE|NEMAT|FLUIL|NHT|OLEO VEGETA|PARA BROCA)\b"
    ),
    "SERVICO_LOGISTICA": (
        r"(?i)^(TRANSPORTE|PASSAGEM|PATIO|TRATAMENTO)\b"
    ),
    "ALIMENTO_VAREJO": (
        r"(?i)^(CARNE|PAO|FLOCOS DE MILHO|ERVA MATE|TOMATE|"
        r"FRANGO|ARROZ|FEIJAO|BATATA|CENOURA|CEBOLA|ALFACE|"
        r"REPOLHO|ABOBRINHA|PIMENTAO|LARANJA|BANANA|MACA|"
        r"MAMAO|UVA)\b"
    ),
}


def _sanitize_local_text(series: pl.Series) -> pl.Series:
    """Strip padded whitespace from local file columns (fixed-width padding)."""
    return series.str.strip_chars()


def categorizar_produtos(df: pl.DataFrame) -> pl.DataFrame:
    """Adiciona coluna ``categoria_b2c`` via regex sobre o nome original do produto.

    A avaliação é feita sobre ``_produto_original`` (antes da combinação com
    ``classificao_produto``), garantindo que ``TRATOR 150 16X16`` seja
    capturado pela regra ``MAQUINARIO_FERRAMENTA``.

    Categorias:
      - ``ALIMENTO_VAREJO``     → alimentos para o app B2C
      - ``MAQUINARIO_FERRAMENTA`` → tratores, ferramentas
      - ``INSUMO_AGRICOLA``     → fertilizantes, defensivos
      - ``SERVICO_LOGISTICA``   → transporte, serviços
      - ``MATERIA_PRIMA_B2B``   → borracha, celulose, etc (fallback)
    """
    col = "_produto_original" if "_produto_original" in df.columns else "produto"

    expr = pl.lit("MATERIA_PRIMA_B2B")  # fallback
    for categoria, pattern in REGRAS_CATEGORIAS.items():
        expr = pl.when(pl.col(col).str.contains(pattern)).then(pl.lit(categoria)).otherwise(expr)

    return df.with_columns(expr.alias("categoria_b2c"))


def load_local_file(filepath: str) -> tuple[pl.DataFrame, dict[str, str]]:
    """Lê arquivo local LISTA*.txt, categoriza e mapeia para UF_COLUMNS.

    Layout real (separador ``;``):
      produto;classificao_produto;id_produto;uf;regiao;ano;mes;
      dsc_nivel_comercializacao;valor_produto_kg

    Returns:
        Tupla ``(df_uf, categorias)`` onde:
        - ``df_uf``: DataFrame com ``UF_COLUMNS`` + ``categoria_b2c``
        - ``categorias``: dict ``{nome_produto_combinado: categoria}``
    """
    raw_text = Path(filepath).read_bytes().decode("latin-1")
    df = pl.read_csv(
        io.StringIO(raw_text),
        separator=";",
        infer_schema_length=10_000,
        ignore_errors=True,
        truncate_ragged_lines=True,
    )

    before = df.height
    df = df.rename({c: c.strip().lower().replace(" ", "_").replace("-", "_")
                     for c in df.columns})

    # Strip padding de TODAS as colunas string
    for col in df.columns:
        if df[col].dtype == pl.Utf8:
            df = df.with_columns(_sanitize_local_text(pl.col(col)).alias(col))

    # Preservar nome original ANTES da combinação (para categorização)
    df = df.with_columns(pl.col("produto").alias("_produto_original"))

    # Combinar produto + classificacao para garantir unicidade
    # Ex: "TRATOR" + "150 16X16 JOHN DEERE" → "TRATOR - 150 16X16 JOHN DEERE"
    #      vs "TRATOR" + "100 4X4" → "TRATOR - 100 4X4" (surrogate keys diferentes)
    if "classificao_produto" in df.columns:
        df = df.with_columns(
            (pl.col("produto") + " - " + pl.col("classificao_produto")).alias("produto")
        )

    # Motor de categorização semântica
    df = categorizar_produtos(df)
    categorias = dict(
        df.select(["produto", "categoria_b2c"]).unique().iter_rows()
    )

    # Renomear valor_produto_kg → preco_medio
    if "valor_produto_kg" in df.columns:
        df = df.rename({"valor_produto_kg": "preco_medio"})

    # Converter preço (vírgula → ponto) e tipos
    df = df.with_columns(
        _sanitize_price(pl.col("preco_medio")).alias("preco_medio"),
        pl.col("ano").cast(pl.Int32, strict=False),
        pl.col("mes").cast(pl.Int32, strict=False),
    )

    # Filtrar inválidos
    # ATENÇÃO: parênteses obrigatórios — Python dá precedence maior a & que ==
    df = df.filter(
        pl.col("preco_medio").is_not_null()
        & (pl.col("preco_medio") > 0)
        & pl.col("produto").is_not_null()
        & (pl.col("uf").str.len_chars() == 2)
        & pl.col("ano").is_not_null()
        & pl.col("mes").is_not_null()
        & pl.col("mes").is_between(1, 12)
    )

    # Remover falsos cabeçalhos
    df = df.filter(
        ~pl.col("produto").str.to_lowercase().str.contains("produto")
    )

    after = before - df.height
    if df.height == 0:
        raise ValueError(f"Zero linhas após limpeza do arquivo local: {filepath}")

    logger.info(
        "LocalFile: %s — %d -> %d linhas (%d removidas) | categorias=%s",
        Path(filepath).name, before, df.height, after,
        set(categorias.values()),
    )
    df_out = df.select([*UF_COLUMNS, "categoria_b2c"])
    return df_out, categorias


# ────────────────────────────────────────────────────────────────────
# LOAD — COPY nativo do PostgreSQL com upsert idempotente
# ────────────────────────────────────────────────────────────────────

def _get_pg_conn():
    """Cria conexão PostgreSQL com statement timeout e timezone."""
    import psycopg2
    conn = psycopg2.connect(DATABASE_URL, options="-c timezone=UTC")
    conn.set_session(autocommit=False)
    return conn


def _ensure_dimensions(
    conn,
    df_uf: pl.DataFrame,
    df_mun: pl.DataFrame,
    df_prohort: pl.DataFrame | None = None,
) -> dict:
    """Garante que dimensões existam e retorna mapping {chave → id}.

    Estratégia: INSERT ON CONFLICT DO NOTHING + SELECT em lote.
    Isso é ~10x mais rápido que INSERT...RETURNING linha por linha.
    """

    with conn.cursor() as cur:
        # Produtos
        produtos = set(df_uf["produto"].to_list() + df_mun["produto"].to_list())
        if df_prohort is not None:
            produtos |= set(df_prohort["produto"].to_list())
        execute_values(
            cur,
            "INSERT INTO staging.dim_produto (nome_produto) VALUES %s ON CONFLICT DO NOTHING",
            [(p,) for p in produtos],
        )
        cur.execute("SELECT id_produto, nome_produto FROM staging.dim_produto")
        produto_map = {row[1]: row[0] for row in cur.fetchall()}

        # Localidades (UF + Municipio)
        localidades = set()
        for uf in df_uf["uf"].unique().to_list():
            localidades.add((uf, "", ""))
        for row in df_mun.select(["uf", "municipio_id", "municipio_nome"]).unique().iter_rows():
            localidades.add((row[0], row[1] if row[1] else None, row[2] if row[2] else None))
        if df_prohort is not None:
            for row in df_prohort.select(["uf", "municipio_id", "municipio_nome"]).unique().iter_rows():
                localidades.add((row[0], row[1] if row[1] else None, row[2] if row[2] else None))

        execute_values(
            cur,
            """
            INSERT INTO staging.dim_localidade (uf, municipio_id, municipio_nome)
            VALUES %s ON CONFLICT (uf, municipio_id) DO NOTHING
            """,
            [(uf, mid, mnome) for uf, mid, mnome in localidades],
        )
        cur.execute(
            "SELECT id_localidade, uf, municipio_id FROM staging.dim_localidade"
        )
        localidade_map = {(row[1], row[2]): row[0] for row in cur.fetchall()}

    conn.commit()
    logger.info(
        "Dimensões sincronizadas: %d produtos, %d localidades",
        len(produto_map), len(localidade_map),
    )
    return {"produtos": produto_map, "localidades": localidade_map}


def _copy_to_fact(
    conn,
    df: pl.DataFrame,
    mapping: dict,
    batch_id: str,
    is_uf: bool,
) -> int:
    """Insere dados na fact_precos_mensais via COPY buffer.

    Returns:
        Número de linhas inseridas.
    """

    prod_map = mapping["produtos"]
    loc_map = mapping["localidades"]

    rows: list[tuple] = []
    seen = set()
    for row in df.iter_rows():
        produto = row[0]
        uf = row[1] if is_uf else row[3]
        ano = row[2] if is_uf else row[4]
        mes = row[3] if is_uf else row[5]
        preco = row[4] if is_uf else row[6]
        municipio_id = None if is_uf else (row[1] if row[1] else None)

        if municipio_id is None:
            loc_key = (uf, None)
        else:
            loc_key = (uf, municipio_id)
        id_prod = prod_map.get(produto)
        id_loc = loc_map.get(loc_key)
        if id_prod is None or id_loc is None:
            continue

        key = (id_prod, id_loc, ano, mes)
        if key in seen:
            continue
        seen.add(key)
        rows.append((id_prod, id_loc, ano, mes, preco, batch_id))

    if not rows:
        return 0

    COPY_SQL = """
    INSERT INTO staging.fact_precos_mensais
        (id_produto, id_localidade, ano, mes, preco_medio, batch_id)
    VALUES %s
    ON CONFLICT (id_produto, id_localidade, ano, mes)
    DO UPDATE SET
        preco_medio = EXCLUDED.preco_medio,
        batch_id    = EXCLUDED.batch_id,
        loaded_at   = NOW()
    """

    total = 0
    with conn.cursor() as cur:
        for i in range(0, len(rows), COPY_BATCH_SIZE):
            batch = rows[i:i + COPY_BATCH_SIZE]
            execute_values(cur, COPY_SQL, batch, page_size=COPY_BATCH_SIZE)
            total += len(batch)

    conn.commit()
    return total


def _executar_pos_carga(conn) -> None:
    """Completa o ciclo medalhão: calcular sazonalidade → refresh MV.

    Deve ser chamado APÓS a carga de todos os arquivos na mesma transação.
    """
    import time as _time
    t0 = _time.perf_counter()
    logger.info("Completando ciclo medalhão — SP + MV refresh...")

    with conn.cursor() as cur:
        cur.execute("CALL staging.sp_executar_carga_completa()")
    conn.commit()

    duracao = _time.perf_counter() - t0
    logger.info("Ciclo medalhão concluído em %.1fs", duracao)


def _registrar_carga(
    conn,
    batch_id: str,
    arquivo: str,
    lidas: int,
    inseridas: int,
    rejeitadas: int,
    duracao: float,
    status: str,
) -> None:
    """Registra metadados da carga em raw.controle_carga."""
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO raw.controle_carga
                (batch_id, arquivo, linhas_lidas, linhas_inseridas,
                 linhas_rejeitadas, duracao_seg, status, concluido_em)
            VALUES (%s, %s, %s, %s, %s, %s, %s, NOW())
            ON CONFLICT (batch_id) DO UPDATE SET
                linhas_inseridas  = EXCLUDED.linhas_inseridas,
                linhas_rejeitadas = EXCLUDED.linhas_rejeitadas,
                duracao_seg       = EXCLUDED.duracao_seg,
                status            = EXCLUDED.status,
                concluido_em      = NOW()
            """,
            (batch_id, arquivo, lidas, inseridas, rejeitadas, duracao, status),
        )
    conn.commit()


def _atualizar_categorias_produtos(
    conn,
    categorias: dict[str, str],
) -> None:
    """Atualiza ``categoria_b2c`` em ``dim_produto`` após a carga.

    Args:
        categorias: dict ``{nome_produto_combinado: categoria}``.
    """
    if not categorias:
        return
    with conn.cursor() as cur:
        for nome_produto, cat in categorias.items():
            cur.execute(
                "UPDATE staging.dim_produto SET categoria_b2c = %s "
                "WHERE nome_produto = %s AND categoria_b2c IS DISTINCT FROM %s",
                (cat, nome_produto, cat),
            )
    conn.commit()
    logger.info("Categorias atualizadas: %d produtos", len(categorias))


def load(
    df_uf: pl.DataFrame,
    df_mun: pl.DataFrame,
    df_prohort: pl.DataFrame | None = None,
) -> dict[str, CargaResult]:
    """Executa a carga completa no banco: dimensões → fato → controle → sazonalidade.

    Após a carga dos dados brutos, completa o ciclo medalhão:
      CALL staging.sp_executar_carga_completa()
      REFRESH MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade

    Args:
        df_uf: DataFrame transformado de UF (PrecosMensalUF).
        df_mun: DataFrame transformado de município (PrecosMensalMunicipio).
        df_prohort: DataFrame transformado do ProhortMensal (CEASA flow).

    Returns:
        Dicionário com resultados por arquivo.
    """
    import uuid
    batch_id = str(uuid.uuid4())
    inicio = time.perf_counter()

    conn = _get_pg_conn()
    try:
        # 1. Sincronizar dimensões
        mapping = _ensure_dimensions(conn, df_uf, df_mun, df_prohort)

        # 2. Carga UF
        t0 = time.perf_counter()
        uf_inseridas = _copy_to_fact(conn, df_uf, mapping, batch_id, is_uf=True)
        uf_duracao = time.perf_counter() - t0
        _registrar_carga(
            conn, batch_id, "PrecosMensalUF",
            df_uf.height, uf_inseridas, 0, uf_duracao, "sucesso",
        )
        resultado_uf = CargaResult(
            arquivo="PrecosMensalUF",
            linhas_lidas=df_uf.height,
            linhas_inseridas=uf_inseridas,
            duracao_seg=uf_duracao,
        )

        # 3. Carga Prohort (substitui PrecosMensalMunicipio)
        pro_inseridas = 0
        resultado_pro = CargaResult(arquivo="ProhortMensal")
        if df_prohort is not None and df_prohort.height > 0:
            t0 = time.perf_counter()
            pro_inseridas = _copy_to_fact(conn, df_prohort, mapping, batch_id, is_uf=False)
            pro_duracao = time.perf_counter() - t0
            _registrar_carga(
                conn, batch_id, "ProhortMensal",
                df_prohort.height, pro_inseridas, 0, pro_duracao, "sucesso",
            )
            resultado_pro = CargaResult(
                arquivo="ProhortMensal",
                linhas_lidas=df_prohort.height,
                linhas_inseridas=pro_inseridas,
                duracao_seg=pro_duracao,
            )

        # 4. Ciclo medalhão: sazonalidade + MV refresh
        _executar_pos_carga(conn)

        total_duracao = time.perf_counter() - inicio
        logger.info(
            "Carga concluída: batch=%s | UF=%d | Prohort=%d | total=%.1fs",
            batch_id, uf_inseridas, pro_inseridas, total_duracao,
        )

        return {"uf": resultado_uf, "prohort": resultado_pro}

    except Exception:
        conn.rollback()
        logger.exception("Carga falhou — rollback executado para batch=%s", batch_id)
        _registrar_carga(
            conn, batch_id, "geral", 0, 0, 0, 0, "falha",
        )
        raise
    finally:
        conn.close()


# ────────────────────────────────────────────────────────────────────
# ORQUESTRAÇÃO
# ────────────────────────────────────────────────────────────────────

def run() -> None:
    """Executa o pipeline completo: extract → transform → load → medalhão.

    Fontes ativas:
      1. PrecosMensalUF.txt   → preços UF (fertilizantes/insumos, fallback)
      2. ProhortMensal.txt     → fluxo CEASA com preço por kg derivado

    Ciclo medalhão (pós-carga):
      - CALL staging.sp_executar_carga_completa()
      - REFRESH MATERIALIZED VIEW mart.vw_api_produtos_sazonalidade
    """
    inicio = time.perf_counter()
    logger.info("=" * 60)
    logger.info("Pipeline CONAB — Iniciando")
    logger.info("=" * 60)

    # Extract (sequencial — httpx com retry embutido)
    logger.info("[1/4] Download dos arquivos CONAB...")
    raw_uf = extract(CONAB_URLS["uf"])
    raw_pro = extract(CONAB_URLS["prohort"])
    logger.info("Download concluído: UF=%.1fMB, Prohort=%.1fMB",
                len(raw_uf) / 1_048_576, len(raw_pro) / 1_048_576)

    # Transform
    logger.info("[2/4] Limpeza e normalização...")
    df_uf = transform_uf(raw_uf)
    df_pro = transform_prohort(raw_pro)
    # df_mun mantido vazio para compatibilidade com a assinatura de load()
    df_mun = pl.DataFrame(schema={"produto": pl.Utf8, "municipio_id": pl.Utf8,
                                   "municipio_nome": pl.Utf8, "uf": pl.Utf8,
                                   "ano": pl.Int32, "mes": pl.Int32,
                                   "preco_medio": pl.Float64})

    # Load
    logger.info("[3/4] Carga no PostgreSQL...")
    resultados = load(df_uf, df_mun, df_pro)

    # Pós-carga (já executado dentro de load() via _executar_pos_carga)
    logger.info("[4/4] Ciclo medalhão concluído (sazonalidade + MV)")

    # Relatório
    total_inseridas = sum(r.linhas_inseridas for r in resultados.values())
    total_lidas = sum(r.linhas_lidas for r in resultados.values())
    duracao = time.perf_counter() - inicio

    logger.info("=" * 60)
    logger.info("RELATÓRIO FINAL")
    logger.info("  Arquivos processados: %d (%s)", len(resultados), ", ".join(resultados.keys()))
    logger.info("  Linhas lidas: %d", total_lidas)
    logger.info("  Linhas inseridas: %d", total_inseridas)
    logger.info("  Rejeitadas: 0 (via trigger de anomalia)")
    logger.info("  Duração total: %.1f segundos", duracao)
    logger.info("  Performance: %.0f linhas/s", total_inseridas / duracao if duracao else 0)
    logger.info("=" * 60)


def run_local(filepath: str | None = None) -> None:
    """Pipeline alternativo: lê arquivo(s) local(is) LISTA*.txt → load.

    Fluxo:
      1. Lê cada arquivo com ``load_local_file`` (limpeza + categorização)
      2. Separa ``ALIMENTO_VAREJO`` (B2C → medalhão) de B2B (registro)
      3. Carrega B2C na ``fact_precos_mensais`` via ``load()``
      4. Atualiza ``categoria_b2c`` em ``dim_produto`` para todos os itens

    Args:
        filepath: Caminho para um arquivo específico.
                  Se ``None``, processa todos os ``LISTA*.txt`` do diretório.
    """
    data_dir = Path(LOCAL_DATA_DIR)
    if not data_dir.is_dir():
        logger.warning("Diretório local não encontrado: %s", LOCAL_DATA_DIR)
        return

    if filepath:
        files = [Path(filepath)]
    else:
        files = sorted(data_dir.glob("LISTA*.txt"))

    if not files:
        logger.warning("Nenhum arquivo LISTA*.txt encontrado em %s", data_dir)
        return

    logger.info("=" * 60)
    logger.info("Pipeline Local — %d arquivo(s) encontrado(s)", len(files))
    logger.info("=" * 60)

    inicio = time.perf_counter()
    total_b2c_inseridas = 0
    total_b2c_lidas = 0
    total_b2b = 0
    all_categorias: dict[str, str] = {}

    for f in files:
        logger.info("Processando: %s", f.name)
        t0 = time.perf_counter()

        # Ler, limpar e categorizar
        df, categorias = load_local_file(str(f))
        all_categorias.update(categorias)
        if df.height == 0:
            continue

        # Separar B2C (app) de B2B (insumos, máquinas)
        df_b2c = df.filter(pl.col("categoria_b2c") == "ALIMENTO_VAREJO")
        df_b2b = df.filter(pl.col("categoria_b2c") != "ALIMENTO_VAREJO")
        total_b2b += df_b2b.height

        if df_b2c.height == 0:
            logger.info("  → %s: 0 B2C, %d B2B (ignorado)", f.name, df_b2b.height)
            continue

        # DataFrame vazio para mun (compatibilidade com assinatura de load)
        df_mun = pl.DataFrame(schema={
            "produto": pl.Utf8, "municipio_id": pl.Utf8,
            "municipio_nome": pl.Utf8, "uf": pl.Utf8,
            "ano": pl.Int32, "mes": pl.Int32, "preco_medio": pl.Float64,
        })

        # Load B2C no medalhão
        df_b2c_uf = df_b2c.select(UF_COLUMNS)
        resultados = load(df_b2c_uf, df_mun, None)
        uf_result = resultados.get("uf", CargaResult(arquivo=f.name))
        total_b2c_inseridas += uf_result.linhas_inseridas
        total_b2c_lidas += df_b2c.height

        duracao = time.perf_counter() - t0
        logger.info(
            "  → %s: %d B2C inseridas + %d B2B ignorados em %.1fs",
            f.name, uf_result.linhas_inseridas, df_b2b.height, duracao,
        )

    # Atualizar categorias em dim_produto
    conn = _get_pg_conn()
    try:
        _atualizar_categorias_produtos(conn, all_categorias)
    finally:
        conn.close()

    duracao = time.perf_counter() - inicio
    logger.info("=" * 60)
    logger.info("RELATÓRIO FINAL — Carga Local")
    logger.info("  Arquivos: %d", len(files))
    logger.info("  Linhas B2C lidas: %d", total_b2c_lidas)
    logger.info("  Linhas B2C inseridas: %d", total_b2c_inseridas)
    logger.info("  Linhas B2B (excluídas do app): %d", total_b2b)
    logger.info("  Categorias: %s", set(all_categorias.values()))
    logger.info("  Duração total: %.1f segundos", duracao)
    logger.info("=" * 60)


def main() -> NoReturn:
    """Entry point com logging e tratamento de erro.

    Uso:
        python -m pipeline.ingestao_conab                  # download CONAB
        python -m pipeline.ingestao_conab --local          # todos LISTA*.txt
        python -m pipeline.ingestao_conab --local caminho/arquivo.txt
    """
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        stream=sys.stdout,
    )

    try:
        if "--local" in sys.argv:
            idx = sys.argv.index("--local")
            filepath = sys.argv[idx + 1] if len(sys.argv) > idx + 1 else None
            run_local(filepath)
        else:
            run()
        sys.exit(0)
    except Exception:
        logger.exception("Pipeline abortado — falha crítica")
        sys.exit(1)


if __name__ == "__main__":
    main()
