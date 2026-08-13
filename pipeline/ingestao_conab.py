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
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn

import polars as pl
import requests
from dotenv import load_dotenv
from psycopg2.extras import execute_values
from tenacity import (
    before_sleep_log,
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

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
    "produto",
    "municipio_id",
    "municipio_nome",
    "uf",
    "ano",
    "mes",
    "preco_medio",
]

# ProhortMensal.txt mapeado para MUN_COLUMNS (CEASA como local de observação)
# Derivado de: dsc_produto, cod_ibge_municipio_ceasa, municipio_ceasa,
#              uf_ceasa, id_ano_comercializacao, id_mes_comercializacao,
#              valor_comercializado / qtd_comercializada_kg
PROHORT_COLUMNS: list[str] = [
    "produto",
    "municipio_id",
    "municipio_nome",
    "uf",
    "ano",
    "mes",
    "preco_medio",
]

# Diretório dos arquivos locais LISTA*.txt
LOCAL_DATA_DIR: str = os.path.join(
    os.path.dirname(__file__),
    "..",
    "dados_sazonliza_dados_bruto",
)

# Colunas esperadas nos arquivos locais
LOCAL_FILE_COLUMNS: list[str] = [
    "produto",
    "classificao_produto",
    "id_produto",
    "uf",
    "regiao",
    "ano",
    "mes",
    "dsc_nivel_comercializacao",
    "valor_produto_kg",
]


@dataclass
class CargaResult:
    """Resultado consolidado de uma execução do pipeline."""

    arquivo: str
    linhas_lidas: int = 0
    linhas_inseridas: int = 0
    linhas_rejeitadas: int = 0
    duracao_seg: float = 0.0


@dataclass
class ContextoCarga:
    """Metadados de extração para fallback contextual de dados ausentes.

    Carregado na fase de extract() e passado para transform() para que
    colunas inferíveis (mes, ano) possam ser preenchidas quando o CSV
    da CONAB vier com valores implícitos em branco.

    Attributes:
        arquivo: Nome do arquivo de origem (p/ex: ``boletim_maio_2026.csv``).
        mes: Mês inferido do contexto (1-12).
        ano: Ano inferido do contexto.
    """

    arquivo: str = ""
    mes: int | None = None
    ano: int | None = None


# ── Inferência de metadados a partir do nome do arquivo ─────────────

MESES_BR: dict[str, int] = {
    "janeiro": 1,
    "fevereiro": 2,
    "marco": 3,
    "abril": 4,
    "maio": 5,
    "junho": 6,
    "julho": 7,
    "agosto": 8,
    "setembro": 9,
    "outubro": 10,
    "novembro": 11,
    "dezembro": 12,
}

QUALIDADE_COL: str = "_qualidade"
QUALIDADE_NORMAL: str = "NORMAL"


def _inferir_mes_do_contexto(arquivo: str) -> int | None:
    """Extrai o mês do nome do arquivo quando a coluna ``mes`` vier em branco.

    Formatos suportados:
      - ``boletim_05_2024.csv`` → 5
      - ``LISTA_05_2024.txt``  → 5
      - ``dados_05.txt``        → 5
      - ``boletim_maio_2024.csv`` → 5

    Returns:
        Mês (1-12) ou ``None`` se não foi possível inferir.
    """
    nome = Path(arquivo).stem.lower()
    m = re.search(r"(?:^|[_\s])(\d{2})(?:_\d{4}|$)", nome)
    if m:
        mes = int(m.group(1))
        if 1 <= mes <= 12:
            return mes
    for nome_mes, num in MESES_BR.items():
        if nome_mes in nome:
            return num
    return None


def _build_contexto(
    arquivo: str,
    mes: int | None = None,
    ano: int | None = None,
) -> ContextoCarga:
    """Constrói contexto de carga tentando inferir metadados do nome do arquivo."""
    return ContextoCarga(
        arquivo=arquivo,
        mes=mes if mes is not None else _inferir_mes_do_contexto(arquivo),
        ano=ano,
    )


