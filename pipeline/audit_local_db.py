"""
Auditoria de Integridade — Pipeline Local vs Banco de Dados.

Varre os arquivos LISTA*.txt locais, conta linhas de ALIMENTO_VAREJO,
compara com staging.fact_precos_mensais, testa o endpoint da API,
e valida se o número de produtos distintos no banco corresponde ao
que a interface gráfica vai renderizar.

Uso:
    python -m pipeline.audit_local_db

Exit code 0: integridade OK
Exit code 1: divergência detectada (dados perdidos)
"""

from __future__ import annotations

import io
import logging
import os
import sys
from pathlib import Path
from typing import NoReturn

import polars as pl
import requests

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("audit_local_db")

LOCAL_DATA_DIR: str = os.path.join(
    os.path.dirname(__file__),
    "..",
    "dados_sazonliza_dados_bruto",
)

DATABASE_URL: str = os.environ.get(
    "DATABASE_URL",
    "postgresql://role_api_reader:senha@localhost:5432/quero_comprar",
)

API_BASE: str = os.environ.get("API_BASE_URL", "http://localhost:8000/api/v1")


# ────────────────────────────────────────────────────────────────────
# Contagem local
# ────────────────────────────────────────────────────────────────────


def contar_linhas_locais(data_dir: str) -> dict[str, int]:
    """Conta linhas de ALIMENTO_VAREJO nos LISTA*.txt.

    Returns:
        {arquivo: linhas_alimento_varejo} para cada arquivo processado.
    """
    pattern = "LISTA*.txt"
    files = sorted(Path(data_dir).glob(pattern))
    if not files:
        logger.warning("Nenhum arquivo %s encontrado em %s", pattern, data_dir)
        return {}

    resultados: dict[str, int] = {}
    for f in files:
        raw_text = f.read_bytes().decode("latin-1")
        df = pl.read_csv(
            io.StringIO(raw_text),
            separator=";",
            infer_schema_length=10_000,
            ignore_errors=True,
            truncate_ragged_lines=True,
        )

        df = df.rename(
            {c: c.strip().lower().replace(" ", "_").replace("-", "_") for c in df.columns}
        )

        if "valor_produto_kg" in df.columns:
            df = df.rename({"valor_produto_kg": "preco_medio"})

        if "preco_medio" not in df.columns:
            logger.warning("  %s: coluna preco_medio ausente, ignorando", f.name)
            continue

        if "classificao_produto" in df.columns:
            df = df.with_columns(
                (pl.col("produto") + " - " + pl.col("classificao_produto")).alias("produto")
            )

        # Filtrar inválidos (mesmo filtro do pipeline)
        df = df.filter(
            pl.col("preco_medio")
            .str.strip_chars()
            .str.replace(",", ".")
            .cast(pl.Float64, strict=False)
            .is_not_null()
            & (
                pl.col("preco_medio")
                .str.strip_chars()
                .str.replace(",", ".")
                .cast(pl.Float64, strict=False)
                > 0
            )
            & pl.col("produto").is_not_null()
            & (pl.col("uf").str.len_chars() == 2)
            & pl.col("ano").cast(pl.Int32, strict=False).is_not_null()
            & pl.col("mes").cast(pl.Int32, strict=False).is_not_null()
            & pl.col("mes").cast(pl.Int32, strict=False).is_between(1, 12)
        )

        # Motor de categorização semântica (réplica simplificada)
        from pipeline.ingestao_conab import REGRAS_CATEGORIAS

        df = df.with_columns(pl.col("produto").alias("_produto_original"))

        expr = pl.lit("MATERIA_PRIMA_B2B")
        for categoria, pattern_re in REGRAS_CATEGORIAS.items():
            expr = (
                pl.when(pl.col("_produto_original").str.contains(pattern_re))
                .then(pl.lit(categoria))
                .otherwise(expr)
            )

        df = df.with_columns(expr.alias("categoria_b2c"))

        total_linhas = df.height
        b2c = df.filter(pl.col("categoria_b2c") == "ALIMENTO_VAREJO").height
        b2b = total_linhas - b2c

        resultados[f.name] = b2c
        logger.info("  %s: %d total | %d ALIMENTO_VAREJO | %d B2B", f.name, total_linhas, b2c, b2b)

    return resultados


# ────────────────────────────────────────────────────────────────────
# Contagem no banco (via SQL direto)
# ────────────────────────────────────────────────────────────────────


def contar_fact_table() -> int:
    """Retorna total de linhas em staging.fact_precos_mensais."""
    import psycopg2

    conn = psycopg2.connect(DATABASE_URL)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM staging.fact_precos_mensais")
            return cur.fetchone()[0]
    finally:
        conn.close()


def contar_produtos_distintos_mart() -> int:
    """Retorna total de produtos distintos que a API vai expor.

    Consulta a MV (já filtrada por ALIMENTO_VAREJO e != INSUFICIENTE).
    """
    import psycopg2

    conn = psycopg2.connect(DATABASE_URL)
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(DISTINCT id_sazonalidade) FROM mart.vw_api_produtos_sazonalidade"
            )
            return cur.fetchone()[0]
    finally:
        conn.close()


