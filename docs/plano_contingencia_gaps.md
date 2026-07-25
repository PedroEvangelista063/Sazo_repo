# Plano de Contingência — Gaps de Cobertura CONAB 2024–2026

**Baseado em:** `auditoria_cobertura_2024_2026.md`
**Gerado em:** Julho/2026
**Stack do projeto:** `pipeline/scraper/` (micro-engines + SmartRouter + Discovery), `pipeline/ingestao_conab.py` (pipeline alternativo), `config/sources_matrix.json` (186 fontes em 4 categorias)

---

## Entendimento Temporal — 2026

Julho de 2026 é o mês corrente. **Meses futuros de 2026 (jul–dez) NÃO configuram gap** — são meses que ainda não ocorreram e serão preenchidos automaticamente quando o usuário ligar o motor de scraper manualmente a cada mês.

O plano de contingência trata APENAS gaps reais:
- **2024:** anos completos — todo gap é real e precisa de ação (R1).
- **2025:** ano completo — gaps indicam fonte incompleta.
- **2026 jan–jun:** meses já decorridos — gaps são reais e merecem investigação (R4).
- **2026 jul–dez:** meses futuros — **ignorados pelo plano.** O preenchimento é responsabilidade do scraper mensal, não de contingência.

---

## Matriz de Riscos

| Risco | Severidade | Probabilidade | Impacto |
|-------|-----------|---------------|---------|
| **R1** — 8 UFs sem 2024 (AC, AM, AP, MS, PI, RO, RR, SE) | 🔴 Alta | Alta | Sem baseline histórico para forecast |
| **R2** — ProHort nunca carregado (fato_cotacao_regional = 0) | 🔴 Alta | Certa | Metade do pipeline CONAB não roda |
| **R3** — Rolling window da CONAB (arquivo substituído, perda de dado histórico) | 🟡 Média | Média | Perda mensal de ~3.000 registros se scraper não rodar a tempo |
| **R4** — SP com 1.245 gaps em 2026 (jan–jun: reais; jul–dez: meses futuros, ignorados) | 🟡 Média | Média | Subnotificação do maior mercado do Brasil |
| **R5** — Fonte CONAB muda URL (404/403 sem aviso) | 🟢 Baixa | Baixa | Ghost DBA Agent já trata com LLMUrlRouter |

---

## Plano de Ação por Risco

### R1 — Backfill 2024 para 8 UFs Críticas

**Alvo:** AC, AM, AP, MS, PI, RO, RR, SE (2024 inteiro sem dados)

#### Estratégia A (Recomendada) — CONAB Precosiagroweb
- **URL:** https://sisdep.conab.gov.br/precosiagroweb/
- **Cobertura:** Dados de 2014 até hoje, por UF + produto + mês
- **Formato:** HTML table com query params (POST)
- **Implementação:** Criar micro-engine `PrecosiagrowebEngine` em `pipeline/scraper/micro_engines/`
  - POST com parâmetros: periodo_inicial, periodo_final, produto, uf, nivel_comercializacao
  - Parsear HTML table retornada
  - Para 2024: iterar por UF (8) × mês (12) × produto (usar lista da dim_produto)
  - Usar `asyncio.Semaphore(3)` + `CircuitBreaker` (padrão base_engine)
- **Pipeline de carga:** Inserir via `raw.coleta_bruta` → `SortingEngine` → `fact_precos_mensais`
- **Estimativa:** ~96 requisições (8 UFs × 12 meses), ~5 min com semáforo 3
- **Risco:** CONAB pode limitar por rate ou mudar o HTML

#### Estratégia B — CONAB Série Histórica (download de arquivo único)
- **URL:** https://portaldeinformacoes.conab.gov.br/precos-agropecuarios-serie-historica.html
- **Cobertura:** Pode conter CSV completo por ano
- **Abordagem:** Fazer download direto via `ingestao_conab.py` se houver link CSV
- **Vantagem:** Arquivo único vs 96 requests

#### Estratégia C (Fallback) — CEPEA/ESALQ
- **URL:** https://www.cepea.esalq.usp.br/br
- **Cobertura:** HF brasil, preços atacado, séries históricas
- **Formato:** CSV/JSON (API paga, scraping necessário)
- **Implementação:** Já mapeado em `sources_matrix.json` como agregador. Enganchar no SmartRouter.
- **Limitação:** Apenas preços de atacado (SP como referência), não cobre todas as 8 UFs