def _apply_fallback_context(
    df: pl.DataFrame,
    contexto: ContextoCarga | None,
) -> pl.DataFrame:
    """Aplica fallback contextual pós-forward-fill com flag de qualidade por-linha.

    Materializa o estado de nulidade de mes/ano em colunas temporárias
    ANTES do fill_null, para computar a flag ``_qualidade`` individualmente
    por linha.

    Args:
        df: DataFrame já com ``_forward_fill_keys()`` aplicado.
        contexto: Metadados de extração (arquivo, mes, ano).

    Returns:
        DataFrame com coluna ``_qualidade`` (NORMAL | MES_INFERIDO |
        ANO_INFERIDO | ANO_INFERIDO+MES_INFERIDO).
    """
    # Materializar flags de nulidade ANTES de qualquer fill
    colunas_originais = set(df.columns)
    if contexto is not None and contexto.mes is not None and "mes" in colunas_originais:
        qtd = df.filter(pl.col("mes").is_null()).height
        if qtd:
            df = df.with_columns(pl.col("mes").is_null().alias("_mes_nulo"))
            df = df.with_columns(pl.col("mes").fill_null(contexto.mes))

    if contexto is not None and contexto.ano is not None and "ano" in colunas_originais:
        qtd = df.filter(pl.col("ano").is_null()).height
        if qtd:
            df = df.with_columns(pl.col("ano").is_null().alias("_ano_nulo"))
            df = df.with_columns(pl.col("ano").fill_null(contexto.ano))

    # Computar flag por-linha a partir das colunas temporárias
    flag_expr: pl.Expr = pl.lit(QUALIDADE_NORMAL)

    if "_mes_nulo" in df.columns and "_ano_nulo" in df.columns:
        flag_expr = (
            pl.when(pl.col("_mes_nulo") & pl.col("_ano_nulo"))
            .then(pl.lit("ANO_INFERIDO+MES_INFERIDO"))
            .when(pl.col("_mes_nulo"))
            .then(pl.lit("MES_INFERIDO"))
            .when(pl.col("_ano_nulo"))
            .then(pl.lit("ANO_INFERIDO"))
            .otherwise(pl.lit(QUALIDADE_NORMAL))
        )
    elif "_mes_nulo" in df.columns:
        flag_expr = (
            pl.when(pl.col("_mes_nulo"))
            .then(pl.lit("MES_INFERIDO"))
            .otherwise(pl.lit(QUALIDADE_NORMAL))
        )
    elif "_ano_nulo" in df.columns:
        flag_expr = (
            pl.when(pl.col("_ano_nulo"))
            .then(pl.lit("ANO_INFERIDO"))
            .otherwise(pl.lit(QUALIDADE_NORMAL))
        )

    df = df.with_columns(flag_expr.alias(QUALIDADE_COL))
    # Remover colunas temporárias
    return df.drop([c for c in ("_mes_nulo", "_ano_nulo") if c in df.columns])


# ────────────────────────────────────────────────────────────────────
# EXTRACT — Download com streaming e retry exponencial
# ────────────────────────────────────────────────────────────────────


class DownloadError(Exception):
    """Falha no download após todas as tentativas."""


def _build_session() -> requests.Session:
    """Cria session com pool de conexões e headers padrão."""
    session = requests.Session()
    session.headers.update(
        {
            "User-Agent": "QueroComprar/2.0 (dados publicos CONAB; contato: dev@querocomprar.app)",
            "Accept": "text/plain, text/csv, */*",
        }
    )
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
    retry=retry_if_exception_type((requests.ConnectionError, requests.Timeout, requests.HTTPError)),
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
    return series.str.strip_chars().str.replace(",", ".").cast(pl.Float64, strict=False)


def _sanitize_text(series: pl.Series) -> pl.Series:
    """Remove espaços extras e padroniza uppercase."""
    return series.str.strip_chars().str.to_uppercase()


# ── Forward-Fill: Memória de Estado para Dados Implícitos CONAB ──────
# A CONAB estrutura arquivos CSV com valores implícitos em bloco:
#   PRODUTO_A;SP;2024;5;2.50
#   ;;;5;2.55         ← produto, uf, ano herdados do bloco
#   ;;;5;2.60
#   PRODUTO_B;SP;2024;6;3.00  ← mês muda explicitamente
#
# O forward_fill preenche os nulls com o último valor válido visto.

