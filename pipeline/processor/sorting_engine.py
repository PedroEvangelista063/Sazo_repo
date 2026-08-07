from __future__ import annotations

import asyncio
import json
import logging
import re
import unicodedata
import uuid
from typing import TYPE_CHECKING, Any, Self

import asyncpg
from pydantic import BaseModel, Field, field_validator

# Anotações de tipo para o LSP: o import de runtime é local em _extrair_de_html
# (para manter a dependência de bs4 leve). TYPE_CHECKING resolve BeautifulSoup/Tag
# apenas em tempo de análise, sem custo de runtime.
if TYPE_CHECKING:
    from bs4 import BeautifulSoup, Tag

logger = logging.getLogger(__name__)

_PRECO_RE = re.compile(r"(?:R\$\s*)?(\d+[.,]\d+)")
_HTML_RE = re.compile(r"^\s*(?:<!DOCTYPE|<html|<head|<body|<div)", re.IGNORECASE)


def _normalizar(texto: str) -> str:
    """Remove acentos/diacríticos para comparação. preserva maiúsculas/minúsculas."""
    nfkd = unicodedata.normalize("NFKD", texto)
    return "".join(c for c in nfkd if not unicodedata.combining(c))


# ──────────────────────────────────────────────
# Contrato Pydantic — ProdutoSazonalSchema
# ──────────────────────────────────────────────
_HORTIFRUTI_KEYWORDS: set[str] = {
    "abacate",
    "abacaxi",
    "abóbora",
    "abobrinha",
    "aipo",
    "alface",
    "alho",
    "ameixa",
    "amora",
    "banana",
    "batata",
    "batata-doce",
    "berinjela",
    "beterraba",
    "brócolis",
    "caqui",
    "cará",
    "carambola",
    "cenoura",
    "cebola",
    "cereja",
    "chuchu",
    "coco",
    "coentro",
    "couve",
    "couve-flor",
    "espinafre",
    "feijão",
    "figo",
    "gengibre",
    "goiaba",
    "graviola",
    "hortelã",
    "inhame",
    "jaca",
    "kiwi",
    "laranja",
    "limão",
    "maçã",
    "mamão",
    "manga",
    "mandioca",
    "mandioquinha",
    "maracujá",
    "melancia",
    "melão",
    "milho",
    "morango",
    "mostarda",
    "nectarina",
    "noz",
    "palmito",
    "pêra",
    "pêssego",
    "pepino",
    "pimenta",
    "pimentão",
    "quiabo",
    "repolho",
    "rúcula",
    "salsa",
    "salsão",
    "tangerina",
    "tomate",
    "uva",
    "vagem",
    "acerola",
    "caju",
    "cajá",
    "dendê",
    "jambo",
    "pitanga",
    "umbu",
    "cupuaçu",
    "açaí",
    "bacuri",
    "murici",
    "pequi",
    "buriti",
    "mangaba",
    "araticum",
    "cagaita",
    "guariroba",
    "jenipapo",
    "mama-cadela",
    "pinhão",
    "taioba",
    "ora-pro-nóbis",
    "bertalha",
    "azedinha",
    "almeirão",
    "escarola",
    "radite",
    "alho-poró",
    "cebolinha",
    "manjericão",
    "alecrim",
    "sálvia",
}

_HORTIFRUTI_NORM: frozenset[str] = frozenset(_normalizar(k).lower() for k in _HORTIFRUTI_KEYWORDS)


class ProdutoSazonalSchema(BaseModel):
    nome_produto: str = Field(..., min_length=2)
    preco_kg: float = Field(..., gt=0)
    uf: str = Field(..., min_length=2, max_length=2)
    data_referencia: str = Field(..., pattern=r"^\d{4}-(0[1-9]|1[0-2])$")

    @field_validator("nome_produto")
    @classmethod
    def nome_nao_vazio(cls, v: str) -> str:
        return v.strip().lower()

    @field_validator("uf")
    @classmethod
    def uf_maiusculo(cls, v: str) -> str:
        return v.strip().upper()

    @field_validator("data_referencia")
    @classmethod
    def janela_temporal(cls, v: str) -> str:
        ano = int(v[:4])
        if ano < 2024 or ano > 2026:
            raise ValueError(f"data_referencia {v} fora da janela 2024-2026")
        return v


