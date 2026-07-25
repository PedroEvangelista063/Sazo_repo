# Task Breakdown: contingencia-gaps-conab

## Dependency Graph

```
R2-T1 (engine) ──→ R2-T2 (orchestrator) ──→ R2-T4 (integration E2E)
    │                                           ↑
    └──→ R2-T3 (_parsear_payload fix) ──────────┘
                                                     R3-T1 (snapshot_helper)
                                                         ↓
R2-T2 ──→ R3-T2 (main_runner hook) ──→ R3-T3 (integration E2E)
                                             ↓
                                        R3-T4 (ghost_dba check)
                                             ↓
                                        R3-T5 (snapshot tests)
                                             ↓
                                        R3-T6 (ghost_dba expiry tests)

R1-T1 (engine) ──→ R1-T2 (orchestrator) ──→ R1-T4 (integration E2E)
    │                  ↑                        ↑
    └──→ R2-T3 ───────┘                        │
    └──→ R1-T3 (tests unit) ───────────────────┘

R4-T1 (SQL queries)
    ↓
R4-T2 (report)
```

**Critical path**: R2-T1 → R2-T3 → R2-T2 → R2-T4

- R2-T3 (_parsear_payload fix) is a **shared dependency** for R2 and R1 — both engines use `{"linhas": [...]}` payload format which existing `_parsear_payload` does not handle.
- R3-T1 (snapshot_helper) has **no code dependencies** on R2 and can start in parallel with R2, but E2E testing (R3-T2→R3-T3) needs R2-T2 done.
- R1 is fully independent of R2/R3 — can run in parallel.
- R4 is independent of everything — SQL-only, no code changes.

---

## Tasks

### R2 — ProhortMensalEngine

#### R2-T1: Criar ProhortMensalEngine class

Implementar a micro-engine que baixa o CSV ProhortMensal.txt do portal CONAB, faz parse, filtra por ano/mês, calcula preço médio e retorna payload no formato `{"linhas": [...]}`.

**Arquivos:**
- `pipeline/scraper/micro_engines/prohort_mensal_engine.py` (NEW, ~180 lines)
- `pipeline/scraper/micro_engines/__init__.py` (empty init, only touch if needed)

**Estrutura da classe:**
- `ProhortMensalEngine(BaseMicroEngine)`
- `COLUNAS = ["dsc_produto", "cod_ibge_municipio_ceasa", "municipio_ceasa", "uf_ceasa", "id_ano_comercializacao", "id_mes_comercializacao", "qtd_comercializada_kg", "valor_comercializado"]`
- `extract(url, ano, mes)` → baixa, parseia, filtra, calcula, retorna dict
- `extract_all(ano, mes)` → delega para extract, retorna `[result]`
- `_download_csv()` → GET com httpx.Timeout(180.0, connect=15.0), follow_redirects=True, CircuitBreaker manual, decode utf-8 → fallback iso-8859-1
- `_parse_csv(raw)` → csv.DictReader com delimiter=";", fieldnames=COLUNAS, pula header row
- `_filtrar(linhas, ano, mes)` → filter by id_ano_comercializacao, id_mes_comercializacao
- `_calcular_preco_medio(linhas)` → converte "," → "." para qtd/valor, preco_medio = valor / qtd, filtra qtd=0 e preco_medio<=0, mapeia para {"nome_produto", "preco_kg", "uf", "data_referencia"}

**Payload de saída:**
```python
{
    "fonte_id": "conab-prohort-mensal",
    "payload_bruto": {
        "linhas": [
            {"nome_produto": str, "preco_kg": float, "uf": str, "data_referencia": "YYYY-MM"}
        ],
        "total_linhas": int,
        "ufs_abrangidas": list[str],
        "periodo_inicial": str,
        "periodo_final": str,
    },
    "competencia": "YYYY-MM",
}
```

**Decisões de implementação:**
- `_download_csv()` cria `AsyncClient` próprio (não reusa `self._client` da base por causa do timeout diferente de 180s)
- CircuitBreaker chamado manualmente via `registrar_sucesso()`/`registrar_falha()` no `_download_csv()`
- Semáforo herdado (`self._semaphore`) aplicado via `async with self._semaphore`
- preco_medio calculado como float, arredondado para 2 casas decimais
- `data_referencia` formatada como `f"{ano}-{mes:02d}"`

