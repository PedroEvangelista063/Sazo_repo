"""
AUDITORIA DE CONCILIAÇÃO — FASE 2: RAW (arquivos locais) vs. Staging (banco)
============================================================================
O Teste do Parsing.

Lê os arquivos RAW locais baixados pelo scraper (JSON/CSV da CONAB em
``database/processed_data/01_raw/``), sorteia uma amostra de 50 registros e
compara o valor EXATO (em texto) do Preço e do Ano/Mês com o que foi
efetivamente salvo em ``staging.fact_precos_mensais``.

Diagnósticos que este script responde:
  1. O ETL está perdendo centavos? (preco texto != preco_medio salvo)
  2. O separador decimal (vírgula vs. ponto) está sendo lido corretamente?
  3. O ano/mês extraído do arquivo condiz com a coluna ``ano``/``mes`` do banco?
  4. Registros B2C presentes no RAW mas AUSENTES no banco (queda silenciosa)?

Uso:
    python utilities/audit_raw_vs_db.py [--amostra 50] [--semente 42]
"""

from __future__ import annotations

import json
import logging
import os
import random
import sys
from pathlib import Path

import psycopg2
from dotenv import load_dotenv

# ─────────────────────────────────────────────────────────────────────────────
# Configuração de ambiente (padrão do projeto: DATABASE_URL → banco remoto/Aiven)
# ─────────────────────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

_ENV_CANDIDATES = [
    PROJECT_ROOT / "backend" / ".env",
    PROJECT_ROOT / ".env",
]
for _env in _ENV_CANDIDATES:
    if _env.exists():
        load_dotenv(_env)
        break
else:
    load_dotenv()

DATABASE_URL: str = os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/quero_comprar",
)
RAW_DIR: Path = PROJECT_ROOT / "database" / "processed_data" / "01_raw"
AMOSTRA_PADRAO: int = 50
SEMENTE_PADRAO: int = 42

logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger("audit_raw_vs_db")

# ─────────────────────────────────────────────────────────────────────────────
# PARSING DE PREÇO — réplica fiel do ETL (_sanitizar_preco / _parse_price_column)
# ─────────────────────────────────────────────────────────────────────────────


def parse_preco_etl(texto: str) -> float | None:
    """Converte '2,27' → 2.27, igual ao Polars (strip + vírgula→ponto + float).

    Se a string for inválida, retorna None (o ETL filtra a linha).
    """
    if texto is None:
        return None
    t = str(texto).strip()
    if not t:
        return None
    try:
        return float(t.replace(",", "."))
    except (ValueError, TypeError):
        return None


def _fix_mojibake(texto: str) -> str:
    """Corrige double-encoding latin1→utf8 (ex: 'NÃ\x83O' → 'NÃO').

    Os arquivos LISTA*.json exportados pelo scraper gravaram strings
    duplamente codificadas; os .txt originais da CONAB são limpos.
    Esta função tenta reverter, e devolve o original se a tentativa falhar.
    """
    try:
        decodificado = texto.encode("latin1").decode("utf-8")
        # Só aceita se realmente mudou e não introduziu replacement chars
        if decodificado != texto and "\ufffd" not in decodificado:
            return decodificado
    except (UnicodeDecodeError, UnicodeEncodeError):
        pass
    return texto


def normalizar_nome(nome: str) -> str:
    """Normaliza nome de produto: fix mojibake + trim + uppercase + colapsa espaços."""
    return " ".join(_fix_mojibake(str(nome)).strip().upper().split())


def chaves_produto_candidatas(produto: str, classificacao: str | None) -> list[str]:
    """Gera as chaves de produto que o ETL pode ter gravado em dim_produto,
    em ordem de prioridade:
      1. ``PRODUTO - CLASSIFICAO`` (nome composto, usado pelo ETL)
      2. ``PRODUTO`` sozinho (quando a classificação é "NÃO INFORMADO" ou
         quando o produto foi gravado sem sufixo)

    O ETL grava ``TOMATE - NÃO INFORMADO`` como nome composto, então a
    variante completa é tentada primeiro; a simples cobre registros gravados
    como ``BATATA`` sem sufixo.
    """
    p = normalizar_nome(produto)
    chaves = [p]
    if classificacao:
        c = normalizar_nome(classificacao)
        if c:
            chaves.insert(0, f"{p} - {c}")
    return list(dict.fromkeys(chaves))  # dedupe preservando ordem


# ─────────────────────────────────────────────────────────────────────────────
# LEITURA DOS ARQUIVOS RAW
# ─────────────────────────────────────────────────────────────────────────────


