# Design: contingencia-gaps-conab

## R2 — ProhortMensalEngine

### File Structure
```
pipeline/scraper/micro_engines/prohort_mensal_engine.py
pipeline/tests/test_prohort_mensal_engine.py
pipeline/tests/samples/prohort_mensal_sample.txt
```

### Class Design

`ProhortMensalEngine(BaseMicroEngine)`:

```
┌──────────────────────────────┐
│   BaseMicroEngine (ABC)      │
│  - _semaphore: Semaphore(3)  │
│  - _circuit_breaker: CB(5,120) │
│  - _client: AsyncClient      │
│  - extract() [abstract]      │
│  - _fetch()                  │
└──────────────┬───────────────┘
               │ inherits
┌──────────────▼───────────────┐
│  ProhortMensalEngine         │
│  + extract(url, ano, mes)    │
│  + extract_all(ano, mes)     │
│  - _download_csv()           │
│  - _parse_csv(raw)           │
│  - _filtrar(linhas, ano, mes)│
│  - _calcular_preco_medio()   │
│  - close()                   │
└──────────────────────────────┘
```

### Decisions

**1. Download strategy**: Override `_fetch()` from BaseMicroEngine because the ProhortMensal.txt file can be >5MB. Instead of using the default `httpx.AsyncClient` with 15s timeout, create a dedicated client with `httpx.Timeout(180.0, connect=15.0)` and `follow_redirects=True`. Stream response into memory (no temp file needed for CSV — 5MB is fine in-memory).

**2. Encoding**: Spec says ISO-8859-1, but try `resp.content.decode("utf-8")` first, fallback to `"iso-8859-1"`. This mirrors ConabApiEngine behavior which uses iso-8859-1 directly.

**3. CSV parsing**: Hardcode `COLUNAS` as a class-level list matching the spec columns. Use `csv.DictReader` with `delimiter=";"` and `fieldnames=self.COLUNAS`. Skip header row by detecting known column names in the first row's values (same pattern as `ConabApiEngine._parse_csv`).

**4. Decimal conversion**: `qtd_comercializada_kg` and `valor_comercializado` use `,` as decimal separator. Apply `str.replace(",", ".")` before `float()`.

**5. Preço médio calculation**: `preco_medio = valor_comercializado / qtd_comercializada_kg`. Filter rows where `qtd_comercializada_kg == 0` OR `preco_medio <= 0` to avoid division by zero and meaningless data.

**6. Payload format**: Target `_extrair_de_dict()` contract in sorting_engine.py:495. Each linha requires `nome_produto`, `preco_kg` (maps to preco_medio), `uf`, `data_referencia` ("YYYY-MM"). Wrap in `{"fonte_id": "conab-prohort-mensal", "payload_bruto": {"linhas": [...]}, "competencia": "YYYY-MM"}`.

**7. CircuitBreaker**: Inherit from BaseMicroEngine but override `_download_csv()` to manually call `self._circuit_breaker.registrar_sucesso()` / `registrar_falha()` since we bypass `_fetch()`.

**8. Semaphore**: Already in `BaseMicroEngine.__init__` as `asyncio.Semaphore(3)`. The `_download_csv()` method wraps the HTTP call with `async with self._semaphore:`.

**9. extract_all()**: Accept `ano` and `mes` parameters, delegate to `extract()`. Return `[result]` — same pattern as `ConabApiEngine.extract_all()`.

### Data Flow

```
ProhortMensalEngine.extract(url, ano, mes)
  │
  ├─ _download_csv()
  │   ├─ check CircuitBreaker (esta_aberto → RuntimeError)
  │   ├─ acquire Semaphore(3)
  │   ├─ httpx GET with 180s timeout, follow_redirects
  │   ├─ decode iso-8859-1
  │   ├─ CB.registrar_sucesso() on success
  │   └─ CB.registrar_falha() on failure → raise
  │
  ├─ _parse_csv(raw)
  │   ├─ csv.DictReader with COLUNAS, delimiter=";"
  │   └─ skip header line
  │
  ├─ _filtrar(linhas, ano, mes)
  │   └─ filter by id_ano_comercializacao == ano AND id_mes_comercializacao == mes
  │
  ├─ _calcular_preco_medio(linhas)
  │   ├─ convert "," → "." for qtd/valor
  │   ├─ preco_medio = valor / qtd
  │   └─ filter out qtd=0 or preco_medio<=0
  │
  └─ return {"fonte_id", "payload_bruto": {"linhas": [...]}, "competencia"}

→ AutonomousOrchestrator._executar_com_timeout()
→ persistir_coleta_bruta() → raw.coleta_bruta
→ SortingEngine._parsear_payload() → _extrair_de_dict()
→ ProdutoSazonalSchema validation
→ staging.fact_precos_mensais (upsert)
```