**Critérios de aceite:**
- `extract()` baixa CSV com httpx em até 180s
- `_parse_csv()` parseia corretamente CSV com encoding latin-1
- `_filtrar()` retorna apenas linhas do ano/mês especificado
- `_calcular_preco_medio()` calcula `valor / qtd` e filtra divisões por zero
- Payload final contém `fonte_id`, `payload_bruto.linhas` (lista de dicts), `competencia`
- CircuitBreaker abre após 5 falhas consecutivas → levanta RuntimeError
- `extract_all()` retorna `[resultado]`

**Dependências:** nenhuma
**Estimativa:** 180 linhas
**Tipo:** NEW

---

#### R2-T2: Registrar ProhortMensalEngine no orchestrator.py

Registrar a nova engine no orquestrador para ser executada 1x por competência (não por UF).

**Arquivos:**
- `pipeline/scraper/orchestrator.py` (~20 lines modified)

**Mudanças:**
1. Import: `from pipeline.scraper.micro_engines.prohort_mensal_engine import ProhortMensalEngine`
2. `_FONTE_ID_PARA_ALVO`: add `"conab-prohort-mensal": "conab_prohort_mensal"`
3. `_resolver_motor()`: add `if "prohort" in fid: return ProhortMensalEngine()`
4. Criar `_passo_prohort()` em `_coletar_interno()`:
   ```python
   # Após _passo_direto(uf, ano, mes), executar 1x por competência
   if uf == "SP":  # só roda uma vez, não por UF
       prohort = await self._passo_prohort(ano, mes)
       if prohort:
           acumulado.extend(prohort)
   ```
5. Implementar `_passo_prohort(ano, mes)`:
   ```python
   async def _passo_prohort(self, ano: int, mes: int) -> list[dict[str, Any]] | None:
       engine = ProhortMensalEngine()
       url = "https://portaldeinformacoes.conab.gov.br/downloads/arquivos/ProhortMensal.txt"
       resultado = await self._executar_com_timeout(engine, url, ano, mes, "conab-prohort-mensal")
       return [resultado] if resultado else None
   ```

**Critérios de aceite:**
- Engine registrada em `_resolver_motor()` para `"conab-prohort-mensal"`
- `_passo_prohort()` executado 1x por competência (quando `uf == list(_UFS)[0]` ou similar)
- Payload flui corretamente para `raw.coleta_bruta`

**Dependências:** R2-T1
**Estimativa:** 20 linhas
**Tipo:** MODIFY

---

#### R2-T3: Ajustar SortingEngine._parsear_payload para payloads com "linhas"

O método `_parsear_payload` atual não reconhece o formato `{"linhas": [...]}`. Adicionar handler para iterar sobre a lista e extrair cada dict individual via `_extrair_de_dict()`.

**Arquivos:**
- `pipeline/processor/sorting_engine.py` (~15 lines modified)

**Mudanças:**
```python
@staticmethod
def _parsear_payload(payload: Any) -> list[dict[str, Any]] | None:
    if isinstance(payload, dict):
        # NOVO: payload bruto com lista de linhas (ex: ProhortMensal, Precosiagroweb)
        linhas = payload.get("linhas") or payload.get("itens") or payload.get("rows")
        if isinstance(linhas, list) and linhas:
            resultados = []
            for item in linhas:
                parsed = _extrair_de_dict(item)
                if parsed:
                    resultados.extend(parsed)
            return resultados or None
        
        body = payload.get("body", "") or payload.get("payload", "")
        # ... resto do código existente ...
```

**Critérios de aceite:**
- `_parsear_payload({"linhas": [{"nome_produto": "BATATA", "preco_kg": 3.5, "uf": "SP", "data_referencia": "2026-07"}]})` retorna lista com 1 item
- `_parsear_payload({"linhas": []})` retorna None
- `_parsear_payload({"linhas": [{"nome_produto": "X"}]})` retorna None (sem preco_kg)
- Comportamento existente para payloads HTML/texto/dict simples não é alterado (retrocompatível)
- Testes unitários no sorting_engine passam