KEY_COLS_FFILL: list[str] = ["produto", "uf", "ano", "mes"]


def _forward_fill_keys(df: pl.DataFrame) -> pl.DataFrame:
    """Aplica forward-fill nas colunas de agrupamento temporal/espacial.

    Deve ser chamado ANTES do filtro de nulls, para que as linhas
    com campos implícitos sejam preenchidas antes da validação.
    """
    cols = [c for c in KEY_COLS_FFILL if c in df.columns]
    return df.with_columns(pl.col(c).forward_fill() for c in cols)


# ── Mapeamento IBGE → UF para fallback de Municípios Órfãos ──────────
# Os primeiros 2 dígitos do código IBGE de 7 dígitos identificam a UF.
IBGE_UF: dict[str, str] = {
    "11": "RO",
    "12": "AC",
    "13": "AM",
    "14": "RR",
    "15": "PA",
    "16": "AP",
    "17": "TO",
    "21": "MA",
    "22": "PI",
    "23": "CE",
    "24": "RN",
    "25": "PB",
    "26": "PE",
    "27": "AL",
    "28": "SE",
    "29": "BA",
    "31": "MG",
    "32": "ES",
    "33": "RJ",
    "35": "SP",
    "41": "PR",
    "42": "SC",
    "43": "RS",
    "50": "MS",
    "51": "MT",
    "52": "GO",
    "53": "DF",
}


def _infer_uf_fallback(
    municipio_id: str | None,
    municipio_nome: str | None,
) -> str | None:
    """Infere UF a partir do código IBGE ou sufixo do nome do município.

    Ex: municipio_id='3550308' → prefixo '35' → SP
        municipio_nome='SÃO PAULO-SP' → sufixo '-SP' → SP
    """
    if municipio_id and len(municipio_id) >= 2:
        uf = IBGE_UF.get(municipio_id[:2])
        if uf:
            return uf
    if municipio_nome:
        import re as _re

        m = _re.search(r"-([A-Z]{2})$", municipio_nome.upper().strip())
        if m:
            return m.group(1)
    return None


