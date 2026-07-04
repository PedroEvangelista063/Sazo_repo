from __future__ import annotations

import logging
from abc import ABC, abstractmethod
from typing import Any, Protocol

from pipeline.scraper.transport.config import BrowserConfig, EngineType
from pipeline.scraper.transport.fingerprint import (
    build_init_scripts,
    build_launch_args,
    resolve_user_agent,
)

logger = logging.getLogger(__name__)


class PageProxy(Protocol):
    url: str

    async def content(self) -> str: ...
    async def title(self) -> str: ...


class StealthTransportEngine(ABC):
    engine_type: EngineType

    def __init__(self, config: BrowserConfig) -> None:
        self._config = config
        self._page: Any = None
        self._browser: Any = None
        self._context: Any = None
        self._running = False
        self._init_scripts: list[str] = []
        self._launch_args: list[str] = []

    @abstractmethod
    async def _start_browser(self) -> None:
        ...

    @abstractmethod
    async def _create_context(self) -> Any:
        ...

    @abstractmethod
    async def _create_page(self) -> Any:
        ...

    async def start(self) -> None:
        if self._running:
            logger.warning("[%s] Engine already running", self.engine_type)
            return

        fp_cfg = self._config.fingerprint
        self._init_scripts = build_init_scripts(fp_cfg)
        self._launch_args = build_launch_args(fp_cfg)
        self._config.fingerprint.custom_ua = resolve_user_agent(fp_cfg)

        logger.info(
            "[%s] Starting engine | headless=%s | ua=%s...",
            self.engine_type,
            self._config.headless,
            self._config.fingerprint.custom_ua[:80],
        )

        await self._start_browser()
        await self._create_context()
        await self._create_page()
        self._running = True
        logger.info("[%s] Engine ready", self.engine_type)

    async def stop(self) -> None:
        if not self._running:
            return
        logger.info("[%s] Stopping engine", self.engine_type)
        try:
            await self._stop_impl()
        except Exception as e:
            logger.warning("[%s] Error during stop: %s", self.engine_type, e)
        self._running = False
        self._page = None
        self._context = None
        self._browser = None

    @abstractmethod
    async def _stop_impl(self) -> None:
        ...

    @abstractmethod
    async def navigate(
        self, url: str, wait_until: str = "domcontentloaded", timeout: int | None = None
    ) -> None:
        ...

    @abstractmethod
    async def content(self) -> str:
        ...

    @abstractmethod
    async def execute_script(self, script: str) -> Any:
        ...

    @abstractmethod
    async def screenshot(self, path: str, full_page: bool = False) -> bytes:
        ...

    @abstractmethod
    async def wait_for_selector(
        self, selector: str, timeout: int | None = None
    ) -> Any:
        ...

    @abstractmethod
    async def click(self, selector: str, **kwargs: Any) -> None:
        ...

    @abstractmethod
    async def type_text(self, selector: str, text: str, **kwargs: Any) -> None:
        ...

    @abstractmethod
    async def select_option(
        self, selector: str, values: str | list[str], **kwargs: Any
    ) -> list[str]:
        ...

    @abstractmethod
    async def evaluate(self, expression: str, arg: Any = None) -> Any:
        ...

    @abstractmethod
    async def get_cookies(self) -> list[dict[str, Any]]:
        ...

    @abstractmethod
    async def set_cookies(self, cookies: list[dict[str, Any]]) -> None:
        ...

    @abstractmethod
    async def on_response(self, callback: Any) -> None:
        ...

    @abstractmethod
    async def mouse_move(self, x: int, y: int, steps: int = 10) -> None:
        ...

    @abstractmethod
    async def mouse_click(self, x: int, y: int) -> None:
        ...

    @abstractmethod
    async def scroll(self, delta_x: int = 0, delta_y: int = 300) -> None:
        ...

    @property
    def running(self) -> bool:
        return self._running

    @property
    def page(self) -> Any:
        return self._page

    @property
    def config(self) -> BrowserConfig:
        return self._config
