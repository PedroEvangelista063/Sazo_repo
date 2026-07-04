from __future__ import annotations

import asyncio
import logging
from typing import Any

from pipeline.scraper.transport.config import BrowserConfig, EngineType
from pipeline.scraper.transport.engine import StealthTransportEngine
from pipeline.scraper.transport.fingerprint import (
    build_context_kwargs,
)

logger = logging.getLogger(__name__)


class PatchrightCamoufoxTransportEngine(StealthTransportEngine):
    """Async transport engine using Patchright (Playwright fork) + Camoufox.

    Patchright is an undetectable Playwright fork that bypasses CDP leak
    detection. Camoufox provides Firefox-based fingerprint randomization
    (WebRTC, Canvas, TLS/JA3, fonts, screen resolution).

    Falls back to Playwright + playwright-stealth if Patchright is not
    installed.
    """

    engine_type = EngineType.PATCHRIGHT

    def __init__(self, config: BrowserConfig) -> None:
        super().__init__(config)
        self._pw = None
        self._stealth_installed = False

    def _resolve_playwright_module(self):
        try:
            import patchright.async_api as pw_api
            logger.info("[Patchright] Using Patchright (undetectable Playwright fork)")
            return pw_api, False
        except ImportError:
            try:
                import playwright.async_api as pw_api
                logger.info("[Patchright] Patchright not found, falling back to Playwright")
                return pw_api, True
            except ImportError:
                try:
                    from seleniumbase import Driver as SeleniumBaseDriver  # noqa: F401
                    logger.info("[Patchright] Neither found — SeleniumBase UC available as fallback")
                    return None, True
                except ImportError:
                    msg = (
                        "No browser automation library found.\n"
                        "Install: pip install patchright && patchright install chromium\n"
                        "Or:     pip install playwright && playwright install\n"
                        "Or:     pip install seleniumbase"
                    )
                    raise ImportError(msg) from None

    async def _try_apply_stealth(self, context: Any, pw_api: Any) -> None:
        try:
            from playwright_stealth import StealthConfig, stealth_sync

            stealth_config = StealthConfig(
                webdriver=True,
                webgl_vendor="Intel Inc.",
                webgl_renderer="Intel Iris OpenGL Engine",
                vendor_flavor="Google Inc. (Intel)",
                navigator_platform="Win32",
                navigator_languages=["pt-BR", "en-US", "en"],
                navigator_vendor="Google Inc.",
                navigator_user_agent=self._config.fingerprint.custom_ua,
            )
            await stealth_sync(context, stealth_config)
            self._stealth_installed = True
            logger.info("[Patchright] playwright-stealth applied")
        except ImportError:
            logger.debug("[Patchright] playwright-stealth not available, using JS overrides")
        except Exception as e:
            logger.warning("[Patchright] stealth application failed: %s", e)

    async def _try_seleniumbase(self) -> None:
        try:
            from seleniumbase import Driver  # noqa: F401
            self._sb_driver = _SeleniumBaseAdapter(self._config, self._init_scripts)
            await self._sb_driver.start()
            self._browser = self._sb_driver
            self._page = self._sb_driver
            logger.info("[Patchright] SeleniumBase UC driver active")
        except Exception as e:
            raise RuntimeError(f"SeleniumBase fallback failed: {e}") from e

    async def _start_browser(self) -> None:
        pw_api, needs_fallback = self._resolve_playwright_module()

        if pw_api is None:
            await self._try_seleniumbase()
            return

        self._pw_api = pw_api
        self._pw = await pw_api.async_playwright().start()

        browser_type = self._config.browser.value
        launch_options: dict[str, Any] = {
            "headless": self._config.headless,
            "args": self._launch_args,
        }

        if self._config.fingerprint.proxy:
            launch_options["proxy"] = {"server": self._config.fingerprint.proxy}

        launch_options.update(self._config.extra_launch_args)

        if browser_type == "chromium":
            self._browser = await self._pw.chromium.launch(**launch_options)
        elif browser_type == "firefox":
            self._browser = await self._pw.firefox.launch(**launch_options)
        else:
            self._browser = await self._pw.webkit.launch(**launch_options)

    async def _create_context(self) -> None:
        if not self._browser:
            raise RuntimeError("Browser not started")

        context_kwargs = build_context_kwargs(self._config.fingerprint)

        if self._config.storage_state_path:
            context_kwargs["storage_state"] = self._config.storage_state_path

        self._context = await self._browser.new_context(**context_kwargs)

        await self._try_apply_stealth(self._context, self._pw_api)

        await self._context.add_init_script(
            "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
        )

        for script in self._init_scripts:
            await self._context.add_init_script(script)

        await self._context.add_init_script(
            """
            navigator.permissions.query = (() => {
                const original = navigator.permissions.query.bind(navigator.permissions);
                return async (desc) => {
                    if (desc.name === 'notifications' || desc.name === 'clipboard-read') {
                        return { state: 'prompt', onchange: null };
                    }
                    return original(desc);
                };
            })();
            """
        )

    async def _create_page(self) -> None:
        if not self._context:
            raise RuntimeError("Context not created")
        self._page = await self._context.new_page()

    async def _stop_impl(self) -> None:
        if self._context:
            await self._context.close()
        if self._browser:
            await self._browser.close()
        if self._pw:
            await self._pw.stop()

    async def navigate(
        self, url: str, wait_until: str = "domcontentloaded", timeout: int | None = None
    ) -> None:
        if not self._page:
            raise RuntimeError("No page available")
        timeout = timeout or self._config.navigation_timeout_ms
        await self._page.goto(url, wait_until=wait_until, timeout=timeout)

    async def content(self) -> str:
        if not self._page:
            raise RuntimeError("No page available")
        return await self._page.content()

    async def execute_script(self, script: str) -> Any:
        if not self._page:
            raise RuntimeError("No page available")
        return await self._page.evaluate(script)

    async def screenshot(self, path: str, full_page: bool = False) -> bytes:
        if not self._page:
            raise RuntimeError("No page available")
        return await self._page.screenshot(path=path, full_page=full_page)

    async def wait_for_selector(self, selector: str, timeout: int | None = None) -> Any:
        if not self._page:
            raise RuntimeError("No page available")
        timeout = timeout or self._config.navigation_timeout_ms
        return await self._page.wait_for_selector(selector, timeout=timeout)

    async def click(self, selector: str, **kwargs: Any) -> None:
        if not self._page:
            raise RuntimeError("No page available")
        await self._page.click(selector, **kwargs)

    async def type_text(self, selector: str, text: str, **kwargs: Any) -> None:
        if not self._page:
            raise RuntimeError("No page available")
        await self._page.fill(selector, text, **kwargs)

    async def select_option(
        self, selector: str, values: str | list[str], **kwargs: Any
    ) -> list[str]:
        if not self._page:
            raise RuntimeError("No page available")
        result = await self._page.select_option(selector, values, **kwargs)
        return result if isinstance(result, list) else [result]

    async def evaluate(self, expression: str, arg: Any = None) -> Any:
        if not self._page:
            raise RuntimeError("No page available")
        return await self._page.evaluate(expression, arg)

    async def get_cookies(self) -> list[dict[str, Any]]:
        if not self._context:
            raise RuntimeError("No context available")
        return await self._context.cookies()

    async def set_cookies(self, cookies: list[dict[str, Any]]) -> None:
        if not self._context:
            raise RuntimeError("No context available")
        await self._context.add_cookies(cookies)

    async def on_response(self, callback: Any) -> None:
        if not self._page:
            raise RuntimeError("No page available")
        self._page.on("response", callback)

    async def mouse_move(self, x: int, y: int, steps: int = 10) -> None:
        if not self._page:
            raise RuntimeError("No page available")
        await self._page.mouse.move(x, y, steps=steps)

    async def mouse_click(self, x: int, y: int) -> None:
        if not self._page:
            raise RuntimeError("No page available")
        await self._page.mouse.click(x, y)

    async def scroll(self, delta_x: int = 0, delta_y: int = 300) -> None:
        await self._page.evaluate(f"window.scrollBy({delta_x}, {delta_y})")


