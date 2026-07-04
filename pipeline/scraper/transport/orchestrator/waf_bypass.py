from __future__ import annotations

import logging
from dataclasses import dataclass, field
from enum import Enum
from typing import Any
from xml.etree import ElementTree as ET

import httpx

from pipeline.scraper.transport.semantic.block_detector import BlockDetector

logger = logging.getLogger(__name__)


class EncodingStrategy(str, Enum):
    UTF8 = "utf-8"
    UTF16_LE = "utf-16-le"
    UTF16_BE = "utf-16-be"
    UTF7 = "utf-7"


class XmlPayloadStyle(str, Enum):
    SIMPLE = "simple"
    DOCTYPE_ENTITY = "doctype_entity"
    CDATA = "cdata"
    NESTED_ENTITIES = "nested_entities"


@dataclass
class WafBypassResult:
    success: bool = False
    status_code: int = 0
    body: str = ""
    response_headers: dict[str, str] = field(default_factory=dict)
    method_used: str = ""
    encoding_used: str = "utf-8"
    bypass_attempt: int = 0


@dataclass
class BypassAttempt:
    style: XmlPayloadStyle = XmlPayloadStyle.SIMPLE
    encoding: EncodingStrategy = EncodingStrategy.UTF8
    content_type: str = "application/xml"


_XML_BYPASS_STRATEGIES: list[BypassAttempt] = [
    BypassAttempt(XmlPayloadStyle.SIMPLE, EncodingStrategy.UTF8, "application/xml"),
    BypassAttempt(XmlPayloadStyle.CDATA, EncodingStrategy.UTF8, "application/xml"),
    BypassAttempt(
        XmlPayloadStyle.DOCTYPE_ENTITY, EncodingStrategy.UTF8, "application/xml"
    ),
    BypassAttempt(
        XmlPayloadStyle.NESTED_ENTITIES, EncodingStrategy.UTF8, "application/xml"
    ),
    BypassAttempt(XmlPayloadStyle.SIMPLE, EncodingStrategy.UTF16_LE, "application/xml"),
    BypassAttempt(
        XmlPayloadStyle.DOCTYPE_ENTITY, EncodingStrategy.UTF16_LE, "application/xml"
    ),
    BypassAttempt(
        XmlPayloadStyle.NESTED_ENTITIES, EncodingStrategy.UTF16_BE, "text/xml"
    ),
    BypassAttempt(XmlPayloadStyle.CDATA, EncodingStrategy.UTF16_LE, "application/xml"),
    BypassAttempt(XmlPayloadStyle.SIMPLE, EncodingStrategy.UTF7, "text/xml"),
    BypassAttempt(
        XmlPayloadStyle.DOCTYPE_ENTITY, EncodingStrategy.UTF7, "application/xml"
    ),
]