### Orchestrator Registration

In `orchestrator.py`:

1. **Import**: `from pipeline.scraper.micro_engines.prohort_mensal_engine import ProhortMensalEngine`

2. **_resolver_motor()**: Add branch:
   ```python
   if "prohort" in fid:
       return ProhortMensalEngine()
   ```

3. **_FONTE_ID_PARA_ALVO**: Add `"conab-prohort-mensal": "conab_prohort_mensal"`

Note: The existing `_passo_direto()` only triggers for UFs with CEASA mapping (SP, MG, etc.). The ProhortMensalEngine needs to be triggered differently — either through a separate pass that runs for all UFs, or through the `_executar_uma_fonte()` flow when iterating tiers. Since Prohort contains national data (not per-UF), it should be called once per competência, not once per UF. Recommend adding a dedicated `_passo_prohort()` in `_coletar_interno()` that runs once after `_passo_direto()`.

### Testing Strategy

**Unit tests** (`pipeline/tests/test_prohort_mensal_engine.py`):

| Test | Description | Mock |
|------|-------------|------|
| `test_extract_success` | Happy path: download → parse → filter → calculate | httpx mock returning 100-line CSV |
| `test_extract_all` | Delegates to extract, returns list with 1 item | Same as above |
| `test_parse_csv_colunas` | COLUNAS match CSV header positions | 5-line CSV with header |
| `test_calcular_preco_medio` | preco_medio = valor / qtd | 3 rows with known values |
| `test_calcular_preco_medio_zero_qtd` | Filter out qtd=0 rows | Mix of valid and zero-qtd |
| `test_calcular_preco_medio_zero_result` | Filter out preco_medio <= 0 | valor=0 rows |
| `test_filtrar_ano_mes` | Only rows matching ano/mes survive | CSV with multiple months |
| `test_circuit_breaker_opened` | 5 failures → RuntimeError | httpx raises 5 times |
| `test_payload_format` | Output matches _extrair_de_dict() contract | Valid CSV response |
| `test_encoding_fallback` | UTF-8 fails → iso-8859-1 used | Mock with latin-1 bytes |

**Mock setup**: Use `httpx.MockTransport` patching `self._client` on the engine instance, or use `respx` to intercept the specific URL. Prefer `respx` for cleaner test isolation.

**Sample file**: Save at `pipeline/tests/samples/prohort_mensal_sample.txt` — at least 50 real rows (copy from CONAB portal).

**Integration test** (marked `@pytest.mark.integration`): Load sample file, simulate full `extract()` without HTTP mock, validate 50+ rows parsed.

---

## R1 — PrecosiagrowebEngine

### File Structure
```
pipeline/scraper/micro_engines/precosiagroweb_engine.py
pipeline/tests/test_precosiagroweb_engine.py
pipeline/tests/samples/precosiagroweb_sample.html
```

### Class Design

`PrecosiagrowebEngine(BaseMicroEngine)`:

```
┌──────────────────────────────┐
│   BaseMicroEngine (ABC)      │
└──────────────┬───────────────┘
               │ inherits
┌──────────────▼───────────────┐
│  PrecosiagrowebEngine         │
│  + extract(url, ano, mes)    │
│  + extract_all(ano, mes)     │
│  - _post_uf(uf, ano, mes)    │
│  - _parse_html(html)         │
│  - _fallback_serie_historica()│
│  - _fallback_cepea()         │
│  - close()                   │
└──────────────────────────────┘
```

### Decisions

**1. HTTP method**: Override `_fetch()` because the endpoint requires POST with `application/x-www-form-urlencoded`. Create a dedicated method `_post_uf()` that uses the engine's `_client` (or a dedicated `AsyncClient`) but manually manages the semaphore and circuit breaker.

**2. Parameters per POST**:
- `periodo_inicial` e `periodo_final`: format as `DD/MM/YYYY` for full-month range
- `produto`: use `"*"` (wildcard for all products — 1 request covers all products for that UF+month)
- `uf`: 2-letter uppercase (AC, AM, AP, MS, PI, RO, RR, SE)
- `nivel_comercializacao`: `"*"` (all levels)

