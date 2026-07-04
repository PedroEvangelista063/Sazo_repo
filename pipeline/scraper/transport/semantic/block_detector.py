from __future__ import annotations

import logging
import re

from pipeline.scraper.transport.semantic.models import BlockDetectionResult, BlockType

logger = logging.getLogger(__name__)

_BLOCK_PATTERNS: dict[str, list[re.Pattern]] = {
    "rate_limit": [
        re.compile(r"(?i)(rate\s*limit|too\s*many\s*requests|429|try\s*again\s*lat(er|e))"),
        re.compile(r"(?i)(limite\s*de\s*requisiç[ãoõ]es|muitas\s*requisiç[õo]es|tente\s*novamente\s*mais\s*tarde)"),
        re.compile(r"(?i)(exceeded|retry\s*after|\bapi\s*limit\b)"),
        re.compile(r"(?i)(\b503\b|\b429\b|\b403\b)"),
    ],
    "access_denied": [
        re.compile(r"(?i)(access\s*denied|access\s*forbidden|forbidden|not\s*allowed)"),
        re.compile(r"(?i)(acesso\s*negado|proibido|n[ãa]o\s*autorizado|sem\s*permiss[ãa]o)"),
        re.compile(r"(?i)(blocked|bloqueado|your\s*ip|seu\s*ip\s*foi)"),
        re.compile(r"(?i)\b401\b|\b403\b"),
    ],
    "cloudflare_challenge": [
        re.compile(r"(?i)(checking\s*(your)?\s*browser|verifying\s*(your)?\s*browser)"),
        re.compile(r"(?i)(just\s*a\s*moment|please\s*wait\s*while\s*we\s*verify)"),
        re.compile(r"(?i)(verificando\s*seu\s*navegador|s[óo]\s*um\s*momento|aguarde\s*enquanto\s*verificamos)"),
        re.compile(r"(?i)(browser\s*integrity\s*check|desafio\s*de\s*segurança)"),
        re.compile(r"(?i)(cf-browser-verify|cdn-cgi/challenge-platform|challenge-platform)"),
        re.compile(r"(?i)(__cfduid|cf_clearance)"),
    ],
    "cloudflare_block": [
        re.compile(r"(?i)(attention\s*required|cloudflare\s*ray\s*id)"),
        re.compile(r"(?i)(error\s*1010|error\s*1020|error\s*1033)"),
    ],
    "login_required": [
        re.compile(r"(?i)(login\s*required|sign\s*in\s*to\s*continue|please\s*log\s*in)"),
        re.compile(r"(?i)(fa[çc]a\s*login|login\s*obrigat[óo]rio|conecte-se)"),
        re.compile(r"(?i)(authentication\s*required|autentica[çc][ãa]o\s*necess[áa]ria)"),
    ],
    "paywall": [
        re.compile(r"(?i)(subscribe\s*to\s*continue|subscription\s*required|premium\s*content)"),
        re.compile(r"(?i)(assinante|conte[úu]do\s*exclusivo|plano\s*[pP]remium)"),
    ],
    "not_found": [
        re.compile(r"(?i)(404|not\s*found|p[áa]gina\s*n[ãa]o\s*encontrada|page\s*not\s*found)"),
    ],
    "honeypot": [
        re.compile(r"(?i)(display\s*:\s*none|visibility\s*:\s*hidden|type\s*=\s*[\"']hidden[\"'])"),
    ],
}

_TITLE_BLOCK_PATTERNS: dict[str, list[re.Pattern]] = {
    "access_denied": [re.compile(r"(?i)(403|forbidden|access\s*denied|acesso\s*negado)")],
    "rate_limit": [re.compile(r"(?i)(429|rate\s*limit|limite)")],
    "cloudflare_challenge": [re.compile(r"(?i)(just\s*a\s*moment|cloudflare|browser\s*check)")],
    "not_found": [re.compile(r"(?i)(404|not\s*found|n[ãa]o\s*encontrad)")],
}

_SENTIMENT_KEYWORDS = {
    "negative": [
        "denied", "error", "failed", "blocked", "forbidden", "limited",
        "negado", "erro", "bloqueado", "falhou", "proibido",
        "violation", "suspended", "terminated", "restricted",
        "violaçao", "violação", "suspenso", "restrito",
    ],
    "positive": [
        "success", "welcome", "approved", "authorized", "liberado",
        "sucesso", "bem-vindo", "autorizado", "aprovado", "liberado",
    ],
}

_MIN_CONTENT_LENGTH = 200


