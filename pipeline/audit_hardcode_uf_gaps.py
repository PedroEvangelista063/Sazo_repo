"""
Auditoria Hardcode — Gap Analysis UF x Mês x Ano
==================================================

Uso:
    python -m pipeline.audit_hardcode_uf_gaps
    python -m pipeline.audit_hardcode_uf_gaps --db-url "postgresql://..."
    python -m pipeline.audit_hardcode_uf_gaps --verbose
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, NoReturn

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("audit_hardcode_uf_gaps")

if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

DATABASE_URL: str = os.environ.get(
    "DATABASE_URL_ETL",
) or os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/quero_comprar",
)

TODAS_UFS_BR = [
    "AC", "AL", "AP", "AM", "BA", "CE", "DF", "ES", "GO",
    "MA", "MT", "MS", "MG", "PA", "PB", "PR", "PE", "PI",
    "RJ", "RN", "RS", "RO", "RR", "SC", "SP", "SE", "TO",
]

ANO_INICIO = 2025
ANO_FIM = 2026
MES_INICIO = 1
MES_FIM = 7


def _meses_range() -> list[tuple[int, int]]:
    meses: list[tuple[int, int]] = []
    for ano in range(ANO_INICIO, ANO_FIM + 1):
        m_inicio = MES_INICIO if ano == ANO_INICIO else 1
        m_fim = MES_FIM if ano == ANO_FIM else 12
        for mes in range(m_inicio, m_fim + 1):
            meses.append((ano, mes))
    return meses


# ──────────────────────────────────────────────────────────────
# AUDIT 1: Matriz UF x Mês
# ──────────────────────────────────────────────────────────────


async def audit_matriz_uf_mes(conn) -> dict[str, Any]:
    logger.info("=" * 60)
    logger.info("AUDIT 1: MATRIZ UF x MÊS (produtos ALIMENTO_VAREJO)")
    logger.info("=" * 60)

    total_b2c = await conn.fetchval(
        "SELECT count(*) FROM staging.dim_produto WHERE categoria_b2c = 'ALIMENTO_VAREJO'"
    )
    logger.info("  Total ALIMENTO_VAREJO na dim_produto: %d", total_b2c)

    total_mapeado = await conn.fetchval(
        "SELECT count(*) FROM staging.dim_produto WHERE status_fonte = 'MAPEADA'"
    )
    logger.info("  Total MAPEADOS: %d", total_mapeado)

    rows = await conn.fetch("""
        SELECT
            l.uf,
            f.ano,
            f.mes,
            count(DISTINCT f.id_produto) AS qtd_produtos
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
        JOIN staging.dim_produto p ON p.id_produto = f.id_produto
        WHERE p.categoria_b2c = 'ALIMENTO_VAREJO'
        GROUP BY l.uf, f.ano, f.mes
        ORDER BY l.uf, f.ano, f.mes
    """)

    matriz: dict[str, dict[str, int]] = {}
    for row in rows:
        uf = row["uf"]
        periodo = f"{row['ano']:04d}-{row['mes']:02d}"
        if uf not in matriz:
            matriz[uf] = {}
        matriz[uf][periodo] = row["qtd_produtos"]

    return {
        "total_b2c": total_b2c,
        "total_mapeado": total_mapeado,
        "matriz": matriz,
    }


def _imprimir_matriz(matriz_data: dict[str, Any]) -> None:
    total_b2c = matriz_data["total_b2c"]
    total_mapeado = matriz_data["total_mapeado"]
    matriz = matriz_data["matriz"]

    meses = _meses_range()
    cabecalho = "UF      " + " ".join(f"{a:04d}-{m:02d}" for a, m in meses)
    print()
    print("MATRIZ DE COBERTURA — UF x MÊS (qtd ALIMENTO_VAREJO)")
    print(f"  Baseline: {total_b2c} ALIMENTO_VAREJO | {total_mapeado} MAPEADOS")
    print()
    print(cabecalho)
    print("-" * len(cabecalho))

    for uf in sorted(matriz.keys()):
        linha = f"{uf:7s}"
        for ano, mes in meses:
            periodo = f"{ano:04d}-{mes:02d}"
            qtd = matriz.get(uf, {}).get(periodo, 0)
            if qtd == 0:
                linha += "  ....."
            else:
                linha += f"  {qtd:5d}"
        print(linha)

    print()
    ausentes = [uf for uf in TODAS_UFS_BR if uf not in matriz]
    if ausentes:
        print(f"UFs SEM NENHUM DADO: {', '.join(ausentes)}")
    else:
        print("Todas as 27 UFs têm pelo menos algum dado.")
    print()


# ──────────────────────────────────────────────────────────────
# AUDIT 2: Lacunas absolutas por UF
# ──────────────────────────────────────────────────────────────


async def audit_lacunas_absolutas(conn) -> dict[str, Any]:
    logger.info("=" * 60)
    logger.info("AUDIT 2: LACUNAS ABSOLUTAS POR UF (zero MAPEADOS no mês)")
    logger.info("=" * 60)

    uf_rows = await conn.fetch("""
        SELECT DISTINCT l.uf
        FROM staging.dim_localidade l
        JOIN staging.fact_precos_mensais f ON f.id_localidade = l.id_localidade
        ORDER BY l.uf
    """)
    ufs_no_banco = [r["uf"] for r in uf_rows]

    lacunas: list[dict] = []
    uf_scores: dict[str, dict] = {}

    for uf in ufs_no_banco:
        meses_com_dados = 0
        meses_possiveis = 0
        lacunas_uf: list[str] = []

        for ano, mes in _meses_range():
            meses_possiveis += 1
            qtd = await conn.fetchval(
                """
                SELECT count(DISTINCT f.id_produto)
                FROM staging.fact_precos_mensais f
                JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
                JOIN staging.dim_produto p ON p.id_produto = f.id_produto
                WHERE l.uf = $1 AND f.ano = $2 AND f.mes = $3
                  AND p.status_fonte = 'MAPEADA'
                """,
                uf, ano, mes,
            )
            if qtd == 0:
                lacunas.append({"uf": uf, "ano": ano, "mes": mes, "periodo": f"{ano:04d}-{mes:02d}"})
                lacunas_uf.append(f"{ano:04d}-{mes:02d}")
            else:
                meses_com_dados += 1

        score = round(meses_com_dados / meses_possiveis * 100, 1) if meses_possiveis > 0 else 0.0
        uf_scores[uf] = {
            "meses_com_dados": meses_com_dados,
            "meses_possiveis": meses_possiveis,
            "score_pct": score,
            "lacunas": lacunas_uf,
        }

    return {
        "total_ufs_no_banco": len(ufs_no_banco),
        "total_lacunas": len(lacunas),
        "lacunas": lacunas,
        "uf_scores": uf_scores,
    }


def _imprimir_lacunas(lacunas_data: dict[str, Any]) -> None:
    uf_scores = lacunas_data["uf_scores"]
    total_lacunas = lacunas_data["total_lacunas"]

    print(f"\nTotal de lacunas (UF-mês com zero MAPEADOS): {total_lacunas}")
    print()
    ranking = sorted(uf_scores.items(), key=lambda x: x[1]["score_pct"])
    print(f"{'UF':5s} {'Score':>7s} {'Dados':>6s} {'Total':>6s}  Lacunas")
    print("-" * 70)
    for uf, info in ranking:
        lac_str = ", ".join(info["lacunas"][:6])
        if len(info["lacunas"]) > 6:
            lac_str += f"... (+{len(info['lacunas']) - 6})"
        print(f"{uf:5s} {info['score_pct']:6.1f}% {info['meses_com_dados']:5d} "
              f"{info['meses_possiveis']:5d}  {lac_str}")
    print()


# ──────────────────────────────────────────────────────────────
# AUDIT 3: Produtos órfãos por UF
# ──────────────────────────────────────────────────────────────


async def audit_produtos_orfao_por_uf(conn) -> dict[str, Any]:
    logger.info("=" * 60)
    logger.info("AUDIT 3: PRODUTOS ÓRFÃOS POR UF")
    logger.info("=" * 60)

    rows = await conn.fetch("""
        SELECT
            l.uf,
            p.id_produto,
            p.nome_produto,
            COUNT(*) FILTER (WHERE f.ano = 2025) AS qtd_2025,
            COUNT(*) FILTER (WHERE f.ano = 2026) AS qtd_2026,
            MAX(f.ano * 100 + f.mes) AS ultimo_periodo
        FROM staging.dim_produto p
        CROSS JOIN staging.dim_localidade l
        LEFT JOIN staging.fact_precos_mensais f
            ON f.id_produto = p.id_produto
            AND f.id_localidade = l.id_localidade
        WHERE p.status_fonte = 'MAPEADA'
          AND l.municipio_id = ''
        GROUP BY l.uf, p.id_produto, p.nome_produto
        HAVING COUNT(*) FILTER (WHERE f.ano = 2025) > 0
           AND COUNT(*) FILTER (WHERE f.ano = 2026) = 0
        ORDER BY l.uf, p.nome_produto
    """)

    orfaos: dict[str, list[dict]] = {}
    for row in rows:
        uf = row["uf"]
        if uf not in orfaos:
            orfaos[uf] = []
        orfaos[uf].append({
            "id_produto": row["id_produto"],
            "nome_produto": row["nome_produto"],
            "qtd_2025": row["qtd_2025"],
            "ultimo_periodo": row["ultimo_periodo"],
        })

    return {
        "total_orfao": sum(len(v) for v in orfaos.values()),
        "ufs_com_orfao": len(orfaos),
        "orfao_por_uf": orfaos,
    }


def _imprimir_orfao_uf(orfao_data: dict[str, Any]) -> None:
    orfaos = orfao_data["orfao_por_uf"]
    print(f"\nProdutos órfãos por UF (MAPEADOS — 2025 OK, 2026 ZERO)")
    print(f"Total: {orfao_data['total_orfao']} em {orfao_data['ufs_com_orfao']} UFs")
    print()
    for uf in sorted(orfaos.keys()):
        items = orfaos[uf]
        print(f"  {uf}: {len(items)} órfãos")
        for item in items[:5]:
            print(f"    id={item['id_produto']:4d} {item['nome_produto'][:42]:42s}  "
                  f"2025:{item['qtd_2025']}  último:{item['ultimo_periodo']}")
        if len(items) > 5:
            print(f"    ... +{len(items) - 5}")
    print()


# ──────────────────────────────────────────────────────────────
# AUDIT 4: Score de completude
# ──────────────────────────────────────────────────────────────


async def audit_score_completude(conn) -> dict[str, Any]:
    logger.info("=" * 60)
    logger.info("AUDIT 4: SCORE DE COMPLETUDE (UF vs MAPEADOS)")
    logger.info("=" * 60)

    total_mapeado = await conn.fetchval(
        "SELECT count(*) FROM staging.dim_produto WHERE status_fonte = 'MAPEADA'"
    )
    rows = await conn.fetch("""
        SELECT
            l.uf,
            f.ano,
            f.mes,
            count(DISTINCT f.id_produto) AS qtd
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
        JOIN staging.dim_produto p ON p.id_produto = f.id_produto
        WHERE p.status_fonte = 'MAPEADA'
        GROUP BY l.uf, f.ano, f.mes
        ORDER BY l.uf, f.ano, f.mes
    """)

    completude: dict[str, dict] = {}
    for row in rows:
        uf = row["uf"]
        if uf not in completude:
            completude[uf] = {"total_possivel": 0, "total_real": 0, "meses": {}}
        periodo = f"{row['ano']:04d}-{row['mes']:02d}"
        pct = round(row["qtd"] / total_mapeado * 100, 1) if total_mapeado > 0 else 0.0
        completude[uf]["meses"][periodo] = {"qtd": row["qtd"], "pct": pct}
        completude[uf]["total_real"] += row["qtd"]

    meses_len = len(_meses_range())
    for uf in completude:
        completude[uf]["total_possivel"] = total_mapeado * meses_len
        completude[uf]["score_geral_pct"] = round(
            completude[uf]["total_real"] / completude[uf]["total_possivel"] * 100, 1
        ) if completude[uf]["total_possivel"] > 0 else 0.0

    return {"total_mapeado": total_mapeado, "completude": completude}


def _imprimir_score(score_data: dict[str, Any]) -> None:
    completude = score_data["completude"]
    print(f"\nRANKING DE COMPLETUDE POR UF (vs {score_data['total_mapeado']} MAPEADOS)")
    print(f"{'UF':5s} {'Score':>7s} {'Real':>7s} {'Possivel':>9s}")
    print("-" * 35)
    ranking = sorted(completude.items(), key=lambda x: x[1]["score_geral_pct"], reverse=True)
    for uf, info in ranking:
        print(f"{uf:5s} {info['score_geral_pct']:6.1f}% {info['total_real']:6d} / {info['total_possivel']:6d}")
    print()


# ──────────────────────────────────────────────────────────────
# AUDIT 5: Fontes
# ──────────────────────────────────────────────────────────────


async def audit_fontes_por_uf(conn) -> dict[str, list[dict]]:
    logger.info("=" * 60)
    logger.info("AUDIT 5: FONTES POR UF")
    logger.info("=" * 60)

    logger.info("=" * 60)
    logger.info("AUDIT 5: FONTES POR UF — tabela fato_cotacao_regional não existe")
    logger.info("(migração 15 não aplicada — pulando)")
    logger.info("=" * 60)
    return {}

    fontes: dict[str, list[dict]] = {}
    for row in rows:
        uf = row["uf"]
        if uf not in fontes:
            fontes[uf] = []
        fontes[uf].append({
            "fonte": row["fonte"],
            "qtd_linhas": row["qtd_linhas"],
            "qtd_produtos": row["qtd_produtos"],
            "primeiro": row["primeiro_periodo"],
            "ultimo": row["ultimo_periodo"],
        })
    return fontes


def _imprimir_fontes(fontes_data: dict[str, list[dict]]) -> None:
    if not fontes_data:
        print("\nNenhum dado de fonte disponível.")
        return
    print(f"\nFONTES ATIVAS POR UF (fato_cotacao_regional)")
    print("-" * 80)
    for uf in sorted(fontes_data.keys()):
        items = fontes_data[uf]
        print(f"{uf}: {len(items)} fonte(s)")
        for f in items:
            print(f"    {f['fonte']:25s}  {f['qtd_linhas']:5d} linhas  "
                  f"{f['qtd_produtos']:3d} produtos  {f['primeiro']}..{f['ultimo']}")
    print()


# ──────────────────────────────────────────────────────────────
# SALVAR JSON
# ──────────────────────────────────────────────────────────────


def _salvar_json(resultados: dict[str, Any], path: str | Path) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(resultados, indent=2, ensure_ascii=False, default=str), encoding="utf-8")
    logger.info("JSON salvo: %s (%d bytes)", path, path.stat().st_size)


# ──────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────


async def main_async() -> None:
    parser = argparse.ArgumentParser(description="Auditoria Hardcode — UF Coverage Gaps")
    parser.add_argument("--db-url", default=DATABASE_URL, help="PostgreSQL URL")
    parser.add_argument("--verbose", "-v", action="store_true", help="Detalhes extras")
    parser.add_argument("--json", type=str, default="", help="Salvar resultado em JSON")
    args = parser.parse_args()

    logger.info("=" * 60)
    logger.info("AUDITORIA HARDCODE — GAP ANALYSIS UF x MÊS x ANO")
    logger.info("Database: %s", args.db_url)
    logger.info("Range: %04d-%02d a %04d-%02d", ANO_INICIO, MES_INICIO, ANO_FIM, MES_FIM)
    logger.info("=" * 60)

    import asyncpg
    conn = await asyncpg.connect(args.db_url)
    resultados: dict[str, Any] = {}

    try:
        matriz = await audit_matriz_uf_mes(conn)
        resultados["matriz_uf_mes"] = matriz
        _imprimir_matriz(matriz)

        lacunas = await audit_lacunas_absolutas(conn)
        resultados["lacunas_absolutas"] = lacunas
        _imprimir_lacunas(lacunas)

        orfaos = await audit_produtos_orfao_por_uf(conn)
        resultados["produtos_orfao_por_uf"] = orfaos
        _imprimir_orfao_uf(orfaos)

        score = await audit_score_completude(conn)
        resultados["score_completude"] = score
        _imprimir_score(score)

        fontes = await audit_fontes_por_uf(conn)
        resultados["fontes_por_uf"] = fontes
        _imprimir_fontes(fontes)

        if args.json:
            _salvar_json(resultados, args.json)
        elif args.verbose:
            _salvar_json(resultados, "logs/audit_hardcode_uf_gaps.json")

    except Exception:
        logger.exception("Falha crítica na auditoria")
        raise
    finally:
        await conn.close()

    logger.info("=" * 60)
    logger.info("AUDITORIA CONCLUÍDA")
    logger.info("=" * 60)


def main() -> NoReturn:
    try:
        asyncio.run(main_async())
        sys.exit(0)
    except Exception:
        sys.exit(1)


if __name__ == "__main__":
    main()