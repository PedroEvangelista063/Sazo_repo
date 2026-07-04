from __future__ import annotations

import json
import logging
import os
import re
import sys
import time
from collections import Counter
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any, NoReturn

import polars as pl
from dotenv import load_dotenv

load_dotenv()

logger = logging.getLogger("report_engine_gaps")

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
LOGS_DIR = PROJECT_ROOT / "logs"
SOURCES_PATH = PROJECT_ROOT / "config" / "sources.json"
SOURCES_MAP_PATH = PROJECT_ROOT / "config" / "sources_map.json"
ALIASES_PATH = Path(__file__).resolve().parent / "aliases.json"
UNMATCHED_LOG = LOGS_DIR / "unmatched_items.log"
OUTPUT_REPORT = LOGS_DIR / "current_scraping_gaps.md"

DATABASE_URL: str = os.environ.get(
    "DATABASE_URL_ETL",
) or os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/quero_comprar",
)


def _get_pg_conn():
    import psycopg2

    conn = psycopg2.connect(DATABASE_URL, options="-c timezone=UTC")
    conn.set_session(autocommit=True)
    return conn


def _load_json(path: Path) -> dict:
    if not path.exists():
        logger.warning("Arquivo nao encontrado: %s", path)
        return {}
    with open(path, encoding="utf-8") as f:
        return json.load(f)


#  ─────────────────────────────────────────────────────────────────
#  ANÁLISE 1 — SOURCE HEALTH
#  ─────────────────────────────────────────────────────────────────


def _fontes_esperadas() -> list[dict]:
    raw = _load_json(SOURCES_PATH)
    fontes = raw.get("sources", [])
    return [f for f in fontes if f.get("active", False)]


def _fontes_map_produtos() -> dict:
    raw = _load_json(SOURCES_MAP_PATH)
    return raw.get("fontes_prioridade", {})


def _build_fonte_signature(fonte: dict) -> str:
    return f"{fonte.get('fonte','?')} ({fonte.get('uf','?')}-{fonte.get('municipio','?')})"