**3. Coverage**: 8 UFs × 12 months = 96 requests for 2024. With Semaphore(3) and ~1s per request, estimated 32 batches × 1s = ~32s plus overhead → ~60s total.

**4. Semaphore**: Reuse `self._semaphore` from BaseMicroEngine. The `_post_uf()` method wraps the HTTP call with `async with self._semaphore:`.

**5. CircuitBreaker**: In `_post_uf()`:
```python
if self._circuit_breaker.esta_aberto:
    raise RuntimeError(...)
# ... do POST ...
self._circuit_breaker.registrar_sucesso()  # on success
self._circuit_breaker.registrar_falha()    # on exception
```

**6. Retry with exponential backoff**: Use `tenacity` or manual loop. 3 attempts with `wait_exponential(multiplier=2, min=2, max=60)`. If `tenacity` is not in dependencies, implement a simple retry decorator or inline loop.

**7. HTML parsing**: Use `BeautifulSoup` with `html.parser` (built-in, no extra dep). Strategy:
1. Find `<table>` — prefer `class` or position heuristics
2. Extract `<tr>` rows, skip the header row
3. For each `<tr>`, extract `<td>` text
4. Expected columns: produto, classificacao, unidade, preco_min, preco_comum, preco_max
5. `preco_kg = preco_comum` (or calculate via `preco_comum / fator_padrao` if a "unidade/peso" column gives a divisor)
6. Handle malformed HTML gracefully — if `<tr>` has fewer `<td>` than expected, skip that row

**8. Fallback hierarchy**:
- **A — POST Precosiagroweb**: primary. On success → done.
- **B — Série Histórica CONAB**: if POST returns 500/404/403. Download single CSV from the portal, parse, filter by UF+month.
- **C — CEPEA/ESALQ**: if B fails. Use SmartRouter integration (already in sources_matrix.json) via `from pipeline.scraper.adapters.smart_router import SmartCrawler2026`.

**9. extract_all()**: Iterate through 8 UFs, call `_post_uf()` for each, collect all payloads, merge into a single result list. Use `asyncio.gather()` with semaphore to parallelize within Semaphore(3) limit. Add `asyncio.sleep(1)` between UF batches for rate limiting.

**10. extract()**: Accept `url` (unused), `ano`, `mes`. Call `extract_all()` internally but only for the specified ano+mes. Return merged payload.

### Data Flow

```
PrecosiagrowebEngine.extract_all(ano, mes)
  │
  ├─ for each UF in [AC, AM, AP, MS, PI, RO, RR, SE]:
  │   └─ _post_uf(uf, ano, mes)
  │       ├─ CB check → RuntimeError if open
  │       ├─ acquire Semaphore(3)
  │       ├─ POST httpx, data={periodo_inicial, periodo_final, uf, ...}
  │       ├─ CB.registrar_sucesso() → parse HTML
  │       │   └─ _parse_html(html)
  │       │       └─ BeautifulSoup → list of dicts
  │       ├─ CB.registrar_falha() → retry loop (3x exp backoff)
  │       │   └─ if all retries fail:
  │       │       ├─ _fallback_serie_historica(uf, ano, mes)
  │       │       │   └─ httpx GET → CSV parse → filter
  │       │       └─ if fallback B fails:
  │       │           └─ _fallback_cepea()
  │       │               └─ SmartRouter delegate
  │       └─ return {"nome_produto", "preco_kg", "uf", "data_referencia"}
  │
  └─ merge all UF results → return payload

→ Same pipeline as R2 (raw.coleta_bruta → SortingEngine → staging)
```

### Orchestrator Registration

In `orchestrator.py`:

1. **Import**: `from pipeline.scraper.micro_engines.precosiagroweb_engine import PrecosiagrowebEngine`

2. **_resolver_motor()**: Add branch:
   ```python
   if "precosiagroweb" in fid or "precosiagro" in fid:
       return PrecosiagrowebEngine()
   ```

3. **_FONTE_ID_PARA_ALVO**: Add `"precosiagroweb": "precosiagroweb"`

Since this engine needs to run only for the 8 target UFs (not all 27), the orchestration needs care. The `_passo_direto()` already maps specific UFs to CEASA engines. Option: add the 8 UFs to `_UF_CEASA_MAP` pointing to `"precosiagroweb"`, or create a `_passo_contingencia()` method that runs for these 8 UFs between `_passo_direto` and `_passo_smartrouter`.

### Testing Strategy

**Unit tests** (`pipeline/tests/test_precosiagroweb_engine.py`):