# ──────────────────────────────────────────────
# SortingEngine — Esteira de Triagem
# ──────────────────────────────────────────────
_DSN = "postgresql://user:pass@localhost:5432/quero_comprar_vg"
_BATCH_SIZE = 500


class SortingEngine:
    """
    Processo 2 (pós-coleta): lê raw.coleta_bruta, tenta parsear,
    insere na staging ou quarentena, marca como processado.
    """

    def __init__(self, dsn: str = _DSN, pool: asyncpg.Pool | None = None) -> None:
        self._dsn = dsn
        self._pool = pool
        self._owns_pool = pool is None

    async def run(self) -> int:
        if self._pool is None:
            self._pool = await asyncpg.create_pool(
                self._dsn,
                min_size=1,
                max_size=4,
                command_timeout=30,
            )
        total_processados = 0

        async with self._pool.acquire() as conn:
            while True:
                linhas = await conn.fetch(
                    """
                    SELECT id, fonte_id, payload_bruto, competencia_alvo
                    FROM raw.coleta_bruta
                    WHERE processado = FALSE
                      AND competencia_alvo >= '2024-01'
                    ORDER BY data_coleta ASC
                    LIMIT $1
                    """,
                    _BATCH_SIZE,
                )
                if not linhas:
                    break

                for linha in linhas:
                    await self._processar_linha(conn, linha)
                    total_processados += 1

                logger.info(
                    "[SORTING] Batch processado — total acumulado: %d",
                    total_processados,
                )

        logger.info("[SORTING] Concluído — %d registros processados", total_processados)
        return total_processados

    # ──────────────────────────────────────────────
    # Processamento individual
    # ──────────────────────────────────────────────
    async def _processar_linha(
        self,
        conn: asyncpg.Connection,
        linha: asyncpg.Record,
    ) -> None:
        raw_id = linha["id"]
        payload = linha["payload_bruto"]
        competencia = linha["competencia_alvo"]

        dados_lista = self._parsear_payload(payload)
        if not dados_lista:
            await self._rejeitar(
                conn, raw_id, "parse_failed: payload_bruto não pôde ser interpretado"
            )
            await self._marcar_processado(conn, raw_id)
            return

        aceitos = 0
        descartados_preco = 0
        for idx, dados in enumerate(dados_lista):
            try:
                produto = ProdutoSazonalSchema(
                    nome_produto=dados["nome_produto"],
                    preco_kg=dados["preco_kg"],
                    uf=dados["uf"],
                    data_referencia=dados.get("data_referencia") or competencia,
                )
            except Exception as exc:  # noqa: BLE001 — payload externo pode lançar qualquer exceção (malha fina)
                # FASE 1 — Malha fina: item com preço nulo/vazio/zero/não-numérico
                # (ou outro campo inválido) NÃO prossegue. Em vez de descarte
                # silencioso, registra quarentena individual para rastreabilidade.
                motivo = f"malha_fina: {type(exc).__name__}: {exc}"
                if "preco" in str(exc).lower() or (dados.get("preco_kg") is None):
                    descartados_preco += 1
                    motivo = f"malha_fina: preco_invalido: {dados.get('preco_kg')!r}"
                await self._rejeitar(conn, raw_id, motivo)
                continue

            nome_norm = _normalizar(produto.nome_produto).lower()
            is_hortifruti = nome_norm in _HORTIFRUTI_NORM or any(
                kw in nome_norm for kw in _HORTIFRUTI_NORM
            )
            if not is_hortifruti:
                continue

            await self._inserir_staging(conn, produto, raw_id)
            aceitos += 1

        if descartados_preco:
            logger.warning(
                "[SORTING] %s: %d itens descartados pela malha fina (preço inválido)",
                raw_id,
                descartados_preco,
            )

        if aceitos == 0:
            await self._rejeitar(
                conn,
                raw_id,
                f"b2c_filter: nenhum dos {len(dados_lista)} itens é hortifrutigranjeiro",
            )

        await self._marcar_processado(conn, raw_id)

    # ──────────────────────────────────────────────
    # Parser — roteia conforme o formato do payload
    # ──────────────────────────────────────────────
    @staticmethod
    def _parsear_payload(payload: Any) -> list[dict[str, Any]] | None:
        if isinstance(payload, dict):
            # NOVO: payload com lista de linhas (ex: ProhortMensal, Precosiagroweb)
            linhas = payload.get("linhas") or payload.get("itens") or payload.get("rows")
            if isinstance(linhas, list) and linhas:
                resultados = []
                for item in linhas:
                    parsed = _extrair_de_dict(item)
                    if parsed:
                        resultados.extend(parsed)
                return resultados or None

            body = payload.get("body", "") or payload.get("payload", "")
            if isinstance(body, str):
                if _is_html(body):
                    return _extrair_de_html(body)
                return _extrair_de_texto(body)
            if isinstance(body, dict):
                return _extrair_de_dict(body)
            return _extrair_de_dict(payload)
        if isinstance(payload, str):
            try:
                parsed = json.loads(payload)
                if isinstance(parsed, dict):
                    return SortingEngine._parsear_payload(parsed)
            except json.JSONDecodeError:
                pass
            if _is_html(payload):
                return _extrair_de_html(payload)
            return _extrair_de_texto(payload)
        return None

    # ──────────────────────────────────────────────
    # Staging insert (upsert dimensões + fato)
    # ──────────────────────────────────────────────
    async def _inserir_staging(
        self,
        conn: asyncpg.Connection,
        produto: ProdutoSazonalSchema,
        raw_id: uuid.UUID,
    ) -> None:
        ano, mes = map(int, produto.data_referencia.split("-"))

        id_produto = await conn.fetchval(
            """
            INSERT INTO staging.dim_produto (nome_produto)
            VALUES ($1)
            ON CONFLICT (nome_produto) DO UPDATE SET nome_produto = EXCLUDED.nome_produto
            RETURNING id_produto
            """,
            produto.nome_produto,
        )

        id_localidade = await conn.fetchval(
            """
            INSERT INTO staging.dim_localidade (uf, municipio_id, municipio_nome)
            VALUES ($1, NULL, NULL)
            ON CONFLICT (uf) WHERE municipio_id IS NULL
            DO UPDATE SET uf = EXCLUDED.uf
            RETURNING id_localidade
            """,
            produto.uf,
        )

        batch_id = uuid.uuid4()
        await conn.execute(
            """
            INSERT INTO staging.fact_precos_mensais
                (id_produto, id_localidade, ano, mes, preco_medio, batch_id)
            VALUES ($1, $2, $3, $4, $5, $6)
            ON CONFLICT (id_produto, id_localidade, ano, mes)
            DO UPDATE SET preco_medio = EXCLUDED.preco_medio, batch_id = EXCLUDED.batch_id
            """,
            id_produto,
            id_localidade,
            ano,
            mes,
            round(produto.preco_kg, 4),
            batch_id,
        )

        logger.debug(
            "[SORTING] Inserido staging: %s | UF=%s | %s | R$ %.2f",
            produto.nome_produto,
            produto.uf,
            produto.data_referencia,
            produto.preco_kg,
        )

    # ──────────────────────────────────────────────
    # Quarentena
    # ──────────────────────────────────────────────
    @staticmethod
    async def _rejeitar(
        conn: asyncpg.Connection,
        raw_id: uuid.UUID,
        motivo: str,
    ) -> None:
        await conn.execute(
            """
            INSERT INTO ops.quarentena_coleta (raw_id, motivo_falha)
            VALUES ($1, $2)
            """,
            raw_id,
            motivo,
        )
        logger.warning("[SORTING] Rejeitado %s: %s", raw_id, motivo)

    @staticmethod
    async def _marcar_processado(
        conn: asyncpg.Connection,
        raw_id: uuid.UUID,
    ) -> None:
        await conn.execute(
            "UPDATE raw.coleta_bruta SET processado = TRUE WHERE id = $1",
            raw_id,
        )

    async def close(self) -> None:
        if self._owns_pool and self._pool and not self._pool.is_closing():
            await self._pool.close()

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(self, *args: object) -> None:
        await self.close()


