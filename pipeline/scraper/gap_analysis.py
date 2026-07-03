from __future__ import annotations

import json
import logging
import sys
from collections import Counter
from pathlib import Path

import polars as pl
from rapidfuzz import fuzz, process

logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
CSV_PATH = PROJECT_ROOT / "dados_sazonliza_dados_bruto" / "Planilha sem t\u00edtulo - sazonalidade_produtos.csv"
ALIASES_PATH = Path(__file__).resolve().parent / "aliases.json"
UNMATCHED_PATH = PROJECT_ROOT / "logs" / "unmatched_items.log"

NORM_TABLE = str.maketrans({
    "\u00e1": "a", "\u00e0": "a", "\u00e3": "a", "\u00e2": "a",
    "\u00e9": "e", "\u00ea": "e", "\u00ed": "i",
    "\u00f3": "o", "\u00f4": "o", "\u00f5": "o",
    "\u00fa": "u", "\u00fc": "u", "\u00e7": "c",
})

STOP_WORDS = {"da", "de", "do", "das", "dos", "em", "para", "com", "tipo", "variedade", "grupo", "extra", "especial", "primeira", "segunda"}
RE_UNIDADE = __import__("re").compile(r"\d+\s?(kg|g|dz|un|l|ml|cx|sc|cx\d+dz|sc\d+kg|cx\d+kg)", __import__("re").IGNORECASE)


def _norm(n: str) -> str:
    n = n.lower().strip().translate(NORM_TABLE)
    n = RE_UNIDADE.sub("", n)
    n = __import__("re").sub(r"[^\w\s]", " ", n)
    n = __import__("re").sub(r"\s+", " ", n)
    return " ".join(t for t in n.split() if t not in STOP_WORDS)


def carregar_master(path: str | Path | None = None) -> tuple[list[str], list[str]]:
    path = path or CSV_PATH
    df = pl.read_csv(path, encoding="utf-8-sig", null_values=["", "-", "--"])
    col_nome = next((c for c in df.columns if "produto" in c.lower() or "nome" in c.lower()), df.columns[0])
    df = df.filter(pl.col(col_nome).is_not_null()).unique(subset=[col_nome])
    nomes = [str(r) for r in df[col_nome].to_list() if r]
    norm = [_norm(n) for n in nomes]
    return nomes, norm


def carregar_aliases(path: str | Path | None = None) -> dict[str, str]:
    path = path or ALIASES_PATH
    if not path.exists():
        return {}
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    return {_norm(k): v for k, v in raw.items()}


def analisar_descartes(
    unmatched_path: str | Path | None = None,
    aliases_path: str | Path | None = None,
    master_path: str | Path | None = None,
    top_n: int = 15,
    fuzzy_cutoff: float = 60.0,
) -> pl.DataFrame:
    """
    Le o log de unmatched_items.log e, para cada item descartado,
    encontra o melhor match no CSV (mesmo que abaixo do cutoff padrao de 70).
    Mostra oportunidades de alias para itens proximos (score 50-69).

    Retorna DataFrame com colunas:
      produto_original, count, best_match, score, sugestao_alias, acao
    """
    path = unmatched_path or UNMATCHED_PATH
    if not path.exists():
        logger.warning("Arquivo de unmatched nao encontrado: %s", path)
        with open(path, "w", encoding="utf-8") as f:
            f.write("")
        return pl.DataFrame()

    # Parse unmatched log
    raw = path.read_text(encoding="utf-8")
    items: list[str] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("---"):
            continue
        parts = line.split("x ", 1)
        if len(parts) == 2:
            items.append(parts[1].strip())

    if not items:
        logger.info("Nenhum item descartado registrado no log.")
        return pl.DataFrame()

    counter = Counter(items)
    master_nomes, master_norm = carregar_master(master_path)
    aliases = carregar_aliases(aliases_path)

    registros = []
    for produto_original, count in counter.most_common(top_n):
        n = _norm(produto_original)
        if not n:
            continue

        # Ja existe alias?
        alias_existente = aliases.get(n)
        if alias_existente:
            registros.append({
                "produto_original": produto_original,
                "count": count,
                "best_match": alias_existente,
                "score": 100.0,
                "sugestao_alias": "",
                "acao": "JA_EXISTE_ALIAS",
            })
            continue

        # Busca fuzzy com cutoff baixo (50) para ver o mais proximo
        best = process.extractOne(n, master_norm, scorer=fuzz.WRatio, score_cutoff=50.0)
        if best:
            target = master_nomes[master_norm.index(best[0])]
            score = best[1]
            sugestao = ""
            acao = ""

            if score >= 70:
                acao = "OK_JA_MATCH"
            elif score >= 60:
                acao = "ALIAS_ALTA_PRIORIDADE"
                sugestao = json.dumps({"pattern": produto_original.lower(), "target": target}, ensure_ascii=False)
            elif score >= 50:
                acao = "ALIAS_MEDIA_PRIORIDADE"
                sugestao = json.dumps({"pattern": produto_original.lower(), "target": target}, ensure_ascii=False)
            else:
                acao = "SEM_MATCH_PROXIMO"

            registros.append({
                "produto_original": produto_original,
                "count": count,
                "best_match": target if score >= 50 else "",
                "score": round(score, 1),
                "sugestao_alias": sugestao,
                "acao": acao,
            })
        else:
            registros.append({
                "produto_original": produto_original,
                "count": count,
                "best_match": "",
                "score": 0.0,
                "sugestao_alias": "",
                "acao": "SEM_MATCH",
            })

    df = pl.DataFrame(registros).sort("count", descending=True)
    return df