| Test | Description | Mock |
|------|-------------|------|
| `test_post_uf_success` | Happy path: POST → parse HTML table | respx mock returning HTML with 5-10 rows |
| `test_parse_html_valid` | Extract columns from valid HTML | Realistic HTML with product rows |
| `test_parse_html_malformed` | Handle missing `<td>` gracefully | Broken HTML |
| `test_parse_html_empty` | No `<table>` → empty result | HTML without table |
| `test_semaphore_concurrency` | Max 3 simultaneous requests | 3 delayed mocks |
| `test_circuit_breaker_5_failures` | 5 fails → CB open → RuntimeError | httpx raises 5x |
| `test_retry_then_success` | 2 fails, 3rd succeeds | 2 raises then 1 OK |
| `test_retry_all_fail` | 3 fails → exception raised | 3 raises |
| `test_fallback_serie_historica` | POST fails → fallback B called | POST 500, then GET CSV OK |
| `test_extract_all_aggregation` | 8 UFs merged into single payload | 8 separate mocks |
| `test_payload_format` | Output matches _extrair_de_dict() | Valid HTML response |

**Mock setup**: Use `respx` to intercept POST to `sisdep.conab.gov.br/precosiagroweb/` and return different HTML per UF.

**Sample file**: Save at `pipeline/tests/samples/precosiagroweb_sample.html` — real HTML snippet from CONAB with 5-10 product rows.

**Integration test** (marked `@pytest.mark.integration`): Load sample HTML file, simulate parse without HTTP.

---

## R3 — Snapshot automático

### File Structure
Changes to:
```
pipeline/scraper/main_runner.py         # add hook after medalhão
pipeline/scraper/persistence.py          # add executar_snapshot_e_checkpoint()
pipeline/ghost_dba_agent.py             # add checkpoint expiry check
database/utils/snapshot_helper.py        # NEW: export_snapshot()
```

### Decisions

**1. Snapshot helper** (`database/utils/snapshot_helper.py`):

```python
async def export_snapshot(
    pool: asyncpg.Pool,
    schema: str = "staging",
    tabela: str = "fact_precos_mensais",
    diretorio: str | Path = "database/processed_data/01_raw",
) -> Path | None:
```
- Uses `COPY (SELECT ... ORDER BY ano, mes, id_produto, id_localidade) TO <path> WITH (FORMAT PARQUET)`
- If PARQUET format is not available in PostgreSQL, fallback to CSV format
- Creates directory if not exists (idempotent — `os.makedirs(exist_ok=True)`)
- File name: `{tabela}_{YYYY}_{MM}.parquet` where YYYY_MM is the current month
- Returns `Path` to the snapshot file on success, `None` on failure
- Catches all exceptions, logs warning, never raises

**2. Checkpoint update** (`database/utils/snapshot_helper.py`):

```python
async def atualizar_checkpoint(
    diretorio: str | Path = "database/processed_data/01_raw",
    nome_snapshot: str = "",
    fontes: dict | None = None,
) -> None:
```
- Reads existing `ultimate_backfill_checkpoint.json` (or creates from scratch)
- Updates the schema:
  ```json
  {
    "snapshot_atual": "fact_precos_mensais_2026_07.parquet",
    "fontes": {
      "conab-precos-uf": {"ultima_competencia": "2026-07", "ultima_carga": "2026-07-15T10:00:00"},
      "conab-prohort-mensal": {"ultima_competencia": null, "ultima_carga": null},
      "precosiagroweb": {"ultima_competencia": "2024-12", "ultima_carga": "2026-07-15T10:00:00"}
    },
    "ultima_atualizacao": "2026-07-15T10:00:00"
  }
  ```
- Uses `json.dump(..., ensure_ascii=False, indent=2)`

**3. Hook in main_runner.py**:

```python
# After completar_ciclo_medalhao():
await executar_snapshot_e_checkpoint(pool)  # no await — non-blocking fire-and-forget
```

**4. Hook in persistence.py**:

```python
async def executar_snapshot_e_checkpoint(pool: asyncpg.Pool) -> None:
    try:
        caminho = await export_snapshot(pool)
        if caminho:
            await atualizar_checkpoint(nome_snapshot=caminho.name)
    except Exception:
        logger.warning("Snapshot/checkpoint falhou (não crítico)", exc_info=True)
```