**Dependências:** R2-T1 (para testar com payload real)
**Estimativa:** 15 linhas
**Tipo:** MODIFY
**Atenção:** é shared dependency — R1-T2 também depende deste fix

---

#### R2-T4: Sample file para testes ProhortMensal

Baixar amostra real do ProhortMensal.txt e salvar como fixture de teste.

**Arquivos:**
- `pipeline/tests/samples/prohort_mensal_sample.txt` (NEW, ~50 lines — trecho de ~50 linhas reais)
- Ou usar script inline para gerar CSV mock representativo

**Formato do sample:**
```
COLUNAS;...
dsc_produto;cod_ibge_municipio_ceasa;municipio_ceasa;uf_ceasa;id_ano_comercializacao;id_mes_comercializacao;qtd_comercializada_kg;valor_comercializado
BATATA;123;SAO PAULO;SP;2026;1;5000,50;15000,00
CENOURA;123;SAO PAULO;SP;2026;1;3000,00;12000,00
...
```

**Critérios de aceite:**
- Arquivo contém header + ~50 linhas de dados reais ou sintéticos
- Inclui variedade: múltiplos produtos, UFs, meses, qtd=0, valores zero
- Encoding: UTF-8 ou latin-1 (definir no teste qual usar)
- Delimitador: ponto-e-vírgula (`;`)
- Decimal: vírgula (`,`)

**Dependências:** R2-T1
**Estimativa:** 50 linhas
**Tipo:** NEW

---

#### R2-T5: Testes unitários ProhortMensalEngine

Criar suite de testes com httpx mock (respx ou MockTransport) para cobrir todos os cenários.

**Arquivos:**
- `pipeline/tests/test_prohort_mensal_engine.py` (NEW, ~250 lines)

**Casos de teste:**

| Teste | Descrição | Mock |
|-------|-----------|------|
| `test_extract_success` | Happy path completo | CSV 50 linhas |
| `test_extract_all` | Delegação para extract | CSV 50 linhas |
| `test_parse_csv_colunas` | COLUNAS batem com CSV header | 5 linhas c/ header |
| `test_calcular_preco_medio` | preco_medio = valor / qtd | 3 linhas c/ valores conhecidos |
| `test_calcular_preco_medio_zero_qtd` | Filtra qtd=0 | Mix válido + zero |
| `test_calcular_preco_medio_zero_result` | Filtra preco_medio <= 0 | valor=0 |
| `test_filtrar_ano_mes` | Só linhas do ano/mês alvo | CSV multi-mês |
| `test_circuit_breaker_opened` | 5 falhas → RuntimeError | httpx raise 5x |
| `test_circuit_breaker_recovery` | 5 falhas → espera → sucesso | 5 raise + 1 OK |
| `test_payload_format` | Output compatível _extrair_de_dict | CSV válido |
| `test_encoding_utf8` | UTF-8 decode | UTF-8 bytes |
| `test_encoding_fallback_iso` | Falha UTF-8 → latin-1 | Latin-1 bytes |
| `test_semaphore_limit` | Máx 3 concorrentes | 3 delays |

**Mock setup:** `respx.mock` interceptando `https://portaldeinformacoes.conab.gov.br/downloads/arquivos/ProhortMensal.txt`, retornando conteúdo do sample file. Alternativa: patch `httpx.AsyncClient` com `MockTransport`.

**Critérios de aceite:**
- `pytest -v pipeline/tests/test_prohort_mensal_engine.py` passa todos os testes
- Cobertura > 85% na engine (`--cov=pipeline.scraper.micro_engines.prohort_mensal_engine`)
- Testes de CircuitBreaker verificam estado aberto após 5 falhas
- Testes de encoding fallback cobrem ambas as tentativas
- Testes de payload format validam schema completo

**Dependências:** R2-T1, R2-T4 (sample file)
**Estimativa:** 250 linhas
**Tipo:** NEW

---

#### R2-T6: Integração E2E ProhortMensal (opcional)

Teste marcado como `@pytest.mark.integration` que carrega sample real sem HTTP mock e valida pipeline completo via SortingEngine mockado.

