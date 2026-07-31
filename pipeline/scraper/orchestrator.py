from __future__ import annotations

import asyncio
import json
import logging
import os
from dataclasses import asdict
from pathlib import Path
from typing import Any

from pipeline.scraper.adapters.base import CotacaoRegional
from pipeline.scraper.adapters.playwright_html import PlaywrightHtmlAdapter
from pipeline.scraper.adapters.smart_router import (
    ALVOS_CONHECIDOS,
    SmartCrawler2026,
    UF_ALVOS_DEDICADOS,
)
from pipeline.scraper.micro_engines.base_engine import BaseMicroEngine
from pipeline.scraper.micro_engines.ConabApiEngine import ConabApiEngine
from pipeline.scraper.micro_engines.CeagespEngine import CeagespEngine
from pipeline.scraper.micro_engines.precosiagroweb_engine import PrecosiagrowebEngine
from pipeline.scraper.micro_engines.prohort_mensal_engine import ProhortMensalEngine

logger = logging.getLogger(__name__)

_AUDIT_FMT = "[AUDIT] UF: {uf} | Mes/Ano: {competencia} | Alvo: {alvo} | Status: {status} | Decisao: {decisao}"

_UFS_CONTINGENCIA = frozenset({"AC", "AM", "AP", "MS", "PI", "RO", "RR", "SE"})

_UF_SMARTROUTER_ALVOS: dict[str, list[str]] = {
    uf: alvos for uf, alvos in UF_ALVOS_DEDICADOS.items()
    if uf != "BR"
}

def _log_audit(level: int, **kw: str) -> None:
    logger.log(level, _AUDIT_FMT.format(**kw))

_UF_CEASA_MAP: dict[str, str] = {
    "SP": "CEAGESP",
    "MG": "CEASA-MG",
    "PR": "CEASA-PR",
    "MT": "IMEA-MT",
    "ES": "CEASA-ES",
    "DF": "CEASA-DF",
    "BA": "CEASA-BA",
    "PE": "CEASA-PE",
    "RN": "CEASA-RN",
    "MS": "CEASA-MS",
}

SCRAPER_TIMEOUT_SEC = 180

_FONTE_ID_PARA_ALVO: dict[str, str] = {
    "ceagesp": "ceagesp",
    "ceasa-mg": "ceasa_mg",
    "ceasa-pr": "ceasa_pr",
    "ceasa-es": "ceasa_es",
    "ceasa-pe": "ceasa_pe",
    "ceasa-rn": "ceasa_rn",
    "ceasa-ms": "ceasa_ms",
    "ceasa-df": "ceasa_df",
    "ceasa-ba": "ceasa_ba",
    "imea-mt": "imea_mt",
    "cepea": "cepea",
    "conab": "conab",
    "conab-pentaho": "conab_pentaho",
    "conab-prohort-mensal": "conab_prohort_mensal",
    "precosiagroweb": "precosiagroweb",
    "agrolink": "agrolink",
    "calc-rural": "calculadorarural",
}


def _carregar_sources() -> dict:
    caminho = Path(os.getenv("SOURCES_MATRIX_PATH", "config/sources_matrix.json"))
    with open(caminho, encoding="utf-8") as f:
        return json.load(f)