class WafBypassInterceptor:
    """HTTP interceptor that attempts WAF bypass via XML payload encoding.

    Based on Wallarm Lab research: encapsulate blocked POST/JSON payloads
    in XML structures with controlled entity declarations, alternative
    char encodings (UTF-16, UTF-7), and DOCTYPE permutations to evade
    signature-based WAF rules without triggering XML parser edge cases.
    """

    def __init__(
        self,
        block_detector: BlockDetector | None = None,
        max_bypass_attempts: int = 5,
    ) -> None:
        self._block_detector = block_detector or BlockDetector(use_vader=False)
        self._max_attempts = max_bypass_attempts
        self._client = httpx.AsyncClient(timeout=httpx.Timeout(60.0))
        self._stats: dict[str, int] = {
            "blocks_detected": 0,
            "bypass_attempts": 0,
            "bypass_success": 0,
        }

    def _json_to_xml(
        self, data: dict[str, Any], root_tag: str = "request"
    ) -> ET.Element:
        root = ET.Element(root_tag)
        self._dict_to_xml(data, root)
        return root

    def _dict_to_xml(self, data: dict[str, Any], parent: ET.Element) -> None:
        for key, value in data.items():
            key_sanitized = key.replace(" ", "_").replace("/", "_")
            if isinstance(value, dict):
                child = ET.SubElement(parent, key_sanitized)
                self._dict_to_xml(value, child)
            elif isinstance(value, list):
                child = ET.SubElement(parent, key_sanitized)
                for item in value:
                    if isinstance(item, dict):
                        sub = ET.SubElement(child, "item")
                        self._dict_to_xml(item, sub)
                    else:
                        sub = ET.SubElement(child, "item")
                        sub.text = str(item)
            else:
                child = ET.SubElement(parent, key_sanitized)
                child.text = str(value) if value is not None else ""

    def _render_xml(
        self, root: ET.Element, style: XmlPayloadStyle
    ) -> str:
        xml_str = ET.tostring(root, encoding="unicode", short_empty_elements=False)

        if style == XmlPayloadStyle.SIMPLE:
            return xml_str

        if style == XmlPayloadStyle.CDATA:
            parts = xml_str.split(">", 1)
            if len(parts) == 2:
                return (
                    parts[0]
                    + "><![CDATA["
                    + parts[1].rsplit("<", 1)[0]
                    + "]]></"
                    + root.tag
                    + ">"
                )
            return xml_str

        if style == XmlPayloadStyle.DOCTYPE_ENTITY:
            root_tag = root.tag
            header = (
                f'<?xml version="1.0" encoding="UTF-8"?>\n'
                f'<!DOCTYPE {root_tag} [\n'
                f'  <!ENTITY xxe "data">\n'
                f']>\n'
            )
            return header + f"<{root_tag}>&xxe;</{root_tag}>"

        if style == XmlPayloadStyle.NESTED_ENTITIES:
            root_tag = root.tag
            header = (
                f'<?xml version="1.0" encoding="UTF-8"?>\n'
                f'<!DOCTYPE {root_tag} [\n'
                f'  <!ENTITY % outer "&lt;!ENTITY inner &quot;data&quot;&gt;">\n'
                f'  %outer;\n'
                f']>\n'
            )
            return header + f"<{root_tag}>&inner;</{root_tag}>"

        return xml_str

    def _encode_payload(
        self, xml_str: str, encoding: EncodingStrategy
    ) -> bytes:
        if encoding == EncodingStrategy.UTF8:
            return xml_str.encode("utf-8")

        if encoding == EncodingStrategy.UTF16_LE:
            bom = b"\xff\xfe"
            return bom + xml_str.encode("utf-16-le")

        if encoding == EncodingStrategy.UTF16_BE:
            bom = b"\xfe\xff"
            return bom + xml_str.encode("utf-16-be")

        if encoding == EncodingStrategy.UTF7:
            return xml_str.encode("utf-7")

        return xml_str.encode("utf-8")

    def _detect_block(self, response: httpx.Response) -> bool:
        html = response.text[:5000]
        result = self._block_detector.analyze(
            html,
            page_url=str(response.url),
            status_code=response.status_code,
        )
        return result.is_blocked

    async def try_bypass(
        self,
        url: str,
        original_payload: dict[str, Any],
        original_headers: dict[str, str] | None = None,
        original_method: str = "POST",
    ) -> WafBypassResult:
        headers = dict(original_headers or {})

        for attempt_idx, strategy in enumerate(_XML_BYPASS_STRATEGIES):
            if attempt_idx >= self._max_attempts:
                break

            self._stats["bypass_attempts"] += 1
            root = self._json_to_xml(original_payload)
            xml_str = self._render_xml(root, strategy.style)
            body = self._encode_payload(xml_str, strategy.encoding)

            request_headers = dict(headers)
            request_headers["Content-Type"] = strategy.content_type
            request_headers["Accept"] = "*/*"
            request_headers.pop("Content-Length", None)

            logger.debug(
                "[WafBypass] Attempt %d: style=%s encoding=%s ct=%s size=%dB",
                attempt_idx + 1,
                strategy.style.value,
                strategy.encoding.value,
                strategy.content_type,
                len(body),
            )

            try:
                response = await self._client.request(
                    method=original_method,
                    url=url,
                    content=body,
                    headers=request_headers,
                )

                if response.status_code < 400 and not self._detect_block(response):
                    self._stats["bypass_success"] += 1
                    logger.info(
                        "[WafBypass] SUCCESS attempt %d: %s %s -> HTTP %d",
                        attempt_idx + 1,
                        strategy.style.value,
                        strategy.encoding.value,
                        response.status_code,
                    )
                    return WafBypassResult(
                        success=True,
                        status_code=response.status_code,
                        body=response.text,
                        response_headers=dict(response.headers),
                        method_used=f"xml_{strategy.style.value}_{strategy.encoding.value}",
                        encoding_used=strategy.encoding.value,
                        bypass_attempt=attempt_idx + 1,
                    )

                logger.debug(
                    "[WafBypass] Attempt %d blocked: HTTP %d",
                    attempt_idx + 1,
                    response.status_code,
                )

            except httpx.HTTPError as e:
                logger.debug("[WafBypass] Attempt %d error: %s", attempt_idx + 1, e)
                continue

        return WafBypassResult(
            success=False, status_code=0, method_used="all_exhausted"
        )

    async def try_direct_request(
        self,
        url: str,
        payload: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
        method: str = "GET",
    ) -> WafBypassResult:
        if payload is None:
            try:
                response = await self._client.request(
                    method=method, url=url, headers=headers
                )
            except httpx.HTTPError as e:
                return WafBypassResult(success=False, status_code=0, body=str(e))
        else:
            try:
                response = await self._client.request(
                    method=method,
                    url=url,
                    json=payload,
                    headers=headers,
                )
            except httpx.HTTPError as e:
                return WafBypassResult(success=False, status_code=0, body=str(e))

        return WafBypassResult(
            success=response.status_code < 400,
            status_code=response.status_code,
            body=response.text,
            response_headers=dict(response.headers),
            method_used="direct",
            bypass_attempt=0,
        )

    async def smart_bypass(
        self,
        url: str,
        payload: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
        method: str = "GET",
    ) -> WafBypassResult:
        direct = await self.try_direct_request(url, payload, headers, method)

        if direct.success or (payload is None and direct.status_code < 400):
            return direct

        if payload and direct.status_code in (403, 429, 503, 0):
            self._stats["blocks_detected"] += 1
            logger.info(
                "[WafBypass] Direct blocked (HTTP %d). Trying XML bypass...",
                direct.status_code,
            )
            return await self.try_bypass(url, payload, headers, method)

        return direct

    @property
    def stats(self) -> dict[str, int]:
        return dict(self._stats)

    async def close(self) -> None:
        await self._client.aclose()