**Arquivos:**
- `pipeline/tests/test_prohort_mensal_engine.py` (mesmo arquivo, +~50 lines)

**Critérios de aceite:**
- Marcado `@pytest.mark.integration` — não roda em `pytest` sem `-m integration`
- Carrega arquivo `samples/prohort_mensal_sample.txt`
- Simula `_extrair_de_dict()` para cada linha
- Valida que todas as linhas passam em `ProdutoSazonalSchema`

**Dependências:** R2-T4, R2-T3
**Estimativa:** 50 linhas
**Tipo:** ADD (ao mesmo test file)

---

### R3 — Snapshot automático

#### R3-T1: Criar snapshot_helper.py

Implementar funções de exportação de snapshot Parquet e atualização de checkpoint.

**Arquivos:**
- `database/utils/snapshot_helper.py` (NEW, ~120 lines)

**Funções:**
1. `async def export_snapshot(pool, schema="staging", tabela="fact_precos_mensais", diretorio="database/processed_data/01_raw") → Path | None`
   - Gera `COPY (SELECT ... ORDER BY ano, mes, id_produto, id_localidade) TO '<path>' WITH (FORMAT PARQUET)`
   - Nome arquivo: `{tabela}_{YYYY}_{MM}.parquet`
   - Cria diretório com `os.makedirs(exist_ok=True)`
   - Fallback para CSV se PARQUET não disponível no PG
   - Loga warning e retorna None em caso de erro (nunca levanta)

2. `async def atualizar_checkpoint(diretorio, nome_snapshot, fontes=None)`
   - Lê `ultimate_backfill_checkpoint.json` existente ou cria novo
   - Atualiza schema com `snapshot_atual`, `fontes` dict, `ultima_atualizacao`
   - Salva com `json.dump(ensure_ascii=False, indent=2)`

3. `async def executar_snapshot_e_checkpoint(pool)`
   - Chama export_snapshot → se OK, chama atualizar_checkpoint
   - Try/except geral: log warning, nunca levanta

**Critérios de aceite:**
- `export_snapshot()` gera SQL `COPY ... TO ... PARQUET` correto
- `export_snapshot()` cria diretório se não existir (idempotente)
- `export_snapshot()` retorna Path se sucesso, None se falha
- `atualizar_checkpoint()` com checkpoint existente → merge correto
- `atualizar_checkpoint()` sem checkpoint existente → cria novo
- Arquivo JSON formatado com indent=2, ensure_ascii=False
- `executar_snapshot_e_checkpoint()` não levanta exceções

**Dependências:** nenhuma (pode começar em paralelo com R2)
**Estimativa:** 120 linhas
**Tipo:** NEW

---

#### R3-T2: Hook snapshot em main_runner.py + persistence.py

Adicionar chamada ao snapshot/checkpoint após o ciclo medalhão bem-sucedido.

**Arquivos:**
- `pipeline/scraper/main_runner.py` (~3 lines modified)
- `pipeline/scraper/persistence.py` (~4 lines modified)

**Mudanças:**
1. `main_runner.py`: adicionar após `await executar_ciclo_medalhao(pool)`:
   ```python
   from pipeline.scraper.persistence import executar_snapshot_e_checkpoint
   await executar_snapshot_e_checkpoint(pool)
   ```
2. `persistence.py`: importar e reexportar:
   ```python
   from database.utils.snapshot_helper import executar_snapshot_e_checkpoint
   ```

**Critérios de aceite:**
- Snapshot é chamado APÓS `executar_ciclo_medalhao()` com sucesso
- Se `executar_ciclo_medalhao()` não rodou (nenhum dado novo), snapshot não é chamado
- Se snapshot falhar, o job principal não quebra (non-critical)
- Logging adequado: INFO se snapshotted, WARNING se falhou

**Dependências:** R3-T1, R2-T2 (para testar E2E)
**Estimativa:** 7 linhas
**Tipo:** MODIFY

---

#### R3-T3: Ghost DBA — verificação de checkpoint expiry

Adicionar verificação periódica de checkpoint expiry no Ghost DBA Agent.

**Arquivos:**
- `pipeline/ghost_dba_agent.py` (~40 lines added)