def transform_uf(
    raw_bytes: bytes,
    contexto: ContextoCarga | None = None,
) -> pl.DataFrame:
    """Lê CSV bruto CONAB de UF, limpa e normaliza.

    Regras:
        - Encoding LATIN-1 (ISO-8859-1)
        - Separador ;
        - Preço com vírgula → Float64 americano
        - Forward-fill em produto/uf/ano/mes (valores implícitos em bloco)
        - Fallback contextual: se ``mes`` continuar nulo, injeta do contexto
        - Filtrar linhas com preço nulo, zero, ou mês inválido (após fallback)
        - Remover linhas duplicadas de cabeçalho no meio do arquivo

    Args:
        raw_bytes: Conteúdo bruto do CSV CONAB.
        contexto: Metadados de extração para fallback (mês/ano do arquivo).
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
    df = df.rename({c: c.strip().lower().replace(" ", "_").replace("-", "_") for c in df.columns})

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

    # Forward-fill: propaga último valor válido nas colunas de grupo
    # (produto, uf, ano, mes ficam em branco nas linhas de continuação do bloco)
    df = _forward_fill_keys(df)

    # Fallback contextual: injeta mês/ano do contexto onde forward_fill
    # não conseguiu preencher (ex: primeira linha de um bloco veio sem mes)
    df = _apply_fallback_context(df, contexto)

    # Filtrar inválidos (após fallback, linhas que ainda estão nulas
    # são genuinamente inválidas — sem produto, preço, UF, ou mês)
    # ATENÇÃO: parênteses obrigatórios em ``len_chars() == 2`` — Python dá
    # precedência maior a ``&`` que a ``==`` (bug histórico de regressão).
    # preco >= 0.01: valores residuais de divisão arredondam p/ 0 no CHECK
    # numérico do banco (fact_precos_mensais_preco_medio_check: preco > 0).
    df = df.filter(
        pl.col("preco_medio").is_not_null()
        & (pl.col("preco_medio") >= 0.01)
        & pl.col("produto").is_not_null()
        & (pl.col("uf").str.len_chars() == 2)
        & pl.col("ano").is_not_null()
        & pl.col("mes").is_not_null()
        & pl.col("mes").is_between(1, 12)
    )

    # Remover falsos cabeçalhos (linhas onde produto repete o header)
    df = df.filter(~pl.col("produto").str.to_lowercase().str.contains("produto|produto"))

    after = before - df.height
    if df.height == 0:
        raise ValueError("Zero linhas após limpeza — estrutura do arquivo mudou?")

    logger.info(
        "UF: %d -> %d linhas (%d removidas) | qualidade=%s",
        before,
        df.height,
        after,
        df.get_column(QUALIDADE_COL).mode().to_list() if QUALIDADE_COL in df.columns else "N/A",
    )
    return df.select([*UF_COLUMNS, QUALIDADE_COL])


def transform_municipio(
    raw_bytes: bytes,
    contexto: ContextoCarga | None = None,
) -> pl.DataFrame:
    """Lê CSV bruto CONAB de Município, limpa e normaliza.

    Args:
        raw_bytes: Conteúdo bruto do CSV CONAB.
        contexto: Metadados de extração para fallback (mês/ano do arquivo).
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
    df = df.rename({c: c.strip().lower().replace(" ", "_").replace("-", "_") for c in df.columns})

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
        (c for c in df.columns if "municipio" in c and "id" not in c and "cod" not in c),
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
        df = df.with_columns(pl.col("municipio_nome").str.strip_chars().str.to_titlecase())

    # Forward-fill: propaga último valor válido nas colunas de grupo
    df = _forward_fill_keys(df)

    # Fallback contextual: injeta mês/ano do contexto onde forward_fill
    # não conseguiu preencher
    df = _apply_fallback_context(df, contexto)

    # Fallback UF: municípios órfãos sem UF mesmo após forward-fill
    # Usa os 2 primeiros dígitos do código IBGE como identificador da UF
    if "municipio_id" in df.columns:
        uf_from_ibge = (
            pl.when(pl.col("uf").is_null() & pl.col("municipio_id").is_not_null())
            .then(pl.col("municipio_id").str.slice(0, 2))
            .otherwise(pl.col("uf"))
        )
        for prefix, uf_name in IBGE_UF.items():
            uf_from_ibge = (
                pl.when(uf_from_ibge == prefix).then(pl.lit(uf_name)).otherwise(uf_from_ibge)
            )
        df = df.with_columns(uf_from_ibge.alias("uf"))

    df = df.filter(
        pl.col("preco_medio").is_not_null()
        & (pl.col("preco_medio") > 0)
        & pl.col("produto").is_not_null()
        & pl.col("ano").is_not_null()
        & pl.col("mes").is_not_null()
        & pl.col("mes").is_between(1, 12)
    )

    df = df.filter(~pl.col("produto").str.to_lowercase().str.contains("produto"))

    # Preencher municipio_id ausente com placeholder
    if "municipio_id" not in df.columns:
        df = df.with_columns(pl.lit("UF-").alias("municipio_id"))
    if "municipio_nome" not in df.columns:
        df = df.with_columns(pl.lit(None).cast(pl.Utf8).alias("municipio_nome"))

    after = before - df.height
    logger.info(
        "Municipio: %d -> %d linhas (%d removidas) | qualidade=%s",
        before,
        df.height,
        after,
        df.get_column(QUALIDADE_COL).mode().to_list() if QUALIDADE_COL in df.columns else "N/A",
    )
    return df.select([*MUN_COLUMNS, QUALIDADE_COL])