def analisar_source_health(conn) -> dict[str, Any]:
    logger.info("=== ANALISE 1: Source Health ===")
    fontes = _fontes_esperadas()
    fontes_prioridade = _fontes_map_produtos()

    cutoff_7d = date.today() - timedelta(days=7)

    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            l.uf,
            l.municipio_nome,
            COUNT(DISTINCT f.id_produto) AS qtd_produtos,
            COUNT(*)                      AS qtd_linhas,
            MIN(f.loaded_at)              AS primeira_coleta,
            MAX(f.loaded_at)              AS ultima_coleta
        FROM staging.fact_precos_mensais f
        JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
        WHERE f.loaded_at >= %s
        GROUP BY l.uf, l.municipio_nome
        ORDER BY l.uf, l.municipio_nome
        """,
        (cutoff_7d,),
    )
    rows = cur.fetchall()
    cur.close()

    db_cols = ["uf", "municipio_nome", "qtd_produtos", "qtd_linhas", "primeira_coleta", "ultima_coleta"]
    df_db = pl.DataFrame(rows, schema=db_cols, orient="row")

    resultados: list[dict] = []
    for fonte in fontes:
        sig = _build_fonte_signature(fonte)
        uf = fonte.get("uf", "")
        mun = fonte.get("municipio", "")

        match = df_db.filter(
            (pl.col("uf") == uf)
            & (pl.col("municipio_nome").str.to_lowercase().str.contains(mun.lower()))
        )
        if match.height == 0:
            match = df_db.filter(pl.col("uf") == uf)

        if match.height > 0:
            r = match.row(0, named=True)
            resultados.append({
                "fonte": sig,
                "adapter": fonte.get("adapter", "?"),
                "categoria": fonte.get("category", "?"),
                "uf": uf,
                "status": "OK" if r["qtd_linhas"] > 0 else "ZERO",
                "qtd_linhas": r["qtd_linhas"],
                "qtd_produtos": r["qtd_produtos"],
                "ultima_coleta": str(r["ultima_coleta"]),
            })
        else:
            resultados.append({
                "fonte": sig,
                "adapter": fonte.get("adapter", "?"),
                "categoria": fonte.get("category", "?"),
                "uf": uf,
                "status": "SILENCIO",
                "qtd_linhas": 0,
                "qtd_produtos": 0,
                "ultima_coleta": "N/A",
            })

    df = pl.DataFrame(resultados)
    total_ok = df.filter(pl.col("status") == "OK").height
    total_zero = df.filter(pl.col("status") == "ZERO").height
    total_silencio = df.filter(pl.col("status") == "SILENCIO").height

    return {
        "total_fontes_ativas": len(fontes),
        "fontes_ok": total_ok,
        "fontes_zero": total_zero,
        "fontes_silencio": total_silencio,
        "taxa_sucesso_pct": round(total_ok / len(fontes) * 100, 1) if fontes else 0.0,
        "detalhes": df,
    }


#  ─────────────────────────────────────────────────────────────────
#  ANÁLISE 2 — NORMALIZATION BLEED
#  ─────────────────────────────────────────────────────────────────


def _normalizar(nome: str) -> str:
    n = nome.lower().strip()
    tbl = str.maketrans({
        "á": "a", "à": "a", "ã": "a", "â": "a",
        "é": "e", "ê": "e", "í": "i",
        "ó": "o", "ô": "o", "õ": "o",
        "ú": "u", "ü": "u", "ç": "c",
    })
    n = n.translate(tbl)
    n = re.sub(r"\d+\s?(kg|g|dz|un|l|ml|cx|sc)", "", n)
    n = re.sub(r"[^\w\s]", " ", n)
    n = re.sub(r"\s+", " ", n).strip()
    stopwords = {"da", "de", "do", "das", "dos", "em", "para", "com", "tipo", "variedade", "grupo", "extra", "especial", "primeira", "segunda"}
    return " ".join(t for t in n.split() if t not in stopwords)


def analisar_normalization_bleed(conn) -> dict[str, Any]:
    logger.info("=== ANALISE 2: Normalization Bleed ===")

    # 2a. Conversion rate: raw volume vs staging volume
    cur = conn.cursor()
    cur.execute("SELECT COUNT(*) FROM staging.fact_precos_mensais")
    total_fact = cur.fetchone()[0]

    fact_ultimo_mes = 0
    fact_ultimo_batch = 0
    try:
        cur.execute(
            """
            SELECT COUNT(*)
            FROM staging.fact_precos_mensais
            WHERE loaded_at >= NOW() - INTERVAL '1 day'
            """
        )
        fact_ultimo_batch = cur.fetchone()[0]
    except Exception:
        pass
    cur.close()

    # 2b. Parse unmatched_items.log
    raw_unmatched = ""
    if UNMATCHED_LOG.exists():
        raw_unmatched = UNMATCHED_LOG.read_text(encoding="utf-8")

    counter = Counter()
    current_block = ""
    for line in raw_unmatched.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("---"):
            current_block = line
            continue
        parts = line.split("x ", 1)
        if len(parts) == 2:
            try:
                count = int(parts[0].strip())
                item = parts[1].strip()
                counter[item] += count
            except ValueError:
                pass

    if not counter:
        logger.info("Nenhum item descartado no log de unmatched.")
        return {
            "total_raw_estimado": fact_ultimo_batch,
            "total_staging_ultimo_batch": fact_ultimo_batch,
            "taxa_conversao_pct": 100.0,
            "total_descartados": 0,
            "top_descartados": pl.DataFrame(),
            "alias_opportunities": [],
        }

    aliases = _load_json(ALIASES_PATH)
    aliases_norm = {_normalizar(k): v for k in aliases.keys()}

    registros: list[dict] = []
    for item, count in counter.most_common(50):
        item_norm = _normalizar(item)
        if not item_norm:
            continue

        alias_match = aliases_norm.get(item_norm)
        if alias_match:
            registros.append({
                "produto_original": item,
                "count": count,
                "best_match": alias_match,
                "score": 100.0,
                "ja_possui_alias": True,
                "sugestao_alias": "",
            })
            continue

        fuzzy_scores = []
        for raw_key, target in aliases.items():
            raw_key_norm = _normalizar(raw_key)
            if raw_key_norm and len(raw_key_norm) > 2:
                from rapidfuzz import fuzz
                score = fuzz.WRatio(item_norm, raw_key_norm)
                if score >= 50:
                    fuzzy_scores.append((score, raw_key, target))

        fuzzy_scores.sort(key=lambda x: -x[0])
        best_score = fuzzy_scores[0][0] if fuzzy_scores else 0.0
        best_match = fuzzy_scores[0][2] if fuzzy_scores else ""
        best_key = fuzzy_scores[0][1] if fuzzy_scores else ""

        if best_score >= 60:
            acao = "ALIAS_ALTA"
            sugestao = json.dumps({item.lower(): best_match}, ensure_ascii=False)
        elif best_score >= 50:
            acao = "ALIAS_MEDIA"
            sugestao = json.dumps({item.lower(): best_match}, ensure_ascii=False)
        else:
            acao = "SEM_MATCH"
            sugestao = ""

        registros.append({
            "produto_original": item,
            "count": count,
            "best_match": best_match if best_score >= 50 else "",
            "score": round(best_score, 1),
            "ja_possui_alias": False,
            "sugestao_alias": sugestao,
        })

    df_descartados = pl.DataFrame(registros).sort("count", descending=True)

    total_descartados = df_descartados["count"].sum()
    raw_estimado = fact_ultimo_batch + total_descartados if fact_ultimo_batch > 0 else total_descartados
    taxa = round(fact_ultimo_batch / raw_estimado * 100, 2) if raw_estimado > 0 else 0.0

    alias_opps = (
        df_descartados
        .filter((pl.col("ja_possui_alias") == False) & (pl.col("sugestao_alias") != ""))
        .sort("count", descending=True)
    )

    return {
        "total_raw_estimado": raw_estimado,
        "total_staging_ultimo_batch": fact_ultimo_batch,
        "total_staging_geral": total_fact,
        "taxa_conversao_pct": taxa,
        "total_descartados": total_descartados,
        "top_descartados": df_descartados.head(15),
        "alias_opportunities": alias_opps.to_dicts() if alias_opps.height > 0 else [],
    }


#  ─────────────────────────────────────────────────────────────────
#  ANÁLISE 3 — TEMPORAL VOIDS (ÓRFÃOS)
#  ─────────────────────────────────────────────────────────────────


def analisar_temporal_voids(conn) -> dict[str, Any]:
    logger.info("=== ANALISE 3: Temporal Voids ===")

    cutoff_30d = date.today() - timedelta(days=30)

    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            p.id_produto,
            p.nome_produto,
            p.categoria_b2c,
            MAX(f.loaded_at) AS ultima_atualizacao,
            MAX(f.ano * 100 + f.mes) AS ultimo_periodo
        FROM staging.dim_produto p
        LEFT JOIN staging.fact_precos_mensais f ON f.id_produto = p.id_produto
        WHERE p.categoria_b2c = 'ALIMENTO_VAREJO'
        GROUP BY p.id_produto, p.nome_produto, p.categoria_b2c
        HAVING MAX(f.loaded_at) IS NULL
            OR MAX(f.loaded_at) < %s
        ORDER BY COALESCE(MAX(f.loaded_at), '1970-01-01') ASC
        LIMIT 50
        """,
        (cutoff_30d,),
    )
    rows = cur.fetchall()

    cur.execute(
        """
        SELECT
            p.id_produto,
            p.nome_produto,
            p.categoria_b2c,
            MAX(f.loaded_at) AS ultima_atualizacao,
            MAX(f.ano * 100 + f.mes) AS ultimo_periodo
        FROM staging.dim_produto p
        LEFT JOIN staging.fact_precos_mensais f ON f.id_produto = p.id_produto
        WHERE p.categoria_b2c = 'ALIMENTO_VAREJO'
        GROUP BY p.id_produto, p.nome_produto, p.categoria_b2c
        HAVING MAX(f.loaded_at) IS NOT NULL
        ORDER BY MAX(f.loaded_at) DESC
        LIMIT 1
        """
    )
    recent_row = cur.fetchone()

    cur.execute(
        """
        SELECT COUNT(*) FROM staging.dim_produto
        WHERE categoria_b2c = 'ALIMENTO_VAREJO'
        """
    )
    total_alimento_varejo = cur.fetchone()[0]

    cur.execute(
        """
        SELECT COUNT(*)
        FROM staging.dim_produto p
        LEFT JOIN staging.fact_precos_mensais f ON f.id_produto = p.id_produto
        WHERE p.categoria_b2c = 'ALIMENTO_VAREJO'
        GROUP BY p.id_produto
        HAVING MAX(f.loaded_at) IS NULL
        """
    )
    nunca_coletados = len(cur.fetchall())
    cur.close()

    cols = ["id_produto", "nome_produto", "categoria_b2c", "ultima_atualizacao", "ultimo_periodo"]
    df_orf = pl.DataFrame(rows, schema=cols, orient="row")

    mais_recente = str(recent_row[3]) if recent_row else "N/A"

    return {
        "total_alimento_varejo": total_alimento_varejo,
        "nunca_coletados": nunca_coletados,
        "orfãos_sem_atualizacao_30d": df_orf.height,
        "data_mais_recente": mais_recente,
        "top_orfãos": df_orf.head(10) if df_orf.height > 0 else pl.DataFrame(),
    }


