#!/usr/bin/env python3
"""
Motor de Bulk Ingestion e Deflacao via IBGE SIDRA.

Preenche 2020-2024 no banco local usando duas estrategias:

  1. DEFLACAO VIA IBGE SIDRA (Tabela 7060)
     Precos reais de 2025 -> retroagir mes a mes usando IPCA do IBGE.
     is_interpolado = TRUE, fonte = 'IBGE_SIDRA_MATH_MODEL'.

  2. BULK INGESTION (CONAB ProHort / CEASA)
     Tenta baixar dados de portais abertos.
     is_interpolado = FALSE, fonte = 'CONAB_BULK_CSV'.

  3. RECALCULO: CALL staging.sp_executar_carga_completa() ao final
     (orchestrator desativado — dado historico real; guard is_forecast).

Uso:
    python pipeline/run_bulk_historical_fill.py
    python pipeline/run_bulk_historical_fill.py --deflate-only
    python pipeline/run_bulk_historical_fill.py --bulk-only
    python pipeline/run_bulk_historical_fill.py --dry-run
    python pipeline/run_bulk_historical_fill.py --ano 2023
    python pipeline/run_bulk_historical_fill.py --reset
    python pipeline/run_bulk_historical_fill.py --skip-recalc
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import re
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("bulk_historical")


class GuardIsForecastError(RuntimeError):
    """Falha do guard R-ADD-06: count(is_forecast=TRUE) cresceu apos o recalculo.

    Levantada no pipeline e re-levantada antes do catch generico para que a
    reativacao das engines sinteticas aborte o processo com exit != 0 (CI/operador
    enxerga a falha em vez de um "sucesso" com guard engolido).
    """


DATABASE_URL: str = os.environ.get(
    "DATABASE_URL_ETL",
) or os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/quero_comprar",
)

SIDRA_BASE = "https://apisidra.ibge.gov.br/values"

# --- Mapeamento Produto -> IBGE Subitem -----------------------------------------
# IDs da Tabela 7060 (classificacao C315, subitens IPCA).
# Fonte: /t/7060/n1/all/v/63/p/202001/c315/all via apisidra.ibge.gov.br
PRODUTO_TO_SIDRA: dict[str, dict[str, Any]] = {
    "ABACATE": {"sidra_id": "7277", "sidra_nome": "1103026.Abacate", "grupo": "hortalicas"},
    "ABACAXI": {"sidra_id": "7256", "sidra_nome": "1106003.Abacaxi", "grupo": "frutas"},
    "ALFACE": {"sidra_id": "7242", "sidra_nome": "1105001.Alface", "grupo": "hortalicas"},
    "BANANA": {"sidra_id": "7260", "sidra_nome": "1106008.Banana - prata", "grupo": "frutas"},
    "BATATA": {"sidra_id": "7202", "sidra_nome": "1103003.Batata-inglesa", "grupo": "hortalicas"},
    "BATATA-DOCE": {"sidra_id": "7201", "sidra_nome": "1103002.Batata-doce", "grupo": "hortalicas"},
    "BETERRABA": {"sidra_id": "7250", "sidra_nome": "1105015.Beterraba", "grupo": "hortalicas"},
    "CEBOLA": {"sidra_id": "7215", "sidra_nome": "1103043.Cebola", "grupo": "hortalicas"},
    "CENOURA": {"sidra_id": "7216", "sidra_nome": "1103044.Cenoura", "grupo": "hortalicas"},
    "GOIABA": {"sidra_id": "7281", "sidra_nome": "1106084.Goiaba", "grupo": "frutas"},
    "LARANJA": {"sidra_id": "7279", "sidra_nome": "1106039.Laranja - pera", "grupo": "frutas"},
    "LIMAO": {"sidra_id": "7265", "sidra_nome": "1106015.Limao", "grupo": "frutas"},
    "MACA": {"sidra_id": "7266", "sidra_nome": "1106017.Maca", "grupo": "frutas"},
    "MAMAO": {"sidra_id": "7267", "sidra_nome": "1106018.Mamao", "grupo": "frutas"},
    "MANGA": {"sidra_id": "7268", "sidra_nome": "1106019.Manga", "grupo": "frutas"},
    "MARACUJA": {"sidra_id": "7269", "sidra_nome": "1106020.Maracuja", "grupo": "frutas"},
    "MELANCIA": {"sidra_id": "7270", "sidra_nome": "1106021.Melancia", "grupo": "frutas"},
    "MORANGO": {"sidra_id": "7280", "sidra_nome": "1106051.Morango", "grupo": "frutas"},
    "PEPINO": {"sidra_id": "7251", "sidra_nome": "1105016.Pepino", "grupo": "hortalicas"},
    "PIMENTAO": {"sidra_id": "7213", "sidra_nome": "1103026.Pimentao", "grupo": "hortalicas"},
    "REPOLHO": {"sidra_id": "7248", "sidra_nome": "1105010.Repolho", "grupo": "hortalicas"},
    "TOMATE": {"sidra_id": "7212", "sidra_nome": "1103028.Tomate", "grupo": "hortalicas"},
    "UVA": {"sidra_id": "7276", "sidra_nome": "1106028.Uva", "grupo": "frutas"},
}

SIDRA_GRUPO_ALIMENTACAO = "7170"

FONTE_DEFLACAO = "IBGE_SIDRA_MATH_MODEL"
FONTE_CONAB = "CONAB_BULK_CSV"


@dataclass
class InflacaoRecord:
    ano: int
    mes: int
    variacao_pct: float
    nivel: str


@dataclass
class Stats:
    produtos_processados: int = 0
    linhas_geradas: int = 0
    linhas_inseridas: int = 0
    erros_api: int = 0
    erros_db: int = 0
    inicio: float = 0.0

    def resumo(self) -> str:
        elapsed = time.perf_counter() - self.inicio
        return (
            f"Produtos: {self.produtos_processados} | "
            f"Linhas geradas: {self.linhas_geradas} | "
            f"Linhas inseridas: {self.linhas_inseridas} | "
            f"Erros API: {self.erros_api} | "
            f"Erros DB: {self.erros_db} | "
            f"Tempo: {elapsed:.1f}s"
        )


# ==============================================================================
#  PARTE 1: IBGE SIDRA - Busca de Inflacao
# ==============================================================================


def _extrair_chave_produto(nome_produto: str) -> str | None:
    nome = nome_produto.upper().strip()
    if not nome:
        return None
    if nome in PRODUTO_TO_SIDRA:
        return nome
    for sep in [" - ", " ", "  "]:
        parts = nome.split(sep, 1)
        if parts and parts[0] in PRODUTO_TO_SIDRA:
            return parts[0]
    for chave in PRODUTO_TO_SIDRA:
        if chave in nome:
            return chave
    return None


async def fetch_inflacao_subitem(
    client: httpx.AsyncClient,
    sidra_id: str,
    anos: list[int],
) -> list[InflacaoRecord] | None:
    """Busca variacao mensal IPCA para um subitem na Tabela 7060.

    URL: /t/7060/n1/all/v/63/p/{meses}/c315/{sidra_id}
    D3C = codigo do mes (ex: 202001), V = valor da variacao.
    """
    meses_str = ",".join(str(a * 100 + m) for a in anos for m in range(1, 13))
    url = f"{SIDRA_BASE}/t/7060/n1/all/v/63/p/{meses_str}/c315/{sidra_id}"

    try:
        resp = await client.get(url, timeout=30)
        if resp.status_code != 200:
            return None
        data = resp.json()
        if not data or len(data) < 2:
            return None
    except Exception:  # noqa: BLE001 (resiliencia: loga e segue)
        return None

    records: list[InflacaoRecord] = []
    for row in data[1:]:
        cod_mes = row.get("D3C", "")
        valor_str = row.get("V", "")
        if not cod_mes or not valor_str or valor_str == "...":
            continue
        try:
            ano = int(cod_mes[:4])
            mes = int(cod_mes[4:6])
            valor = float(valor_str.replace(",", "."))
        except (ValueError, IndexError):
            continue
        records.append(InflacaoRecord(ano=ano, mes=mes, variacao_pct=valor, nivel="produto"))

    return records if records else None


async def fetch_inflacao_grupo(
    client: httpx.AsyncClient,
    anos: list[int],
) -> list[InflacaoRecord] | None:
    """Busca variacao mensal IPCA para 'Alimentacao no domicilio' (Tabela 7060).

    URL: /t/7060/n1/all/v/63/p/{meses}/c315/7170
    """
    meses_str = ",".join(str(a * 100 + m) for a in anos for m in range(1, 13))
    url = f"{SIDRA_BASE}/t/7060/n1/all/v/63/p/{meses_str}/c315/{SIDRA_GRUPO_ALIMENTACAO}"

    try:
        resp = await client.get(url, timeout=30)
        if resp.status_code != 200:
            return None
        data = resp.json()
        if not data or len(data) < 2:
            return None
    except Exception:  # noqa: BLE001 (resiliencia: loga e segue)
        return None

    records: list[InflacaoRecord] = []
    for row in data[1:]:
        cod_mes = row.get("D3C", "")
        valor_str = row.get("V", "")
        if not cod_mes or not valor_str:
            continue
        try:
            ano = int(cod_mes[:4])
            mes = int(cod_mes[4:6])
            valor = float(valor_str.replace(",", "."))
        except (ValueError, IndexError):
            continue
        records.append(InflacaoRecord(ano=ano, mes=mes, variacao_pct=valor, nivel="grupo"))

    return records if records else None


async def build_serie_inflacao(
    client: httpx.AsyncClient,
    sidra_id: str | None,
    anos_alvo: list[int],
) -> dict[tuple[int, int], float]:
    result: dict[tuple[int, int], float] = {}

    if sidra_id:
        records = await fetch_inflacao_subitem(client, sidra_id, anos_alvo)
        if records:
            for r in records:
                result[(r.ano, r.mes)] = r.variacao_pct
            logger.debug("  Inflacao subitem OK: %d meses", len(records))
            return result

    records = await fetch_inflacao_grupo(client, anos_alvo)
    if records:
        for r in records:
            result[(r.ano, r.mes)] = r.variacao_pct
        logger.debug("  Inflacao GRUPO alimentacao: %d meses", len(records))
        return result

    logger.warning("  Sem inflacao IBGE para sidra_id=%s", sidra_id)
    return result


# ==============================================================================
#  PARTE 2: Deflacao
# ==============================================================================


def deflacionar(preco_base: float, inflacoes: list[float]) -> list[float]:
    precos: list[float] = []
    current = float(preco_base)
    for var_pct in inflacoes:
        current = current / (1 + var_pct / 100.0)
        precos.append(round(current, 4))
    return precos


# ==============================================================================
#  PARTE 3: CONAB / CEASA Bulk Ingestion
# ==============================================================================


def _validar_conab_bulk_autentico(text: str) -> bool:
    """Valida se o response e realmente um CSV da CONAB, nao HTML."""
    head = text[:200].strip()
    if head.upper().startswith("<!DOCTYPE") or head.startswith("<html"):
        return False
    return ";" in head


def _mapear_conab_para_staging(
    registros_brutos: list[dict[str, Any]],
    dim_produtos: dict[str, int],
    dim_localidades: dict[str, int],
) -> list[dict[str, Any]]:
    """Mapeia CSV CONAB -> schema staging.fact_precos_mensais.

    Tenta reconhecer colunas por nome. Formatos conhecidos do CONAB:
        - produto, uf, municipio, preco_medio, ano, mes
        - descricao, local, valor, ano_mes
        - nome_produto, estado, cidade, valor, referencia
    """
    mapeados: list[dict[str, Any]] = []

    if not registros_brutos:
        return mapeados

    colunas = list(registros_brutos[0].keys())

    # Tentar inferir mapeamento de colunas
    col_produto = _match_col(
        colunas, ["produto", "descricao", "nome_produto", "prod", "hortifruti"]
    )
    col_uf = _match_col(colunas, ["uf", "estado", "uf_sigla"])
    col_municipio = _match_col(colunas, ["municipio", "cidade", "local", "municipio_nome"])
    col_preco = _match_col(colunas, ["preco_medio", "preco", "valor", "vlr", "preco_medio_mensal"])
    col_ano = _match_col(colunas, ["ano", "ano_ref", "ano_referencia"])
    col_mes = _match_col(colunas, ["mes", "mes_ref", "mes_referencia", "periodo"])

    if not col_produto or not col_preco:
        logger.warning("CONAB mapping: colunas essenciais nao encontradas. cols=%s", colunas)
        return mapeados

    for row in registros_brutos:
        nome_prod = str(row.get(col_produto, "")).strip().upper()
        if not nome_prod:
            continue

        id_prod = dim_produtos.get(nome_prod) if nome_prod in dim_produtos else None
        if id_prod is None:
            for chave, pid in dim_produtos.items():
                if chave in nome_prod or nome_prod in chave:
                    id_prod = pid
                    break
        if id_prod is None:
            continue

        uf_raw = str(row.get(col_uf, "")).strip().upper() if col_uf else ""
        municipio_raw = str(row.get(col_municipio, "")).strip().upper() if col_municipio else ""
        chave_loc = f"{uf_raw}|{municipio_raw}" if municipio_raw else uf_raw
        id_loc = dim_localidades.get(chave_loc) if chave_loc in dim_localidades else None
        if id_loc is None:
            chave_uf = uf_raw
            id_loc = dim_localidades.get(chave_uf) if chave_uf in dim_localidades else None
        if id_loc is None:
            continue

        try:
            preco_str = str(row.get(col_preco, "")).replace(".", "").replace(",", ".").strip()
            preco = float(preco_str) if preco_str else 0.0
        except (ValueError, TypeError):
            continue
        if preco <= 0:
            continue

        if col_ano:
            try:
                ano = int(str(row.get(col_ano, "0")).strip())
            except (ValueError, TypeError):
                continue
        else:
            ano = 0

        if col_mes:
            mes_raw = str(row.get(col_mes, "0")).strip()
            try:
                mes = int(mes_raw)
            except ValueError:
                # Tentar extrair mes de string tipo "202401" ou "jan/2024"
                m_match = re.search(r"(\d{2})", mes_raw)
                mes = int(m_match.group(1)) if m_match else 0
        else:
            mes = 0

        if ano <= 0 or mes <= 0 or mes > 12:
            continue

        mapeados.append(
            {
                "id_produto": id_prod,
                "id_localidade": id_loc,
                "ano": ano,
                "mes": mes,
                "preco_medio": round(preco, 4),
            }
        )

    return mapeados


def _match_col(colunas: list[str], candidatos: list[str]) -> str | None:
    col_lower = [c.lower() for c in colunas]
    for cand in candidatos:
        for i, cl in enumerate(col_lower):
            if cand == cl or cand in cl:
                return colunas[i]
    return None


async def try_conab_bulk_download(client: httpx.AsyncClient) -> list[dict[str, Any]]:
    """Tenta baixar dados CONAB via URLs conhecidas."""
    registros: list[dict[str, Any]] = []

    urls = [
        "https://www.conab.gov.br/component/fabrik/list/42?format=csv",
        "https://www.conab.gov.br/component/fabrik/list/48?format=csv",
    ]

    for url in urls:
        try:
            resp = await client.get(url, timeout=30)
            if resp.status_code == 200 and len(resp.text) > 200:
                if _validar_conab_bulk_autentico(resp.text):
                    logger.info("CONAB bulk: %d bytes de %s", len(resp.text), url)
                    registros.extend(_parse_conab_csv(resp.text))
                else:
                    logger.debug("CONAB %s: resposta nao e CSV (HTML recebido)", url)
            else:
                logger.debug("CONAB %s: status=%d", url, resp.status_code)
        except Exception as e:  # noqa: BLE001 (resiliencia: loga e segue)
            logger.warning("CONAB bulk: erro %s: %s", url, e)

    return registros


def _parse_conab_csv(text: str) -> list[dict[str, Any]]:
    lines = text.strip().split("\n")
    if len(lines) < 2:
        return []
    headers = [h.strip().lower() for h in lines[0].split(";")]
    registros: list[dict[str, Any]] = []
    for line in lines[1:]:
        if not line.strip():
            continue
        vals = line.split(";")
        row = dict(zip(headers, vals, strict=False))
        registros.append(row)
    return registros


async def try_prohortweb_csv(client: httpx.AsyncClient) -> list[dict[str, Any]]:
    """Tenta baixar relatorio de preco medio mensal do ProHortweb REST."""
    registros: list[dict[str, Any]] = []
    url = "http://www3.ceasa.gov.br/prohortweb/rest/relatorio/precoMedioMensal"

    for ano in range(2020, 2025):
        payload = {"ano": ano, "mes": 0, "ceasa": "Todas", "formato": "csv"}
        try:
            resp = await client.post(url, json=payload, timeout=60)
            if (
                resp.status_code == 200
                and len(resp.text) > 200
                and _validar_conab_bulk_autentico(resp.text)
            ):
                logger.info("ProHortweb %d: %d bytes", ano, len(resp.text))
                registros.extend(_parse_conab_csv(resp.text))
            else:
                logger.debug("ProHortweb %d: status=%d", ano, resp.status_code)
        except Exception as e:  # noqa: BLE001 (resiliencia: loga e segue)
            logger.debug("ProHortweb %d: %s", ano, e)

    return registros


# ==============================================================================
#  PARTE 4: Motor Principal
# ==============================================================================


class BulkHistoricalFill:
    """Motor de preenchimento historico via deflacao IBGE + bulk CONAB."""

    def __init__(self, db_url: str, dry_run: bool = False):
        self._db_url = db_url
        self._dry_run = dry_run
        self._conn: Any = None
        self._stats = Stats()
        self._cache_inflacao: dict[str, dict[tuple[int, int], float]] = {}
        self._client = httpx.AsyncClient(
            headers={"User-Agent": "QueroComprarVG/1.0 academic-research"},
            follow_redirects=True,
            timeout=httpx.Timeout(30.0, connect=10.0),
        )

    async def __aenter__(self):
        import asyncpg

        self._conn = await asyncpg.connect(self._db_url)
        self._stats.inicio = time.perf_counter()
        return self

    async def __aexit__(self, *args: object) -> None:
        if self._conn:
            await self._conn.close()
        await self._client.aclose()

    # --- OBTER BASE 2025 -------------------------------------------------------

    async def obter_precos_base_2025(
        self, ano_base: int = 2025, mes_base: int = 1
    ) -> list[dict[str, Any]]:
        rows = await self._conn.fetch(
            """
            SELECT DISTINCT ON (f.id_produto, f.id_localidade)
                f.id_produto,
                p.nome_produto,
                f.id_localidade,
                l.uf,
                f.ano,
                f.mes,
                COALESCE(f.preco_curado, f.preco_medio) AS preco_referencia
            FROM staging.fact_precos_mensais f
            JOIN staging.dim_produto p ON p.id_produto = f.id_produto
            JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
            WHERE f.ano = $1 AND f.mes = $2
              AND f.is_interpolado = FALSE
              AND p.status_fonte = 'MAPEADA'
              AND l.uf <> 'BR'
            ORDER BY f.id_produto, f.id_localidade, f.loaded_at DESC
        """,
            ano_base,
            mes_base,
        )
        return [dict(r) for r in rows]

    # --- INFLACAO COM CACHE ----------------------------------------------------

    async def get_inflacao(
        self, chave_produto: str | None, anos_alvo: list[int]
    ) -> dict[tuple[int, int], float]:
        cache_key = chave_produto or "__grupo__"
        if cache_key not in self._cache_inflacao:
            sidra_info = PRODUTO_TO_SIDRA.get(chave_produto) if chave_produto else None
            sidra_id = sidra_info["sidra_id"] if sidra_info else None
            logger.info(
                "  Buscando inflacao: produto=%s sidra_id=%s",
                chave_produto,
                sidra_id or "GRUPO",
            )
            serie = await build_serie_inflacao(self._client, sidra_id, anos_alvo)
            self._cache_inflacao[cache_key] = serie
            if not serie:
                logger.warning("  Sem inflacao para %s", chave_produto)
                self._stats.erros_api += 1
        return self._cache_inflacao[cache_key]

    # --- DEFLAR UM PRODUTO -----------------------------------------------------

    async def deflar_produto(
        self,
        produto: dict[str, Any],
        anos_alvo: list[int],
    ) -> list[dict[str, Any]]:
        nome_prod = produto["nome_produto"]
        chave = _extrair_chave_produto(nome_prod)
        preco_base = float(produto["preco_referencia"])
        id_produto = produto["id_produto"]
        id_localidade = produto["id_localidade"]
        uf = produto["uf"]
        ano_base = produto["ano"]
        mes_base = produto["mes"]

        serie_inflacao = await self.get_inflacao(chave, anos_alvo)
        if not serie_inflacao:
            return []

        inflacoes_chain: list[float] = []
        meses_chain: list[tuple[int, int]] = []

        current_ano = ano_base
        current_mes = mes_base

        while True:
            current_mes -= 1
            if current_mes < 1:
                current_mes = 12
                current_ano -= 1

            if current_ano < min(anos_alvo):
                break
            if current_ano == min(anos_alvo) and current_mes < 1:
                break

            var = serie_inflacao.get((current_ano, current_mes))
            if var is None:
                logger.debug(
                    "  Sem inflacao para %04d/%02d (prod=%s)",
                    current_ano,
                    current_mes,
                    nome_prod,
                )
                continue

            inflacoes_chain.append(var)
            meses_chain.append((current_ano, current_mes))

        if not inflacoes_chain:
            return []

        inflacoes_chain.reverse()
        meses_chain.reverse()

        precos = deflacionar(preco_base, inflacoes_chain)

        resultados: list[dict[str, Any]] = []
        for (ano, mes), preco in zip(meses_chain, precos):
            resultados.append(
                {
                    "id_produto": id_produto,
                    "id_localidade": id_localidade,
                    "ano": ano,
                    "mes": mes,
                    "preco_medio": preco,
                    "uf": uf,
                    "nome_produto": nome_prod,
                }
            )

        return resultados

    # --- INSERIR NO BANCO ------------------------------------------------------

    async def inserir_lote(
        self,
        linhas: list[dict[str, Any]],
        is_interpolado: bool = True,
        fonte: str = FONTE_DEFLACAO,
    ) -> int:
        if not linhas:
            return 0

        inseridas = 0
        batch_size = 500

        for i in range(0, len(linhas), batch_size):
            batch = linhas[i : i + batch_size]
            values_clauses: list[str] = []
            params: list[Any] = []
            idx = 0

            batch_id = str(uuid.uuid4())
            for row in batch:
                idx += 1
                p = idx
                values_clauses.append(
                    f"(${p}, ${p + 1}, ${p + 2}, ${p + 3}, ${p + 4}, ${p + 5}, ${p + 6}, ${p + 7}, ${p + 8})"
                )
                params.extend(
                    [
                        row["id_produto"],
                        row["id_localidade"],
                        row["ano"],
                        row["mes"],
                        row["preco_medio"],
                        is_interpolado,
                        datetime.now(UTC),
                        fonte,
                        batch_id,
                    ]
                )
                idx += 8

            sql = f"""
                INSERT INTO staging.fact_precos_mensais
                    (id_produto, id_localidade, ano, mes, preco_medio, is_interpolado, loaded_at, fonte, batch_id)
                VALUES {", ".join(values_clauses)}
                ON CONFLICT ON CONSTRAINT uq_fact_precos_mensais
                DO UPDATE SET preco_medio = EXCLUDED.preco_medio,
                              is_interpolado = EXCLUDED.is_interpolado,
                              loaded_at = EXCLUDED.loaded_at,
                              fonte = EXCLUDED.fonte,
                              batch_id = EXCLUDED.batch_id
                WHERE staging.fact_precos_mensais.is_interpolado = TRUE
            """

            if self._dry_run:
                logger.info("  [DRY-RUN] Inseriria %d linhas (fonte=%s)", len(batch), fonte)
                inseridas += len(batch)
            else:
                try:
                    result = await self._conn.execute(sql, *params)
                    parts = result.split()
                    if len(parts) >= 3:
                        inseridas += int(parts[2])
                    else:
                        inseridas += len(batch)
                except Exception as e:  # noqa: BLE001 (resiliencia: loga e segue)
                    logger.error("  Erro DB batch: %s", e)
                    self._stats.erros_db += 1

        return inseridas

    # --- EXECUTAR DEFLACAO -----------------------------------------------------

    async def executar_deflacao(
        self,
        anos_alvo: list[int],
        ano_base: int = 2025,
        mes_base: int = 1,
    ) -> None:
        logger.info("=" * 60)
        logger.info("DEFLACAO IBGE SIDRA")
        logger.info(
            "Base: %04d/%02d | Alvo: %d-%d", ano_base, mes_base, min(anos_alvo), max(anos_alvo)
        )
        logger.info("Fonte: %s", FONTE_DEFLACAO)
        logger.info("=" * 60)

        precos_base = await self.obter_precos_base_2025(ano_base, mes_base)
        logger.info("Precos base carregados: %d (produto,localidade)", len(precos_base))

        self._stats.produtos_processados = len(precos_base)
        todas_linhas: list[dict[str, Any]] = []

        for i, prod in enumerate(precos_base):
            if (i + 1) % 50 == 0:
                logger.info(
                    "  Progresso: %d/%d produtos | linhas=%d",
                    i + 1,
                    len(precos_base),
                    len(todas_linhas),
                )
            try:
                linhas = await self.deflar_produto(prod, anos_alvo)
                todas_linhas.extend(linhas)
            except Exception as e:  # noqa: BLE001 (resiliencia: loga e segue)
                logger.error(
                    "  Erro deflando %s (prod_id=%d loc_id=%d): %s",
                    prod["nome_produto"],
                    prod["id_produto"],
                    prod["id_localidade"],
                    e,
                )
                self._stats.erros_db += 1

        self._stats.linhas_geradas = len(todas_linhas)
        logger.info("Total linhas geradas: %d", len(todas_linhas))

        if todas_linhas:
            inseridas = await self.inserir_lote(
                todas_linhas, is_interpolado=True, fonte=FONTE_DEFLACAO
            )
            self._stats.linhas_inseridas = inseridas
            logger.info("Total linhas inseridas (deflacao): %d", inseridas)

    # --- REMOVER INTERPOLADOS (reset) ------------------------------------------

    async def limpar_interpolados(self) -> int:
        if self._dry_run:
            count = await self._conn.fetchval(
                "SELECT count(*) FROM staging.fact_precos_mensais WHERE is_interpolado = TRUE"
            )
            logger.info("[DRY-RUN] Removeria %d registros interpolados", count)
            return count

        result = await self._conn.execute(
            "DELETE FROM staging.fact_precos_mensais WHERE is_interpolado = TRUE"
        )
        parts = result.split()
        count = int(parts[-1]) if len(parts) >= 2 else 0
        logger.info("Registros interpolados removidos: %d", count)
        return count

    # --- EXECUTAR BULK CONAB ---------------------------------------------------

    async def _carregar_dimensoes(self) -> tuple[dict[str, int], dict[str, int]]:
        """Retorna (produtos_por_nome, localidades_por_uf_municipio)."""
        prods = await self._conn.fetch("""
            SELECT id_produto, upper(trim(nome_produto)) AS nome
            FROM staging.dim_produto
        """)
        produtos: dict[str, int] = {r["nome"]: r["id_produto"] for r in prods}

        locs = await self._conn.fetch("""
            SELECT id_localidade, uf, upper(trim(coalesce(municipio_nome, ''))) AS cidade
            FROM staging.dim_localidade
        """)
        localidades: dict[str, int] = {}
        for r in locs:
            uf = r["uf"].strip()
            localidades[uf] = r["id_localidade"]
            if r["cidade"]:
                localidades[f"{uf}|{r['cidade']}"] = r["id_localidade"]
        return produtos, localidades

    async def executar_bulk_conab(self) -> None:
        logger.info("=" * 60)
        logger.info("BULK INGESTION - CONAB / ProHort / CEASA")
        logger.info("=" * 60)

        registros = await try_conab_bulk_download(self._client)
        if not registros:
            logger.info("Tentando ProHortweb...")
            registros = await try_prohortweb_csv(self._client)

        if not registros:
            logger.warning(
                "CONAB: fontes temporariamente indisponiveis "
                "(site CONAB migrado para gov.br, ProHortweb REST 404). "
                "Tentativa manual: www.conab.gov.br/info-agro/analises-do-mercado"
            )
            return

        logger.info("Registros CONAB baixados: %d", len(registros))

        produtos, localidades = await self._carregar_dimensoes()
        logger.info(
            "Dimensoes: %d produtos, %d localidades",
            len(produtos),
            len(localidades),
        )

        mapeados = _mapear_conab_para_staging(registros, produtos, localidades)
        logger.info("Registros mapeados para staging: %d", len(mapeados))

        if not mapeados:
            logger.warning("Nenhum registro CONAB mapeado (formato CSV desconhecido)")
            return

        inseridas = await self.inserir_lote(mapeados, is_interpolado=False, fonte=FONTE_CONAB)
        logger.info("Linhas CONAB inseridas: %d", inseridas)
        self._stats.linhas_inseridas += inseridas

    # --- RECALCULAR SAZONALIDADE -----------------------------------------------

    async def recarregar_sazonalidade(self) -> None:
        logger.info("=" * 60)
        logger.info("RECALCULO - refresh real (engines sinteticas desativadas)")
        logger.info("=" * 60)

        if self._dry_run:
            logger.info(
                "[DRY-RUN] Chamaria CALL staging.sp_executar_carga_completa() (engines sinteticas desativadas)"
            )
            return

        try:
            # Guard (R-ADD-06): linhas sinteticas NAO podem crescer — se crescerem,
            # as engines V13/sanduiche foram (re)ativadas e o deploy esta errado.
            n_fc_antes = await self._conn.fetchval(
                "SELECT count(*) FROM mart.sazonalidade_produto WHERE is_forecast = TRUE"
            )
            logger.info("is_forecast antes do recalculo: %s", n_fc_antes)

            # Orchestrator desativado (database/63 + 000021): steps 5-6 (V13/sanduiche)
            # viram no-op guards + RAISE NOTICE; step 7 faz o refresh da MV.
            # Dado exibido passa a ser o historico real com ano ancora (N->N-1->N-2).
            await self._conn.execute("CALL staging.sp_executar_carga_completa()")

            n_fc_depois = await self._conn.fetchval(
                "SELECT count(*) FROM mart.sazonalidade_produto WHERE is_forecast = TRUE"
            )
            logger.info("is_forecast depois do recalculo: %s", n_fc_depois)
            if n_fc_depois > n_fc_antes:
                raise GuardIsForecastError(
                    f"GUARD is_forecast FALHOU: count(is_forecast=TRUE) cresceu de "
                    f"{n_fc_antes} para {n_fc_depois} — engines sinteticas foram (re)ativadas"
                )
            logger.info("Recalculo concluido com sucesso (dado historico real + MV refresh)!")
        except GuardIsForecastError:
            # Guard R-ADD-06: nunca engolir — reativacao de engines sinteticas DEVE
            # abortar o pipeline (exit != 0) para CI/operador enxergar a falha.
            raise
        except Exception as e:  # noqa: BLE001 (resiliencia: loga e segue)
            logger.error("Erro no recalculo: %s", e)
            self._stats.erros_db += 1

    # --- RESUMO -----------------------------------------------------------------

    async def mostrar_cobertura(self) -> None:
        rows = await self._conn.fetch("""
            SELECT ano, mes,
                   count(DISTINCT id_produto) as produtos,
                   bool_or(is_interpolado) as tem_interpolado
            FROM staging.fact_precos_mensais
            GROUP BY ano, mes
            ORDER BY ano, mes
        """)
        print(f"\n{'=' * 62}")
        print(f"  COBERTURA ATUAL ({datetime.now().astimezone():%Y-%m-%d %H:%M})")
        print(f"{'=' * 62}")
        for r in rows:
            flag = " I" if r["tem_interpolado"] else "  "
            print(f"  {r['ano']:4d}/{r['mes']:02d}: {r['produtos']:>4d} produtos{flag}")


# ==============================================================================
#  ENTRYPOINT
# ==============================================================================


async def main() -> None:
    parser = argparse.ArgumentParser(
        description="Bulk Historical Fill - Preenche 2020-2024 via IBGE SIDRA + CONAB"
    )
    parser.add_argument("--deflate-only", action="store_true", help="So IBGE deflacao")
    parser.add_argument("--bulk-only", action="store_true", help="So CONAB bulk")
    parser.add_argument("--dry-run", action="store_true", help="Simula sem inserir")
    parser.add_argument("--ano", type=int, default=None, help="Ano alvo especifico")
    parser.add_argument("--reset", action="store_true", help="Remove interpolados antes")
    parser.add_argument("--ano-base", type=int, default=2025, help="Ano base (deflacao)")
    parser.add_argument("--mes-base", type=int, default=1, help="Mes base (deflacao)")
    parser.add_argument("--skip-recalc", action="store_true", help="Pula procedure de recalculo")
    args = parser.parse_args()

    anos_alvo: list[int]
    if args.ano:
        anos_alvo = [args.ano]
    else:
        anos_alvo = [2020, 2021, 2022, 2023, 2024]

    async with BulkHistoricalFill(DATABASE_URL, dry_run=args.dry_run) as engine:
        if args.reset:
            await engine.limpar_interpolados()

        await engine.mostrar_cobertura()

        if not args.bulk_only:
            await engine.executar_deflacao(anos_alvo, args.ano_base, args.mes_base)

        if not args.deflate_only:
            await engine.executar_bulk_conab()

        if not args.skip_recalc:
            await engine.recarregar_sazonalidade()

        await engine.mostrar_cobertura()

        print(f"\n{'=' * 62}")
        print("  RESUMO DA EXECUCAO")
        print(f"{'=' * 62}")
        print(f"  {engine._stats.resumo()}")
        print(f"  Cache de inflacao: {len(engine._cache_inflacao)} produtos/entradas")


if __name__ == "__main__":
    if sys.platform == "win32":
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    asyncio.run(main())
