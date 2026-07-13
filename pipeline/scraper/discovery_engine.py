"""Discovery Engine — Cache-based com seed de URLs conhecidas.

Nao depende de search engines (todos bloqueiam headless).
Mantem cache persistente entre execucoes para acumular descobertas.
"""

from __future__ import annotations

import json
import logging
import os
import re
from pathlib import Path
from typing import Any

import httpx

logger = logging.getLogger(__name__)

_URL_PDF_RE = re.compile(r"\.pdf$", re.IGNORECASE)

RE_CEASA_TABLE = re.compile(
    r"(?i)(produto|preco|preço|cotação|cotacao)\s.*(?:comum|menor|maior|r\$)",
)

_CACHE_PATH = Path(os.getenv("DISCOVERY_CACHE_PATH", "data/discovery_cache.json"))

_URLS_CONHECIDAS: list[str] = [
    # CEASAs oficiais
    "https://www.ceagesp.gov.br/cotacoes/",
    "https://www.ceasa.pr.gov.br/cotacao",
    "https://www.ceasa.mg.gov.br/cotacoes",
    "https://minas1.ceasa.mg.gov.br/ceasainternet/cst_precosmaiscomumEstados/cst_precosmaiscomumEstados.php",
    "http://200.198.51.71/detec/filtro_boletim_es/filtro_boletim_es.php",
    "https://www.ceasape.org.br/cotacao/hortalicas",
    "https://transparencia.ceasa.rn.gov.br/cotacoes",
    "https://www.ceasa.ms.gov.br/boletim-2025/",
    "https://ceasa.rs.gov.br/cotacoes-de-precos",
    "https://www.ceasa.df.gov.br/cotacoes",
    "https://www.ceasa.ba.gov.br/cotacoes",
    "http://www.imea.com.br",
    # Emater / Secretarias
    "https://www.emater.df.gov.br",
    "https://www.epagri.sc.gov.br",
    "https://www.agricultura.pr.gov.br/deral",
    "https://www.sepror.am.gov.br",
    "https://www.sedap.pa.gov.br",
    # Agregadores nacionais
    "https://www.noticiasagricolas.com.br/cotacoes",
    "https://www.hfbrasil.org.br/br/estatistica",
    "https://www.agrolink.com.br/cotacoes",
    "https://calculadorarural.com.br/ceasa",
    "https://www.conab.gov.br/prohort/api/cotacoes",
    "https://cepea.org.br/br/consultas-ao-banco-de-dados-do-site.aspx",
    # Dados abertos
    "https://dados.gov.br",
    "https://dados.ba.gov.br",
]


class DiscoveryEngine:
    """Discovery Engine que varre URLs conhecidas + cache persistente.

    Flow:
      1. Carrega cache de descobertas anteriores
      2. Testa cada URL via traceroute
      3. Filtra paginas com tabelas de preco
      4. Salva novas URLs no cache
    """

    def __init__(self) -> None:
        self._cache = self._carregar_cache()

    # ──────────────────────────────────────────────
    # API publica
    # ──────────────────────────────────────────────
    async def buscar(
        self, uf: str, ano: int, mes: int
    ) -> list[dict[str, Any]]:
        competencia = f"{ano}-{mes:02d}"
        urls_tentar = self._montar_lista_urls(uf)
        resultados: list[dict[str, Any]] = []

        logger.info(
            "[DISCOVERY] UF=%s | Competencia=%s | %d URLs no cache",
            uf, competencia, len(urls_tentar),
        )

        for url in urls_tentar:
            payload = await self._traceroute(url, uf)
            if payload is not None:
                resultados.append({
                    "fonte_id": "DISCOVERY_AUTONOMO",
                    "payload_bruto": payload,
                    "competencia": competencia,
                })

        # Atualiza cache com novas URLs (caso o traceroute tenha seguido redirects)
        novas_urls = {r["payload_bruto"]["url"] for r in resultados}
        if novas_urls:
            self._cache.extend(novas_urls - set(self._cache))
            self._salvar_cache()

        logger.info("[DISCOVERY] Total URLs com tabela de precos: %d", len(resultados))
        return resultados

    # ──────────────────────────────────────────────
    # Montagem de URL list
    # ──────────────────────────────────────────────
    def _montar_lista_urls(self, uf: str) -> list[str]:
        todas = list(self._cache)
        for url in _URLS_CONHECIDAS:
            if url not in todas:
                todas.append(url)
        return todas

    # ──────────────────────────────────────────────
    # Traceroute — visita URL e verifica se tem tabela
    # ──────────────────────────────────────────────
    async def _traceroute(self, url: str, uf: str = "") -> dict[str, Any] | None:
        if _URL_PDF_RE.search(url):
            return None

        try:
            async with httpx.AsyncClient(
                timeout=5.0, follow_redirects=True,
                headers={
                    "User-Agent": (
                        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                        "AppleWebKit/537.36 Chrome/125.0.0.0 Safari/537.36"
                    ),
                },
            ) as client:
                resp = await client.get(url)

            if resp.status_code != 200:
                return None

            ct = resp.headers.get("content-type", "").lower()
            if "application/pdf" in ct:
                return None

            if not RE_CEASA_TABLE.search(resp.text):
                return None

            logger.info("[DISCOVERY] URL valida: %s (%d bytes)", url, len(resp.text))
            return {
                "url": str(resp.url),
                "status_code": resp.status_code,
                "content_type": ct,
                "body": resp.text,
            }

        except Exception as exc:
            logger.debug("[DISCOVERY] Traceroute falhou %s: %s", url, exc)
            return None

    # ──────────────────────────────────────────────
    # Cache persistente
    # ──────────────────────────────────────────────
    def _carregar_cache(self) -> list[str]:
        try:
            if _CACHE_PATH.exists():
                dados = json.loads(_CACHE_PATH.read_text(encoding="utf-8"))
                if isinstance(dados, list):
                    return dados
        except Exception as exc:
            logger.debug("[DISCOVERY] Falha ao carregar cache: %s", exc)
        return []

    def _salvar_cache(self) -> None:
        try:
            _CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
            _CACHE_PATH.write_text(
                json.dumps(self._cache, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            logger.debug("[DISCOVERY] Cache salvo: %d URLs", len(self._cache))
        except Exception as exc:
            logger.debug("[DISCOVERY] Falha ao salvar cache: %s", exc)