# ──────────────────────────────────────────────
# Parsers auxiliares
# ──────────────────────────────────────────────


def _is_html(texto: str) -> bool:
    """Retorna True se o texto parece HTML (DOCTYPE ou tag raiz)."""
    return bool(_HTML_RE.match(texto.strip()[:200]))


def _extrair_de_html(html: str) -> list[dict[str, Any]] | None:
    """
    Parser HTML genérico: procura por tabelas e padrões de preço.
    Usa BeautifulSoup para navegar no DOM e extrai todos os produtos.
    """
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(html, "html.parser")

    resultados = _extrair_de_html_tabela(soup)
    if resultados:
        return resultados

    resultado_unico = _extrair_de_html_texto_rico(soup)
    if resultado_unico:
        return [resultado_unico]

    return None


def _extrair_de_html_tabela(soup: BeautifulSoup) -> list[dict[str, Any]] | None:
    """
    Varre todas as <table> no HTML, procura linhas com padrão
    (nome_produto, preço). Retorna TODOS os produtos encontrados.

    Tabela CEAGESP (7 colunas):
      Produto | Classif | Uni/Peso | Menor | Comum | Maior | Quilo
      preco_kg = Comum / Quilo
    """
    resultados: list[dict[str, Any]] = []

    for table in soup.find_all("table"):
        classes = table.get_attribute_list("class")
        if any("cookie" in (c or "").lower() for c in classes):
            continue

        linhas = table.find_all("tr")
        for tr in linhas:
            celulas = tr.find_all(["td", "th"])
            textos = [c.get_text(strip=True) for c in celulas]

            if len(textos) < 2:
                continue

            # Nome: primeira coluna real (nao-header)
            nome = ""
            if textos[0] and not any(
                x in textos[0].lower()
                for x in [
                    "produto",
                    "item",
                    "nome",
                    "embalagem",
                    "preco",
                    "r$",
                    "categoria",
                    "classif",
                ]
            ):
                nome = textos[0]
            else:
                for t in textos:
                    if t and not any(
                        x in t.lower()
                        for x in [
                            "produto",
                            "item",
                            "nome",
                            "embalagem",
                            "preco",
                            "r$",
                            "categoria",
                        ]
                    ):
                        nome = t
                        break
            if not nome:
                continue
            nome = nome.strip().lower()
            if len(nome) < 2:
                continue

            # Evitar duplicatas na mesma tabela
            if any(r["nome_produto"] == nome for r in resultados):
                continue

            # Coletar todos os precos da linha
            precos_linha: list[float] = []
            for texto in textos:
                matches = _PRECO_RE.findall(texto)
                for m in matches:
                    try:
                        v = float(m.replace(",", "."))
                        if v > 0:
                            precos_linha.append(v)
                    except ValueError:
                        continue

            if not precos_linha:
                continue

            # Tabela CEAGESP (7 cols): preco = Comum(col 4) / Quilo(col 6)
            if len(textos) >= 7 and len(precos_linha) >= 3:
                comum = precos_linha[1]  # Menor(0), Comum(1), Maior(2)
                quilo_i = len(precos_linha) - 1  # Ultimo preco = Quilo
                fator = precos_linha[quilo_i] if precos_linha[quilo_i] > 0 else 1
                preco_kg = comum / fator
            else:
                preco_kg = precos_linha[0]

            resultados.append(
                {
                    "nome_produto": nome,
                    "preco_kg": round(preco_kg, 4),
                    "uf": "SP",
                    "data_referencia": None,
                }
            )

    return resultados if resultados else None