**Implementação:**
1. Função standalone ou método em `AsyncIOSelfHealer`:
   ```python
   async def verificar_checkpoint_expiry(self) -> None:
       caminho = Path("database/processed_data/01_raw/ultimate_backfill_checkpoint.json")
       if not caminho.exists():
           return
       with open(caminho) as f:
           checkpoint = json.load(f)
       fontes = checkpoint.get("fontes", {})
       agora = datetime.now()
       for nome_fonte, info in fontes.items():
           ultima = info.get("ultima_carga")
           if not ultima:
               continue
           data_ultima = datetime.fromisoformat(ultima)
           dias = (agora - data_ultima).days
           if dias > 45:
               logger.warning(
                   "[GHOST] Fonte %s com %d dias sem carga (limite: 45) — %s",
                   nome_fonte, dias, ultima,
               )
               # Opcional: webhook
   ```
2. Adicionar ao polling loop ou criar task separada em `AsyncIOSelfHealer.poll_errors()`

**Critérios de aceite:**
- Checkpoint com `ultima_carga` > 45 dias → log WARNING
- Checkpoint com `ultima_carga` ≤ 45 dias → sem warning
- Checkpoint inexistente → silêncio (nenhum erro)
- Fonte sem `ultima_carga` (null) → ignorada

**Dependências:** R3-T1 (formato do checkpoint)
**Estimativa:** 40 linhas
**Tipo:** MODIFY

---

#### R3-T4: Testes unitários snapshot_helper

Testar export_snapshot, atualizar_checkpoint e suas variações.

**Arquivos:**
- `pipeline/tests/test_snapshot_helper.py` (NEW, ~180 lines)

**Casos de teste:**

| Teste | Descrição |
|-------|-----------|
| `test_export_snapshot_sql` | Verificar SQL COPY TO PARQUET (mock pool) |
| `test_export_snapshot_fallback_csv` | PARQUET falha → CSV |
| `test_export_snapshot_idempotente` | Diretório já existe → sucesso |
| `test_export_snapshot_failure_log` | Falha → log warning, return None |
| `test_checkpoint_create` | Sem checkpoint existente → cria novo |
| `test_checkpoint_update` | Checkpoint existente → merge |
| `test_checkpoint_format` | JSON indent=2, ensure_ascii=False |
| `test_checkpoint_concorrente` | Atualização concorrente (mock file lock) |

**Critérios de aceite:**
- `pytest -v pipeline/tests/test_snapshot_helper.py` passa
- `test_export_snapshot_sql` verifica que `conn.execute` foi chamado com SQL contendo `COPY`, `TO`, `PARQUET`
- `test_checkpoint_create` verifica que o arquivo foi escrito com conteúdo esperado
- `test_export_snapshot_failure_log` verifica `logger.warning` foi chamado

**Dependências:** R3-T1
**Estimativa:** 180 linhas
**Tipo:** NEW

---

#### R3-T5: Testes Ghost DBA checkpoint expiry

Testar verificação de checkpoint expiry com mocks.

**Arquivos:**
- `pipeline/tests/test_ghost_dba_agent.py` (NEW or ADD, ~80 lines)

**Casos de teste:**

| Teste | Descrição |
|-------|-----------|
| `test_expiry_warning_50_days` | checkpoint 50d → WARNING |
| `test_expiry_ok_10_days` | checkpoint 10d → OK |
| `test_expiry_no_checkpoint` | sem checkpoint → OK |
| `test_expiry_null_ultima_carga` | fonte sem data → OK |
| `test_expiry_multiple_fontes` | 1 expirada, 1 ok → WARNING só na expirada |

**Critérios de aceite:**
- Testes usam `tmp_path` fixture para criar checkpoint temporário
- Verificam `caplog` para presença/ausência de WARNING
- `pytest -v pipeline/tests/test_ghost_dba_agent.py` passa

**Dependências:** R3-T3
**Estimativa:** 80 linhas
**Tipo:** NEW

---

#### R3-T6: Integração E2E snapshot (opcional)

Teste de integração que executa snapshot completo com pool asyncpg real (marcado `@pytest.mark.integration`).

**Arquivos:**
- `pipeline/tests/test_snapshot_helper.py` (ADD, ~40 lines)