def gerar_relatorio_gap(
    unmatched_path: str | Path | None = None,
    aliases_path: str | Path | None = None,
    top_n: int = 15,
) -> None:
    """
    Gera relatorio formatado de gap analysis para stdout.
    """
    df = analisar_descartes(unmatched_path, aliases_path, top_n=top_n)

    if df.height == 0:
        print("Nenhum gap encontrado. Todos os itens foram normalizados com sucesso.")
        return

    total_descartes = df["count"].sum()
    print("=" * 70)
    print("RELATORIO DE GAP ANALYSIS - ITENS DESCARTADOS NO NORMALIZER")
    print("=" * 70)
    print(f"Total de descartes registrados: {total_descartes}")
    print(f"TOP {df.height} itens mais frequentes")
    print()

    prioridade = df.filter(pl.col("acao") == "ALIAS_ALTA_PRIORIDADE")
    media = df.filter(pl.col("acao") == "ALIAS_MEDIA_PRIORIDADE")
    ja_existe = df.filter(pl.col("acao") == "JA_EXISTE_ALIAS")

    if prioridade.height > 0:
        print(f"\n>>> ALTA PRIORIDADE (score 60-69): {prioridade.height} itens")
        print("    Adicione ao aliases.json para recuperar imediatamente:")
        for row in prioridade.iter_rows(named=True):
            print(f"    {row['count']:4d}x {row['produto_original']:40s} -> {row['best_match']:25s} (score={row['score']})")
            if row["sugestao_alias"]:
                print(f"         {row['sugestao_alias']}")

    if media.height > 0:
        print(f"\n>>> MEDIA PRIORIDADE (score 50-59): {media.height} itens")
        for row in media.iter_rows(named=True):
            print(f"    {row['count']:4d}x {row['produto_original']:40s} -> {row['best_match']:25s} (score={row['score']})")
            if row["sugestao_alias"]:
                print(f"         {row['sugestao_alias']}")

    if ja_existe.height > 0:
        print(f"\n>>> JA POSSUI ALIAS (mas continua aparecendo): {ja_existe.height} itens")
        print("    O alias existe mas o termo exato nao esta sendo capturado. Verifique normalizacao.")
        for row in ja_existe.iter_rows(named=True):
            print(f"    {row['count']:4d}x {row['produto_original']:40s} -> {row['best_match']}")

    print()
    print("=" * 70)
    print("INSTRUCAO: Adicione as sugestoes ALTA_PRIORIDADE ao aliases.json")
    print("           e reexecute o pipeline para ver a taxa de conversao subir.")
    print("=" * 70)


if __name__ == "__main__":
    logging.basicConfig(level=logging.WARNING)
    gerar_relatorio_gap()