def _extrair_de_html_texto_rico(soup: BeautifulSoup) -> dict[str, Any] | None:
    """
    Fallback: procura por texto contendo 'R$' seguido de preço,
    com um nome de produto nas proximidades (tag <strong>, <b>, <hX>).
    """
    # Buscar por elementos que contenham "R$"
    for elem in soup.find_all(["p", "span", "div", "li", "td", "h1", "h2", "h3", "h4"]):
        texto = elem.get_text(strip=True)
        precos = _PRECO_RE.findall(texto)
        if not precos:
            continue

        try:
            preco_val = float(precos[0].replace(",", "."))
        except (ValueError, TypeError):
            continue
        if preco_val <= 0:
            continue

        # Procurar nome do produto: irmao anterior, parent, ou texto ao redor
        nome = _encontrar_nome_proximo(elem, soup)
        if nome and len(nome) >= 2:
            return {
                "nome_produto": nome,
                "preco_kg": preco_val,
                "uf": "SP",
                "data_referencia": None,
            }

    return None


def _encontrar_nome_proximo(elem: Tag, soup: BeautifulSoup) -> str | None:
    """
    Tenta encontrar o nome do produto próximo a um elemento de preço.
    Procura: tag anterior, parent, irmão anterior, ou <th> anterior.
    """
    candidates: list[str] = []

    # 1. Irmão anterior
    prev = elem.find_previous_sibling()
    if prev:
        t = prev.get_text(strip=True)
        if t and len(t) > 2 and not any(c in t.lower() for c in ["r$", "preço", "preco"]):
            candidates.append(t.lower())

    # 2. Tag <th> na mesma linha (tabela)
    parent_tr = elem.find_parent("tr")
    if parent_tr:
        th = parent_tr.find("th")
        if th:
            t = th.get_text(strip=True)
            if t and len(t) > 2:
                candidates.insert(0, t.lower())

        # Primeiro td se nao for o proprio
        tds = parent_tr.find_all("td")
        for td in tds:
            if td is not elem:
                t = td.get_text(strip=True)
                if t and len(t) > 2 and "r$" not in t.lower():
                    candidates.insert(0, t.lower())
                    break

    # 3. Texto direto ao redor (regex)
    import re as _re

    parent = elem.parent
    if parent:
        full = parent.get_text(strip=True)
        nome_match = _re.search(r"([A-ZÀ-Ú][A-Za-zÀ-Úà-ú0-9\s/.-]{3,40}?)\s*R?\$?", full)
        if nome_match:
            t = nome_match.group(1).strip().lower()
            if t and len(t) > 2:
                candidates.append(t)

    for c in candidates:
        if c and len(c) >= 2:
            return c
    return None