def carregar_raw_json(path: Path) -> list[dict]:
    """Carrega LISTA*.json (formato CONAB API exportado pelo scraper)."""
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def carregar_raw_txt(path: Path) -> list[dict]:
    """Carrega LISTA*.txt (CSV ';' com header, encoding latin1/utf-8)."""
    try:
        import csv
    except ImportError:  # pragma: no cover
        return []
    for enc in ("latin1", "utf-8"):
        try:
            with open(path, encoding=enc) as f:
                reader = csv.DictReader(f, delimiter=";")
                return [row for row in reader if row]
        except (UnicodeDecodeError, csv.Error):
            continue
    return []


def descobrir_raw_records() -> list[dict]:
    """Descobre todos os registros raw locais (json + txt) com metadados."""
    registros: list[dict] = []
    for path in sorted(RAW_DIR.glob("LISTA*.json")):
        try:
            for rec in carregar_raw_json(path):
                rec = dict(rec)
                rec["_arquivo"] = path.name
                registros.append(rec)
        except Exception as exc:  # pragma: no cover
            logger.warning("  ! falha ao ler %s: %s", path.name, exc)
    for path in sorted(RAW_DIR.glob("LISTA*.txt")):
        try:
            for rec in carregar_raw_txt(path):
                rec = dict(rec)
                rec["_arquivo"] = path.name
                registros.append(rec)
        except Exception as exc:  # pragma: no cover
            logger.warning("  ! falha ao ler %s: %s", path.name, exc)
    return registros


def campo(rec: dict, *nomes: str) -> str | None:
    """Lê o primeiro campo presente (case-insensitive)."""
    lower = {str(k).lower(): v for k, v in rec.items()}
    for nome in nomes:
        if nome in lower and lower[nome] not in (None, ""):
            return str(lower[nome]).strip()
    return None


# ─────────────────────────────────────────────────────────────────────────────
# CONSULTAS AO BANCO
# ─────────────────────────────────────────────────────────────────────────────


def query(sql: str, params: tuple | None = None) -> list[tuple]:
    conn = psycopg2.connect(DATABASE_URL, options="-c timezone=UTC")
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params or ())
            return cur.fetchall()
    finally:
        conn.close()


SQL_FACT_POR_CHAVE = """
SELECT f.id_fato, f.preco_medio, f.preco_curado, f.is_interpolado,
       f.ano, f.mes, f.fonte, p.nome_produto, l.uf, l.municipio_id
FROM staging.fact_precos_mensais f
JOIN staging.dim_produto    p ON p.id_produto = f.id_produto
JOIN staging.dim_localidade l ON l.id_localidade = f.id_localidade
ORDER BY (l.municipio_id IS NULL OR BTRIM(l.municipio_id) = '') DESC,  -- agregado UF
         f.fonte NULLS FIRST
"""

SQL_CATEGORIA_PRODUTO = """
SELECT UPPER(BTRIM(nome_produto)), COALESCE(categoria_b2c, 'NÃO CLASSIFICADO')
FROM staging.dim_produto
"""


def carregar_fact_em_memoria() -> dict[tuple, list[tuple]]:
    """Carrega toda a fact_precos_mensais em memória, indexada por
    (nome_produto_upper, uf, ano, mes). Evita N+1 queries no banco.
    """
    idx: dict[tuple, list[tuple]] = {}
    for row in query(SQL_FACT_POR_CHAVE):
        ano = row[4]
        mes = row[5]
        nome = row[7]
        uf = row[8]
        if ano is None or mes is None:
            continue
        chave = (normalizar_nome(nome), (uf or "").strip().upper(), int(ano), int(mes))
        idx.setdefault(chave, []).append(row)
    return idx


# ─────────────────────────────────────────────────────────────────────────────
# RELATÓRIO
# ─────────────────────────────────────────────────────────────────────────────


