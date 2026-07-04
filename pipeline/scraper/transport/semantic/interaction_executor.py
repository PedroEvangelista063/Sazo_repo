from __future__ import annotations

import asyncio
import logging
import random
from typing import Any

from pipeline.scraper.transport.semantic.models import InteractionAction, InteractionStep

logger = logging.getLogger(__name__)

_JITTER_MIN = 0.15
_JITTER_MAX = 0.6


class InteractionExecutor:
    def __init__(self, engine: Any) -> None:
        self._engine = engine

    async def execute(self, steps: list[InteractionStep]) -> None:
        if not steps:
            return
        logger.info(
            "[InteractionExecutor] Executing %d pre-actions", len(steps),
        )
        for i, step in enumerate(steps):
            try:
                await self._execute_one(step)
                jitter = random.uniform(_JITTER_MIN, _JITTER_MAX)
                await asyncio.sleep(jitter)
            except Exception as e:
                logger.warning(
                    "[InteractionExecutor] Step %d/%d failed (%s): %s",
                    i + 1, len(steps), step.action.value, e,
                )

    async def _execute_one(self, step: InteractionStep) -> None:
        timeout = step.timeout or 5000
        sel = step.selector
        val = step.value

        if step.action == InteractionAction.click:
            logger.debug("[InteractionExecutor] click: %s", sel)
            await self._engine.click(sel, timeout=timeout)

        elif step.action == InteractionAction.select:
            logger.debug("[InteractionExecutor] select: %s = %s", sel, val)
            await self._engine.select_option(sel, val)

        elif step.action == InteractionAction.fill:
            logger.debug("[InteractionExecutor] fill: %s = %s", sel, val)
            await self._engine.type_text(sel, val)

        elif step.action == InteractionAction.wait_for_selector:
            logger.debug("[InteractionExecutor] wait: %s (timeout=%d)", sel, timeout)
            await self._engine.wait_for_selector(sel, timeout=timeout)

        elif step.action == InteractionAction.wait_time:
            secs = float(val or "1")
            logger.debug("[InteractionExecutor] wait: %.1fs", secs)
            await asyncio.sleep(secs)
