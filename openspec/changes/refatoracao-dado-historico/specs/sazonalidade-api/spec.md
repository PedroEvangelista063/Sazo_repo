# Delta Spec: Sazonalidade API — Transparency Fields (Additive Contract)

**Change**: `refatoracao-dado-historico`
**Capability**: `sazonalidade-api`
**Type**: MODIFIED — first formal spec (Base Spec: N/A); behavior-additive only
**Status**: DRAFT

---

## Overview

The B2C API exposes anchor-year transparency from MV V17 as OPTIONAL fields on existing response schemas, so `SazonalidadeNacional`, `TabelaView`, and `GraficosView` keep working unmodified. The misleading hardcoded `FlowItem.ano_referencia: int = 2024` default (responses.py:278) is removed. The B2C R$ price ban (responses.py:7-11) is preserved: transparency fields carry provenance text and year info, never monetary values.

---

## ADDED Requirements

### R-ADD-01: Optional transparency fields on B2C schemas

The schemas `SazonalidadeResponse` (proposal ref: `ProdutoSazonalResponse`), `SazonalidadeComPrecoResponse`, `MesSazonalidade`, and product-card item schemas SHALL add optional/defaulted fields: `ano_referencia: int | None = None`, `tipo_dado: str | None = None`, `mensagem_transparencia: str | None = None`, `is_dado_legado: bool = False`. `is_dado_legado` SHALL be `True` when `ano_referencia < ANO_ATUAL`. These additions MUST be additive — container responses (`SazonalidadeNacionalResponse`, `SazonalidadeNacionalListResponse`, `TabelaView`, `GraficosView`) MUST NOT break when fields are absent.

### R-ADD-02: Endpoints consume V17 transparency columns directly

Endpoints `/api/v1/sazonalidade`, `/api/v1/regioes`, and product-card endpoints SHALL read `ano_referencia`, `tipo_dado`, `idade_dado_anos`, `preco_exibido` from MV V17 via asyncpg raw SQL and map them into R-ADD-01 fields. They SHALL NOT recompute forecasts or run heavy in-memory anchor math.

### R-ADD-03: Provenance message without monetary value

`mensagem_transparencia` SHALL contain provenance text only — e.g. `"Dado real referente à coleta da CONAB em Setembro de 2025 (defasagem de 1 ano)."` — and MUST NOT contain any R$ price. The B2C invariant (responses.py:7-11) SHALL remain in force.

### R-ADD-04: Null/zero signaling guarantee

When `preco_exibido`/`preco_referencia` are null or zero for a tuple, the payload MUST still signal the reason (via `tipo_dado`/`mensagem_transparencia`) and the anchor year (`ano_referencia`) — no silent null/zero without context.

### R-ADD-05: Cache purge and key invalidation

After MV V17 refresh/deploy, cache SHALL be purged via `POST /admin/cache/clear` (`X-API-Key: internal_api_key`), and React Query keys SHALL be invalidated: `['br-sazonalidade', ano]`, `['hortifruti-meta', uf]`, `['hortifruti-filter', uf, ano, mes]`, `['sazonalidade-com-preco', ...]`, `['regiao-resumo', regiaoId, ano]`.

---

## MODIFIED Requirements

### R-MOD-01: FlowItem.ano_referencia default removed

`FlowItem.ano_referencia` SHALL no longer default to the hardcoded `2024` (responses.py:278). It SHALL be `int | None = None`, populated from the real anchor year when available.
(Previously: `ano_referencia: int = 2024` — a hardcoded constant that mislabeled every flow item as 2024.)

#### Scenario: S-L1 Legacy default eliminated

- GIVEN a `FlowItem` built for a product anchored to 2025
- WHEN the item is serialized
- THEN `ano_referencia` is `2025`, not the former hardcoded `2024`

#### Scenario: S-L2 Missing anchor stays explicit

- GIVEN a tuple with no anchor year resolved
- WHEN the item is serialized
- THEN `ano_referencia` is `None` rather than a misleading `2024`

---

## Scenarios

### S1: Current-year product payload

- GIVEN a product with `tipo_dado='REAL_ATUAL'`, `ano_referencia=2026` in V17
- WHEN `GET /api/v1/sazonalidade?uf=SP` returns
- THEN the item includes `ano_referencia=2026`, `tipo_dado='REAL_ATUAL'`, `is_dado_legado=false`, and a "Coleta Efetiva"-type provenance message

### S2: Historical product payload

- GIVEN a product with `tipo_dado='HISTORICO_BASE'`, `ano_referencia=2025`
- WHEN the endpoint returns
- THEN `is_dado_legado=true`, `mensagem_transparencia` states the 2025 anchor with defasagem, and no R$ value is present in the item

### S3: B2C R$ ban preserved with transparency

- GIVEN `mensagem_transparencia` is populated
- WHEN the full B2C payload is inspected
- THEN no field carries a monetary R$ value; only `status_cor`, product name, year, type, and defasagem text are transmitted

### S4: Backward compatibility when fields absent

- GIVEN a consumer (`SazonalidadeNacional`, `TabelaView`, or `GraficosView`) deserializes a payload
- WHEN transparency fields are missing or `None`
- THEN deserialization succeeds via defaults and no consumer errors

### S5: Cache purge after MV refresh

- GIVEN MV V17 was refreshed with new anchor data
- WHEN `POST /admin/cache/clear` is called and the listed React Query keys are invalidated
- THEN the next `GET /api/v1/sazonalidade?uf=SP` returns fresh transparency values, not stale cached ones

### S6: No heavy in-memory forecast math

- GIVEN V17 already contains `preco_exibido`, `ano_referencia`, `tipo_dado`
- WHEN any sazonalidade endpoint runs
- THEN it maps V17 columns directly without re-deriving forecasts in Python

---

## Traceability

| Req      | Scenarios  | Proposal Ref                            |
| -------- | ---------- | --------------------------------------- |
| R-ADD-01 | S4         | API Contract §optional/defaulted        |
| R-ADD-02 | S6         | Approach §backend reads V17 via asyncpg |
| R-ADD-03 | S2, S3     | API Contract §no R$ fields to B2C       |
| R-ADD-04 | S2, S3     | Null/zero guarantee                     |
| R-ADD-05 | S5         | Approach §cache invalidation            |
| R-MOD-01 | S-L1, S-L2 | Affected Areas §responses.py:278        |