def gerar_relatorio(amostra: int = AMOSTRA_PADRAO, semente: int = SEMENTE_PADRAO) -> None:
    logger.info("═" * 78)
    logger.info(" AUDITORIA FASE 2 — RAW (arquivos locais) vs. STAGING (fact_precos_mensais)")
    logger.info("═" * 78)

    # ── 1. Descobrir registros raw ─────────────────────────────────────────
    logger.info("\n[1] Descobrindo arquivos RAW em %s", RAW_DIR)
    registros = descobrir_raw_records()
    if not registros:
        logger.error("Nenhum registro RAW encontrado. Abortando.")
        return
    logger.info("  %d registros raw carregados (%d arquivos).",
                len(registros), len({r["_arquivo"] for r in registros}))

    # ── 2. Diagnóstico do separador decimal na massa toda ─────────────────
    logger.info("\n[2] Diagnóstico do separador decimal (todos os registros raw)")
    com_virgula = 0
    com_ponto = 0
    ambos = 0
    invalidos = 0
    for r in registros:
        preco = campo(r, "valor_produto_kg", "preco_medio", "preco")
        if preco is None:
            continue
        if "," in preco and "." in preco:
            ambos += 1
        elif "," in preco:
            com_virgula += 1
        elif "." in preco:
            com_ponto += 1
        if parse_preco_etl(preco) is None:
            invalidos += 1
    logger.info("  preços com vírgula (padrão BR): %d", com_virgula)
    logger.info("  preços com ponto (formato EN):  %d", com_ponto)
    logger.info("  preços com AMBOS (risco!):       %d", ambos)
    logger.info("  preços NÃO parseáveis:           %d", invalidos)

    # ── 3. Amostra aleatória ───────────────────────────────────────────────
    rng = random.Random(semente)
    amostrados = rng.sample(registros, min(amostra, len(registros)))
    logger.info("\n[3] Amostra de %d registros (semente=%d)", len(amostrados), semente)

    # Cache de categoria B2C dos produtos + index da fact em memória
    logger.info("  Carregando dimensões/fact em memória (1 query)...")
    categorias = {row[0]: row[1] for row in query(SQL_CATEGORIA_PRODUTO)}
    fact_idx = carregar_fact_em_memoria()
    logger.info("  fact indexada: %d chaves", len(fact_idx))

    resultados = {
        "OK_PRECO_E_ANO": [],
        "PRECO_NAO_PARSEAVEL": [],
        "DIVERGENCIA_PRECO": [],
        "DIVERGENCIA_ANO": [],
        "AUSENTE_B2C": [],
        "NAO_ENCONTRADO": [],
    }

    for rec in amostrados:
        produto = campo(rec, "produto")
        classificacao = campo(rec, "classificao_produto", "classificacao")
        uf = campo(rec, "uf")
        ano = campo(rec, "ano")
        mes = campo(rec, "mes")
        preco_txt = campo(rec, "valor_produto_kg", "preco_medio", "preco")

        chaves = chaves_produto_candidatas(produto or "", classificacao)
        chave = chaves[0]
        uf_norm = (uf or "").strip().upper()
        try:
            ano_int = int(float(ano)) if ano else None
        except ValueError:
            ano_int = None
        try:
            mes_int = int(float(mes)) if mes else None
        except ValueError:
            mes_int = None

        preco_etl = parse_preco_etl(preco_txt) if preco_txt else None

        if not chave or not uf_norm or ano_int is None or mes_int is None:
            resultados["NAO_ENCONTRADO"].append((rec["_arquivo"], chave, uf_norm, ano, mes,
                                                 preco_txt, "campos ausentes no RAW"))
            continue

        # Tenta todas as variantes de chave (com e sem sufixo de classificação)
        rows = []
        for ch in chaves:
            rows = fact_idx.get((ch, uf_norm, ano_int, mes_int)) or []
            if rows:
                chave = ch
                break

        if not rows:
            categoria = None
            for ch in chaves:
                categoria = categorias.get(ch)
                if categoria is not None:
                    chave = ch
                    break
            if categoria is None:
                categoria = categorias.get(normalizar_nome(produto or ""), "?")
            if categoria == "ALIMENTO_VAREJO":
                resultados["AUSENTE_B2C"].append(
                    (rec["_arquivo"], chave, uf_norm, ano_int, mes_int, preco_txt, categoria))
            else:
                resultados["NAO_ENCONTRADO"].append(
                    (rec["_arquivo"], chave, uf_norm, ano_int, mes_int, preco_txt,
                     f"categoria={categoria}"))
            continue

        # Há registro — compara preço e ano. Já ordenado com agregado UF
        # primeiro (row: id_fato, preco_medio, preco_curado, is_interpolado,
        # ano, mes, fonte, nome_produto, uf, municipio_id)
        row = rows[0]
        db_preco = float(row[1]) if row[1] is not None else None
        db_ano = int(row[4])
        db_mes = int(row[5])
        db_mun = row[9] or "(UF)"

        dif_preco = None
        if preco_etl is not None and db_preco is not None:
            dif_preco = round(abs(preco_etl - db_preco), 4)

        if db_ano != ano_int or db_mes != mes_int:
            resultados["DIVERGENCIA_ANO"].append(
                (rec["_arquivo"], chave, uf_norm, ano_int, mes_int, f"{db_ano:04d}/{db_mes:02d}", preco_txt,
                 f"{preco_etl} vs DB {db_preco}"))
        elif preco_etl is None:
            resultados["PRECO_NAO_PARSEAVEL"].append(
                (rec["_arquivo"], chave, uf_norm, ano_int, mes_int, preco_txt,
                 "preço raw não parseável"))
        elif dif_preco is not None and dif_preco > 0.0001:
            resultados["DIVERGENCIA_PRECO"].append(
                (rec["_arquivo"], chave, uf_norm, ano_int, mes_int, preco_txt,
                 f"RAW parse={preco_etl} | DB={db_preco} (loc={db_mun}) | dif={dif_preco}"))
        else:
            resultados["OK_PRECO_E_ANO"].append(
                (rec["_arquivo"], chave, uf_norm, ano_int, mes_int, preco_txt,
                 f"DB={db_preco} (loc={db_mun})"))

    # ── 4. Exibir resultados ────────────────────────────────────────────────
    logger.info("\n[4] RESULTADO DA AMOSTRA (%d registros):", len(amostrados))
    logger.info("  ✅ Preço + Ano idênticos:       %d", len(resultados["OK_PRECO_E_ANO"]))
    logger.info("  ⚠️  Preço raw não parseável:     %d", len(resultados["PRECO_NAO_PARSEAVEL"]))
    logger.info("  ❌ Divergência de PREÇO:        %d", len(resultados["DIVERGENCIA_PRECO"]))
    logger.info("  ❌ Divergência de ANO/MÊS:      %d", len(resultados["DIVERGENCIA_ANO"]))
    logger.info("  ⚠️  B2C ausente no banco:        %d", len(resultados["AUSENTE_B2C"]))
    logger.info("  ➖ Não encontrado (B2B/outros):  %d", len(resultados["NAO_ENCONTRADO"]))

    if resultados["DIVERGENCIA_PRECO"]:
        logger.info("\n  --- Divergências de PREÇO (RAW texto vs DB) ---")
        for r in resultados["DIVERGENCIA_PRECO"][:15]:
            logger.info("    • %s | %s | %s %04d/%02d | raw=%s | %s",
                        r[0], r[1], r[2], r[3], r[4], r[5], r[6])

    if resultados["DIVERGENCIA_ANO"]:
        logger.info("\n  --- Divergências de ANO (RAW vs DB) ---")
        for r in resultados["DIVERGENCIA_ANO"][:15]:
            logger.info("    • %s | %s | %s | RAW ano=%s mes=%s | DB ano=%s | raw preço=%s | %s",
                        r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7])

    if resultados["AUSENTE_B2C"]:
        logger.info("\n  --- B2C presentes no RAW mas AUSENTES no banco ---")
        for r in resultados["AUSENTE_B2C"][:15]:
            logger.info("    • %s | %s | %s %04d/%02d | preço raw=%s",
                        r[0], r[1], r[2], r[3], r[4], r[5])

    logger.info("\n  --- Amostra de registros OK (preço+ano batem) ---")
    for r in resultados["OK_PRECO_E_ANO"][:8]:
        logger.info("    • %s | %s | %s %04d/%02d | raw=%s | %s",
                    r[0], r[1], r[2], r[3], r[4], r[5], r[6])

    # ── 5. Conclusões ───────────────────────────────────────────────────────
    logger.info("\n[5] CONCLUSÃO (FASE 2)")
    if resultados["DIVERGENCIA_PRECO"]:
        logger.info("  ⚠️  Existem divergências de preço: o ETL/banco não preserva o valor exato do RAW.")
    else:
        logger.info("  ✅ Nenhuma divergência de preço encontrada na amostra.")
    if resultados["DIVERGENCIA_ANO"]:
        logger.info("  ⚠️  Existem divergências de ano/mês: o ETL está gravando período diferente do RAW.")
    else:
        logger.info("  ✅ Ano/mês do RAW batem com o banco na amostra.")
    if resultados["AUSENTE_B2C"]:
        logger.info("  ⚠️  %d produtos B2C do RAW não foram encontrados no banco (queda na ingestão).",
                    len(resultados["AUSENTE_B2C"]))
    logger.info("  Total registros raw na base local: %d", len(registros))


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Auditoria RAW vs. Staging (FASE 2)")
    parser.add_argument("--amostra", type=int, default=AMOSTRA_PADRAO)
    parser.add_argument("--semente", type=int, default=SEMENTE_PADRAO)
    args = parser.parse_args()
    gerar_relatorio(amostra=args.amostra, semente=args.semente)