class AutonomousOrchestrator:
    """
    Orquestrador autonomo multi-tier.
    Tenta TODAS as fontes em cada tier, acumula resultados.
    So cai para o proximo tier se o acumulado estiver vazio.
    """

    def __init__(self) -> None:
        self._sources = _carregar_sources()

    # ──────────────────────────────────────────────
    # Multi-tier: tenta cada categoria de fontes
    # ──────────────────────────────────────────────
    _TIERS: list[str] = [
        "core",
        "ceasas_diretas",
        "agregadores",
        "perifericos",
    ]

    async def coletar(
        self, uf: str, competencia: str
    ) -> list[dict[str, Any]]:
        ano_str, mes_str = competencia.split("-")
        ano, mes = int(ano_str), int(mes_str)

        if ano < 2024 or ano > 2026:
            raise ValueError(f"competencia {competencia} fora da janela 2024-2026")

        try:
            return await asyncio.wait_for(
                self._coletar_interno(uf, ano, mes),
                timeout=SCRAPER_TIMEOUT_SEC,
            )
        except asyncio.TimeoutError:
            _log_audit(logging.WARNING, uf=uf, competencia=competencia,
                       alvo="COLETAR", status="TIMEOUT",
                       decisao=f"Coleta excedeu {SCRAPER_TIMEOUT_SEC}s")
            return []

    async def coletar_global(
        self, competencia: str
    ) -> list[dict[str, Any]]:
        """Single dispatch por competência — micro-engines que coletam todas as UFs."""
        ano_str, mes_str = competencia.split("-")
        ano, mes = int(ano_str), int(mes_str)
        acumulado: list[dict[str, Any]] = []

        for fonte_id in ("ceagesp", "conab"):
            engine = self._resolver_motor(fonte_id)
            if not engine:
                continue
            fonte = self._encontrar_fonte(fonte_id, "ceasas_diretas") or \
                    self._encontrar_fonte(fonte_id, "core")
            if not fonte:
                await engine.close()
                continue
            resultado = await self._executar_com_timeout(engine, fonte["url_base"], ano, mes, fonte_id)
            if resultado:
                acumulado.append(resultado)

        return acumulado

    async def _coletar_interno(
        self, uf: str, ano: int, mes: int
    ) -> list[dict[str, Any]]:
        acumulado: list[dict[str, Any]] = []

        # Tier 1: micro-engines (Ceagesp, CONAB) — rapido, existente
        direto = await self._passo_direto(uf, ano, mes)
        if direto:
            acumulado.extend(direto)

        # Tier 2: SmartRouter — adapters dedicados por UF (CEASA, SantoGraal)
        smart = await self._passo_smartrouter(uf, ano, mes)
        if smart:
            acumulado.extend(smart)

        # R1: Contingência para UFs sem CEASA direta
        contingencia = await self._passo_contingencia(uf, ano, mes)
        if contingencia:
            acumulado.extend(contingencia)

        # R2: ProHort Mensal — 1x por competência (não por UF)
        if uf == "SP":
            prohort = await self._passo_prohort(ano, mes)
            if prohort:
                acumulado.extend(prohort)

        # Tier 3-5: categorias da sources_matrix — tenta cada fonte
        for categoria in self._TIERS:
            if categoria == "core":
                continue
            tier_result = await self._executar_tier(categoria, uf, ano, mes)
            if tier_result:
                acumulado.extend(tier_result)

        if acumulado:
            return acumulado

        # Tier final: discovery (web search — ultimo recurso)
        return await self._passo_discovery(uf, ano, mes)

    # ──────────────────────────────────────────────
    # Executa todas as fontes de uma categoria
    # ──────────────────────────────────────────────
    async def _executar_tier(
        self, categoria: str, uf: str, ano: int, mes: int
    ) -> list[dict[str, Any]]:
        fontes = self._sources.get(categoria, [])
        if not fontes:
            return []

        uf_alvo = uf.upper()
        resultados: list[dict[str, Any]] = []

        _log_audit(
            logging.INFO, uf=uf_alvo,
            competencia=f"{ano}-{mes:02d}",
            alvo=f"TIER_{categoria.upper()}",
            status="TENTANDO",
            decisao=f"Tier {categoria}: {len(fontes)} fonte(s)",
        )

        for fonte in fontes:
            fonte_uf = fonte.get("uf", "BR").upper()
            if fonte_uf != "BR" and fonte_uf != uf_alvo:
                continue

            items = await self._executar_uma_fonte(fonte, uf_alvo, ano, mes)
            if items:
                resultados.extend(items)

        if resultados:
            _log_audit(
                logging.INFO, uf=uf_alvo,
                competencia=f"{ano}-{mes:02d}",
                alvo=f"TIER_{categoria.upper()}",
                status="SUCESSO",
                decisao=f"{len(resultados)} registros de {categoria}",
            )

        return resultados

    # ──────────────────────────────────────────────
    # Dispatcher: fonte -> engine/adapter
    # ──────────────────────────────────────────────
    async def _executar_uma_fonte(
        self, fonte: dict, uf: str, ano: int, mes: int
    ) -> list[dict[str, Any]]:
        fonte_id = fonte.get("fonte_id", "UNKNOWN").lower()
        url = fonte.get("url_base", "")

        # 1. Old micro-engines
        engine = self._resolver_motor(fonte_id)
        if engine:
            resultado = await self._executar_com_timeout(engine, url, ano, mes, fonte_id)
            return [resultado] if resultado else []

        # 2. SmartRouter alvo conhecido
        alvo_key = _FONTE_ID_PARA_ALVO.get(fonte_id)
        if alvo_key and alvo_key in ALVOS_CONHECIDOS:
            crawler = SmartCrawler2026()
            adp = crawler.criar_adapter_para_alvo(alvo_key, ano=ano, mes=mes)
            if adp:
                try:
                    if hasattr(adp, "fetch"):
                        cotacoes = await adp.fetch()
                    elif hasattr(adp, "execute"):
                        cotacoes = await adp.execute()
                    else:
                        cotacoes = []
                    return [self._cotacao_to_bruta_dict(c) for c in cotacoes if c]
                except Exception as exc:
                    _log_audit(
                        logging.WARNING, uf=uf,
                        competencia=f"{ano}-{mes:02d}",
                        alvo=fonte_id, status="FALHA",
                        decisao=f"SmartRouter: {exc}",
                    )
                    return []

        # 3. Generic PlaywrightHtmlAdapter — navega com Chromium stealth para qualquer URL
        if url and url.startswith("http"):
            try:
                from pipeline.scraper.adapters.stealth import async_playwright
                async with async_playwright() as pw:
                    browser = await pw.chromium.launch(headless=True)
                    context = await browser.new_context(
                        viewport={"width": 1280, "height": 720},
                        user_agent=(
                            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                            "AppleWebKit/537.36 (KHTML, like Gecko) "
                            "Chrome/122.0.0.0 Safari/537.36"
                        ),
                    )
                    page = await context.new_page()
                    adp = PlaywrightHtmlAdapter(
                        url=url,
                        uf=uf,
                        municipio=fonte.get("municipio", ""),
                        fonte=fonte_id,
                        ano=ano,
                        mes=mes,
                    )
                    cotacoes = await adp.execute(page)
                    await browser.close()
                    if cotacoes:
                        return [self._cotacao_to_bruta_dict(c) for c in cotacoes if c]
            except Exception:
                pass

        _log_audit(
            logging.DEBUG, uf=uf,
            competencia=f"{ano}-{mes:02d}",
            alvo=fonte_id, status="SKIP",
            decisao="Fonte sem engine/adapter registrado",
        )
        return []

    # ──────────────────────────────────────────────
    # Passo 1 — micro-engines (Ceagesp, CONAB)
    # ──────────────────────────────────────────────
    async def _passo_direto(
        self, uf: str, ano: int, mes: int
    ) -> list[dict[str, Any]] | None:
        uf_upper = uf.upper()
        fonte_id = _UF_CEASA_MAP.get(uf_upper)
        if not fonte_id:
            return None

        _log_audit(logging.INFO, uf=uf_upper, competencia=f"{ano}-{mes:02d}", alvo=fonte_id, status="TENTANDO", decisao="Passo 1: micro-engine CEASA")
        fonte = self._encontrar_fonte(fonte_id, "ceasas_diretas")
        if not fonte:
            return None

        engine = self._resolver_motor(fonte_id)
        if not engine:
            return None

        resultado = await self._executar_com_timeout(engine, fonte["url_base"], ano, mes, fonte_id)
        if resultado:
            _log_audit(logging.INFO, uf=uf_upper, competencia=f"{ano}-{mes:02d}", alvo=fonte_id, status="SUCESSO", decisao="Dados coletados via micro-engine")
            return [resultado]
        return None

    # ──────────────────────────────────────────────
    # Passo 2 — SmartRouter (adapters dedicados por UF)
    # ──────────────────────────────────────────────
    async def _passo_smartrouter(
        self, uf: str, ano: int, mes: int
    ) -> list[dict[str, Any]] | None:
        uf_upper = uf.upper()
        alvos = _UF_SMARTROUTER_ALVOS.get(uf_upper)
        if not alvos:
            return None

        _log_audit(
            logging.INFO, uf=uf_upper,
            competencia=f"{ano}-{mes:02d}",
            alvo=f"SMARTROUTER_{'_'.join(alvos)}",
            status="TENTANDO",
            decisao="SmartCrawler2026 adapters dedicados",
        )
        crawler = SmartCrawler2026()
        try:
            resultados = await asyncio.wait_for(
                crawler.executar_para_ufs([uf_upper], ano=ano, mes=mes),
                timeout=SCRAPER_TIMEOUT_SEC,
            )
        except asyncio.TimeoutError:
            _log_audit(logging.WARNING, uf=uf_upper, competencia=f"{ano}-{mes:02d}", alvo="SMARTROUTER", status="TIMEOUT", decisao=f"SmartRouter excedeu {SCRAPER_TIMEOUT_SEC}s")
            return None

        cotacoes = resultados.get(uf_upper, [])
        if not cotacoes:
            return None

        brutos = [self._cotacao_to_bruta_dict(c) for c in cotacoes]
        _log_audit(logging.INFO, uf=uf_upper, competencia=f"{ano}-{mes:02d}", alvo="SMARTROUTER", status="SUCESSO", decisao=f"{len(brutos)} registros via {len(alvos)} alvos")
        return brutos

    # ──────────────────────────────────────────────
    # Passo — Contingência para UFs sem CEASA direta
    # ──────────────────────────────────────────────
    async def _passo_contingencia(self, uf: str, ano: int, mes: int) -> list[dict[str, Any]] | None:
        if uf.upper() not in _UFS_CONTINGENCIA:
            return None
        engine = PrecosiagrowebEngine()
        url = "https://sisdep.conab.gov.br/precosiagroweb/"
        resultado = await self._executar_com_timeout(engine, url, ano, mes, "precosiagroweb")
        return [resultado] if resultado else None

    # ──────────────────────────────────────────────
    # Passo — ProHort Mensal (1x por competência)
    # ──────────────────────────────────────────────
    async def _passo_prohort(self, ano: int, mes: int) -> list[dict[str, Any]] | None:
        engine = ProhortMensalEngine()
        url = "https://portaldeinformacoes.conab.gov.br/downloads/arquivos/ProhortMensal.txt"
        resultado = await self._executar_com_timeout(engine, url, ano, mes, "conab-prohort-mensal")
        return [resultado] if resultado else None

    # ──────────────────────────────────────────────
    # Passo final — Discovery (web search)
    # ──────────────────────────────────────────────
    async def _passo_discovery(
        self, uf: str, ano: int, mes: int
    ) -> list[dict[str, Any]]:
        _log_audit(logging.INFO, uf=uf, competencia=f"{ano}-{mes:02d}", alvo="DISCOVERY_AUTONOMO", status="TENTANDO", decisao="Todas as fontes falharam -> discovery engine")
        from pipeline.scraper.discovery_engine import DiscoveryEngine
        engine = DiscoveryEngine()
        try:
            resultados = await asyncio.wait_for(
                engine.buscar(uf, ano, mes),
                timeout=SCRAPER_TIMEOUT_SEC,
            )
        except asyncio.TimeoutError:
            return []
        return resultados

    # ──────────────────────────────────────────────
    # Conversao CotacaoRegional -> raw.coleta_bruta
    # ──────────────────────────────────────────────
    @staticmethod
    def _cotacao_to_bruta_dict(cotacao: CotacaoRegional) -> dict[str, Any]:
        payload = asdict(cotacao)
        return {
            "fonte_id": cotacao.fonte or "SmartRouter",
            "payload_bruto": payload,
            "competencia": f"{cotacao.ano}-{cotacao.mes:02d}",
        }

    # ──────────────────────────────────────────────
    # Execucao blindada para micro-engines
    # ──────────────────────────────────────────────
    async def _executar_com_timeout(
        self,
        engine: BaseMicroEngine,
        url: str,
        ano: int,
        mes: int,
        fonte_id: str,
    ) -> dict[str, Any] | None:
        try:
            return await asyncio.wait_for(
                engine.extract(url, ano, mes),
                timeout=SCRAPER_TIMEOUT_SEC,
            )
        except asyncio.TimeoutError:
            _log_audit(logging.WARNING, uf="?", competencia=f"{ano}-{mes:02d}", alvo=fonte_id, status="TIMEOUT", decisao=f"Motor excedeu {SCRAPER_TIMEOUT_SEC}s")
            return None
        except Exception as exc:
            _log_audit(logging.WARNING, uf="?", competencia=f"{ano}-{mes:02d}", alvo=fonte_id, status="FALHA", decisao=f"Excecao: {exc}")
            return None
        finally:
            await engine.close()

    # ──────────────────────────────────────────────
    # Helpers
    # ──────────────────────────────────────────────
    def _encontrar_fonte(self, fonte_id: str, categoria: str) -> dict | None:
        for item in self._sources.get(categoria, []):
            if item["fonte_id"] == fonte_id:
                return item
        return None

    @staticmethod
    def _resolver_motor(fonte_id: str) -> BaseMicroEngine | None:
        fid = fonte_id.lower()
        if "ceagesp" in fid:
            return CeagespEngine()
        if "prohort-mensal" in fid or "conab-prohort" in fid:
            return ProhortMensalEngine()
        if "precosiagroweb" in fid:
            return PrecosiagrowebEngine()
        if "conab" in fid:
            return ConabApiEngine()
        return None

    async def close(self) -> None:
        pass

    async def __aenter__(self) -> "AutonomousOrchestrator":
        return self

    async def __aexit__(self, *args: Any) -> None:
        await self.close()
