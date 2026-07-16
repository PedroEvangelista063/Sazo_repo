# Spec: contingencia-gaps-conab

## R2 — ProhortMensalEngine

### Input
- **URL**: `https://portaldeinformacoes.conab.gov.br/downloads/arquivos/ProhortMensal.txt`
- **Formato**: CSV delimitado por `;`, encoding ISO-8859-1 (latin-1)
- **Método**: HTTP GET via `httpx.AsyncClient` com `timeout=180s`, `follow_redirects=True`
- **Semáforo**: `asyncio.Semaphore(3)` herdado da `BaseMicroEngine`
- **CircuitBreaker**: `failure_threshold=5`, `recovery_timeout_s=120.0`

### Colunas esperadas no CSV
| Nome coluna | Tipo | Mapeamento saída |
|---|---|---|
| `dsc_produto` | string | `nome_produto` |
| `cod_ibge_municipio_ceasa` | string | (usado internamente) |
| `municipio_ceasa` | string | (usado internamente) |
| `uf_ceasa` | string | `uf` |
| `id_ano_comercializacao` | int | `ano` |
| `id_mes_comercializacao` | int | `mes` |
| `qtd_comercializada_kg` | float (str `,` decimal) | usado no cálculo |
| `valor_comercializado` | float (str `,` decimal) | usado no cálculo |

### Transformação
1. Parse CSV com `csv.DictReader`, delimitador `;`
2. Pular primeira linha se for cabeçalho (detectar por `COLUNAS` no `fieldnames`)
3. Converter `qtd_comercializada_kg` e `valor_comercializado`: `str.replace(",", ".")` → `float`
4. Calcular `preco_medio = valor_comercializado / qtd_comercializada_kg` (apenas onde `qtd > 0`)
5. Filtrar linhas com `preco_medio > 0`

### Output — payload bruto
Formato aceito por `SortingEngine._extrair_de_dict()`:
```python
{
  "fonte_id": "conab-prohort-mensal",
  "payload_bruto": {
    "linhas": [
      {
        "nome_produto": str,   # dsc_produto
        "preco_kg": float,     # preco_medio calculado
        "uf": str,             # uf_ceasa (2 chars, uppercase)
        "data_referencia": str, # "YYYY-MM" (ano-mes)
      }
    ],
    "total_linhas": int,
    "ufs_abrangidas": list[str],
    "periodo_inicial": str,
    "periodo_final": str,
  },
  "competencia": "YYYY-MM",
}
```

### Pipeline
`raw.coleta_bruta` → `SortingEngine._parsear_payload()` → `_extrair_de_dict()` → valida `ProdutoSazonalSchema` → `INSERT INTO staging.fact_precos_mensais` (upsert por `id_produto, id_localidade, ano, mes`).

### Arquivo
`pipeline/scraper/micro_engines/prohort_mensal_engine.py`

### Classe
`ProhortMensalEngine(BaseMicroEngine)`:
- `extract(url, ano, mes)` → baixa CSV completo, filtra por ano/mes, calcula preco_medio, retorna dict formato acima
- `extract_all(ano, mes)` → delega para `extract()`
- `_download_csv()` → GET com httpx, decode iso-8859-1, CircuitBreaker, semáforo
- `_parse_csv(raw)` → csv.DictReader, fieldnames hardcoded, pula header
- `_filtrar(linhas, ano, mes)` → filtra por `id_ano_comercializacao` e `id_mes_comercializacao`
- `_calcular_preco_medio(linhas)` → deriva preco_kg, filtra qtd=0

### Testes
1. **Unit test** (`pipeline/tests/test_prohort_mensal_engine.py`):
   - Mock HTTP response com `httpx.MockTransport` ou `respx` — retorna CSV sample de ~100 linhas
   - Verificar parse do CSV (colunas, encoding)
   - Verificar cálculo `preco_medio = valor / qtd`
   - Verificar filtro por ano/mes
   - Verificar rejeição de qtd=0
   - Verificar CircuitBreaker aberto → RuntimeError
   - Verificar extração completa sem filtro (`extract_all`)
   - Verificar formato do payload de saída compatível com `ProdutoSazonalSchema`

