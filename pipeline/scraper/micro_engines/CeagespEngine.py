from __future__ import annotations

import logging
import re
from typing import Any

import httpx

from pipeline.scraper.micro_engines.base_engine import BaseMicroEngine

logger = logging.getLogger(__name__)

_GRUPOS = [
    "DIVERSOS", "FLORES", "FRUTAS", "LEGUMES",
    "ORGÂNICOS", "PESCADOS", "VERDURAS",
]

_GRUPOS_DATA_RE = re.compile(
    r'var\s+Grupos\s*=\s*({.*?});',
    re.DOTALL,
)


class CeagespEngine(BaseMicroEngine):
    """
    Micro-motor CEAGESP — POST com cot_grupo + cot_data.
    Extrai tabela de precos do entreposto da Capital (SP).
    """

    async def extract(self, url: str, ano: int, mes: int) -> dict[str, Any]:
        competencia = f"{ano}-{mes:02d}"
        payload = await self._coletar_todas_categorias(url, ano, mes)
        return {
            "fonte_id": "CEAGESP",
            "payload_bruto": payload,
            "competencia": competencia,
        }

    async def extract_all(self, ano: int, mes: int) -> list[dict[str, Any]]:
        resultados: list[dict[str, Any]] = []
        for grupo in _GRUPOS:
            try:
                raw = await self._post_grupo("https://ceagesp.gov.br/cotacoes", grupo, ano, mes)
                if raw:
                    resultados.append({
                        "fonte_id": f"CEAGESP-{grupo}",
                        "payload_bruto": raw,
                        "competencia": f"{ano}-{mes:02d}",
                    })
            except Exception as exc:
                logger.warning("[CEAGESP] Grupo %s falhou: %s", grupo, exc)
                continue
        logger.info("[CEAGESP] Total: %d grupos extraidos para %d-%d", len(resultados), ano, mes)
        return resultados

    async def _coletar_todas_categorias(
        self, url: str, ano: int, mes: int,
    ) -> dict[str, Any]:
        """Coleta todas as categorias e mescla num payload unico."""
        corpos: list[str] = []
        for grupo in _GRUPOS:
            try:
                raw = await self._post_grupo(url, grupo, ano, mes)
                if raw:
                    body = raw.get("body", "")
                    if body and len(body) > 500:
                        corpos.append(f"<!-- GRUPO: {grupo} -->\n{body}")
            except Exception:
                continue

        html_unificado = "<html><body>" + "\n".join(corpos) + "</body></html>"
        return {"status_code": 200, "headers": {}, "body": html_unificado}

    async def _post_grupo(
        self, url: str, grupo: str, ano: int, mes: int,
    ) -> dict[str, Any] | None:
        if self._circuit_breaker.esta_aberto:
            raise RuntimeError(f"CircuitBreaker aberto para CEAGESP")

        datas_disponiveis = await self._extrair_datas_disponiveis(url)
        cot_data = self._melhor_data(datas_disponiveis, ano, mes, grupo) or "01/01/2024"

        async with self._semaphore:
            try:
                resp = await self._client.post(
                    url,
                    data={"cot_grupo": grupo, "cot_data": cot_data},
                    follow_redirects=True,
                    timeout=15.0,
                )
                resp.raise_for_status()
                self._circuit_breaker.registrar_sucesso()
                return {
                    "status_code": resp.status_code,
                    "headers": dict(resp.headers),
                    "body": resp.text,
                }
            except httpx.HTTPStatusError as exc:
                self._circuit_breaker.registrar_falha()
                logger.warning("[CEAGESP] HTTP %s para grupo=%s data=%s", exc.response.status_code, grupo, cot_data)
                return None
            except Exception as exc:
                self._circuit_breaker.registrar_falha()
                logger.warning("[CEAGESP] Falha grupo=%s data=%s: %s", grupo, cot_data, exc)
                return None

    async def _extrair_datas_disponiveis(self, url: str) -> dict[str, list[str]]:
        """Faz GET na pagina CEAGESP e extrai o objeto JS Grupos com as datas."""
        try:
            resp = await self._client.get(url, follow_redirects=True, timeout=10.0)
            m = _GRUPOS_DATA_RE.search(resp.text)
            if m:
                import json as _json
                raw = m.group(1)
                raw = raw.replace("\\/", "/")
                return _json.loads(raw)
        except Exception as exc:
            logger.debug("[CEAGESP] Falha ao extrair datas: %s", exc)
        return {}

    @staticmethod
    def _melhor_data(
        datas: dict[str, list[str]], ano: int, mes: int, grupo: str,
    ) -> str | None:
        """Encontra a data mais recente para o mes/ano no grupo solicitado."""
        from datetime import datetime

        datas_grupo = datas.get(grupo)
        if not datas_grupo:
            return None

        # Filtrar pelo mes/ano alvo
        target = f"/{mes:02d}/{ano}"
        candidatas = [d for d in datas_grupo if d.endswith(target)]
        if not candidatas:
            # Se nenhuma data no mes exato, pegar a mais recente
            return datas_grupo[-1] if datas_grupo else None

        # Ordenar e pegar a mais recente
        def _parse(d: str) -> tuple:
            return tuple(reversed([int(x) for x in d.split("/")]))
        candidatas.sort(key=_parse)
        return candidatas[-1]