#  ─────────────────────────────────────────────────────────────────
#  GERADOR DO RELATÓRIO MARKDOWN
#  ─────────────────────────────────────────────────────────────────


def _format_tabela(df: pl.DataFrame, colunas: list[str] | None = None) -> str:
    if df.height == 0:
        return "_(vazio)_"
    cols = colunas or df.columns
    linhas = [" | ".join(cols)]
    linhas.append(" | ".join(["---"] * len(cols)))
    for row in df.iter_rows():
        vals = []
        for c in cols:
            v = row[df.columns.index(c)]
            if v is None or (isinstance(v, str) and not v):
                vals.append("—")
            else:
                vals.append(str(v))
        linhas.append(" | ".join(vals))
    return "\n".join(linhas)


def gerar_relatorio(
    source_health: dict,
    norm_bleed: dict,
    temporal_voids: dict,
) -> str:
    gerado_em = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    report = [
        f"# Relatório de Gap Analysis — SmartCrawler2026",
        f"",
        f"**Gerado em:** {gerado_em}",
        f"**Versão alvo:** v1.0.0-rc1",
        f"",
    ]

    # ── GLOBAL METRICS ──
    report.append("## [MÉTRICAS GLOBAIS]")
    report.append("")
    report.append(f"| Métrica | Valor |")
    report.append(f"|---------|-------|")
    sh = source_health
    report.append(f"| Fontes ativas monitoradas | {sh['total_fontes_ativas']} |")
    report.append(f"| Fontes com dados nos últimos 7d | {sh['fontes_ok']} |")
    report.append(f"| Fontes com 0 cotações | {sh['fontes_zero']} |")
    report.append(f"| Fontes em silêncio total | {sh['fontes_silencio']} |")
    report.append(f"| Taxa de sucesso por fonte | {sh['taxa_sucesso_pct']}% |")
    report.append("")
    nb = norm_bleed
    report.append(f"| Volume bruto estimado (último batch) | {nb['total_raw_estimado']} |")
    report.append(f"| Registros retidos no staging | {nb['total_staging_ultimo_batch']} |")
    report.append(f"| Taxa de conversão (bruto → staging) | {nb['taxa_conversao_pct']}% |")
    report.append(f"| Total itens descartados (log) | {nb['total_descartados']} |")
    report.append(f"| Total histórico na fact_precos_mensais | {nb['total_staging_geral']} |")
    report.append("")
    tv = temporal_voids
    report.append(f"| Produtos ALIMENTO_VAREJO na dim | {tv['total_alimento_varejo']} |")
    report.append(f"| Nunca coletados (zero dados) | {tv['nunca_coletados']} |")
    report.append(f"| Órfãos sem atualização nos últimos 30d | {tv['orfãos_sem_atualizacao_30d']} |")
    report.append(f"| Data da coleta mais recente | {tv['data_mais_recente']} |")
    report.append("")

    # ── SOURCE ALERTS ──
    report.append("## [ALERTA DE FONTES]")
    report.append("")
    df_fontes = sh["detalhes"]
    alertas = df_fontes.filter(pl.col("status") != "OK")

    if alertas.height > 0:
        report.append("### Fontes com problemas (últimos 7 dias)")
        report.append("")
        report.append("| Fonte | Adapter | Categoria | UF | Status | Qtd Linhas | Última Coleta |")
        report.append("|-------|---------|-----------|----|--------|------------|----------------|")
        for row in alertas.iter_rows(named=True):
            report.append(
                f"| {row['fonte']} | {row['adapter']} | {row['categoria']} "
                f"| {row['uf']} | {row['status']} | {row['qtd_linhas']} | {row['ultima_coleta']} |"
            )
        report.append("")

    if sh["fontes_silencio"] > 0:
        report.append("### ⚠️  Atenção especial: fontes em silêncio total")
        report.append("")
        for row in df_fontes.filter(pl.col("status") == "SILENCIO").iter_rows(named=True):
            report.append(f"- **{row['fonte']}** — adapter `{row['adapter']}` (cat. {row['categoria']})")
        report.append("")
        report.append("**Ação sugerida:** Verificar adapter — possível mudança no HTML/API da fonte ou WAF bloqueando.")
        report.append("")

    if sh["fontes_zero"] > 0:
        report.append("### ⚠️  Fontes retornando 0 cotações")
        report.append("")
        for row in df_fontes.filter(pl.col("status") == "ZERO").iter_rows(named=True):
            report.append(f"- **{row['fonte']}** — adapter executou mas retornou 0 linhas")
        report.append("")

    # ── ALIAS OPPORTUNITIES ──
    report.append("## [OPORTUNIDADES DE ALIAS]")
    report.append("")
    opps = nb["alias_opportunities"]
    if opps:
        report.append("| # | Produto Original | Ocorrências | Best Match | Score | Sugestão para aliases.json |")
        report.append("|---|------------------|-------------|------------|-------|---------------------------|")
        for i, opp in enumerate(opps[:15], 1):
            report.append(
                f"| {i} | {opp['produto_original']} | {opp['count']}x "
                f"| {opp['best_match']} | {opp['score']} | `{opp['sugestao_alias']}` |"
            )
        report.append("")
        report.append("**Impacto estimado:** Cada entrada adicionada no `aliases.json` recupera em média "
                       f"{sum(o['count'] for o in opps[:15])} itens por execução.")
        report.append("")
    else:
        report.append("Nenhuma oportunidade de alias identificada. ")
        report.append("")

    # ── TOP 15 DISCARDED ──
    report.append("### Top 15 produtos descartados pelo Normalizer")
    report.append("")
    df_top = nb["top_descartados"]
    if df_top.height > 0:
        mostrar = ["produto_original", "count", "best_match", "score", "ja_possui_alias"]
        report.append(f"| Produto Original | Ocorrências | Best Match | Score | Já possui alias? |")
        report.append(f"|------------------|-------------|------------|-------|-------------------|")
        for row in df_top.iter_rows(named=True):
            report.append(
                f"| {row['produto_original']} | {row['count']}x "
                f"| {row['best_match'][:25]} | {row['score']} | {'✅' if row['ja_possui_alias'] else '❌'} |"
            )
        report.append("")

    # ── ORPHANS ──
    report.append("## [PRODUTOS ÓRFÃOS]")
    report.append("")
    report.append("### Top 10 produtos ALIMENTO_VAREJO sem atualização nos últimos 30 dias")
    report.append("")
    df_orf = tv["top_orfãos"]
    if df_orf.height > 0:
        report.append("| ID | Produto | Última Atualização | Último Período |")
        report.append("|----|---------|-------------------|----------------|")
        for row in df_orf.iter_rows(named=True):
            ult = str(row["ultima_atualizacao"]) if row["ultima_atualizacao"] else "NUNCA"
            per = str(row["ultimo_periodo"]) if row["ultimo_periodo"] else "N/A"
            report.append(f"| {row['id_produto']} | {row['nome_produto']} | {ult} | {per} |")
        report.append("")
    report.append("### Nunca coletados (existem na dim_produto mas sem nenhum registro na fact)")
    report.append("")
    report.append(f"**Total:** {tv['nunca_coletados']} produtos — "
                  "são itens cadastrados que o scraper nunca conseguiu mapear para nenhuma cotação real.")
    report.append("")
    report.append("**Ação sugerida:** Verificar se esses produtos têm fontes mapeadas em "
                  "`config/sources_map.json` ou se são itens órfãos da importação CONAB que não existem "
                  "no mundo real do varejo hortifrúti.")
    report.append("")

    # ── FOOTER ──
    report.append("---")
    report.append("")
    report.append("*Relatório gerado automaticamente por `report_engine_gaps.py`*")
    report.append(f"*Pipeline: quero_comprar_vg | SmartCrawler2026 :heart:*")

    return "\n".join(report)