2. **Integration test** (opcional, marcado `@pytest.mark.integration`):
   - Usar sample real do arquivo salvo em `pipeline/tests/samples/prohort_mensal_sample.txt`
   - Validar parsing de ~50 linhas reais
   - Verificar encoding latin-1

### Critérios de aceite
- [x] Carga inicial de TODO o histórico disponível no arquivo (sem limite de ano)
- [x] Pelo menos 5.000 registros em `staging.fato_cotacao_regional` (query: `SELECT COUNT(*) FROM staging.fato_cotacao_regional`)
- [x] Timeout 180s configurável via `httpx.Timeout(180.0, connect=15.0)`
- [x] CircuitBreaker integrado (herdado da `BaseMicroEngine`)
- [x] Registrado no `orchestrator.py` como `"conab-prohort-mensal"` em `_resolver_motor()` e `_FONTE_ID_PARA_ALVO`

---

## R1 — PrecosiagrowebEngine

### Input
- **URL**: `https://sisdep.conab.gov.br/precosiagroweb/`
- **Método**: HTTP POST com `application/x-www-form-urlencoded`
- **Parâmetros obrigatórios**:
  - `periodo_inicial`: `"DD/MM/YYYY"`
  - `periodo_final`: `"DD/MM/YYYY"`
  - `produto`: `"*"` (todos) ou nome específico
  - `uf`: sigla 2 letras (ex: `"AC"`)
  - `nivel_comercializacao`: `"*"` (todos)
- **Formato resposta**: HTML table com linhas de dados
- **Timeout**: 30s por request

### Cobertura
- **8 UFs**: AC, AM, AP, MS, PI, RO, RR, SE
- **Período**: 2024 (janeiro a dezembro)
- **Produtos**: usar lista da `staging.dim_produto` como referência para `produto` parameter
- **Total estimado**: ~96 requisições (8 UFs × 12 meses × 1 request por UF+mês com `produto=*`)
- Abordagem recomendada: 1 requisição por UF+mes com `produto="*"`, em vez de N requisições por produto

### Controles de execução
- `asyncio.Semaphore(3)` — máximo 3 requisições concorrentes ao mesmo domínio
- `CircuitBreaker` — `failure_threshold=5`, `recovery_timeout_s=120.0`
- Retry com backoff exponencial: 3 tentativas, `wait_exponential(multiplier=2, min=2, max=60)`
- Rate limiting: respeitar intervalo mínimo de 1s entre requisições por UF (pode usar `asyncio.sleep(1)` entre batches de UF)

### Parser HTML
- BeautifulSoup (`html.parser`)
- Estratégia:
  1. Encontrar `<table>` com dados (procurar por classe ou posição)
  2. Extrair linhas `<tr>` (pular header)
  3. Colunas esperadas: produto, classificacao, unidade, preco_min, preco_comum, preco_max
  4. Calcular `preco_medio = preco_comum / fator_padrao` (ou usar preco_comum)
  5. Fallback: se `<tr>` não seguir padrão, varrer `<td>` e extrair texto

### Fallback hierarchy
1. **A — CONAB Precosiagroweb** (POST HTML) — primário
2. **B — CONAB Série Histórica** — download CSV único de `https://portaldeinformacoes.conab.gov.br/precos-agropecuarios-serie-historica.html`
3. **C — CEPEA/ESALQ** — já mapeado em `sources_matrix.json` como agregador, enganchar no SmartRouter

### Output — payload bruto
```python
{
  "fonte_id": "precosiagroweb",
  "payload_bruto": {
    "linhas": [
      {
        "nome_produto": str,
        "preco_kg": float,
        "uf": str,
        "data_referencia": str,  # "YYYY-MM"
      }
    ],
    "total_requisicoes": int,
    "uf": str,
    "periodo": {"inicio": str, "fim": str},
  },
  "competencia": "YYYY-MM",
}
```

### Pipeline
`raw.coleta_bruta` → `SortingEngine._parsear_payload()` → `_extrair_de_dict()` → `staging.fact_precos_mensais`

### Arquivo
`pipeline/scraper/micro_engines/precosiagroweb_engine.py`

