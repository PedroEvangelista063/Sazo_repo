from __future__ import annotations

import asyncio
import logging
from typing import Any

from pipeline.scraper.transport.config import BrowserConfig, EngineType
from pipeline.scraper.transport.engine import StealthTransportEngine

logger = logging.getLogger(__name__)


class PydollTransportEngine(StealthTransportEngine):
    """Async transport engine using Pydoll (direct CDP, no Playwright wrapper).

    Pydoll connects via Chrome DevTools Protocol directly, avoiding the
    Playwright/Puppeteer detection vectors. Suitable for Cloudflare
    undetected-chromium bypass strategies.
    """

    engine_type = EngineType.PYDOLL

    def __init__(self, config: BrowserConfig) -> None:
        super().__init__(config)
        self._pydoll_browser = None
        self._pydoll_page = None

    async def _start_browser(self) -> None:
        try:
            from pydoll import browser as pydoll_browser_module
        except ImportError:
            msg = (
                "Pydoll is required. Install with: pip install pydoll-python"
            )
            raise ImportError(msg) from None

        fp = self._config.fingerprint
        options = {
            "headless": self._config.headless,
            "disable_automation_controls": True,
            "arguments": self._launch_args,
        }

        if fp.proxy:
            options["proxy"] = fp.proxy

        browser_cls = pydoll_browser_module.ChromiumBrowser
        self._pydoll_browser = browser_cls(**options)
        await self._pydoll_browser.start()

    async def _create_context(self) -> None:
        pass

    async def _create_page(self) -> None:
        if not self._pydoll_browser:
            raise RuntimeError("Browser not started")
        self._pydoll_page = await self._pydoll_browser.create_page()

        if self._init_scripts:
            for script in self._init_scripts:
                await self._pydoll_page.execute_script(script)

    async def _stop_impl(self) -> None:
        if self._pydoll_browser:
            await self._pydoll_browser.stop()

    async def navigate(
        self, url: str, wait_until: str = "domcontentloaded", timeout: int | None = None
    ) -> None:
        if not self._pydoll_page:
            raise RuntimeError("No page available")
        timeout = timeout or self._config.navigation_timeout_ms
        await self._pydoll_page.go_to(url)
        await asyncio.sleep(0.5)

    async def content(self) -> str:
        if not self._pydoll_page:
            raise RuntimeError("No page available")
        return await self._pydoll_page.page_source

    async def execute_script(self, script: str) -> Any:
        if not self._pydoll_page:
            raise RuntimeError("No page available")
        return await self._pydoll_page.execute_script(script)

    async def screenshot(self, path: str, full_page: bool = False) -> bytes:
        if not self._pydoll_page:
            raise RuntimeError("No page available")
        result = await self._pydoll_page.take_screenshot(path=path)
        return result if isinstance(result, bytes) else b""

    async def wait_for_selector(self, selector: str, timeout: int | None = None) -> Any:
        if not self._pydoll_page:
            raise RuntimeError("No page available")
        timeout = timeout or self._config.navigation_timeout_ms
        return await self._pydoll_page.wait_element(selector, timeout=timeout)

    async def click(self, selector: str, **kwargs: Any) -> None:
        if not self._pydoll_page:
            raise RuntimeError("No page available")
        await self._pydoll_page.click(selector)

    async def type_text(self, selector: str, text: str, **kwargs: Any) -> None:
        if not self._pydoll_page:
            raise RuntimeError("No page available")
        element = await self._pydoll_page.find_element(selector)
        if element:
            await element.type(text)

    async def select_option(self, selector: str, values: str | list[str], **kwargs: Any) -> list[str]:
        if not self._pydoll_page:
            raise RuntimeError("No page available")
        element = await self._pydoll_page.find_element(selector)
        if element:
            vals = [values] if isinstance(values, str) else values
            for val in vals:
                await element.click()
                opt = await self._pydoll_page.find_element(f"option[value='{val}']")
                if opt:
                    await opt.click()
        return [values] if isinstance(values, str) else values

    async def evaluate(self, expression: str, arg: Any = None) -> Any:
        if not self._pydoll_page:
            raise RuntimeError("No page available")
        return await self._pydoll_page.execute_script(expression)

    async def get_cookies(self) -> list[dict[str, Any]]:
        if not self._pydoll_page:
            raise RuntimeError("No page available")
        return list(self._pydoll_page.cookies)

    async def set_cookies(self, cookies: list[dict[str, Any]]) -> None:
        if not self._pydoll_page:
            raise RuntimeError("No page available")
        for cookie in cookies:
            await self._pydoll_page.set_cookie(cookie)

    async def on_response(self, callback: Any) -> None:
        if not self._pydoll_page:
            raise RuntimeError("No page available")
        self._pydoll_page.on("response", callback)

    async def mouse_move(self, x: int, y: int, steps: int = 10) -> None:
        if not self._pydoll_page:
            raise RuntimeError("No page available")
        await self._pydoll_page.mouse.move(x, y)

    async def mouse_click(self, x: int, y: int) -> None:
        if not self._pydoll_page:
            raise RuntimeError("No page available")
        await self._pydoll_page.mouse.click(x, y)

    async def scroll(self, delta_x: int = 0, delta_y: int = 300) -> None:
        await self.evaluate(f"window.scrollBy({delta_x}, {delta_y})")