**Critérios de aceite:**
- Marcado `@pytest.mark.integration`
- Verifica que arquivo .parquet é gerado no diretório temporário
- Verifica que checkpoint.json contém os campos esperados

**Dependências:** R3-T1, R3-T2
**Estimativa:** 40 linhas
**Tipo:** ADD

---

### R1 — PrecosiagrowebEngine

#### R1-T1: Criar PrecosiagrowebEngine class

Implementar micro-engine para scraping do Precosiagroweb da CONAB via POST com HTML table parsing.

**Arquivos:**
- `pipeline/scraper/micro_engines/precosiagroweb_engine.py` (NEW, ~250 lines)

**Estrutura da classe:**
- `PrecosiagrowebEngine(BaseMicroEngine)`
- `UFS_CONTINGENCIA = ["AC", "AM", "AP", "MS", "PI", "RO", "RR", "SE"]`
- `URL_POST = "https://sisdep.conab.gov.br/precosiagroweb/"`
- `extract(url, ano, mes)` → delega para extract_all, retorna payload merged
- `extract_all(ano, mes)` → itera 8 UFs com semáforo, coleta resultados, merge
- `_post_uf(uf, ano, mes)` → POST application/x-www-form-urlencoded, CircuitBreaker, retry
- `_parse_html(html)` → BeautifulSoup, extrai table rows, fallback se <tr> não seguir padrão
- `_fallback_serie_historica(uf, ano, mes)` → GET CSV do portal CONAB
- `_fallback_cepea()` → delega para SmartRouter
- `_extrair_tabela(soup)` → encontra <table>, itera <tr>, extrai <td>

**Payload de saída (por UF):**
```python
{
    "fonte_id": "precosiagroweb",
    "payload_bruto": {
        "linhas": [
            {"nome_produto": str, "preco_kg": float, "uf": str, "data_referencia": "YYYY-MM"}
        ],
        "total_requisicoes": int,
        "uf": str,
        "periodo": {"inicio": str, "fim": str},
    },
    "competencia": "YYYY-MM",
}
```

**Detalhes de implementação:**
- Retry com `tenacity` ou loop manual: 3 tentativas, `wait_exponential(multiplier=2, min=2, max=60)`
- Rate limiting: `asyncio.sleep(1)` entre batches de UF
- `_post_uf()` usa `self._semaphore` e CircuitBreaker manual
- `_parse_html()` usa `html.parser` (built-in, sem dep extra)
- Fallback hierarchy: A → B → C (cepea)
- `extract_all()` usa `asyncio.gather()` com `self._semaphore` para paralelismo controlado

**Critérios de aceite:**
- `_post_uf()` faz POST com parâmetros corretos
- `_parse_html()` extrai colunas de tabela HTML real
- `extract_all()` coleta dados de 8 UFs
- CircuitBreaker abre após 5 falhas consecutivas
- Retry com backoff exponencial (3 tentativas)
- Fallback acionado quando POST retorna 500/404/403
- Payload final compatível com `_extrair_de_dict()` via R2-T3

**Dependências:** R2-T3 (parsear_payload com suporte a "linhas")
**Estimativa:** 250 linhas
**Tipo:** NEW

---

#### R1-T2: Registrar PrecosiagrowebEngine no orchestrator.py

Registrar engine para as 8 UFs de contingência (AC, AM, AP, MS, PI, RO, RR, SE).

**Arquivos:**
- `pipeline/scraper/orchestrator.py` (~25 lines modified)

**Mudanças:**
1. Import: `from pipeline.scraper.micro_engines.precosiagroweb_engine import PrecosiagrowebEngine`
2. `_resolver_motor()`: add `if "precosiagroweb" in fid: return PrecosiagrowebEngine()`
3. `_FONTE_ID_PARA_ALVO`: add `"precosiagroweb": "precosiagroweb"`
4. Criar `_UFS_CONTINGENCIA = ["AC", "AM", "AP", "MS", "PI", "RO", "RR", "SE"]`
5. Criar `_passo_contingencia(uf, ano, mes)`:
   ```python
   async def _passo_contingencia(self, uf: str, ano: int, mes: int) -> list[dict[str, Any]] | None:
       if uf.upper() not in _UFS_CONTINGENCIA:
           return None
       engine = PrecosiagrowebEngine()
       url = "https://sisdep.conab.gov.br/precosiagroweb/"
       resultado = await self._executar_com_timeout(engine, url, ano, mes, "precosiagroweb")
       return [resultado] if resultado else None
   ```
