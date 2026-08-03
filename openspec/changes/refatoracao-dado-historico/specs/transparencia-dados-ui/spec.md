# Delta Spec: Transparência de Dados — UI

**Change**: `refatoracao-dado-historico`
**Capability**: `transparencia-dados-ui`
**Type**: NEW — first formal spec (Base Spec: N/A, per repo convention)
**Status**: DRAFT

---

## Overview

The seasonal grid stops showing gray "gap" cells and forecast badges: every cell is filled with the most recent REAL data, labeled with a year badge, and — for legacy/historical data — a circled `(i)` icon opens a transparency popover explaining the anchor year, data type, and defasagem. B2C surfaces keep showing badges/semáforo/year but NEVER R$ values (responses.py:7-11 contract).

---

## ADDED Requirements

### R-ADD-01: DataTransparencyInfo component

A new `DataTransparencyInfo.tsx` component SHALL render a circled `(i)` icon (lucide-react `Info` or Mantine Tooltip/Popover `^9.4.1`) whose popup shows: Anchor Year (`"Ano de Origem: 2025"` / `"Dado Atual: 2026"`), a status badge (`"Histórico Real CONAB"` for `HISTORICO_BASE` / `"Coleta Efetiva"` for `REAL_ATUAL`), an explanation (`"Este valor reflete a última cotação real registrada para este produto no mês correspondente. Não é uma estimativa sintética."`), and defasagem (`"Histórico de 1 ano atrás"` / `"2 anos atrás"`).

### R-ADD-02: Gray-cell removal in SazonalidadeNacional

`SazonalidadeNacional.tsx` SHALL stop rendering the structural/collection gray cells from `GAP_STYLES` (L22-33). Each month cell SHALL be filled with the most recent real data; a year badge (e.g. `'25` / `'24`) SHALL appear next to the value on cells whose anchor year is not current, and the `(i)` icon SHALL be shown on those legacy cells.

### R-ADD-03: Apuração year in SupermercadoView and ProductCard

`SupermercadoView.tsx` (year logic L76-80, badge L482-507, year-1 link L508-515) and `ProductCard.tsx` (forecast badges L103-129) SHALL display the apuração year/date in the card footer and SHALL replace the forecast badges (`📊 Estimativa`, `🪄 Estimado`) with badges reflecting real/histórico status (`REAL_ATUAL` vs `HISTORICO_BASE`).

### R-ADD-04: React Query cache invalidation

After the MV refresh/deploy, the hooks SHALL invalidate: `['br-sazonalidade', ano]`, `['hortifruti-meta', uf]`, `['hortifruti-filter', uf, ano, mes]`, `['sazonalidade-com-preco', ...]`, `['regiao-resumo', regiaoId, ano]` so the grid and cards refetch transparent real data.

### R-ADD-05: B2C no-R$ constraint on UI

B2C surfaces SHALL render badges, semáforo, year, and the transparency tooltip (ano/tipo/defasagem) WITHOUT any R$ monetary value. The tooltip MUST NOT display price even when the underlying data has one.

---

## Scenarios

### S1: Legacy cell fully filled

- GIVEN a product has only 2025 real data for a month cell
- WHEN the seasonal grid renders
- THEN the cell is filled with the real value, shows a `'25` year badge and an `(i)` icon; no gray cell is rendered

### S2: Tooltip content for historical data

- GIVEN the user hovers/clicks the `(i)` icon on a `HISTORICO_BASE` cell anchored to 2025
- THEN the popover shows `"Ano de Origem: 2025"`, badge `"Histórico Real CONAB"`, the explanation text, and `"Histórico de 1 ano atrás"` — with no R$ value

### S3: Tooltip content for current data

- GIVEN the user opens the `(i)` icon on a `REAL_ATUAL` cell anchored to 2026
- THEN the popover shows `"Dado Atual: 2026"` and badge `"Coleta Efetiva"`, confirming a real current collection

### S4: Card footer with apuração

- GIVEN a product card for a product whose anchor year is 2025
- WHEN `ProductCard.tsx` renders
- THEN the card footer shows the apuração year/date and a "Histórico Real" status badge instead of `📊 Estimativa` / `🪄 Estimado`

### S5: Cache invalidation after MV refresh

- GIVEN MV V17 was refreshed
- WHEN the listed React Query keys are invalidated
- THEN the grid, cards, and regional summary refetch and display the new anchor years/types

### S6: No R$ leakage on B2C surfaces

- GIVEN a B2C page (grid, card, tooltip) rendering a product with real price data
- WHEN the page DOM is inspected
- THEN no R$-formatted monetary value appears; only semáforo, badges, year, and defasagem text

---

## Traceability

| Req      | Scenarios | Proposal Ref                                 |
| -------- | --------- | -------------------------------------------- |
| R-ADD-01 | S2, S3    | Approach §DataTransparencyInfo.tsx           |
| R-ADD-02 | S1        | Success criterion (c) §gray-cell removal     |
| R-ADD-03 | S4        | Affected Areas §SupermercadoView/ProductCard |
| R-ADD-04 | S5        | Approach §cache invalidation                 |
| R-ADD-05 | S6        | Authoritative decision 3 / B2C constraints   |
