from __future__ import annotations

import logging
import random
from typing import Any

from pipeline.scraper.transport.config import FingerprintConfig

logger = logging.getLogger(__name__)

UA_POOL = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:127.0) Gecko/20100101 Firefox/127.0",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0",
]

JA3_POOL = [
    "771,4865-4866-4867-49195-49199-49196-49200-52393-52392-49171-49172-156-157-47-53,0-23-65281-10-11-35-16-5-13-18-51-45-43-27-17513-21,29-23-24,0",
    "771,4865-4867-4866-49195-49199-49196-49200-52393-52392-49171-49172-156-157-47-53,0-23-65281-10-11-35-16-5-13-18-51-45-43-27-17513-21,29-23-24,0",
    "771,4865-4866-4867-49195-49199-49196-49200-52393-52392-49171-49172-156-157-47-53,0-23-65281-10-11-35-16-5-13-18-51-45-43-27-17513-21,29-23-24,0",
]


def resolve_user_agent(cfg: FingerprintConfig) -> str:
    if cfg.custom_ua:
        return cfg.custom_ua
    if cfg.dynamic_ua:
        return random.choice(UA_POOL)
    return UA_POOL[0]


def resolve_ja3(cfg: FingerprintConfig) -> str | None:
    if cfg.tls_ja3_override:
        return cfg.tls_ja3_override
    return random.choice(JA3_POOL) if cfg.tls_ja3_override is None else None


def build_webrtc_spoof_js() -> str:
    return """
(() => {
    const nativeRTCPeerConnection = window.RTCPeerConnection || window.webkitRTCPeerConnection;
    if (!nativeRTCPeerConnection) return;
    const proxy = class extends nativeRTCPeerConnection {
        constructor(config) {
            const iceServers = (config?.iceServers || []).map(s => ({
                ...s,
                urls: Array.isArray(s.urls)
                    ? s.urls.filter(u => !u.includes('stun:'))
                    : typeof s.urls === 'string' && !s.urls.includes('stun:') ? s.urls : []
            }));
            super({ ...config, iceServers });
        }
    };
    window.RTCPeerConnection = proxy;
    window.webkitRTCPeerConnection = proxy;
    Object.defineProperty(navigator.mediaDevices, 'enumerateDevices', {
        get: () => async () => []
    });
})();
"""


def build_canvas_spoof_js() -> str:
    return """
(() => {
    const noisify = (orig, ctx) => {
        const originalGetImageData = orig;
        return function(...args) {
            const imageData = originalGetImageData.apply(this, args);
            const pixels = imageData.data;
            for (let i = 0; i < pixels.length; i += 4) {
                pixels[i] = pixels[i] ^ 1;
                pixels[i+1] = pixels[i+1] ^ 1;
                pixels[i+2] = pixels[i+2] ^ 1;
            }
            return imageData;
        };
    };
    const p = CanvasRenderingContext2D.prototype;
    const origGetImageData = p.getImageData;
    p.getImageData = noisify(origGetImageData);

    const offscreen = OffscreenCanvasRenderingContext2D?.prototype;
    if (offscreen) {
        const origOffscreen = offscreen.getImageData;
        offscreen.getImageData = noisify(origOffscreen);
    }
    HTMLCanvasElement.prototype.toBlob = new Proxy(HTMLCanvasElement.prototype.toBlob, {
        apply(target, thisArg, args) {
            const origToDataURL = HTMLCanvasElement.prototype.toDataURL;
            return Reflect.apply(target, thisArg, args);
        }
    });
    const origToDataURL = HTMLCanvasElement.prototype.toDataURL;
    HTMLCanvasElement.prototype.toDataURL = function(type, ...args) {
        const fake = document.createElement('canvas');
        fake.width = this.width;
        fake.height = this.height;
        const ctx = fake.getContext('2d');
        if (ctx) ctx.drawImage(this, 0, 0);
        return origToDataURL.call(fake, type, ...args);
    };
})();
"""


def build_webgl_spoof_js() -> str:
    return """
(() => {
    const getParameter = WebGLRenderingContext.prototype.getParameter;
    WebGLRenderingContext.prototype.getParameter = function(parameter) {
        if (parameter === 37445) return 'Intel Inc.';
        if (parameter === 37446) return 'Intel Iris OpenGL Engine';
        if (parameter === 7936) return ['WebGL Vendor'];
        if (parameter === 7937) return ['WebGL Renderer'];
        if (parameter === 35724) return 'WebGL 1.0 (OpenGL ES 2.0 Chromium)';
        return getParameter.apply(this, arguments);
    };
    const getSupportedExtensions = WebGLRenderingContext.prototype.getSupportedExtensions;
    WebGLRenderingContext.prototype.getSupportedExtensions = function() {
        const exts = getSupportedExtensions.apply(this, arguments);
        return exts.filter(e => !['WEBGL_debug_renderer_info'].includes(e));
    };
})();
"""


def build_audio_spoof_js() -> str:
    return """
(() => {
    const origGetChannelData = AudioBuffer.prototype.getChannelData;
    AudioBuffer.prototype.getChannelData = function(channel) {
        const data = origGetChannelData.apply(this, arguments);
        for (let i = 0; i < data.length; i += 10) {
            data[i] = data[i] + (Math.random() * 0.000001 - 0.0000005);
        }
        return data;
    };
    if (navigator.mediaDevices?.getUserMedia) {
        const orig = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
        navigator.mediaDevices.getUserMedia = async (constraints) => {
            if (constraints?.audio) {
                constraints.audio = false;
            }
            return orig(constraints);
        };
    }
})();
"""