### Classe
`PrecosiagrowebEngine(BaseMicroEngine)`:
- `extract(url, ano, mes)` → POST para 1 UF+mes, retorna payload
- `extract_all(ano, mes)` → itera 8 UFs, executa com semáforo, coleta todos resultados
- `_post_uf(uf, ano, mes)` → POST com parâmetros, trata resposta HTML, CircuitBreaker
- `_parse_html(html)` → BeautifulSoup, extrai table rows
- `_fallback_serie_historica(uf, ano, mes)` → tenta download CSV Série Histórica
- `_fallback_cepea()` → delega para SmartRouter (fonte CEPEA)

### Testes
1. **Unit test** (`pipeline/tests/test_precosiagroweb_engine.py`):
   - Mock HTTP POST com HTML sample real da CONAB (5-10 linhas de tabela)
   - Verificar parse de HTML table
   - Verificar extração de colunas (produto, preco, uf)
   - Verificar semáforo: 3 requisições concorrentes
   - Verificar CircuitBreaker: 5 falhas consecutivas → aberto
   - Verificar retry: mock 2 falhas seguidas, depois sucesso
   - Verificar fallback: mock POST 404 → tentar Série Histórica

2. **Integration test** (opcional, marcado `@pytest.mark.integration`):
   - HTML sample real em `pipeline/tests/samples/precosiagroweb_sample.html`

### Critérios de aceite
- [x] Dados de 2024 para AC, AM, AP, MS, PI, RO, RR, SE carregados em `staging.fact_precos_mensais`
- [x] Fallback automático se POST falhar (tentar Série Histórica CONAB)
- [x] Rate limiting respeitando servidor CONAB (Semaphore(3), 1s entre UFs)
- [x] Testes com HTML mockado

---

## R3 — Snapshot automático

### Trigger
Hook pós-carga no `main_runner.py`, executado imediatamente após `executar_ciclo_medalhao()` retornar com sucesso.

### Fluxo
```python
await executar_ciclo_medalhao(pool)          # já existe
await executar_snapshot_e_checkpoint(pool)   # novo hook
```

### Ação
1. **Snapshot Parquet**:
   - `COPY (SELECT * FROM staging.fact_precos_mensais ORDER BY ano, mes, id_produto, id_localidade) TO '<output_path>' WITH (FORMAT PARQUET)`
   - Output path: `database/processed_data/01_raw/snapshot_YYYY_MM.parquet`
   - Usar asyncpg ou psycopg2 para executar COPY
   - Se o diretório `database/processed_data/01_raw/` não existir, criar (idempotente)

2. **Checkpoint expandido**:
   - Atualizar `database/processed_data/01_raw/ultimate_backfill_checkpoint.json`
   - Novo schema:
   ```json
   {
     "snapshot_atual": "snapshot_2026_07.parquet",
     "fontes": {
       "conab-precos-uf": {"ultima_competencia": "2026-07", "ultima_carga": "2026-07-15T10:00:00"},
       "conab-prohort-mensal": {"ultima_competencia": "2026-07", "ultima_carga": "2026-07-15T10:00:00"},
       "precosiagroweb": {"ultima_competencia": "2024-12", "ultima_carga": "2026-07-15T10:00:00"}
     },
     "ultima_atualizacao": "2026-07-15T10:00:00"
   }
   ```
   - Usar `json.dump` com `ensure_ascii=False, indent=2`

3. **Alerta Ghost DBA Agent**:
   - Adicionar verificação no `LLMUrlRouter` ou no ciclo de polling: consultar checkpoint, se `ultima_carga` de qualquer fonte > 45 dias, logar WARNING e disparar webhook
   - Implementar como método separado em `AsyncIOSelfHealer` ou função standalone em `ghost_dba_agent.py`

### Arquivos modificados
- `pipeline/scraper/main_runner.py` — adicionar hook pós-medalhão
- `pipeline/scraper/persistence.py` — nova função `executar_snapshot_e_checkpoint(pool)`
- `pipeline/ghost_dba_agent.py` — nova checagem de checkpoint expiry

### Testes
1. **Unit test** (mock de pool asyncpg):
   - Verificar chamada SQL gerada (deve conter `COPY ... TO ... PARQUET`)
   - Verificar conteúdo do checkpoint JSON
   - Verificar idempotência (diretório já existe)

2. **Mock de Ghost DBA Agent**:
   - Checkpoint com `ultima_carga` = 50 dias atrás → deve logar WARNING

