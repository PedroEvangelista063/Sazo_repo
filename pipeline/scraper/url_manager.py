from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from datetime import date
from io import BytesIO
from typing import Any

import httpx
import polars as pl
from bs4 import BeautifulSoup

logger = logging.getLogger(__name__)

MESES_NOME = [
    "", "janeiro", "fevereiro", "marco", "abril", "maio", "junho",
    "julho", "agosto", "setembro", "outubro", "novembro", "dezembro",
]

MESES_NOME3 = [
    "", "jan", "fev", "mar", "abr", "mai", "jun",
    "jul", "ago", "set", "out", "nov", "dez",
]


def resolver_url_template(
    template: str,
    ano: int | None = None,
    mes: int | None = None,
    data_ref: date | None = None,
    page: int | None = None,
    uf: str = "",
) -> str:
    if data_ref is None:
        if ano is not None and mes is not None:
            data_ref = date(ano, mes, 1)
        elif ano is not None:
            data_ref = date(ano, 1, 1)
        else:
            data_ref = date.today()

    y = data_ref.year
    m = data_ref.month

    subs: dict[str, str] = {
        "YYYY": f"{y:04d}",
        "YY": f"{y % 100:02d}",
        "MM": f"{m:02d}",
        "M": str(m),
        "YYYY-MM": f"{y:04d}-{m:02d}",
        "ANOMES": f"{y:04d}{m:02d}",
        "DATA": f"{data_ref.day:02d}/{m:02d}/{y:04d}",
        "DATA_ISO": f"{y:04d}-{m:02d}-{data_ref.day:02d}",
        "DATA_BR": f"{data_ref.day:02d}/{m:02d}/{y:04d}",
        "MES_NOME": MESES_NOME[m] if m < len(MESES_NOME) else "",
        "MES_NOME3": MESES_NOME3[m] if m < len(MESES_NOME3) else "",
        "uf": uf.lower().strip(),
        "UF": uf.upper().strip(),
    }

    if page is not None:
        subs["PAGE"] = str(page)

    url = template
    for key, val in subs.items():
        url = url.replace(f"{{{key}}}", val)

    return url


@dataclass
class PaginationConfig:
    page_param: str = "pagina"
    page_start: int = 1
    page_step: int = 1
    max_pages: int = 10
    min_rows_to_paginate: int = 20
    stop_on_empty: bool = True
    stop_on_duplicate: bool = True


@dataclass
class ColumnMapping:
    header_row: bool = False
    produto_col: str | int = 0
    preco_col: str | int = 1
    uf_col: str | int | None = None
    municipio_col: str | int | None = None
    data_col: str | int | None = None
    delimiter: str = ","


BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/125.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7",
}

EXT_PADRAO_PRECO = re.compile(r"R?\$?\s*([\d.,]+)")


def _is_static_url(url: str) -> bool:
    ext = url.rsplit(".", 1)[-1].lower().split("?")[0].split("#")[0]
    return ext in ("csv", "xls", "xlsx")


def _content_type_is_static(content_type: str) -> bool:
    ct = content_type.lower()
    return any(
        k in ct
        for k in (
            "text/csv",
            "application/csv",
            "application/vnd.ms-excel",
            "application/vnd.openxmlformats-officedocument.spreadsheetml",
            "application/octet-stream",
        )
    )


async def baixar_arquivo_estatico(
    url: str,
    columns: ColumnMapping | None = None,
    uf: str = "",
    municipio: str = "",
    fonte: str = "",
    ano: int | None = None,
    mes: int | None = None,
) -> list:  # list[CotacaoRegional]
    ext = url.rsplit(".", 1)[-1].lower().split("?")[0].split("#")[0]

    async with httpx.AsyncClient(
        verify=False, timeout=30.0, headers=BROWSER_HEADERS, follow_redirects=True
    ) as client:
        try:
            logger.info("[StaticFile] Baixando %s", url)
            resp = await client.get(url)
            resp.raise_for_status()
        except Exception as e:
            logger.error("[StaticFile] Download falhou: %s", e)
            return []

        ct = resp.headers.get("content-type", "") or ""
        raw = resp.content

        # Detect CSV by extension or content-type
        if ext in ("csv",) or "csv" in ct:
            return _parse_csv_bytes(
                raw, columns=columns, uf=uf, municipio=municipio,
                fonte=fonte, ano=ano, mes=mes,
            )

        # Detect Excel by extension or content-type
        if ext in ("xls", "xlsx") or "excel" in ct or "spreadsheet" in ct:
            return _parse_excel_bytes(
                raw, ext=ext, columns=columns, uf=uf, municipio=municipio,
                fonte=fonte, ano=ano, mes=mes,
            )

        logger.warning("[StaticFile] Extensao desconhecida: .%s, ct=%s", ext, ct)
        return []


