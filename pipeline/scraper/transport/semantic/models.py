from __future__ import annotations

from enum import Enum
from typing import Any

from pydantic import BaseModel, Field


class BlockType(str, Enum):
    ACCESS_DENIED = "access_denied"
    RATE_LIMIT = "rate_limit"
    CLOUDFLARE_CHALLENGE = "cloudflare_challenge"
    CLOUDFLARE_BLOCK = "cloudflare_block"
    HONEYPOT = "honeypot"
    LOGIN_REQUIRED = "login_required"
    PAYWALL = "paywall"
    NOT_FOUND = "not_found"
    EMPTY_PAGE = "empty_page"
    UNKNOWN = "unknown"


class EntityLabel(str, Enum):
    PERSON = "PERSON"
    ORGANIZATION = "ORG"
    LOCATION = "LOC"
    DATE = "DATE"
    MONEY = "MONEY"
    PRICE = "PRICE"
    PRODUCT = "PRODUCT"
    CNPJ = "CNPJ"
    CPF = "CPF"
    QUANTITY = "QUANTITY"
    UNIT = "UNIT"
    TIME = "TIME"
    PERCENT = "PERCENT"
    MISC = "MISC"


class ExtractedEntity(BaseModel):
    text: str = Field(..., min_length=1)
    label: EntityLabel
    confidence: float = Field(default=1.0, ge=0.0, le=1.0)
    start_char: int = Field(default=0, ge=0)
    end_char: int = Field(default=0, ge=0)
    metadata: dict[str, Any] = Field(default_factory=dict)


class PriceEntity(BaseModel):
    raw: str
    value: float = 0.0
    currency: str = "BRL"
    unit: str = ""
    context: str = ""


class DateEntity(BaseModel):
    raw: str
    normalized: str = ""
    year: int = 0
    month: int = 0
    day: int = 0


class BlockDetectionResult(BaseModel):
    is_blocked: bool = False
    confidence: float = 0.0
    block_type: BlockType = BlockType.UNKNOWN
    trigger_rotation: bool = False
    matched_keywords: list[str] = Field(default_factory=list)
    sentiment_score: float = 0.0
    sentiment_compound: float = 0.0
    status_code: int = 0
    html_length: int = 0


class TableCandidate(BaseModel):
    xpath: str
    score: float = 0.0
    row_count: int = 0
    header_hint: str = ""
    entity_overlap: int = 0
    columns: list[str] = Field(default_factory=list)


class InteractionAction(str, Enum):
    click = "click"
    select = "select"
    fill = "fill"
    wait_for_selector = "wait_for_selector"
    wait_time = "wait_time"


class InteractionStep(BaseModel):
    action: InteractionAction
    selector: str = ""
    value: str = ""
    timeout: int = 5000


class ExtractionResult(BaseModel):
    url: str = ""
    title: str = ""
    clean_text: str = ""
    entities: list[ExtractedEntity] = Field(default_factory=list)
    prices: list[PriceEntity] = Field(default_factory=list)
    dates: list[DateEntity] = Field(default_factory=list)
    organizations: list[str] = Field(default_factory=list)
    locations: list[str] = Field(default_factory=list)
    persons: list[str] = Field(default_factory=list)
    table_candidates: list[TableCandidate] = Field(default_factory=list)
    table_rows: list[list[str]] = Field(default_factory=list)
    pre_actions: list[InteractionStep] = Field(default_factory=list)
    block_detection: BlockDetectionResult | None = None
    extraction_time_ms: int = 0
    spaCy_available: bool = False
    vader_available: bool = False