#### Estratégia D (Último recurso) — Solicitação oficial CONAB
- **Contato:** `conab.gepep@conab.gov.br` ou `geinf@conab.gov.br`
- **SIC:** `sic.conab@conab.gov.br` (Lei de Acesso à Informação)
- **Prazo:** 20 dias úteis (LAI)
- **Formato:** CSV por email

---

### R2 — Implementar Scraper ProHort

**Alvo:** `staging.fato_cotacao_regional` — atualmente 0 registros

#### Análise do gap
O arquivo `ProhortMensal.txt` existe na CONAB mas o pipeline nunca carregou. Já existe infraestrutura:

| Componente | Status | Localização |
|------------|--------|-------------|
| `ingestao_conab.py` — `transform_prohort()` | ✅ Pronto, testado | `pipeline/ingestao_conab.py:349` |
| `ConabApiEngine` (ProhortDiario.txt) | ✅ Em produção | `pipeline/scraper/micro_engines/ConabApiEngine.py` |
| `ProHortAdapter` (API REST) | ✅ Pronto, não usado | `pipeline/scraper/adapters/hortifrut/prohort.py` |
| `staging.fato_cotacao_regional` | ✅ Schema criado | DDL Fase 15 |
| `CONAB_URLS["prohort"]` | ✅ Constante | `ghost_dba_agent.py:219` |

#### Estratégia A (Recomendada) — Nova Micro-Engine
Criar `ProhortMensalEngine` em `pipeline/scraper/micro_engines/prohort_mensal_engine.py`:
- Herdar de `BaseMicroEngine`
- `extract()` → GET com httpx, timeout 180s (arquivo ~5MB+)
- Parsear CSV com `csv.DictReader` (delimitador `;`)
- Transformar: `preco_medio = valor_comercializado / qtd_comercializada_kg`
- Retornar payload no formato esperado pelo `SortingEngine._extrair_de_dict()`
- Registrar no `orchestrator.py` como `"conab-prohort-mensal"`

#### Estratégia B — Usar `ingestao_conab.py` + agendamento
- A função `transform_prohort()` já está implementada e funcional
- A carga direta em `raw.precos_municipio` já está mapeada
- Criar schedule (cron mensal) para `python -m pipeline.ingestao_conab --prohort-only`
- Depois rodar `INSERT INTO staging.fato_cotacao_regional SELECT ...` via SP

#### Estratégia C — Usar ConabApiEngine existente (ProhortDiario)
- O `ConabApiEngine` já baixa `ProhortDiario.txt` (dados DIÁRIOS)
- Adaptar para também aceitar o formato MENSAL
- Mais complexo mas reusa toda a infra de rate-limit, circuito, semáforo

---

### R3 — Mitigação do Rolling Window

**Risco:** A CONAB substitui `PrecosMensalUF.txt` periodicamente (~12 meses). Se o scraper não rodar antes da substituição, perdemos o mês anterior.

#### Plano
1. **Cron mensal obrigatório**: agendar execução do `main_runner.py` para o **dia 1 de cada mês**
2. **Snapshot automático**: após cada carga, fazer `COPY staging.fact_precos_mensais TO '.../01_raw/snapshot_YYYY_MM.parquet'` via SP
3. **Arquivo de checkpoint**: `database/processed_data/01_raw/ultimate_backfill_checkpoint.json` já existe — expandir para registrar o mês vigente de cada fonte
4. **Ghost DBA Agent**: já monitora as URLs CONAB com `LLMUrlRouter` — configurar alerta se `_ultima_carga` tiver mais de 45 dias

---

### R4 — SP Gaps em 2026

**Alvo:** Investigar por que SP tem 1.245 combinações sem dado em 2026.

⚠️ **Ressalva temporal:** gaps de jul–dez/2026 são meses futuros e **não entram na conta**. O número real de gaps a investigar é apenas jan–jun/2026. O restante será preenchido pelo scraper mensal conforme o calendário avança.

#### Hipóteses
1. SP tem mais produtos cadastrados que outras UFs e a cobertura jan–jun/2026 não alcançou todos
2. Alguns produtos de SP deixaram de ser publicados pela CONAB em 2026
3. Bug no mapeamento de `dim_localidade` para SP