class _SeleniumBaseAdapter:
    """Wraps SeleniumBase UC Driver to match StealthTransportEngine interface.

    SeleniumBase uses undetected-chromedriver under the hood with built-in
    fingerprint randomization. The `uc=True` flag enables undetected mode.
    `extension_dir` must point to an extracted directory, not a .zip file.
    """

    def __init__(self, config: Any, init_scripts: list[str]) -> None:
        self._config = config
        self._init_scripts = init_scripts
        self._driver = None
        self._running = False

    async def start(self) -> None:
        from seleniumbase import Driver
        fp = self._config.fingerprint
        options = {
            "uc": True,
            "headless": self._config.headless,
            "headless2": self._config.headless,
        }
        if fp.extensions_paths:
            options["extension_dir"] = fp.extensions_paths[0]
        if fp.proxy:
            options["proxy"] = fp.proxy
        if fp.user_agent:
            options["agent"] = fp.user_agent

        def _launch():
            d = Driver(**options)
            for script in self._init_scripts:
                d.execute_cdp_cmd("Page.addScriptToEvaluateOnNewDocument", {"source": script})
            return d

        self._driver = await asyncio.to_thread(_launch)
        self._running = True

    async def stop(self) -> None:
        if self._driver:
            self._driver.quit()
            self._running = False

    async def navigate(self, url: str, **kwargs: Any) -> None:
        await asyncio.to_thread(self._driver.get, url)

    async def content(self) -> str:
        return self._driver.page_source

    async def evaluate(self, script: str) -> Any:
        return self._driver.execute_script(script)

    async def screenshot(self, path: str, **kwargs: Any) -> bytes:
        self._driver.save_screenshot(path)
        with open(path, "rb") as f:
            return f.read()

    async def get_cookies(self) -> list[dict[str, Any]]:
        return [{"name": c["name"], "value": c["value"], "domain": c.get("domain", ""),
                 "path": c.get("path", "/"), "httpOnly": c.get("httpOnly", False),
                 "secure": c.get("secure", True)}
                for c in self._driver.get_cookies()]

    async def set_cookies(self, cookies: list[dict[str, Any]]) -> None:
        for c in cookies:
            self._driver.add_cookie(c)

    async def execute_script(self, script: str) -> Any:
        return self._driver.execute_script(script)

    async def wait_for_selector(self, selector: str, timeout: int | None = None) -> Any:
        import asyncio
        return await asyncio.to_thread(
            lambda: self._driver.find_element("css selector", selector)
        )

    async def click(self, selector: str, **kwargs: Any) -> None:
        import asyncio
        el = self._driver.find_element("css selector", selector)
        await asyncio.to_thread(el.click)

    async def mouse_move(self, x: int, y: int, steps: int = 10) -> None:
        from selenium.webdriver.common.action_chains import ActionChains
        actions = ActionChains(self._driver)
        actions.move_by_offset(x, y)
        actions.perform()

    async def mouse_click(self, x: int, y: int) -> None:
        from selenium.webdriver.common.action_chains import ActionChains
        actions = ActionChains(self._driver)
        actions.move_by_offset(x, y).click().perform()

    async def type_text(self, selector: str, text: str, **kwargs: Any) -> None:
        el = self._driver.find_element("css selector", selector)
        el.clear()
        el.send_keys(text)

    async def select_option(self, selector: str, values: str | list[str], **kwargs: Any) -> list[str]:
        from selenium.webdriver.support.ui import Select
        el = self._driver.find_element("css selector", selector)
        select = Select(el)
        vals = [values] if isinstance(values, str) else values
        for v in vals:
            select.select_by_value(v)
        return vals

    async def on_response(self, callback: Any) -> None:
        pass

    async def scroll(self, **kwargs: Any) -> None:
        self._driver.execute_script("window.scrollBy(0, 300)")

    @property
    def running(self) -> bool:
        return self._running