6. Em `_coletar_interno()`: adicionar `_passo_contingencia()` entre `_passo_direto()` e `_passo_smartrouter()`:
   ```python
   # R1: Contingência para UFs sem CEASA direta (8 UFs)
   contingencia = await self._passo_contingencia(uf, ano, mes)
   if contingencia:
       acumulado.extend(contingencia)
   ```

**Critérios de aceite:**
- Engine registrada em `_resolver_motor()` para `"precosiagroweb"`
- `_passo_contingencia()` só executa para as 8 UFs alvo
- Payload flui para `raw.coleta_bruta`
- Não interfere com UFs que já têm CEASA mapping

**Dependências:** R1-T1, R2-T3
**Estimativa:** 25 linhas
**Tipo:** MODIFY

---

#### R1-T3: Testes unitários PrecosiagrowebEngine

Suite de testes com respx mock para POST HTTP e HTML table parsing.

**Arquivos:**
- `pipeline/tests/test_precosiagroweb_engine.py` (NEW, ~300 lines)

**Casos de teste:**

| Teste | Descrição | Mock |
|-------|-----------|------|
| `test_post_uf_success` | Happy path POST → parse HTML | respx POST → HTML 5-10 linhas |
| `test_parse_html_valid` | Extrair colunas de HTML válido | HTML realista |
| `test_parse_html_malformed` | HTML quebrado com <td> faltando | HTML mal formado |
| `test_parse_html_empty` | Sem <table> → lista vazia | HTML sem tabela |
| `test_semaphore_concurrency` | Máx 3 requests simultâneos | 3 delays mock |
| `test_circuit_breaker_5_failures` | 5 falhas → CB aberto | httpx raise 5x |
| `test_circuit_breaker_recovery` | 5 falhas → espera → 1 sucesso | 5 raise + 1 OK |
| `test_retry_then_success` | 2 falhas → 3ª sucesso | 2 raise + 1 OK |
| `test_retry_all_fail` | 3 falhas → exceção | 3 raises |
| `test_fallback_serie_historica` | POST 500 → fallback B | POST 500, GET CSV OK |
| `test_fallback_all_fail` | POST 500 + B falha → fallback C | POST 500, GET 404 |
| `test_extract_all_aggregation` | 8 UFs → 1 payload merged | 8 mocks diferentes |
| `test_payload_format` | Output compatível _extrair_de_dict | HTML válido |

**Mock setup:** `respx.mock` interceptando POST para `sisdep.conab.gov.br/precosiagroweb/`. Retornar HTML diferente por UF usando side_effect ou conditional mock.

**Sample HTML:** Salvar em `pipeline/tests/samples/precosiagroweb_sample.html` (~30 linhas de tabela real da CONAB).

**Critérios de aceite:**
- `pytest -v pipeline/tests/test_precosiagroweb_engine.py` passa todos
- Cobertura > 80% na engine
- Teste de semáforo verifica que máximo 3 requests estão ativos simultaneamente
- Teste de fallback verifica hierarquia A → B → C

**Dependências:** R1-T1
**Estimativa:** 300 linhas
**Tipo:** NEW

---

#### R1-T4: Integração E2E Precosiagroweb (opcional)

Teste de integração com sample HTML real, sem HTTP mock.

**Arquivos:**
- `pipeline/tests/test_precosiagroweb_engine.py` (ADD, ~40 lines)

**Critérios de aceite:**
- Marcado `@pytest.mark.integration`
- Carrega `samples/precosiagroweb_sample.html`
- Simula `_parse_html()` sem HTTP
- Valida que todas as linhas têm nome_produto, preco_kg, uf

**Dependências:** R1-T1
**Estimativa:** 40 linhas
**Tipo:** ADD

---

### R4 — Investigação SP

#### R4-T1: Criar SQL queries de investigação SP