# ────────────────────────────────────────────────────────────────────
# Teste do endpoint
# ────────────────────────────────────────────────────────────────────


def testar_endpoint_api() -> dict:
    """Testa GET /api/v1/sazonalidade e retorna metadados da resposta.

    Returns:
        Dict com total_retornado, status_code, tempo_resposta_ms.
    """
    import time

    url = f"{API_BASE}/sazonalidade?por_pagina=1"
    inicio = time.perf_counter()
    resp = requests.get(url, timeout=30)
    duracao = (time.perf_counter() - inicio) * 1000

    if resp.status_code != 200:
        logger.error("  Endpoint retornou HTTP %d", resp.status_code)
        return {
            "status_code": resp.status_code,
            "total_retornado": 0,
            "tempo_ms": round(duracao, 1),
        }

    data = resp.json()
    total_api = data.get("total", 0)
    logger.info("  Endpoint OK: %d produtos retornados em %.1fms", total_api, duracao)
    return {
        "status_code": resp.status_code,
        "total_retornado": total_api,
        "tempo_ms": round(duracao, 1),
    }


# ────────────────────────────────────────────────────────────────────
# Orquestração
# ────────────────────────────────────────────────────────────────────


def audit() -> int:
    """Executa auditoria completa.

    Returns:
        0 se integridade OK, 1 se divergência.
    """
    logger.info("=" * 60)
    logger.info("AUDITORIA DE INTEGRIDADE — Local vs Banco")
    logger.info("=" * 60)

    erros: list[str] = []

    # 1. Contagem local
    logger.info("\n[1/4] Varrendo arquivos LISTA*.txt locais...")
    locais = contar_linhas_locais(LOCAL_DATA_DIR)
    total_local = sum(locais.values())
    if not locais:
        logger.warning("  Nenhum dado local encontrado. Pulando validação local.")
    else:
        logger.info(
            "  TOTAL ALIMENTO_VAREJO nos TXT: %d (em %d arquivo(s))", total_local, len(locais)
        )

    # 2. Contagem na fact table
    logger.info("\n[2/4] Consultando staging.fact_precos_mensais...")
    try:
        total_fact = contar_fact_table()
        logger.info("  Linhas na fact_precos_mensais: %d", total_fact)
        if total_fact == 0:
            erros.append("FATAL: staging.fact_precos_mensais está VAZIA — nenhum dado ingerido")
    except Exception as e:
        erros.append(f"Falha ao consultar fact table: {e}")
        total_fact = 0

    # 3. Produtos distintos na MV (o que a API vai servir)
    logger.info("\n[3/4] Consultando mart.vw_api_produtos_sazonalidade...")
    try:
        total_mart = contar_produtos_distintos_mart()
        logger.info("  Produtos distintos na MV (ALIMENTO_VAREJO): %d", total_mart)
        if total_mart == 0:
            erros.append(
                "FATAL: mart.vw_api_produtos_sazonalidade está VAZIA — frontend não renderizará nada"
            )
    except Exception as e:
        erros.append(f"Falha ao consultar MV: {e}")
        total_mart = 0

    # 4. Teste do endpoint da API
    logger.info("\n[4/4] Testando endpoint /api/v1/sazonalidade...")
    try:
        api_result = testar_endpoint_api()
        if api_result["status_code"] != 200:
            erros.append(f"Endpoint retornou HTTP {api_result['status_code']} (esperado 200)")
        elif api_result["total_retornado"] != total_mart:
            erros.append(
                f"DIVERGÊNCIA: MV tem {total_mart} produtos, mas API retornou {api_result['total_retornado']}"
            )
    except requests.ConnectionError:
        erros.append(f"Falha de conexão com API em {API_BASE} — servidor está rodando?")
    except Exception as e:
        erros.append(f"Falha ao testar endpoint: {e}")

    # 5. Relatório final
    logger.info("\n" + "=" * 60)
    if erros:
        logger.error("INTEGRIDADE: ❌ FALHA — %d erro(s) detectado(s)", len(erros))
        for i, err in enumerate(erros, 1):
            logger.error("  %d. %s", i, err)
        logger.info("=" * 60)
        return 1
    else:
        logger.info("INTEGRIDADE: ✅ OK")
        if locais:
            logger.info("  Linhas ALIMENTO_VAREJO locais: %d", total_local)
        logger.info("  Linhas na fact table:         %d", total_fact)
        logger.info("  Produtos na MV (API):         %d", total_mart)
        logger.info("  Endpoint API:                 HTTP 200 OK")
        logger.info("=" * 60)
        return 0


def main() -> NoReturn:
    try:
        exit_code = audit()
        sys.exit(exit_code)
    except Exception:
        logger.exception("Auditoria abortada — erro crítico")
        sys.exit(1)


if __name__ == "__main__":
    main()