def _parse_csv_bytes(
    raw: bytes,
    columns: ColumnMapping | None,
    uf: str,
    municipio: str,
    fonte: str,
    ano: int | None,
    mes: int | None,
) -> list:
    try:
        df = pl.read_csv(
            BytesIO(raw),
            has_header=bool(columns and columns.header_row),
            separator=(columns.delimiter if columns else ","),
            ignore_errors=True,
            truncate_ragged_lines=True,
        )
    except Exception as e:
        logger.error("[StaticFile CSV] pl.read_csv falhou: %s", e)
        return _parse_csv_fallback(raw, columns, uf, municipio, fonte, ano, mes)

    return _df_para_cotacoes(df, columns, uf, municipio, fonte, ano, mes)


def _parse_excel_bytes(
    raw: bytes,
    ext: str,
    columns: ColumnMapping | None,
    uf: str,
    municipio: str,
    fonte: str,
    ano: int | None,
    mes: int | None,
) -> list:
    engine = "calamine" if ext == "xls" else None
    try:
        df = pl.read_excel(
            BytesIO(raw),
            sheet_id=0,
            engine=engine,
        )
    except Exception as e:
        logger.error("[StaticFile Excel] pl.read_excel falhou: %s", e)
        # Try openpyxl as fallback for .xlsx
        try:
            df = pl.read_excel(BytesIO(raw), sheet_id=0, engine="openpyxl")
        except Exception as e2:
            logger.error("[StaticFile Excel] openpyxl fallback falhou: %s", e2)
            return []

    return _df_para_cotacoes(df, columns, uf, municipio, fonte, ano, mes)


def _df_para_cotacoes(
    df: pl.DataFrame,
    columns: ColumnMapping | None,
    uf: str,
    municipio: str,
    fonte: str,
    ano: int | None,
    mes: int | None,
) -> list:
    from pipeline.scraper.adapters.base import CotacaoRegional
    if df.is_empty():
        return []

    col_mapping: dict[str, str | int] = {}
    if columns:
        col_mapping["produto"] = columns.produto_col
        col_mapping["preco"] = columns.preco_col
        if columns.uf_col is not None:
            col_mapping["uf"] = columns.uf_col
        if columns.municipio_col is not None:
            col_mapping["municipio"] = columns.municipio_col
        if columns.data_col is not None:
            col_mapping["data"] = columns.data_col

    if not columns or not col_mapping:
        # Auto-detect: use first two string/number columns
        col_produto = df.columns[0]
        col_preco = df.columns[1] if len(df.columns) > 1 else df.columns[0]
    else:
        col_produto = _resolve_col(df, col_mapping["produto"])
        col_preco = _resolve_col(df, col_mapping["preco"])
        if col_produto is None:
            col_produto = df.columns[0]
        if col_preco is None:
            col_preco = df.columns[1] if len(df.columns) > 1 else df.columns[0]

    resultados: list[CotacaoRegional] = []
    for row in df.iter_rows(named=True):
        produto = str(row.get(col_produto) or "")
        if not produto or produto.strip() == "" or produto in ("-", "--", ""):
            continue

        preco_raw = row.get(col_preco)
        if preco_raw is None:
            continue

        preco = _parse_valor_estatico(str(preco_raw))
        if preco is None:
            continue

        resultados.append(
            CotacaoRegional(
                produto_original=produto.strip(),
                preco_bruto=preco,
                uf=uf,
                municipio=municipio,
                fonte=fonte,
                ano=ano or 0,
                mes=mes or 0,
                status_coleta="sucesso",
            )
        )

    logger.info("[StaticFile] %d cotacoes extraidas de %d linhas", len(resultados), df.height)
    return resultados


def _parse_csv_fallback(
    raw: bytes,
    columns: ColumnMapping | None,
    uf: str,
    municipio: str,
    fonte: str,
    ano: int | None,
    mes: int | None,
) -> list:
    """Emergency CSV parser when polars fails — split lines, regex for prices."""
    from pipeline.scraper.adapters.base import CotacaoRegional
    text = raw.decode("utf-8", errors="replace")
    resultados: list = []
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split((columns.delimiter if columns else ","))
        if len(parts) < 2:
            continue
        produto = parts[0].strip().strip('"').strip()
        if not produto or len(produto) < 2:
            continue
        preco_raw = parts[1].strip().strip('"').strip()
        preco = _parse_valor_estatico(preco_raw)
        if preco is None:
            continue
        resultados.append(
            CotacaoRegional(
                produto_original=produto,
                preco_bruto=preco,
                uf=uf,
                municipio=municipio,
                fonte=fonte,
                ano=ano or 0,
                mes=mes or 0,
                status_coleta="sucesso",
            )
        )
    return resultados


def _parse_valor_estatico(v: str) -> float | None:
    if not v or v.strip() in ("-", "--", "", "n/d", "N/D", "s/ info", "ND"):
        return None
    v = v.replace("R$", "").replace("r$", "").replace(" ", "")
    v = v.replace(".", "").replace(",", ".")
    m = EXT_PADRAO_PRECO.search(v)
    if not m:
        return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


def _resolve_col(df: pl.DataFrame, col_spec: str | int) -> str | None:
    if isinstance(col_spec, int):
        if col_spec < len(df.columns):
            return df.columns[col_spec]
        return None
    if isinstance(col_spec, str):
        if col_spec in df.columns:
            return col_spec
        # Fuzzy match
        for c in df.columns:
            if col_spec.lower() in c.lower():
                return c
        return None
    return None