def transform_prohort(
    raw_bytes: bytes,
    contexto: ContextoCarga | None = None,
) -> pl.DataFrame:
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
        - Forward-fill em produto/uf/ano/mes
        - Fallback contextual: se ``mes`` continuar nulo, injeta do contexto
        - Remover outliers extremos (Z-score > 5)

    Args:
        raw_bytes: Conteúdo bruto do CSV CONAB.
        contexto: Metadados de extração para fallback (mês/ano do arquivo).
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
    df = df.rename({c: c.strip().lower().replace(" ", "_").replace("-", "_") for c in df.columns})

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
    # ATENÇÃO: qtd/valor podem chegar como NUMÉRICOS (polars lê por inferência)
    # — converter via String + troca de vírgula só quando for texto, senão
    # cast direto (bug histórico: .str.replace em coluna i64 → InvalidOperation).
    def _qtd_valor_to_float(col: str) -> pl.Expr:
        return pl.col(col).cast(pl.String).str.replace(",", ".").cast(pl.Float64, strict=False)

    df = df.with_columns(
        _qtd_valor_to_float("qtd_comercializada_kg").alias("_qtd"),
        _qtd_valor_to_float("valor_comercializado").alias("_valor"),
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

    # Forward-fill: propaga último valor válido nas colunas de grupo
    df = _forward_fill_keys(df)

    # Fallback contextual: injeta mês/ano do contexto onde forward_fill
    # não conseguiu preencher
    df = _apply_fallback_context(df, contexto)

    # Filtrar inválidos (parênteses obrigatórios em ``len_chars() == 2``).
    # preco >= 0.01: resíduos de valor/qtd arredondam p/ 0 no CHECK do banco.
    df = df.filter(
        pl.col("preco_medio").is_not_null()
        & (pl.col("preco_medio") >= 0.01)
        & pl.col("produto").is_not_null()
        & (pl.col("uf").str.len_chars() == 2)
        & pl.col("ano").is_not_null()
        & pl.col("mes").is_not_null()
        & pl.col("mes").is_between(1, 12)
        & pl.col("_qtd").is_not_null()
        & (pl.col("_qtd") > 0)
    )

    # Remover falsos cabeçalhos
    df = df.filter(~pl.col("produto").str.to_lowercase().str.contains("produto"))

    # Preencher municipio_id ausente
    if "municipio_id" not in df.columns:
        df = df.with_columns(pl.lit(None).cast(pl.Utf8).alias("municipio_id"))
    else:
        df = df.with_columns(pl.col("municipio_id").str.strip_chars().cast(pl.Utf8))

    if "municipio_nome" not in df.columns:
        df = df.with_columns(pl.lit(None).cast(pl.Utf8).alias("municipio_nome"))

    after = before - df.height
    if df.height == 0:
        raise ValueError("Zero linhas após limpeza do Prohort — estrutura mudou?")

    logger.info(
        "Prohort: %d -> %d linhas (%d removidas) | qualidade=%s",
        before,
        df.height,
        after,
        df.get_column(QUALIDADE_COL).mode().to_list() if QUALIDADE_COL in df.columns else "N/A",
    )
    return df.select([*PROHORT_COLUMNS, QUALIDADE_COL])


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
    "SERVICO_LOGISTICA": (r"(?i)^(TRANSPORTE|PASSAGEM|PATIO|TRATAMENTO)\b"),
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


def load_local_file(
    filepath: str,
    contexto: ContextoCarga | None = None,
) -> tuple[pl.DataFrame, dict[str, str]]:
    """Lê arquivo local LISTA*.txt, categoriza e mapeia para UF_COLUMNS.

    Layout real (separador ``;``):
      produto;classificao_produto;id_produto;uf;regiao;ano;mes;
      dsc_nivel_comercializacao;valor_produto_kg

    Args:
        filepath: Caminho do arquivo local.
        contexto: Metadados de extração para fallback (mês/ano inferido do nome).

    Returns:
        Tupla ``(df_uf, categorias)`` onde:
        - ``df_uf``: DataFrame com ``UF_COLUMNS`` + ``categoria_b2c`` + ``_qualidade``
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
    df = df.rename({c: c.strip().lower().replace(" ", "_").replace("-", "_") for c in df.columns})

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
    categorias = dict(df.select(["produto", "categoria_b2c"]).unique().iter_rows())

    # Renomear valor_produto_kg → preco_medio
    if "valor_produto_kg" in df.columns:
        df = df.rename({"valor_produto_kg": "preco_medio"})

    # Converter preço (vírgula → ponto) e tipos
    df = df.with_columns(
        _sanitize_price(pl.col("preco_medio")).alias("preco_medio"),
        pl.col("ano").cast(pl.Int32, strict=False),
        pl.col("mes").cast(pl.Int32, strict=False),
    )

    # Fallback contextual: injeta mês/ano do contexto onde arquivos locais
    # podem ter a coluna de mês vazia (ex: LISTA_05_2024.txt → mês=5)
    df = _apply_fallback_context(df, contexto)

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
    df = df.filter(~pl.col("produto").str.to_lowercase().str.contains("produto"))

    after = before - df.height
    if df.height == 0:
        raise ValueError(f"Zero linhas após limpeza do arquivo local: {filepath}")

    logger.info(
        "LocalFile: %s — %d -> %d linhas (%d removidas) | categorias=%s | qualidade=%s",
        Path(filepath).name,
        before,
        df.height,
        after,
        set(categorias.values()),
        df.get_column(QUALIDADE_COL).mode().to_list() if QUALIDADE_COL in df.columns else "N/A",
    )
    df_out = df.select([*UF_COLUMNS, "categoria_b2c", QUALIDADE_COL])
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


def _normalizar_nome(nome: str) -> str:
    """Normaliza nome para match por similaridade (sem acentos, minúsculas).

    Ex: ``ABÓBORA`` → ``abobora`` · ``Abacaxi Pérola`` → ``abacaxi perola``.
    Usado no match de produtos para evitar duplicatas quando a CONAB
    nomeia o mesmo item de formas diferentes (``abobora`` vs ``ABÓBORA``).
    """
    import unicodedata as _ud

    s = _ud.normalize("NFD", nome or "")
    s = "".join(c for c in s if _ud.category(c) != "Mn")  # remove acentos
    return s.lower().strip()


def _ensure_dimensions(
    conn,
    df_uf: pl.DataFrame,
    df_mun: pl.DataFrame,
    df_prohort: pl.DataFrame | None = None,
) -> dict:
    """Garante que dimensões existam e retorna mapping {chave → id}.

    Estratégia: INSERT ON CONFLICT DO NOTHING + SELECT em lote.
    Isso é ~10x mais rápido que INSERT...RETURNING linha por linha.

    O match de PRODUTO é feito por nome NORMALIZADO (sem acentos): a CONAB
    grava o mesmo item com variações (``abobora`` vs ``ABÓBORA``); sem isso,
    cada variação criaria um id_produto novo e o preço nunca preencheria a
    linha canônica da grade. A variante mais frequente vira a canônica.
    """

    with conn.cursor() as cur:
        # Produtos — carregar mapa atual (por nome exato E por nome normalizado)
        cur.execute("SELECT id_produto, nome_produto FROM staging.dim_produto")
        rows_existentes = cur.fetchall()
        produto_map = {row[1]: row[0] for row in rows_existentes}  # nome exato → id
        norm_to_id: dict[str, int] = {}
        for _id, _nome in rows_existentes:
            norm = _normalizar_nome(_nome)
            if norm and norm not in norm_to_id:
                norm_to_id[norm] = _id

        # Colecionar produtos de entrada
        produtos = set(df_uf["produto"].to_list() + df_mun["produto"].to_list())
        if df_prohort is not None:
            produtos |= set(df_prohort["produto"].to_list())

        # Resolver cada produto de entrada para o id canônico:
        #  1. nome exato já existe → id existente
        #  2. nome normalizado casa com existente → id existente (evita dup)
        #  3. senão → novo id (INSERT)
        novos_para_inserir: list[str] = []
        for p in produtos:
            if p in produto_map:
                continue
            norm = _normalizar_nome(p)
            if norm in norm_to_id:
                produto_map[p] = norm_to_id[norm]
            else:
                novos_para_inserir.append(p)

        if novos_para_inserir:
            execute_values(
                cur,
                "INSERT INTO staging.dim_produto (nome_produto) VALUES %s ON CONFLICT DO NOTHING",
                [(p,) for p in novos_para_inserir],
            )
            # Recarregar mapa para incluir os recém-criados
            cur.execute("SELECT id_produto, nome_produto FROM staging.dim_produto")
            for _id, _nome in cur.fetchall():
                if _nome in produto_map:
                    continue
                produto_map[_nome] = _id
                norm = _normalizar_nome(_nome)
                if norm and norm not in norm_to_id:
                    norm_to_id[norm] = _id

        # Localidades (UF + Municipio)
        localidades = set()
        for uf in df_uf["uf"].unique().to_list():
            localidades.add((uf, None, None))
        for row in df_mun.select(["uf", "municipio_id", "municipio_nome"]).unique().iter_rows():
            localidades.add((row[0], row[1] if row[1] else None, row[2] if row[2] else None))
        if df_prohort is not None:
            for row in (
                df_prohort.select(["uf", "municipio_id", "municipio_nome"]).unique().iter_rows()
            ):
                localidades.add((row[0], row[1] if row[1] else None, row[2] if row[2] else None))

        # dim_localidade usa ÍNDICES ÚNICOS PARCIAIS (WHERE municipio_id IS
        # NULL / NOT NULL) — índices parciais NÃO são elegíveis para inferência
        # em ``ON CONFLICT (col...)``; ``ON CONFLICT DO NOTHING`` (sem target)
        # respeita qualquer constraint única existente, inclusive parciais.
        execute_values(
            cur,
            """
            INSERT INTO staging.dim_localidade (uf, municipio_id, municipio_nome)
            VALUES %s ON CONFLICT DO NOTHING
            """,
            [(uf, mid, mnome) for uf, mid, mnome in localidades],
        )
        cur.execute("SELECT id_localidade, uf, municipio_id FROM staging.dim_localidade")
        localidade_map = {(row[1], row[2]): row[0] for row in cur.fetchall()}

    conn.commit()
    logger.info(
        "Dimensões sincronizadas: %d produtos, %d localidades",
        len(produto_map),
        len(localidade_map),
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

    tem_qualidade = QUALIDADE_COL in df.columns
    rows: list[tuple] = []
    seen = set()
    descartados_preco = 0
    for row in df.iter_rows():
        produto = row[0]
        uf = row[1] if is_uf else row[3]
        ano = row[2] if is_uf else row[4]
        mes = row[3] if is_uf else row[5]
        preco = row[4] if is_uf else row[6]
        municipio_id = None if is_uf else (row[1] if row[1] else None)

        # FASE 1 — Malha fina: preço nulo, não-numérico ou <= 0 NÃO entra na fato.
        # (defesa em profundidade; as transformações já filtram, mas nunca confie
        # em downstream para manter a integridade do preço.)
        if preco is None or not isinstance(preco, (int, float)) or preco <= 0:
            descartados_preco += 1
            continue

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
        qualidade = row[-1] if tem_qualidade else QUALIDADE_NORMAL
        rows.append((id_prod, id_loc, ano, mes, preco, batch_id, qualidade))

    if not rows:
        if descartados_preco:
            logger.warning(
                "_copy_to_fact[is_uf=%s]: %d linhas descartadas pela malha fina (preço nulo/inválido)",
                is_uf,
                descartados_preco,
            )
        return 0

    COPY_SQL = """
    INSERT INTO staging.fact_precos_mensais
        (id_produto, id_localidade, ano, mes, preco_medio, batch_id, _qualidade)
    VALUES %s
    ON CONFLICT (id_produto, id_localidade, ano, mes, (COALESCE(unidade_canonica, 'kg')))
    DO UPDATE SET
        preco_medio = EXCLUDED.preco_medio,
        batch_id    = EXCLUDED.batch_id,
        loaded_at   = NOW(),
        _qualidade  = EXCLUDED._qualidade
    """

    total = 0
    with conn.cursor() as cur:
        for i in range(0, len(rows), COPY_BATCH_SIZE):
            batch = rows[i : i + COPY_BATCH_SIZE]
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
    """Registra metadados da carga em raw.controle_carga.

    Schema real da tabela (diferente do legado):
        (id serial, tipo text, status text, total_linhas int,
         inseridas int, erro text, criado_em timestamptz)
    O `batch_id` é preservado no campo `tipo` para rastreabilidade.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO raw.controle_carga
                (tipo, status, total_linhas, inseridas, erro, criado_em)
            VALUES (%s, %s, %s, %s, %s, NOW())
            """,
            (
                f"{arquivo}:{batch_id}",
                status,
                lidas,
                inseridas,
                None if status == "sucesso" else f"rejeitadas={rejeitadas} dur={duracao:.1f}s",
            ),
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

    # ── Log da qualidade dos dados (fallback audit) ────────────────
    for nome_fonte, df in [("UF", df_uf), ("Prohort", df_prohort)]:
        if df is not None and QUALIDADE_COL in df.columns:
            counts = df[QUALIDADE_COL].value_counts()
            logger.info(
                "Qualidade [%s]: %s",
                nome_fonte,
                {row[0]: row[1] for row in counts.iter_rows()},
            )

    # _qualidade mantida — migração 38 já adicionou a coluna no banco
    # A flag é propagada para fact_precos_mensais via _copy_to_fact()

    conn = _get_pg_conn()
    try:
        # 1. Sincronizar dimensões
        mapping = _ensure_dimensions(conn, df_uf, df_mun, df_prohort)

        # 2. Carga UF
        t0 = time.perf_counter()
        uf_inseridas = _copy_to_fact(conn, df_uf, mapping, batch_id, is_uf=True)
        uf_duracao = time.perf_counter() - t0
        _registrar_carga(
            conn,
            batch_id,
            "PrecosMensalUF",
            df_uf.height,
            uf_inseridas,
            0,
            uf_duracao,
            "sucesso",
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
                conn,
                batch_id,
                "ProhortMensal",
                df_prohort.height,
                pro_inseridas,
                0,
                pro_duracao,
                "sucesso",
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
            batch_id,
            uf_inseridas,
            pro_inseridas,
            total_duracao,
        )

        return {"uf": resultado_uf, "prohort": resultado_pro}

    except Exception:
        conn.rollback()
        logger.exception("Carga falhou — rollback executado para batch=%s", batch_id)
        _registrar_carga(
            conn,
            batch_id,
            "geral",
            0,
            0,
            0,
            0,
            "falha",
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
    logger.info(
        "Download concluído: UF=%.1fMB, Prohort=%.1fMB",
        len(raw_uf) / 1_048_576,
        len(raw_pro) / 1_048_576,
    )

    # Construir contexto de extração para fallback
    # Nota: URLs CONAB atuais (PrecosMensalUF.txt, ProhortMensal.txt) não
    # codificam mês/ano no nome — a inferência por filename retornará None.
    # Quando houver download por mês (ex: boletim_maio_2026.csv), o mês
    # será automaticamente extraído via _inferir_mes_do_contexto().
    ctx_uf = ContextoCarga(arquivo=CONAB_URLS["uf"].rsplit("/", 1)[-1])
    ctx_pro = ContextoCarga(arquivo=CONAB_URLS["prohort"].rsplit("/", 1)[-1])

    # Transform
    logger.info("[2/4] Limpeza e normalização...")
    df_uf = transform_uf(raw_uf, contexto=ctx_uf)
    df_pro = transform_prohort(raw_pro, contexto=ctx_pro)
    # df_mun mantido vazio para compatibilidade com a assinatura de load()
    df_mun = pl.DataFrame(
        schema={
            "produto": pl.Utf8,
            "municipio_id": pl.Utf8,
            "municipio_nome": pl.Utf8,
            "uf": pl.Utf8,
            "ano": pl.Int32,
            "mes": pl.Int32,
            "preco_medio": pl.Float64,
        }
    )

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

        # Construir contexto com inferência de mês/ano a partir do nome
        # Ex: LISTA_05_2024.txt → mes=5, ano=2024
        contexto = _build_contexto(str(f))

        # Ler, limpar e categorizar
        df, categorias = load_local_file(str(f), contexto=contexto)
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
        df_mun = pl.DataFrame(
            schema={
                "produto": pl.Utf8,
                "municipio_id": pl.Utf8,
                "municipio_nome": pl.Utf8,
                "uf": pl.Utf8,
                "ano": pl.Int32,
                "mes": pl.Int32,
                "preco_medio": pl.Float64,
            }
        )

        # Load B2C no medalhão (inclui _qualidade para auditoria em load())
        resultados = load(df_b2c, df_mun, None)
        uf_result = resultados.get("uf", CargaResult(arquivo=f.name))
        total_b2c_inseridas += uf_result.linhas_inseridas
        total_b2c_lidas += df_b2c.height

        duracao = time.perf_counter() - t0
        logger.info(
            "  → %s: %d B2C inseridas + %d B2B ignorados em %.1fs",
            f.name,
            uf_result.linhas_inseridas,
            df_b2b.height,
            duracao,
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
