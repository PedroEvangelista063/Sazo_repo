#!/usr/bin/env python3
"""
gera_relatorio_validacao.py — Relatório de validação do pipeline de Boletins
Logísticos CONAB (Fase 6 — validação final / promoção para produção).

Monta ``relatorio_validacao.json`` + ``relatorio_validacao.md`` no diretório de
staging, consolidando os artefatos das três etapas:

  1. Scraper   → ``manifest.json``            (pdfs / bytes / baixados/existentes/erros)
  2. Extração  → ``extracted/resumo_extracao.json`` + ``extracted/relatorio_carga.json``
  3. Carga     → tabela ``staging.fact_fluxo_logistico`` + view ``staging.vw_fluxo_logistico_boletins``

Também consulta o banco (psycopg2, sync) para a distribuição por ano/mês/produto,
o Quality Gate (meses sem dados na janela 2025-01..2026-12) e — quando o endpoint
estiver no ar — o total de linhas retornadas por ``GET /api/v1/fluxos/boletins``.

USO:
  python3 ops/gera_relatorio_validacao.py \
      --staging-dir pipeline/data/conab_boletins_staging \
      --dsn "postgresql://postgres:postgres_dev_local@localhost:5432/quero_comprar" \
      [--api-url http://127.0.0.1:8000/api/v1/fluxos/boletins] \
      [--out-json ...] [--out-md ...]

DSN padrão: resolve da mesma ordem do loader (--dsn > DATABASE_URL_ETL >
DATABASE_URL_LOCAL_BACKUP > fallback local).

Dependências: psycopg2-binary (HTTP via stdlib urllib — zero deps extras).
Exit: 0 = OK (relatório gravado); 1 = falha.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

MANIFEST = "manifest.json"
RESUMO_EXTRACAO = "extracted/resumo_extracao.json"
RELATORIO_CARGA = "extracted/relatorio_carga.json"
OUT_JSON = "relatorio_validacao.json"
OUT_MD = "relatorio_validacao.md"

# Janela temporal do projeto (AGENTS.md / Quality Gate): 2024-01 a 2026-12.
# O pipeline de boletins opera em 2025-2026 — a janela de validação é essa.
JANELA_INICIO = (2025, 1)
JANELA_FIM = (2026, 12)

DEFAULT_DSN = "postgresql://postgres:postgres@localhost:5432/quero_comprar"


def resolve_dsn(explicito: str | None = None) -> str:
    if explicito:
        return explicito
    for var in ("DATABASE_URL_ETL", "DATABASE_URL_LOCAL_BACKUP"):
        valor = os.environ.get(var)
        if valor:
            return valor
    return DEFAULT_DSN


def ler_json(caminho: Path) -> dict:
    with caminho.open(encoding="utf-8") as fh:
        return json.load(fh)


def mes_por_extenso(ano: int, mes: int) -> str:
    nomes = {
        1: "janeiro",
        2: "fevereiro",
        3: "março",
        4: "abril",
        5: "maio",
        6: "junho",
        7: "julho",
        8: "agosto",
        9: "setembro",
        10: "outubro",
        11: "novembro",
        12: "dezembro",
    }
    return f"{ano}-{mes:02d} ({nomes[mes]})"


def consulta_db(dsn: str) -> dict:
    """Distribuição, total no banco e Quality Gate — tudo via SQL (psycopg2)."""
    import psycopg2

    conn = psycopg2.connect(dsn, options="-c timezone=UTC")
    try:
        cur = conn.cursor()

        def fetch_json(sql: str, params=None) -> list:
            cur.execute(sql, params or ())
            col = cur.fetchone()
            valor = col[0] if col else None
            if isinstance(valor, (str, bytes, bytearray)):
                return json.loads(valor)
            return valor or []

        total_no_banco = cur.execute("SELECT count(*) FROM staging.fact_fluxo_logistico")
        cur.execute("SELECT count(*) FROM staging.fact_fluxo_logistico")
        total_no_banco = cur.fetchone()[0]
        cur.execute("SELECT count(DISTINCT dedup_hash) FROM staging.fact_fluxo_logistico")
        distinct_dedup_hash = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM staging.fact_fluxo_logistico WHERE ano_referencia = 2023")
        fallback_2023 = cur.fetchone()[0]

        por_ano = fetch_json(
            "SELECT json_agg(x) FROM (SELECT ano_referencia AS ano, count(*) AS qtd "
            "FROM staging.fact_fluxo_logistico GROUP BY 1 ORDER BY 1) x"
        )
        por_mes = fetch_json(
            "SELECT json_agg(x) FROM (SELECT mes_referencia AS mes, count(*) AS qtd "
            "FROM staging.fact_fluxo_logistico GROUP BY 1 ORDER BY 1) x"
        )
        por_ano_mes = fetch_json(
            "SELECT json_agg(x) FROM (SELECT ano_referencia AS ano, "
            "mes_referencia AS mes, count(*) AS qtd "
            "FROM staging.fact_fluxo_logistico GROUP BY 1,2 ORDER BY 1,2) x"
        )
        por_produto = fetch_json(
            "SELECT json_agg(x) FROM (SELECT produto_nome AS produto, count(*) AS qtd "
            "FROM staging.fact_fluxo_logistico GROUP BY 1 ORDER BY 2 DESC, 1) x"
        )
        combos_existentes = fetch_json(
            "SELECT json_agg(x) FROM (SELECT DISTINCT ano_referencia AS ano, "
            "mes_referencia AS mes FROM staging.fact_fluxo_logistico ORDER BY 1,2) x"
        )

        # ── Quality Gate: meses da janela SEM dados reais ─────────────
        existentes = {(r["ano"], r["mes"]) for r in combos_existentes}
        meses_sem_dados: list[str] = []
        ano, mes = JANELA_INICIO
        while (ano, mes) <= JANELA_FIM:
            if (ano, mes) not in existentes:
                meses_sem_dados.append(f"{ano}-{mes:02d}")
            mes += 1
            if mes > 12:
                mes = 1
                ano += 1

        return {
            "total_no_banco": total_no_banco,
            "distinct_dedup_hash": distinct_dedup_hash,
            "fallback_2023_rows": fallback_2023,
            "por_ano": por_ano,
            "por_mes": por_mes,
            "por_ano_mes": por_ano_mes,
            "por_produto": por_produto,
            "meses_sem_dados": meses_sem_dados,
        }
    finally:
        conn.close()


def valida_endpoint(api_url: str | None) -> dict | None:
    """Chama GET /api/v1/fluxos/boletins e devolve total de linhas retornadas.

    Tolerante: se a API não estiver no ar, devolve None (não derruba o relatório).
    """
    if not api_url:
        return None
    url = urllib.parse.urljoin(api_url, "?limit=1000")
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
        return {
            "url": url,
            "total_linhas_retornadas": len(payload.get("data", [])),
            "total_contrato": payload.get("total"),
            "status_http": resp.status,
        }
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return {"url": url, "erro": str(exc)}


def monta_relatorio(staging: Path, dsn: str, api_url: str | None) -> dict:
    manifest = ler_json(staging / MANIFEST)
    resumo = ler_json(staging / RESUMO_EXTRACAO)
    carga = ler_json(staging / RELATORIO_CARGA)
    db = consulta_db(dsn)
    endpoint = valida_endpoint(api_url)

    resumo_scraper = manifest["resumo"]
    boletins_manifest = manifest.get("boletins", [])
    erros_por_pdf = [
        {"slug": b["slug"], "erro": b.get("erro", b.get("status"))}
        for b in boletins_manifest
        if b.get("status") == "erro"
    ]

    motores: dict[str, int] = {}
    for b in resumo.get("boletins", []):
        motores[b.get("motor_usado", "desconhecido")] = (
            motores.get(b.get("motor_usado", "desconhecido"), 0) + 1
        )
    taxas = [b.get("taxa_texto", 0.0) for b in resumo.get("boletins", [])]

    etapas = [
        {
            "etapa": "scraper",
            "status": "ok" if resumo_scraper["erros"] == 0 else "com_erros",
            "resumo": (
                f"{resumo_scraper['total_boletins']} boletins | "
                f"{resumo_scraper['baixados']} baixados | "
                f"{resumo_scraper['existentes']} existentes | "
                f"{resumo_scraper['erros']} erros | "
                f"{resumo_scraper['bytes_totais']} bytes"
            ),
        },
        {
            "etapa": "extracao",
            "status": "ok" if resumo["boletins_sem_registros"] == [] else "com_erros",
            "resumo": (
                f"{resumo['total_boletins']} boletins | "
                f"{resumo['total_registros']} registros | "
                f"{len(resumo.get('boletins_sem_registros', []))} sem registros"
            ),
        },
        {
            "etapa": "carga",
            "status": "ok" if not carga.get("erros") else "com_erros",
            "resumo": (
                f"{carga['registros_extraidos']} extraídos | "
                f"{carga['duplicados_descartados']} duplicados | "
                f"inserted={carga['registros_gravados']['inserted']} | "
                f"updated={carga['registros_gravados']['updated']}"
            ),
        },
        {
            "etapa": "validacao",
            "status": "ok",
            "resumo": (
                f"total_no_banco={db['total_no_banco']} | "
                f"meses_sem_dados={len(db['meses_sem_dados'])}"
            ),
        },
    ]

    return {
        "pipeline_run": {
            "data_execucao": datetime.now(UTC).isoformat(),
            "versao_artefatos": {
                "scraper": "boletim_logistico_engine.py",
                "extracao": "pipeline/pdf_extractor/run_extract.py",
                "carga": "pipeline/load_boletins_fluxo.py",
            },
            "etapas": etapas,
        },
        "pdfs": {
            "total_boletins": resumo_scraper["total_boletins"],
            "total_bytes": resumo_scraper["bytes_totais"],
            "baixados": resumo_scraper["baixados"],
            "existentes": resumo_scraper["existentes"],
            "erros": resumo_scraper["erros"],
            "erros_por_pdf": erros_por_pdf,
        },
        "extracao": {
            "total_registros": resumo["total_registros"],
            "boletins_sem_registros": resumo["boletins_sem_registros"],
            "motores_utilizados": motores,
            "taxa_texto_min": round(min(taxas), 4) if taxas else None,
            "taxa_texto_max": round(max(taxas), 4) if taxas else None,
        },
        "carga": {
            "extraidos": carga["registros_extraidos"],
            "duplicados_descartados": carga["duplicados_descartados"],
            "inserted": carga["registros_gravados"]["inserted"],
            "updated": carga["registros_gravados"]["updated"],
            "total_no_banco": db["total_no_banco"],
            "distinct_dedup_hash": db["distinct_dedup_hash"],
        },
        "distribuicao": {
            "por_ano_referencia": db["por_ano"],
            "por_mes_referencia": db["por_mes"],
            "por_ano_mes": db["por_ano_mes"],
            "por_produto": db["por_produto"],
        },
        "quality_gate": {
            "fallback_2023_utilizado": db["fallback_2023_rows"] > 0,
            "janela": {
                "inicio": f"{JANELA_INICIO[0]}-{JANELA_INICIO[1]:02d}",
                "fim": f"{JANELA_FIM[0]}-{JANELA_FIM[1]:02d}",
            },
            "meses_sem_dados": db["meses_sem_dados"],
        },
        "endpoint": endpoint,
    }


def monta_md(rel: dict) -> str:
    e = rel["endpoint"] or {"erro": "endpoint não consultado (API fora do ar)"}
    linhas: list[str] = [
        "# Relatório de Validação — Boletins Logísticos CONAB",
        "",
        f"**Data de execução:** `{rel['pipeline_run']['data_execucao']}`  ",
        (
            "**Artefatos:** "
            f"`{rel['pipeline_run']['versao_artefatos']['scraper']}` → "
            f"`{rel['pipeline_run']['versao_artefatos']['extracao']}` → "
            f"`{rel['pipeline_run']['versao_artefatos']['carga']}`"
        ),
        "",
        "## 1. Etapas do pipeline",
        "",
        "| Etapa | Status | Resumo |",
        "|-------|--------|--------|",
    ]
    for etapa in rel["pipeline_run"]["etapas"]:
        linhas.append(f"| {etapa['etapa']} | {etapa['status']} | {etapa['resumo']} |")

    p = rel["pdfs"]
    linhas += [
        "",
        "## 2. PDFs (scraper)",
        "",
        f"- **Total de boletins:** {p['total_boletins']}  ",
        f"- **Bytes totais:** {p['total_bytes']:,}  ",
        ("- **Baixados:** {baixados} | **Existentes:** {existentes} | **Erros:** {erros}").format(
            **p
        ),
        "",
    ]
    if p["erros_por_pdf"]:
        linhas.append(
            "- Erros por PDF: " + "; ".join(f"{x['slug']}: {x['erro']}" for x in p["erros_por_pdf"])
        )
        linhas.append("")

    x = rel["extracao"]
    motores = ", ".join(f"{k}={v}" for k, v in x["motores_utilizados"].items())
    linhas += [
        "## 3. Extração",
        "",
        f"- **Total de registros:** {x['total_registros']}  ",
        f"- **Boletins sem registros:** {x['boletins_sem_registros'] or 'nenhum'}  ",
        f"- **Motores utilizados:** {motores}  ",
        f"- **Taxa de texto (min/max):** {x['taxa_texto_min']} / {x['taxa_texto_max']}",
        "",
        "## 4. Carga (staging.fact_fluxo_logistico)",
        "",
        f"- **Extraídos:** {rel['carga']['extraidos']}  ",
        f"- **Duplicados descartados:** {rel['carga']['duplicados_descartados']}  ",
        f"- **Inserted:** {rel['carga']['inserted']} | **Updated:** {rel['carga']['updated']}  ",
        (
            "- **Total no banco:** {total_no_banco} | "
            "**Distinct dedup_hash:** {distinct_dedup_hash}"
        ).format(**rel["carga"]),
        "",
        "## 5. Distribuição",
        "",
        "### Por ano de referência",
        "",
        "| Ano | Qtd |",
        "|-----|-----|",
    ]
    for a in rel["distribuicao"]["por_ano_referencia"]:
        linhas.append(f"| {a['ano']} | {a['qtd']} |")

    linhas += ["", "### Por mês de referência", "", "| Mês | Qtd |", "|-----|-----|"]
    for m in rel["distribuicao"]["por_mes_referencia"]:
        linhas.append(f"| {m['mes']} | {m['qtd']} |")

    linhas += ["", "### Por produto", "", "| Produto | Qtd |", "|---------|-----|"]
    for pr in rel["distribuicao"]["por_produto"]:
        linhas.append(f"| {pr['produto']} | {pr['qtd']} |")

    qg = rel["quality_gate"]
    linhas += [
        "",
        "## 6. Quality Gate",
        "",
        f"- **Fallback 2023 utilizado:** {qg['fallback_2023_utilizado']}  ",
        f"- **Janela validada:** {qg['janela']['inicio']} a {qg['janela']['fim']}",
        "",
        "**Meses sem dados reais (status CINZA no frontend):**",
        "",
    ]
    if qg["meses_sem_dados"]:
        linhas += [
            "| Mês |",
            "|-----|",
        ]
        for mstr in qg["meses_sem_dados"]:
            ano, mes = mstr.split("-")
            linhas.append(f"| {mes_por_extenso(int(ano), int(mes))} |")
    else:
        linhas.append("_Nenhum mês sem dados na janela._")

    linhas += ["", "## 7. Endpoint", "", f"- **URL:** `{e.get('url')}`  "]
    if "erro" in e:
        linhas.append(f"- **Erro ao consultar:** {e['erro']}")
    else:
        linhas += [
            f"- **Total de linhas retornadas:** {e['total_linhas_retornadas']}  ",
            f"- **Total no contrato:** {e['total_contrato']}  ",
            f"- **HTTP:** {e['status_http']}",
        ]
    linhas.append("")
    return "\n".join(linhas)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Gera relatorio_validacao.json/.md do pipeline de boletins CONAB."
    )
    parser.add_argument(
        "--staging-dir",
        type=Path,
        default=Path("pipeline/data/conab_boletins_staging"),
    )
    parser.add_argument("--dsn", type=str, default=None)
    parser.add_argument(
        "--api-url",
        type=str,
        default=None,
        help="Base do endpoint (ex: http://127.0.0.1:8000/api/v1/fluxos/boletins).",
    )
    parser.add_argument("--out-json", type=Path, default=None)
    parser.add_argument("--out-md", type=Path, default=None)
    args = parser.parse_args()

    dsn = resolve_dsn(args.dsn)
    staging = args.staging_dir
    if not (staging / MANIFEST).exists():
        print(f"ERRO: manifest não encontrado em {staging / MANIFEST}", file=sys.stderr)
        return 1

    rel = monta_relatorio(staging, dsn, args.api_url)

    out_json = args.out_json or staging / OUT_JSON
    out_md = args.out_md or staging / OUT_MD
    out_json.write_text(json.dumps(rel, ensure_ascii=False, indent=2), encoding="utf-8")
    out_md.write_text(monta_md(rel), encoding="utf-8")

    print(f"Relatório JSON: {out_json}")
    print(f"Relatório MD:   {out_md}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