def _extrair_de_texto(texto: str) -> list[dict[str, Any]] | None:
    linhas = texto.strip().split("\n")
    if len(linhas) < 2:
        return None

    nome_produto = linhas[0].strip().lower()
    precos = _PRECO_RE.findall(texto)
    if not precos:
        return None

    preco = float(precos[0].replace(",", "."))
    return [
        {
            "nome_produto": nome_produto,
            "preco_kg": preco,
            "uf": "BR",
            "data_referencia": None,
        }
    ]


def _extrair_de_dict(d: dict) -> list[dict[str, Any]] | None:
    nome = (
        d.get("nome_produto")
        or d.get("produto")
        or d.get("nome")
        or d.get("product")
        or d.get("item")
    )
    preco = (
        d.get("preco_kg")
        or d.get("preco")
        or d.get("preco_medio")
        or d.get("price")
        or d.get("valor")
    )
    uf = d.get("uf") or d.get("estado") or d.get("UF") or "BR"
    data_ref = d.get("data_referencia") or d.get("competencia") or d.get("data")

    if not nome or not preco:
        return None

    try:
        preco_float = float(str(preco).replace(",", ".").replace("R$", "").strip())
    except (ValueError, TypeError):
        return None

    return [
        {
            "nome_produto": str(nome).strip(),
            "preco_kg": preco_float,
            "uf": str(uf).strip().upper()[:2],
            "data_referencia": str(data_ref).strip() if data_ref else None,
        }
    ]


async def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
    )
    engine = SortingEngine()
    total = await engine.run()
    logger.info("SORTING ENGINE finalizado — %d registros processados.", total)


if __name__ == "__main__":
    asyncio.run(main())
