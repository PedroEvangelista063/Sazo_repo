from __future__ import annotations

import logging
import re
from typing import Any

import httpx

logger = logging.getLogger(__name__)

# ──────────────────────────────────────────────
# Operadores PERMITIDOS (proibido AND/OR/filetype:)
# ──────────────────────────────────────────────
# Apenas: "", site:, inurl:, intext:, *
_URL_PDF_RE = re.compile(r"\.pdf$", re.IGNORECASE)

_ESTADOS_BR: dict[str, str] = {
    "AC": "Acre", "AL": "Alagoas", "AP": "Amapá", "AM": "Amazonas",
    "BA": "Bahia", "CE": "Ceará", "DF": "Distrito Federal",
    "ES": "Espírito Santo", "GO": "Goiás", "MA": "Maranhão",
    "MT": "Mato Grosso", "MS": "Mato Grosso do Sul", "MG": "Minas Gerais",
    "PA": "Pará", "PB": "Paraíba", "PR": "Paraná", "PE": "Pernambuco",
    "PI": "Piauí", "RJ": "Rio de Janeiro", "RN": "Rio Grande do Norte",
    "RS": "Rio Grande do Sul", "RO": "Rondônia", "RR": "Roraima",
    "SC": "Santa Catarina", "SP": "São Paulo", "SE": "Sergipe",
    "TO": "Tocantins",
}


class SimpleDorkGenerator:
    """
    Gera queries de busca estilo 'humano' para evitar bloqueio WAF.
    Sem AND, OR, filetype:, parênteses — apenas operadores simples.
    """

    # Padrões aprovados — hardcoded conforme especificação
    _PADROES: list[str] = [
        'site:gov.br inurl:ceasa "{nome_estado}" intext:preço',
        'site:emater.*.gov.br "boletim" "hortifrúti"',
        'inurl:cotacao "preço atacado" "ceasa {uf_upper}"',
        'site:*.{uf_lower}.gov.br "hortifruti" "cotação"',
    ]

    @classmethod
    def gerar(cls, uf: str) -> list[str]:
        nome_estado = _ESTADOS_BR.get(uf.upper(), uf)
        uf_lower = uf.lower().strip()
        uf_upper = uf.upper().strip()

        queries: list[str] = []
        for padrao in cls._PADROES:
            query = (
                padrao
                .replace("{nome_estado}", nome_estado)
                .replace("{uf_lower}", uf_lower)
                .replace("{uf_upper}", uf_upper)
            )
            queries.append(query)
        return queries


class DiscoveryEngine:
    """
    Passo 3 do orquestrador: busca ativa na web por URLs promissoras,
    aplica traceroute heurístico (rejeita PDFs), salva na landing zone.
    """

    def __init__(self) -> None:
        self._dork_gen = SimpleDorkGenerator()

    async def buscar(
        self, uf: str, ano: int, mes: int
    ) -> list[dict[str, Any]]:
        queries = SimpleDorkGenerator.gerar(uf)
        resultados: list[dict[str, Any]] = []
        competencia = f"{ano}-{mes:02d}"

        logger.info(
            "[DISCOVERY] UF=%s | Competência=%s | %d queries geradas",
            uf, competencia, len(queries),
        )

        for query in queries:
            logger.debug("[DISCOVERY] Query: %s", query)
            urls = await self._executar_busca(query)
            for url in urls:
                payload = await self._traceroute(url)
                if payload is not None:
                    resultados.append({
                        "fonte_id": "DISCOVERY_AUTONOMO",
                        "payload_bruto": payload,
                        "competencia": competencia,
                    })

        logger.info("[DISCOVERY] Total URLs coletadas: %d", len(resultados))
        return resultados

    # ──────────────────────────────────────────────
    # Simulação de busca (stub — substituir por API real de busca)
    # ──────────────────────────────────────────────
    async def _executar_busca(self, query: str) -> list[str]:
        """
        Stub: retorna lista vazia.
        Em produção: integrar com API de busca (Google Custom Search, Bing, etc.)
        """
        logger.debug("[DISCOVERY] Busca simulada para: %s", query)
        return []

    # ──────────────────────────────────────────────
    # Traceroute heurístico — filtra PDFs
    # ──────────────────────────────────────────────
    async def _traceroute(self, url: str) -> dict[str, Any] | None:
        if _URL_PDF_RE.search(url):
            logger.info("[DISCOVERY] URL .pdf descartada: %s", url)
            return None

        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.get(url, follow_redirects=True)

            content_type = resp.headers.get("content-type", "").lower()
            if "application/pdf" in content_type:
                logger.info("[DISCOVERY] Content-Type PDF descartado: %s", url)
                return None

            if resp.status_code != 200:
                logger.debug("[DISCOVERY] Status %d para %s — descartado", resp.status_code, url)
                return None

            logger.info("[DISCOVERY] URL válida: %s (%d bytes)", url, len(resp.text))
            return {
                "url": url,
                "status_code": resp.status_code,
                "content_type": content_type,
                "body": resp.text,
            }

        except Exception as exc:
            logger.debug("[DISCOVERY] Falha no traceroute %s: %s", url, exc)
            return None