**5. Ghost DBA Agent — checkpoint expiry**: Add a method `verificar_checkpoint_expiry()` in `AsyncIOSelfHealer` (or as standalone in ghost_dba_agent.py):
- Read `ultimate_backfill_checkpoint.json`
- For each fonte in `fontes`, check if `ultima_carga` > 45 days ago
- If expired, log WARNING and optionally fire webhook
- Add to the main polling loop in `AsyncIOSelfHealer.poll_errors()` or create a separate polling task

### Testing Strategy

**Unit tests**:

| Test | File | Description |
|------|------|-------------|
| `test_export_snapshot_sql` | `test_snapshot_helper.py` | Mock asyncpg pool, verify COPY TO PARQUET SQL |
| `test_export_snapshot_fallback_csv` | same | Mock PARQUET failure → verify CSV fallback |
| `test_export_snapshot_idempotente` | same | Directory already exists → succeeds |
| `test_export_snapshot_failure_log` | same | COPY TO fails → logs warning, returns None |
| `test_checkpoint_create` | same | No existing checkpoint → creates new JSON |
| `test_checkpoint_update` | same | Existing checkpoint → updates fields |
| `test_checkpoint_format` | same | Verify JSON format (ensure_ascii, indent) |
| `test_checkpoint_concorrente` | same | Concurrent updates → no corruption |
| `test_ghost_dba_expiry_warning` | `test_ghost_dba_agent.py` | Checkpoint 50d old → WARNING |
| `test_ghost_dba_expiry_ok` | same | Checkpoint 10d old → no warning |

---

## R4 — Investigação SP

### SQL File

`database/processed_data/sql/03_investigacao_sp.sql`:

**Query 1 — Produtos SP em 2025-12 vs 2026-06**:
Compare the product lists at both endpoints. Products in 2025-12 but missing in 2026-06 indicate potential coverage gaps.

**Query 2 — Produtos que sumiram completamente de SP em 2026**:
Subquery pattern: products present in 2025 SP data that are absent from 2026 jan-jun SP data. If this returns rows, it indicates CONAB stopped publishing those products for SP (source gap, not pipeline bug).

**Query 3 — Cross-check com dim_produto**:
Left join from dim_produto to fact_precos_mensais with UF='SP' filter on the join. Uses `bool_or` aggregate to flag presence in each period. `HAVING` clause finds products present in 2025 but absent in 2026 jan-jun.

**Query 4 — categoria_b2c no SortingEngine**:
Check if SP products have unexpected `categoria_b2c` values. The regex in SortingEngine's `_processar_linha()` filters via `_HORTIFRUTI_NORM` — if a product name doesn't match, it gets rejected. This query checks whether `dim_produto.categoria_b2c` differs from the expected `ALIMENTO_VAREJO` for products with SP data. If products that ARE in fact_precos_mensais for SP in 2025 show as non-ALIMENTO_VAREJO, the regex may be dropping them for 2026.

### Output Report

`docs/relatorio_investigacao_sp.md` — manual analysis after running queries. Not automated.

### Decision Documentation

The report must answer: are the 1,245 SP gaps (jan-jun 2026 only, after excluding jul-dec future months):
- **Bug**: SortingEngine regex or dim_localidade mapping drops SP products
- **Source gap**: CONAB stopped publishing certain products for SP in 2026
- **Coverage partial**: Products exist but with fewer data points in 2026

---

## Integration Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| ConabApiEngine._download_csv() uses iso-8859-1 directly; ProhortMensalEngine needs UTF-8 first attempt | Encodign mismatch → garbage data | Implement encoding detection: try utf-8 first, fallback iso-8859-1 |
| Precosiagroweb HTML structure unknown (never scraped) | Parser may fail on real HTML | Build resilient parser with multiple fallback strategies; add integration test with real HTML sample |
| 96 sequential POSTs to CONAB may trigger rate limiting | IP blocked temporarily | Semaphore(3) + 1s sleep between UF batches + exponential retry |
| Snapshot COPY TO PARQUET may not be available (PG version) | Snapshot fails | Fallback to CSV format |
| SortingEngine._parsear_payload() expects payload_bruto as dict; ProhortMensalEngine outputs nested dict | Parser mismatch | Verify payload format matches `_extrair_de_dict()` contract exactly |
| AutonomousOrchestrator._UF_CEASA_MAP doesn't include the 8 contingent UFs | New engines never called | Create `_passo_contingencia()` or add UFs to the map |

## Skill Resolution

`skill_resolution`: `none` — skill registry not available in this session. Orchestrator injected project conventions from `AGENTS.md` directly.
