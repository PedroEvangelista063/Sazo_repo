from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import Any

from pipeline.scraper.adapters.base import BaseAdapter, CotacaoRegional

logger = logging.getLogger(__name__)


@dataclass
class ResultadoFonte:
    nome: str
    uf: str
    municipio: str
    status: str
    cotacoes: int
    tempo_s: float
    erro: str = ""


@dataclass
class RelatorioColeta:
    total_adapters: int = 0
    fontes_ok: int = 0
    fontes_falha: int = 0
    total_cotacoes: int = 0
    tempo_execucao_s: float = 0.0
    resultados: list[ResultadoFonte] = field(default_factory=list)
    erros: list[str] = field(default_factory=list)
    proporcao_fontes: dict[str, int] = field(default_factory=dict)

    @property
    def taxa_sucesso_pct(self) -> float:
        total = self.fontes_ok + self.fontes_falha
        return self.fontes_ok / total * 100 if total > 0 else 0.0

    def resumo(self) -> str:
        linhas = [
            "=" * 60,
            "RELATORIO DE COLETA AGRO-REGIONAL",
            "=" * 60,
            f"  Adaptadores:           {self.total_adapters}",
            f"  Sucesso:               {self.fontes_ok}",
            f"  Falha:                 {self.fontes_falha}",
            f"  Taxa de sucesso:       {self.taxa_sucesso_pct:.1f}%",
            f"  Cotacoes coletadas:    {self.total_cotacoes}",
            f"  Tempo total:           {self.tempo_execucao_s:.1f}s",
            "",
        ]
        if self.resultados:
            linhas.append("  Desempenho por fonte:")
            for r in sorted(self.resultados, key=lambda x: x.tempo_s):
                icone = "OK" if r.status == "sucesso" else "XX"
                linhas.append(
                    f"    [{icone}] {r.nome:25s} {r.uf}-{r.municipio:15s} "
                    f"{r.cotacoes:4d} cotacoes  {r.tempo_s:.1f}s"
                )
            linhas.append("")
        if self.erros:
            linhas.append(f"  Erros ({len(self.erros)}):")
            for e in self.erros[:5]:
                linhas.append(f"    - {e}")
            linhas.append("")
        linhas.append("=" * 60)
        return "\n".join(linhas)


class DispatcherOrquestrador:
    def __init__(self, max_concorrencia: int = 5):
        self._semaforo = asyncio.Semaphore(max_concorrencia)
        self._max_concorrencia = max_concorrencia

    async def executar(
        self,
        adapters: list[BaseAdapter],
    ) -> tuple[list[CotacaoRegional], RelatorioColeta]:
        relatorio = RelatorioColeta()
        relatorio.total_adapters = len(adapters)
        t0 = time.perf_counter()
        todas: list[CotacaoRegional] = []

        async def wrapper(adapter: BaseAdapter) -> tuple[str, list[CotacaoRegional], float]:
            t_start = time.perf_counter()
            async with self._semaforo:
                nome = f"{adapter.fonte or adapter.nome}"
                try:
                    items = await adapter.fetch()
                    elapsed = time.perf_counter() - t_start
                    logger.info(
                        "%s %s-%s: %d cotacoes em %.1fs",
                        nome, adapter.uf, adapter.municipio,
                        len(items), elapsed,
                    )
                    relatorio.fontes_ok += 1
                    relatorio.resultados.append(ResultadoFonte(
                        nome=nome,
                        uf=adapter.uf,
                        municipio=adapter.municipio,
                        status="sucesso",
                        cotacoes=len(items),
                        tempo_s=round(elapsed, 1),
                    ))
                    return nome, items, elapsed
                except Exception as e:
                    elapsed = time.perf_counter() - t_start
                    logger.error(
                        "%s %s-%s falhou em %.1fs: %s",
                        nome, adapter.uf, adapter.municipio, elapsed, e,
                    )
                    relatorio.fontes_falha += 1
                    relatorio.erros.append(f"{nome} {adapter.uf}-{adapter.municipio}: {e}")
                    relatorio.resultados.append(ResultadoFonte(
                        nome=nome,
                        uf=adapter.uf,
                        municipio=adapter.municipio,
                        status="erro",
                        cotacoes=0,
                        tempo_s=round(elapsed, 1),
                        erro=str(e)[:200],
                    ))
                    return nome, [], elapsed

        sem_limitado = asyncio.Semaphore(self._max_concorrencia)

        async def limitado(adapter: BaseAdapter) -> list[CotacaoRegional]:
            async with sem_limitado:
                _, items, _ = await wrapper(adapter)
                return items

        tasks = [limitado(adp) for adp in adapters]
        for coro in asyncio.as_completed(tasks):
            items = await coro
            todas.extend(items)

        relatorio.total_cotacoes = len(todas)
        relatorio.tempo_execucao_s = round(time.perf_counter() - t0, 1)

        for item in todas:
            fonte = item.fonte or "desconhecida"
            relatorio.proporcao_fontes[fonte] = (
                relatorio.proporcao_fontes.get(fonte, 0) + 1
            )

        return todas, relatorio

    async def executar_para_produto(
        self,
        produto: str,
        regiao: str | None = None,
    ) -> tuple[list[CotacaoRegional], RelatorioColeta]:
        from pipeline.scraper.adapters.factory import ScraperFactory

        factory = ScraperFactory()
        adapters = factory.adapters_para_produto(produto, regiao)
        if not adapters:
            logger.warning("Nenhum adapter encontrado para %s (regiao=%s)", produto, regiao)
            return [], RelatorioColeta()

        logger.info(
            "Dispatcher: %d adapters para %s (regiao=%s)",
            len(adapters), produto, regiao,
        )
        return await self.executar(adapters)