def build_webdriver_undetect_js() -> str:
    return """
(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
    Object.defineProperty(navigator, 'plugins', { get: () => [1,2,3,4,5] });
    Object.defineProperty(navigator, 'languages', { get: () => ['pt-BR', 'en-US', 'en'] });
    window.chrome = { runtime: {} };
    Object.defineProperty(navigator, 'deviceMemory', { get: () => 8 });
    Object.defineProperty(navigator, 'hardwareConcurrency', { get: () => 8 });
    Object.defineProperty(navigator, 'maxTouchPoints', { get: () => 0 });
    Object.defineProperty(navigator, 'onLine', { get: () => true });
    const origToString = Function.prototype.toString;
    Function.prototype.toString = function() {
        if (this === navigator.webdriver) return 'function webdriver() { [native code] }';
        return origToString.call(this);
    };
})();
"""


def build_timezone_spoof_js(tz: str = "America/Sao_Paulo") -> str:
    return f"""
(() => {{
    const origGetTimezoneOffset = Date.prototype.getTimezoneOffset;
    const tzOffset = -new Date().toLocaleString('en', {{ timeZone: '{tz}', timeZoneName: 'short' }});
    try {{
        const parts = new Intl.DateTimeFormat('en', {{ timeZone: '{tz}', timeZoneName: 'short' }}).formatToParts(new Date());
        const tzName = parts.find(p => p.type === 'timeZoneName')?.value || '';
        Object.defineProperty(Intl, 'DateTimeFormat', {{
            get: () => function(locales, options) {{
                return new (Intl.DateTimeFormat.bind.apply(Intl.DateTimeFormat, [null, ...arguments]))({{
                    ...options,
                    timeZone: '{tz}',
                }});
            }}
        }});
    }} catch(e) {{}}
}})();
"""


def build_geolocation_spoof_js(lat: float = -23.5505, lng: float = -46.6333) -> str:
    return f"""
(() => {{
    const origGetCurrentPosition = navigator.geolocation.getCurrentPosition.bind(navigator.geolocation);
    navigator.geolocation.getCurrentPosition = (success, error, options) => {{
        success({{
            coords: {{
                latitude: {lat},
                longitude: {lng},
                accuracy: 10,
                altitude: null,
                altitudeAccuracy: null,
                heading: null,
                speed: null,
            }},
            timestamp: Date.now(),
        }});
    }};
    const origWatchPosition = navigator.geolocation.watchPosition.bind(navigator.geolocation);
    navigator.geolocation.watchPosition = (success, error, options) => {{
        success({{
            coords: {{
                latitude: {lat},
                longitude: {lng},
                accuracy: 10,
                altitude: null,
                altitudeAccuracy: null,
                heading: null,
                speed: null,
            }},
            timestamp: Date.now(),
        }});
        return 0;
    }};
}})();
"""


def build_init_scripts(cfg: FingerprintConfig) -> list[str]:
    scripts: list[str] = [build_webdriver_undetect_js()]
    if cfg.webrtc_spoof:
        scripts.append(build_webrtc_spoof_js())
    if cfg.canvas_spoof:
        scripts.append(build_canvas_spoof_js())
    if cfg.webgl_spoof:
        scripts.append(build_webgl_spoof_js())
    if cfg.audio_spoof:
        scripts.append(build_audio_spoof_js())
    if cfg.timezone_spoof:
        scripts.append(build_timezone_spoof_js(cfg.timezone))
    if cfg.geolocation_spoof:
        geo = cfg.geolocation or {"lat": -23.5505, "lng": -46.6333}
        scripts.append(build_geolocation_spoof_js(**geo))
    return scripts


def build_launch_args(cfg: FingerprintConfig) -> list[str]:
    args: list[str] = [
        "--disable-blink-features=AutomationControlled",
        "--disable-features=IsolateOrigins,site-per-process",
        "--disable-session-crashed-bubble",
        "--disable-search-engine-choice-screen",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-background-timer-throttling",
        "--disable-backgrounding-occluded-windows",
        "--disable-renderer-backgrounding",
        "--disable-field-trial-config",
        "--disable-breakpad",
        "--disable-crash-reporter",
        "--disable-component-update",
        "--disable-infobars",
        "--disable-sync",
    ]

    if cfg.extensions_paths:
        ext_arg = ",".join(
            # É mandatório passar o caminho do diretório extraído, não o arquivo zip
            p.rstrip(".zip") if p.endswith(".zip") else p
            for p in cfg.extensions_paths
        )
        args.append(f"--load-extension={ext_arg}")

    if cfg.proxy:
        args.append(f"--proxy-server={cfg.proxy}")

    args.extend(cfg.extra_args)
    return args


def build_context_kwargs(cfg: FingerprintConfig) -> dict[str, Any]:
    kwargs: dict[str, Any] = {
        "viewport": cfg.viewport,
        "locale": cfg.locale,
        "timezone_id": cfg.timezone,
    }

    if cfg.geolocation:
        geo = cfg.geolocation
        if "lat" in geo and "lng" in geo:
            kwargs["geolocation"] = {"latitude": geo["lat"], "longitude": geo["lng"]}
        else:
            kwargs["geolocation"] = geo
        kwargs["permissions"] = ["geolocation"]

    if cfg.custom_ua or cfg.dynamic_ua:
        kwargs["user_agent"] = resolve_user_agent(cfg)

    return kwargs