### Critérios de aceite
- [x] Snapshot `.parquet` gerado automaticamente após cada execução bem-sucedida do scraper
- [x] Checkpoint legível por humanos e por máquina (JSON formatado)
- [x] Não falha se diretório já existir (idempotente)
- [x] Ghost DBA Agent alerta se última carga > 45 dias

---

## R4 — Investigação SP

### Contexto
SP tem 1.245 gaps apontados na auditoria. Destes, jul-dez/2026 são meses futuros (ignorados). Restam gaps reais em jan-jun/2026. Investigar causa: bug no pipeline ou cobertura parcial da CONAB.

### SQL Queries

**Query 1** — Produtos de SP em 2025-12 vs 2026-06 (comparação extremos)
```sql
SELECT dp.nome_produto, COUNT(*) AS qtd_ocorrencias
FROM staging.fact_precos_mensais fpm
JOIN staging.dim_produto dp ON fpm.id_produto = dp.id_produto
JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
WHERE dl.uf = 'SP'
  AND fpm.ano = 2025
  AND fpm.mes = 12
GROUP BY dp.nome_produto
ORDER BY dp.nome_produto;
```
Executar a mesma query para `ano=2026 AND mes=6`. Comparar resultados: produtos que aparecem em 2025 mas não em 2026.

**Query 2** — Produtos que sumiram completamente de SP em 2026
```sql
SELECT dp.nome_produto
FROM staging.dim_produto dp
WHERE dp.id_produto IN (
  SELECT DISTINCT fpm.id_produto
  FROM staging.fact_precos_mensais fpm
  JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
  WHERE dl.uf = 'SP'
    AND fpm.ano = 2025
)
AND dp.id_produto NOT IN (
  SELECT DISTINCT fpm.id_produto
  FROM staging.fact_precos_mensais fpm
  JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade
  WHERE dl.uf = 'SP'
    AND fpm.ano = 2026
    AND fpm.mes BETWEEN 1 AND 6
);
```
Se retornar linhas: produtos foram descontinuados pela CONAB em 2026 (gap da fonte, não bug).

**Query 3** — Cross-check com `dim_produto` para ver se algum produto foi descontinuado
```sql
SELECT dp.nome_produto, dp.categoria_b2c,
  bool_or(fpm.ano = 2025) AS presente_2025,
  bool_or(fpm.ano = 2026 AND fpm.mes BETWEEN 1 AND 6) AS presente_2026_jan_jun
FROM staging.dim_produto dp
LEFT JOIN staging.fact_precos_mensais fpm ON dp.id_produto = fpm.id_produto
LEFT JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade AND dl.uf = 'SP'
GROUP BY dp.nome_produto, dp.categoria_b2c
HAVING bool_or(fpm.ano = 2025) = TRUE
   AND bool_or(fpm.ano = 2026 AND fpm.mes BETWEEN 1 AND 6) = FALSE
ORDER BY dp.nome_produto;
```
Produtos com `presente_2025=true, presente_2026_jan_jun=false` são gap real — CONAB parou de publicar.

**Query 4** — Verificar se `categoria_b2c` no SortingEngine está dropando produtos SP
```sql
SELECT dp.nome_produto, dp.categoria_b2c, COUNT(fpm.id_produto) AS qtd_registros
FROM staging.dim_produto dp
LEFT JOIN staging.fact_precos_mensais fpm ON dp.id_produto = fpm.id_produto
LEFT JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade AND dl.uf = 'SP'
WHERE dp.categoria_b2c IS NULL
   OR dp.categoria_b2c != 'ALIMENTO_VAREJO'
GROUP BY dp.nome_produto, dp.categoria_b2c
ORDER BY dp.nome_produto;
```
Se produtos ALIMENTO_VAREJO estão com categoria_b2c diferente, é bug no regex do SortingEngine para SP.

### Output esperado
Relatório em `docs/relatorio_investigacao_sp.md` com:
1. Resultados das 4 queries (tabelas com contagens)
2. Análise: gaps são bug ou cobertura parcial da CONAB
3. Decisão documentada

### Critérios de aceite
- [x] Relatório SQL com resultados das queries
- [x] Decisão documentada: bug ou gap real da CONAB
- [x] Diferenciação clara entre meses futuros (jul-dez/2026, ignorados) e gaps reais (jan-jun/2026)