#### Ação
1. `SELECT dp.nome_produto, COUNT(*) FROM staging.fact_precos_mensais fpm JOIN staging.dim_produto dp ON fpm.id_produto = dp.id_produto JOIN staging.dim_localidade dl ON fpm.id_localidade = dl.id_localidade WHERE dl.uf = 'SP' AND fpm.ano = 2025 AND fpm.mes = 12 GROUP BY dp.nome_produto ORDER BY COUNT(*) DESC LIMIT 20;`
2. Comparar com `WHERE fpm.ano = 2026 AND fpm.mes = 6` — se produtos sumiram, é CONAB. Se produtos existem mas com menos UFs, é cobertura parcial.
3. Verificar se SP precisa de tratamento especial no `SortingEngine`: talvez a classificação `categoria_b2c` esteja dropando produtos SP que seriam válidos.

---

### R5 — Ghost DBA Agent (já implementado)

O `LLMUrlRouter` em `pipeline/ghost_dba_agent.py:223` já faz:
- Verificação periódica das URLs CONAB
- Em caso de 404/403, varre o portal e usa LLM para descobrir novo endpoint
- Persistência automática no `.env`
- ✅ Nenhuma ação necessária

---

## Mapa de Fallback — Motores Scraper Alternativos

| Fonte | URL | Tipo | Cobertura | Já integrado? | Prioridade |
|-------|-----|------|-----------|---------------|------------|
| **CONAB Precosiagroweb** | https://sisdep.conab.gov.br/precosiagroweb/ | HTML table (POST) | 2014–hoje, todas UFs | ❌ | 🔴 R1 |
| **CONAB Série Histórica** | https://portaldeinformacoes.conab.gov.br/precos-agropecuarios-serie-historica.html | HTML/CSV | Histórico completo | ❌ | 🔴 R1 |
| **CONAB Prohort Mensal** | https://portaldeinformacoes.conab.gov.br/downloads/arquivos/ProhortMensal.txt | CSV | Mensal, CEASAs nacionais | ✅ `ingestao_conab.py` | 🔴 R2 |
| **CEPEA/ESALQ** | https://www.cepea.esalq.usp.br/br | CSV/JSON | Preços atacado SP (referência nacional) | ⚠️ `sources_matrix.json` | 🟡 R1 fallback |
| **CEASA Data Warehouse** | http://dw.ceasa.gov.br/ | Web | Série histórica CEASAs | ❌ | 🟡 R1 fallback |
| **IBGE SIDRA Tabela 7060** | https://sidra.ibge.gov.br/tabela/7060 | API JSON | Inflação modelo, preços varejo | ✅ `sources_matrix.json` core | 🟢 Monitoria |
| **CONAB Portal Downloads** | https://portaldeinformacoes.conab.gov.br/download-arquivos.html | HTML | Lista completa de arquivos disponíveis | ✅ Ghost DBA Agent | 🟢 Autodescoberta |

---

## Priorização e Timeline

```
Mês 1 (Jul-Ago 2026) — Crítico:
  ├── R2 Scraper ProHort Mensal Engine
  └── R2 Carga inicial ProHort (backfill)

Mês 2 (Ago-Set 2026) — Alto:
  ├── R1 Precosiagroweb Engine (8 UFs críticas)
  └── R1 Backfill 2024 para AC, AM, AP, MS, PI, RO, RR, SE

Mês 3 (Set 2026) — Médio:
  ├── R3 Snapshot automático pós-carga
  └── R4 Investigação SP (gaps reais jan–jun, ignorando jul–dez)

Contínuo:
  ├── R5 Ghost DBA Agent monitoring
  └── Cron mensal main_runner.py
```

---

## Métricas de Sucesso

| Indicador | Alvo | Medição |
|-----------|------|---------|
| Gaps 2024 nas 8 UFs críticas | < 10% do esperado | `00_audit_cobertura.sql` Bloco 4 |
| `fato_cotacao_regional` populada | ≥ 5.000 registros | `SELECT COUNT(*)` |
| Rolling window sem perda | 0 meses perdidos | Gap de continuidade = 0 |
| SP gaps reais jan–jun/2026 | < 200 (vs 1.245 total que inclui meses futuros) | `00_audit_cobertura.sql` Bloco 1 filtrando mes <= 6 |
| Meses futuros jul–dez/2026 | Ignorado — preenchimento por scraper mensal | Sem ação de contingência |