class BlockDetector:
    def __init__(self, use_vader: bool = True) -> None:
        self._vader_available = False
        self._sia = None
        if use_vader:
            self._vader_available = self._try_load_vader()

    def _try_load_vader(self) -> bool:
        try:
            from nltk.sentiment.vader import SentimentIntensityAnalyzer
            import nltk
            try:
                self._sia = SentimentIntensityAnalyzer()
            except LookupError:
                nltk.download("vader_lexicon", quiet=True)
                self._sia = SentimentIntensityAnalyzer()
            return True
        except ImportError:
            logger.info("[BlockDetector] NLTK/VADER not installed, using keyword heuristics only")
            return False
        except Exception as e:
            logger.warning("[BlockDetector] VADER load failed: %s", e)
            return False

    @property
    def vader_available(self) -> bool:
        return self._vader_available

    def analyze(self, html: str, page_url: str = "", status_code: int = 0) -> BlockDetectionResult:
        title = self._extract_title(html)
        body = self._extract_body_text(html)
        body_lower = body.lower()

        result = BlockDetectionResult(
            status_code=status_code,
            html_length=len(html),
        )

        if len(body) < 50 or len(html) < _MIN_CONTENT_LENGTH:
            result.is_blocked = True
            result.block_type = BlockType.EMPTY_PAGE
            result.confidence = 0.7
            result.trigger_rotation = False
            result.matched_keywords = ["empty_page"]
            return result

        sentiments = self._compute_sentiment(body)

        result.sentiment_score = sentiments.get("compound", 0.0)
        result.sentiment_compound = sentiments.get("compound", 0.0)

        keyword_matches: list[str] = []
        for block_type, patterns in _BLOCK_PATTERNS.items():
            for pattern in patterns:
                m = pattern.search(body_lower)
                if m:
                    keyword_matches.append(m.group(0).strip()[:80])

        for block_type, patterns in _TITLE_BLOCK_PATTERNS.items():
            for pattern in patterns:
                if pattern.search(title):
                    keyword_matches.append(f"title:{title[:60]}")

        if not keyword_matches:
            return result

        result.matched_keywords = keyword_matches
        result.is_blocked = True

        result.block_type = self._classify_block_type(keyword_matches, body_lower, sentiments)

        result.confidence = self._compute_confidence(
            result.block_type, len(keyword_matches), sentiments, status_code
        )

        if result.confidence >= 0.5 and result.block_type in (
            BlockType.RATE_LIMIT,
            BlockType.ACCESS_DENIED,
            BlockType.CLOUDFLARE_CHALLENGE,
            BlockType.CLOUDFLARE_BLOCK,
        ):
            result.trigger_rotation = True

        return result

    def _extract_title(self, html: str) -> str:
        m = re.search(r"<title[^>]*>(.*?)</title>", html, re.IGNORECASE | re.DOTALL)
        return m.group(1).strip() if m else ""

    def _extract_body_text(self, html: str) -> str:
        text = re.sub(r"<[^>]+>", " ", html)
        text = re.sub(r"\s+", " ", text).strip()
        return text

    def _compute_sentiment(self, body: str) -> dict[str, float]:
        if self._sia:
            try:
                return self._sia.polarity_scores(body[:4096])
            except Exception as e:
                logger.debug("[BlockDetector] VADER error: %s", e)

        words = body.lower().split()
        neg_count = sum(1 for w in words if w in _SENTIMENT_KEYWORDS["negative"])
        pos_count = sum(1 for w in words if w in _SENTIMENT_KEYWORDS["positive"])
        total = neg_count + pos_count
        if total == 0:
            return {"compound": 0.0, "neg": 0.0, "pos": 0.0, "neu": 1.0}

        neg_norm = neg_count / total if total > 0 else 0
        pos_norm = pos_count / total if total > 0 else 0
        compound = -neg_norm + pos_norm
        return {
            "compound": compound,
            "neg": neg_norm,
            "pos": pos_norm,
            "neu": 1.0 - neg_norm - pos_norm,
        }

    @staticmethod
    def _classify_block_type(
        keywords: list[str], body: str, sentiments: dict[str, float]
    ) -> BlockType:
        body_lower = body.lower()
        negative_bias = sentiments.get("compound", 0) < -0.3

        if any("cloudflare" in k.lower() or "challenge" in k.lower() or "cf-" in k.lower() for k in keywords):
            if any("block" in k.lower() or "error" in body_lower for k in keywords):
                return BlockType.CLOUDFLARE_BLOCK
            return BlockType.CLOUDFLARE_CHALLENGE

        if any("rate" in k.lower() or "429" in k or "limit" in k.lower() for k in keywords):
            return BlockType.RATE_LIMIT

        if any("denied" in k.lower() or "forbidden" in k.lower() or "403" in k for k in keywords):
            return BlockType.ACCESS_DENIED

        if any("login" in k.lower() or "sign" in k.lower() for k in keywords):
            return BlockType.LOGIN_REQUIRED

        if any("404" in k or "not found" in k.lower() for k in keywords):
            return BlockType.NOT_FOUND

        if any("subscribe" in k.lower() or "premium" in k.lower() for k in keywords):
            return BlockType.PAYWALL

        if any("hidden" in k.lower() or "display:none" in k.lower() for k in keywords):
            return BlockType.HONEYPOT

        if negative_bias:
            return BlockType.ACCESS_DENIED

        return BlockType.UNKNOWN

    @staticmethod
    def _compute_confidence(
        block_type: BlockType, match_count: int, sentiments: dict[str, float], status_code: int
    ) -> float:
        base: float = 0.0

        if block_type in (BlockType.RATE_LIMIT, BlockType.ACCESS_DENIED):
            base = 0.7
        elif block_type in (BlockType.CLOUDFLARE_CHALLENGE, BlockType.CLOUDFLARE_BLOCK):
            base = 0.8
        elif block_type == BlockType.EMPTY_PAGE:
            base = 0.7
        elif block_type == BlockType.LOGIN_REQUIRED:
            base = 0.6
        else:
            base = 0.4

        boost = min(match_count * 0.1, 0.2)

        compound = sentiments.get("compound", 0.0)
        if compound < -0.5:
            boost += 0.15
        elif compound < -0.2:
            boost += 0.05

        if status_code in (403, 429, 503):
            boost += 0.2
        elif status_code in (401, 404):
            boost += 0.1

        return min(base + boost, 0.99)
