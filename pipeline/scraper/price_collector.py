from __future__ import annotations

import asyncio
import logging
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass, field

from pipeline.scraper.ceasa_spider import CotacaoHistorica

logger = logging.getLogger(__name__)


class ScraperAdapter(ABC):
    nome: str = ""
    uf: str = ""
    municipio: str = ""
    semaforo: asyncio.Semaphore | None = None

    @abstractmethod
    async def fetch(self) -> list[CotacaoHistorica]: ...


@dataclass
class QualidadeMetricas:
    total_adapters: int = 0
    total_bruto: int = 0
    total_apos_fuzzy: int = 0
    total_localidades: int = 0
    fontes_ok: int = 0
    fontes_falha: int = 0
    tempo_execucao_s: float = 0.0
    taxa_conversao_pct: float = 0.0
    proporcao_categorias: dict[str, int] = field(default_factory=dict)
    erros: list[str] = field(default_factory=list)
    adapters_executados: list[dict] = field(default_factory=list)

    def relatorio(self) -> str:
        linhas = [
            "=" * 50,
            "RELATORIO DE COLETA \u2014 QUALIDADE",
            "=" * 50,
            f"  Adaptadores registrados:    {self.total_adapters}",
            f"  Fontes com sucesso:         {self.fontes_ok}",
            f"  Fontes com falha:           {self.fontes_falha}",
            f"  Taxa de sucesso:            {self.taxa_sucesso_pct():.1f}%",
            f"",
            f"  Cotacoes brutas:            {self.total_bruto}",
            f"  Apos fuzzy + staging:       {self.total_apos_fuzzy}",
            f"  Taxa de conversao:          {self.taxa_conversao_pct:.1f}%",
            f"  Tempo de execucao:          {self.tempo_execucao_s:.1f}s ({self.tempo_execucao_s/60:.1f}min)",
            f"",
        ]
        if self.proporcao_categorias:
            linhas.append("  Proporcao por fonte (bruto):")
            for cat, qtd in sorted(self.proporcao_categorias.items()):
                pct = qtd / self.total_bruto * 100 if self.total_bruto > 0 else 0
                linhas.append(f"    {cat}: {qtd} ({pct:.1f}%)")
            linhas.append("")

        if self.adapters_executados:
            linhas.append("  Desempenho por adapter:")
            for a in sorted(self.adapters_executados, key=lambda x: x["tempo_s"]):
                icone = "OK" if a["status"] == "ok" else "XX"
                linhas.append(f"    [{icone}] {a['nome']:30s} {a['uf']}-{a['municipio']:15s} {a['cotacoes']:4d} cotacoes  {a['tempo_s']:.1f}s")
            linhas.append("")

        if self.erros:
            linhas.append(f"  Erros ({len(self.erros)}):")
            for e in self.erros[:5]:
                linhas.append(f"    - {e}")
            linhas.append("")

        linhas.append("=" * 50)
        return "\n".join(linhas)

    def taxa_sucesso_pct(self) -> float:
        total = self.fontes_ok + self.fontes_falha
        return self.fontes_ok / total * 100 if total > 0 else 0.0


class PriceCollector:
    def __init__(self):
        self._adapters: dict[str, ScraperAdapter] = {}
        self._semaforo = asyncio.Semaphore(3)

    def register_adapter(self, nome: str, adapter: ScraperAdapter) -> None:
        adapter.semaforo = self._semaforo
        self._adapters[nome] = adapter

    def register_from_localidades(self, localidades: list[dict]) -> None:
        from pipeline.scraper.adapters import HFBrasilAdapter, CEAGESPAdapter, adapter_discovery

        conhecidos = {
            "HF Brasil/CEPEA": HFBrasilAdapter,
            "CEAGESP": CEAGESPAdapter,
        }

        for loc in localidades:
            cls = conhecidos.get(loc["fonte"])
            if cls:
                nome = f"{loc['fonte']} {loc['uf']}-{loc['municipio']}"
                self.register_adapter(nome, cls(loc["uf"], loc["municipio"]))
                continue

            discovered = adapter_discovery(loc)
            if discovered:
                nome = f"{loc['fonte']} {loc['uf']}-{loc['municipio']}"
                self.register_adapter(nome, discovered)

    def total_adapters(self) -> int:
        return len(self._adapters)

    async def collect_all(self, max_concorrencia: int = 3) -> tuple[list[CotacaoHistorica], QualidadeMetricas]:
        self._semaforo = asyncio.Semaphore(max_concorrencia)
        metricas = QualidadeMetricas()
        metricas.total_adapters = len(self._adapters)
        t0 = time.perf_counter()

        todas: list[CotacaoHistorica] = []

        async def wrapper(nome: str, adapter: ScraperAdapter) -> tuple[str, list[CotacaoHistorica], float]:
            t_start = time.perf_counter()
            async with self._semaforo:
                try:
                    items = await adapter.fetch()
                    t = time.perf_counter() - t_start
                    logger.info("Adapter %s %s-%s: %d cotacoes em %.1fs", nome, adapter.uf, adapter.municipio, len(items), t)
                    if len(items) == 0:
                        logger.warning("FONTE VAZIA: %s %s-%s retornou 0 cotacoes", nome, adapter.uf, adapter.municipio)
                    metricas.fontes_ok += 1
                    metricas.adapters_executados.append({
                        "nome": nome, "uf": adapter.uf, "municipio": adapter.municipio,
                        "status": "ok", "cotacoes": len(items), "tempo_s": round(t, 1),
                    })
                    return nome, items, t
                except Exception as e:
                    t = time.perf_counter() - t_start
                    logger.error("Adapter %s falhou em %.1fs: %s", nome, t, e)
                    metricas.fontes_falha += 1
                    metricas.erros.append(f"{nome}: {e}")
                    metricas.adapters_executados.append({
                        "nome": nome, "uf": adapter.uf, "municipio": adapter.municipio,
                        "status": "erro", "cotacoes": 0, "tempo_s": round(t, 1),
                    })
                    return nome, [], t

        tasks = [wrapper(nome, adp) for nome, adp in self._adapters.items()]
        for coro in asyncio.as_completed(tasks):
            _, items, _ = await coro
            todas.extend(items)

        metricas.total_bruto = len(todas)
        metricas.tempo_execucao_s = round(time.perf_counter() - t0, 1)

        for item in todas:
            fonte = item.fonte or "desconhecida"
            metricas.proporcao_categorias[fonte] = metricas.proporcao_categorias.get(fonte, 0) + 1

        return todas, metricas
