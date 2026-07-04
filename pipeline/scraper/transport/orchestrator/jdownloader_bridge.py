from __future__ import annotations

import json
import logging
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import httpx

logger = logging.getLogger(__name__)

_RE_HEAVY_FILE = re.compile(
    r"\.(zip|rar|7z|tar\.gz|tgz|mp4|mkv|avi|iso|dmg|exe|msi|pdf)$", re.IGNORECASE
)
_RE_TEMP_TOKEN = re.compile(
    r"(token|sign|expir|auth|key|hash|secure)[=]\w{8,}", re.IGNORECASE
)
_RE_SEGMENTED = re.compile(
    r"(part|seg|chunk|piece|split|zip\.\d{3})", re.IGNORECASE
)


@dataclass
class DownloadCandidate:
    url: str = ""
    filename: str = ""
    size_bytes: int = 0
    source_url: str = ""
    is_heavy: bool = False
    has_temp_token: bool = False
    is_segmented: bool = False
    mime_type: str = ""
    headers: dict[str, str] = field(default_factory=dict)


@dataclass
class JDownloaderStatus:
    connected: bool = False
    device_name: str = ""
    download_speed: int = 0
    queue_count: int = 0
    running_count: int = 0
    error: str = ""


class JDownloaderBridge:
    """Interface for JDownloader via MyJDownloader API or watch folder.

    Primary: MyJDownloader REST API (https://api.jdownloader.org)
    Fallback: watch folder monitoring for manual JDownloader integration.
    """

    API_BASE = "https://api.jdownloader.org"

    def __init__(
        self,
        myjdownloader_email: str = "",
        myjdownloader_password: str = "",
        device_name: str = "",
        watch_folder: str = "",
    ) -> None:
        self._email = myjdownloader_email
        self._password = myjdownloader_password
        self._device_name = device_name
        self._watch_folder = Path(watch_folder) if watch_folder else None
        self._session_token: str = ""
        self._regain_token: str = ""
        self._api_client: httpx.AsyncClient | None = None
        self._direct_connection: dict[str, Any] = {}
        self._connected = False
        self._pending: list[DownloadCandidate] = []

    async def _ensure_api_client(self) -> httpx.AsyncClient:
        if self._api_client is None:
            self._api_client = httpx.AsyncClient(
                base_url=self.API_BASE, timeout=httpx.Timeout(30.0)
            )
        return self._api_client

    async def connect(self) -> bool:
        if self._connected:
            return True
        if not self._email or not self._password:
            logger.info("[JDownloader] No credentials — using watch folder mode")
            return await self._ensure_watch_folder()

        return await self._connect_api()

    async def _connect_api(self) -> bool:
        try:
            client = await self._ensure_api_client()
            resp = await client.post(
                "/my/connect",
                json={"email": self._email, "passwd": self._password},
            )
            if resp.status_code != 200:
                logger.error("[JDownloader] Auth failed: HTTP %d", resp.status_code)
                return False

            data = resp.json()
            self._session_token = data.get("sessionToken", "")
            self._regain_token = data.get("regainToken", "")

            if not self._session_token:
                logger.error("[JDownloader] No session token in response")
                return False

            await self._resolve_device()
            self._connected = True
            logger.info("[JDownloader] Connected and device '%s' resolved", self._device_name)
            return True

        except httpx.HTTPError as e:
            logger.error("[JDownloader] API connection failed: %s", e)
            return await self._ensure_watch_folder()
        except Exception as e:
            logger.error("[JDownloader] Connection error: %s", e)
            return await self._ensure_watch_folder()

    async def _resolve_device(self) -> None:
        if not self._session_token:
            return
        try:
            client = await self._ensure_api_client()
            resp = await client.post(
                "/my/configuredevices",
                json={"sessionToken": self._session_token},
            )
            if resp.status_code == 200:
                devices = resp.json().get("list", [])
                if self._device_name:
                    for dev in devices:
                        if dev.get("name") == self._device_name:
                            self._direct_connection = dev
                            break
                elif devices:
                    self._direct_connection = devices[0]
                    self._device_name = self._direct_connection.get("name", "")
        except Exception as e:
            logger.warning("[JDownloader] Device resolution failed: %s", e)

    async def _ensure_watch_folder(self) -> bool:
        if self._watch_folder:
            self._watch_folder.mkdir(parents=True, exist_ok=True)
            logger.info(
                "[JDownloader] Watch folder ready: %s", self._watch_folder
            )
            self._connected = True
            return True
        logger.warning("[JDownloader] No watch folder configured — download bridge inactive")
        return False

    async def add_link(self, url: str, filename: str = "", package_name: str = "") -> bool:
        candidate = DownloadCandidate(url=url, filename=filename, source_url=url)
        return await self.add_links([candidate], package_name)

    async def add_links(
        self, candidates: list[DownloadCandidate], package_name: str = ""
    ) -> bool:
        if not self._connected:
            await self.connect()

        if not self._connected:
            logger.error("[JDownloader] Not connected — cannot add links")
            return False

        if not self._session_token:
            return await self._add_links_watch(candidates)

        return await self._add_links_api(candidates, package_name)

    async def _add_links_api(
        self, candidates: list[DownloadCandidate], package_name: str
    ) -> bool:
        try:
            client = await self._ensure_api_client()
            urls = [c.url for c in candidates]
            payload = {
                "sessionToken": self._session_token,
                "deviceId": self._direct_connection.get("id", ""),
                "urls": json.dumps(urls),
            }
            if package_name:
                payload["packageName"] = package_name
            if candidates and candidates[0].filename:
                payload["autoStart"] = True

            resp = await client.post(
                "/device/addLinks", json=payload, timeout=60.0
            )
            success = resp.status_code == 200
            if success:
                logger.info("[JDownloader] %d links sent to JDownloader", len(candidates))
            else:
                logger.warning("[JDownloader] addLinks HTTP %d", resp.status_code)
            return success
        except Exception as e:
            logger.error("[JDownloader] API addLinks failed: %s", e)
            return False

    async def _add_links_watch(self, candidates: list[DownloadCandidate]) -> bool:
        if not self._watch_folder:
            return False
        try:
            link_file = self._watch_folder / f"links_{int(time.time())}.txt"
            urls = [c.url for c in candidates]
            link_file.write_text("\n".join(urls), encoding="utf-8")
            logger.info(
                "[JDownloader] %d URLs written to %s", len(candidates), link_file
            )
            return True
        except Exception as e:
            logger.error("[JDownloader] Watch folder write failed: %s", e)
            return False

    async def query_queue(self) -> JDownloaderStatus:
        status = JDownloaderStatus(device_name=self._device_name)
        if not self._session_token:
            return status

        try:
            client = await self._ensure_api_client()
            resp = await client.post(
                "/device/queryQueue",
                json={
                    "sessionToken": self._session_token,
                    "deviceId": self._direct_connection.get("id", ""),
                },
                timeout=15.0,
            )
            if resp.status_code == 200:
                data = resp.json()
                status.connected = True
                status.queue_count = len(data.get("data", []))
        except Exception as e:
            status.error = str(e)
        return status

    async def get_downloads(self) -> list[DownloadCandidate]:
        if not self._session_token:
            return list(self._pending)
        status = await self.query_queue()
        return list(self._pending) if not status.connected else self._pending

    async def evaluate_link(self, url: str, source_url: str = "") -> DownloadCandidate:
        parsed = urlparse(url)
        path = parsed.path
        filename = path.split("/")[-1] if path else "download"

        candidate = DownloadCandidate(
            url=url,
            filename=filename,
            source_url=source_url or url,
            is_heavy=bool(_RE_HEAVY_FILE.search(filename)),
            has_temp_token=bool(_RE_TEMP_TOKEN.search(url)),
            is_segmented=bool(_RE_SEGMENTED.search(filename)),
        )

        if candidate.is_heavy or candidate.has_temp_token or candidate.is_segmented:
            logger.info(
                "[JDownloader] Candidate: %s | heavy=%s token=%s seg=%s",
                filename[:60], candidate.is_heavy, candidate.has_temp_token,
                candidate.is_segmented,
            )

        return candidate

    async def auto_enqueue_heavy(self, links: list[str], source_url: str = "") -> int:
        candidates: list[DownloadCandidate] = []
        for link in links:
            candidate = await self.evaluate_link(link, source_url)
            if candidate.is_heavy or candidate.has_temp_token or candidate.is_segmented:
                candidates.append(candidate)

        if not candidates:
            return 0

        package = f"Scraper_{source_url[:30]}" if source_url else "Scraper_Auto"
        await self.add_links(candidates, package_name=package)
        return len(candidates)

    async def status(self) -> JDownloaderStatus:
        return await self.query_queue()

    async def close(self) -> None:
        if self._api_client:
            await self._api_client.aclose()
            self._api_client = None
        self._connected = False

    @staticmethod
    def is_download_link(url: str, content_type: str = "") -> bool:
        if _RE_HEAVY_FILE.search(url):
            return True
        if _RE_TEMP_TOKEN.search(url):
            return True
        if _RE_SEGMENTED.search(url):
            return True
        if content_type:
            ct = content_type.lower()
            if any(
                t in ct
                for t in [
                    "application/zip",
                    "application/x-rar",
                    "application/x-7z",
                    "application/octet-stream",
                    "application/pdf",
                    "video/",
                ]
            ):
                return True
        return False