#  ─────────────────────────────────────────────────────────────────
#  MAIN
#  ─────────────────────────────────────────────────────────────────


def run() -> NoReturn:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        stream=sys.stdout,
    )

    logger.info("=" * 60)
    logger.info("REPORT ENGINE GAPS — Auditoria de Qualidade de Dados")
    logger.info("=" * 60)

    t0 = time.perf_counter()

    conn = _get_pg_conn()

    try:
        logger.info("[1/3] Analisando Source Health...")
        source_health = analisar_source_health(conn)
        logger.info(
            "  Fontes OK=%d, Zero=%d, Silencio=%d | Taxa=%.1f%%",
            source_health["fontes_ok"],
            source_health["fontes_zero"],
            source_health["fontes_silencio"],
            source_health["taxa_sucesso_pct"],
        )

        logger.info("[2/3] Analisando Normalization Bleed...")
        norm_bleed = analisar_normalization_bleed(conn)
        logger.info(
            "  Raw=%d → Staging=%d | Taxa conv=%.2f%% | Descartados=%d",
            norm_bleed["total_raw_estimado"],
            norm_bleed["total_staging_ultimo_batch"],
            norm_bleed["taxa_conversao_pct"],
            norm_bleed["total_descartados"],
        )

        logger.info("[3/3] Analisando Temporal Voids...")
        temporal_voids = analisar_temporal_voids(conn)
        logger.info(
            "  Alim.Varejo=%d | Orfãos 30d=%d | Nunca coletados=%d",
            temporal_voids["total_alimento_varejo"],
            temporal_voids["orfãos_sem_atualizacao_30d"],
            temporal_voids["nunca_coletados"],
        )

        logger.info("Gerando relatório markdown...")
        md = gerar_relatorio(source_health, norm_bleed, temporal_voids)

        LOGS_DIR.mkdir(parents=True, exist_ok=True)
        OUTPUT_REPORT.write_text(md, encoding="utf-8")
        logger.info("Relatório salvo em: %s", OUTPUT_REPORT)

        duracao = time.perf_counter() - t0
        logger.info("Report Engine concluído em %.1fs", duracao)
        print("\n" + md)

    except Exception:
        logger.exception("Falha crítica no Report Engine")
        sys.exit(1)
    finally:
        conn.close()

    sys.exit(0)


if __name__ == "__main__":
    run()