Criar arquivo SQL com as 4 queries de investigação para os gaps de SP.

**Arquivos:**
- `database/processed_data/sql/03_investigacao_sp.sql` (NEW, ~80 lines)

**Conteúdo:**
- Query 1 — Produtos SP em 2025-12 vs 2026-06 (comparação extremos)
- Query 2 — Produtos que sumiram completamente de SP em 2026 (subquery com NOT IN)
- Query 3 — Cross-check dim_produto com bool_or para presente_2025 vs presente_2026
- Query 4 — Verificar categoria_b2c no SortingEngine (produtos SP com categoria errada)

**Formato:** SQL comentado com blocos separados por `-- ======`, pronto para copiar/colar no DBeaver.

**Critérios de aceite:**
- Arquivo SQL com as 4 queries da spec
- Comentários explicativos para cada query
- Queries executáveis diretamente no banco de staging
- Inclui filtro `fpm.mes BETWEEN 1 AND 6` para 2026 (excluir meses futuros)

**Dependências:** nenhuma
**Estimativa:** 80 linhas
**Tipo:** NEW

---

#### R4-T2: Relatório de investigação SP

Criar template para relatório de análise dos resultados das queries.

**Arquivos:**
- `docs/relatorio_investigacao_sp.md` (NEW, ~50 lines — template + instruções)

**Conteúdo:**
1. Instruções para executar as 4 queries
2. Tabela para preencher resultados de cada query (contagens)
3. Seções de análise: bug vs cobertura parcial CONAB
4. Decisão documentada (template preenchido manualmente após execução)

**Critérios de aceite:**
- Template cobre todas as 4 queries
- Inclui seção de decisão (bug ou gap CONAB)
- Diferencia meses futuros (jul-dez/2026, ignorados) de gaps reais (jan-jun/2026)
- Formato markdown

**Dependências:** R4-T1
**Estimativa:** 50 linhas
**Tipo:** NEW

---

## Summary

| Item | Tasks | Total Est. Lines | Type |
|------|-------|-----------------|------|
| R2 | R2-T1 a R2-T6 | ~565 | engine + orchestrator + parse fix + tests |
| R3 | R3-T1 a R3-T6 | ~467 | snapshot + checkpoint + ghost_dba + tests |
| R1 | R1-T1 a R1-T4 | ~615 | engine + orchestrator + tests |
| R4 | R4-T1 a R4-T2 | ~130 | SQL + report |
| **Total** | **18 tasks** | **~1.777** | |

---

## Review Workload Forecast

**total_lines_estimate:** 1.777

**chained_prs_recommended:** 3 PRs
- PR 1: R2 + R3 (dependentes, ~1.032 lines) — maior risco de merge conflict com sorting_engine.py e orchestrator.py
- PR 2: R1 (independente, ~615 lines) — pode seguir em paralelo
- PR 3: R4 (130 lines) — trivial, pode ir junto com PR 2

**decision_needed_before_apply:**
1. **R2-T3 execution model**: ProhortMensalEngine roda 1x por competência (não por UF). Onde colocar o hook? Alternativa A: `_passo_prohort()` em `_coletar_interno()` executado quando `uf == _UFS[0]` (SP). Alternativa B: método separado chamado por competência no `main_runner.py`. **Recomendação:** Alternativa A (dentro do orquestrador, minimiza mudanças externas) — mas confirmar com o usuário.
2. **R1-T2 UF routing**: `_passo_contingencia()` ou adicionar UFs ao `_UF_CEASA_MAP`? **Recomendação:** `_passo_contingencia()` — não polui o mapa existente e é mais explícito.
3. **R3-T1 PARQUET fallback**: PostgreSQL pode não ter suporte a `FORMAT PARQUET` no `COPY`. **Decisão:** implementar fallback para CSV e documentar limitação. Se PARQUET falhar, salvar como CSV + registrar warning.
4. **R2-R3/R1 merge order**: R2 e R3 tocam `orchestrator.py` e `main_runner.py` — potencial conflito. **Recomendação:** aplicar R2 first, depois R3 (que só adiciona 1 linha em main_runner.py), e R1 por último (adiciona `_passo_contingencia`).
