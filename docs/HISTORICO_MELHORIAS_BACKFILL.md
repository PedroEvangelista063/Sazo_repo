# Historico de Melhorias — Backfill Historico (Santo Graal)

## Data: 2026-07-07

### Contexto

O projeto `quero_comprar_vg` coleta precos de hortalicas, frutas e legumes de
multiplas fontes (CEAGESP, HF Brasil, Agrolink CEASA) mensalmente. Meses
anteriores a 2025 permaneciam sem dados por falta de um mecanismo de busca
historica — as fontes primarias (CEAGESP, HF Brasil) so retornam dados do mes
corrente.

### O Problema (Gap Original)

Antes da implementacao do backfill:
- 59 de 79 meses (74.7%) estavam **completamente vazios** no banco local
- A cobertura media era de apenas **1.3%**
- Anos 2021, 2022, 2023, 2024: 0% de cobertura em todos os meses
- Nao havia pipeline automatizado para buscar dados historicos
- Nao havia checkpoint/recomeco para varreduras longas

### O Que Foi Feito (Melhorias)

#### 1. SantoGraalAdapter (Cascata Camada 0)

Criacao de adapter dedicado para busca historica profunda via Playwright,
executado como **Camada 0** na cascata do SmartRouter (antes de qualquer
outra fonte):

- **CEAGESP**: Navegacao por categorias (FRUTAS, LEGUMES, VERDURAS, etc.) via
  formulario web com Playwright
- **CEPEA**: Tentativa de extracao via banco de dados CEPEA (pickadate.js)
- Fallback silencioso se ambas fontes falharem

**Descoberta critica**: CEPEA nao possui dados de HF (hortifruti). As entradas
como "Uva", "Tomate" no site CEPEA sao links externos para HF Brasil. CEPEA
so tem indicadores de commodities (boi, cafe, soja, leite). O banco de dados
do CEPEA usa pickadate.js com selects sem name/id e botao `<a id="adicionar">`.

**Descoberta critica 2**: CEAGESP nao permite consulta historica — o form
de consulta sempre retorna dados do mes corrente. Cada execucao do backfill
para um mes passado carrega os mesmos 571 precos atuais em um slot mensal
diferente.

#### 2. Patchright/Stealth Integration

- `executar_adapters_playwright()` agora aplica `playwright-stealth`
  automaticamente em todas as sessoes do browser
- Aceita `**context_kwargs` para fingerprint (locale, timezone, UA dinamico)
- SmartRouter Camada 0 injeta configuracao de fingerprint do Organism
  quando disponivel (locale=pt-BR, timezone=America/Sao_Paulo, UA pool)

#### 3. Pipeline de Backfill (run_ultimate_backfill.py)

- Sistema de **checkpoint** em JSON para retomada de varreduras longas
- `--parallel N` com `asyncio.Semaphore` + jitter aleatorio (0-5s) entre
  chunks
- `--skip-check` para ignorar deteccao de orfaos e varrer range fixo
- `--reset` para limpar checkpoint e recomecar
- `PYTHONPATH` configurado para subprocessos resolverem `import pipeline`

### Resultados: Cobertura Pre vs Pos

```
Metrica                  Pre-Backfill    Pos-Backfill    Melhoria
------------------------------------------------------------------------
Meses com dados          18/79 (22.8%)   20/79 (25.3%)   +2 meses
Cobertura media global   1.3%            6.3%            +5.0 p.p.
Meses VAZIOS (0 prod)    63              59              -4 meses
Meses COMPLETO (>=95%)   0               0               sem mudanca
Meses PARCIAL (50-94%)   2               2               sem mudanca
```

### Matriz de Cobertura Atual

```
Ano     1    2    3    4    5    6    7    8    9   10   11   12   Media
2020    4%   0%   0%   0%   0%   0%   0%   0%   0%   0%   0%   0%   0.3%
2021    0%   0%   0%   0%   0%   0%   0%   0%   0%   0%   0%   0%   0.0%
2022    0%   0%   0%   0%   0%   0%   0%   0%   0%   0%   0%   0%   0.0%
2023    0%   0%   0%   0%   0%   0%   0%   0%   0%   0%   0%   0%   0.0%
2024    0%   0%   0%   0%   0%   0%   0%   0%   0%   0%   0%   0%   0.0%
2025    5%   5%   4%   4%   4%  32%  34%  32%  32%  32%  33%  33%  20.8%
2026   24%  23%  22%  22%  22%  64%  70%   --   --   --   --   --  35.3%
```

### Gaps Nao Preenchidos (59 meses vazios)

| Ano | Meses Vazios |
|-----|-------------|
| 2020 | 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12 |
| 2021 | 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12 |
| 2022 | 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12 |
| 2023 | 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12 |
| 2024 | 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12 |

Causa raiz: CEAGESP e HF Brasil nao fornecem consulta historica. A unica
fonte com dados retroativos reais e a Agrolink CEASA (521 cotacoes de 27 UFs),
que cobre ~21 produtos por mes (4.0% de cobertura).

### Produtos Mapeados

Total: 524 produtos com status `MAPEADA`.

Distribuicao por classificacao:
- (sem classificacao): 512 produtos
- INSUMO_AGRICOLA: 12 produtos

### Conclusao

A melhoria real nao foi numerica (apenas +2 meses preenchidos), mas sim
**arquitetural**:

1. Pipeline automatizado de backfill com checkpoint e paralelismo
2. Playwright com stealth/fingerprint para todas as fontes
3. Descoberta de que CEPEA e CEAGESP nao sao viaveis para historico
4. SmartRouter agora executa Camada 0 (busca historica) antes de fallback

Para preencher os 59 meses restantes, seria necessario:
- Integrar uma fonte externa com dados historicos reais (ex: CONAB series
  temporais, IBGE, ou API de CEASA especifica por UF)
- Ou aceitar que a cobertura historica e limitada aos ~21 produtos/mes
  da Agrolink CEASA e baixar o threshold de qualidade


### Fase 2: Bulk Ingestion e Deflacao (Execucao em 2026-07-07)

#### Estrategia: Deflacao via IBGE SIDRA (Tabela 7060)

Em vez de depender exclusivamente de scraping de fontes que nao oferecem
consulta historica (CEAGESP, HF Brasil), implementamos um **modelo matematico
de deflacao** usando os indices de variacao mensal do IPCA do IBGE:

- **Fonte**: Tabela 7060 do IBGE SIDRA, classificacao C315 (subitens)
- **API**: `GET /t/7060/n1/all/v/63/p/{periodos}/c315/{subitem_id}`
- **Coluna chave**: `D3C` = codigo do mes (ex: 202001). `V` = valor %.
  Descoberta critica: `D1C` e o codigo territorial (sempre "1" para Brasil),
  nao o mes. O codigo original tentava `D1C`, o que teria retornado zero registros.
- **Estrategia de fallback**: IPCA grupo "Alimentacao no domicilio"
  (codigo 7170) quando o subitem especifico nao tem dados ou retorna "..."
  (suprimido por confidencialidade).
- **Mapeamento**: 23 produtos mapeados para subitens IPCA (ex: Tomate=7212,
  Cebola=7215, Batata=7202). Tabela 7061 foi testada mas NAO possui
  a variavel 63 (IPCA mensal) — essencial usar a Tabela 7060.

#### Pipeline: run_bulk_historical_fill.py

Script Python unificado em `pipeline/run_bulk_historical_fill.py`:

1. **Deflacao (Tabela 7060)**: Para cada (produto, localidade) com preco real
   em 2025/01, retroage mes a mes usando a formula:
   `price_{t-1} = price_t / (1 + var_t/100)`, onde `var_t` e a variacao IPCA
   do mes `t`. Marca como `is_interpolado=TRUE`, `fonte='IBGE_SIDRA_MATH_MODEL'`.

2. **Bulk CONAB**: Download de CSVs estaticos CONAB (endpoints historicos via
   Fabrik Joomla: `/component/fabrik/list/42?format=csv` e ProHortweb REST:
   `http://www3.ceasa.gov.br/prohortweb/rest/relatorio/precoMedioMensal`).
   Coluna `fonte` adicionada a `fact_precos_mensais` via ALTER TABLE.

3. **Recalculo**: `CALL staging.sp_calcular_sazonalidade_preditiva()` ao final.

#### Resultados

```
Metrica                          Pre-Fase2       Pos-Fase2       Melhoria
------------------------------------------------------------------------------
Produtos base processados        21              35              +14 produtos
Linhas geradas (deflacao)        -               2.100           +2.100
Linhas inseridas (deflacao)      -               2.072           +2.072
Meses preenchidos (2020-2024)    1/60            60/60           +59 meses
Conflitos com dados reais        -               28 preservados  sem perda
Erros API SIDRA                  -               0               perfeito
Erros DB                         -               0               perfeito
Tempo de execucao                -               4.4s            rapido
Procedure recalc                 -               sucesso         -
```

#### Matriz de Cobertura Atualizada (2026-07-07)

```
Ano     1    2    3    4    5    6    7    8    9   10   11   12   Media
2020   25I  25I  25I  25I  25I  25I  25I  25I  25I  25I  25I  25I  4.8%I
2021   25I  25I  25I  25I  25I  25I  25I  25I  25I  25I  25I  25I  4.8%I
2022   25I  25I  25I  25I  25I  25I  25I  25I  25I  25I  25I  25I  4.8%I
2023   25I  25I  25I  25I  25I  25I  25I  25I  25I  25I  25I  25I  4.8%I
2024   25I  25I  25I  25I  25I  25I  25I  25I  25I  25I  25I  25I  4.8%I
2025    5%   5%   4%   4%   4%  32%  34%  32%  32%  32%  33%  33% 20.8%
2026   24%  23%  22%  22%  22%  64%  70%   --   --   --   --   -- 35.3%
```

I = Interpolado (IBGE_SIDRA_MATH_MODEL). Total: 25 produtos/mes dos 35
disponiveis em 2025/01 (71.4% dos produtos base conseguiram mapeamento SIDRA).

#### Bloqueio CONAB (Registro para Proxima Fase)

O codigo de mapeamento CONAB foi implementado no script, mas as fontes estao
inoperantes:

| Fonte | URL | Status | Causa |
|-------|-----|--------|-------|
| CONAB Fabrik CSV | `/component/fabrik/list/42?format=csv` | 301 -> HTML | Site migrado de Joomla para gov.br |
| ProHortweb REST | `www3.ceasa.gov.br/.../precoMedioMensal` | 404 | API descontinuada |
| dados.gov.br CKAN | `dados.gov.br/api/3/action/package_search` | 401 | Requer API key |

Alternativas para investigacao:
- Portal de dados abertos da CONAB com nova URL (gov.br/conab/dadosabertos)
- Series temporais do IPEADATA (ipeadata.gov.br)
- CEASAs estaduais com APIs proprias (CEASA Campinas, CEAGESP)
- IBGE PEVS (Producao Agricola Municipal) — dados anuais

#### Estado Final do Banco

Apos a execucao, o banco `quero_comprar` em `localhost:5432` possui:

- **3 camadas de dados**: Scraping tempo real (2025+), Deflacao (2020-2024),
  Bulk CONAB (quando disponivel)
- **Coluna `fonte`** em `fact_precos_mensais`:
  - `'IBGE_SIDRA_MATH_MODEL'` = precos gerados por deflacao
  - `'SCRAPER'` = dados de scraping em tempo real (default de coluna)
  - `'CONAB_BULK_CSV'` = dados de bulk CONAB (reservado)
- **UPSERT condicional**: `ON CONFLICT ... WHERE is_interpolado = TRUE`
  para nunca sobrescrever dados reais com interpolados
- **Procedure recalculada**: `staging.sp_calcular_sazonalidade_preditiva()`
  executada apos cada carga

#### Produtos com Mapeamento SIDRA

Os 23 produtos mapeados para a Tabela 7060 do IBGE:

| Produto | SIDRA ID | Nome IPCA | Grupo |
|---------|----------|-----------|-------|
| ABACATE | 7277 | 1103026.Abacate | hortalicas |
| ABACAXI | 7256 | 1106003.Abacaxi | frutas |
| ALFACE | 7242 | 1105001.Alface | hortalicas |
| BANANA | 7260 | 1106008.Banana - prata | frutas |
| BATATA | 7202 | 1103003.Batata-inglesa | hortalicas |
| BATATA-DOCE | 7201 | 1103002.Batata-doce | hortalicas |
| BETERRABA | 7250 | 1105015.Beterraba | hortalicas |
| CEBOLA | 7215 | 1103043.Cebola | hortalicas |
| CENOURA | 7216 | 1103044.Cenoura | hortalicas |
| GOIABA | 7281 | 1106084.Goiaba | frutas |
| LARANJA | 7279 | 1106039.Laranja - pera | frutas |
| LIMAO | 7265 | 1106015.Limao | frutas |
| MACA | 7266 | 1106017.Maca | frutas |
| MAMAO | 7267 | 1106018.Mamao | frutas |
| MANGA | 7268 | 1106019.Manga | frutas |
| MARACUJA | 7269 | 1106020.Maracuja | frutas |
| MELANCIA | 7270 | 1106021.Melancia | frutas |
| MORANGO | 7280 | 1106051.Morango | frutas |
| PEPINO | 7251 | 1105016.Pepino | hortalicas |
| PIMENTAO | 7213 | 1103026.Pimentao | hortalicas |
| REPOLHO | 7248 | 1105010.Repolho | hortalicas |
| TOMATE | 7212 | 1103028.Tomate | hortalicas |
| UVA | 7276 | 1106028.Uva | frutas |

---

## Diagnóstico: Gap 2024 (Consolidado de diagnostico_scraper_2024.md)

### Duas Arquiteturas Desconectadas

```
Pipeline A (main_runner -> AutonomousOrchestrator -> micro_engines):
  - CeagespEngine      [httpx, SP apenas]
  - ConabApiEngine     [httpx, CSV 30MB, API CONAB declarada morta]

Pipeline B (dispatcher -> SmartCrawler2026 -> adapters):
  - SantoGraalAdapter   [Playwright → CEAGESP + CEPEA]
  - AgenticHtmlAdapter  [httpx → CEASA-PR, CEASA-MG, CEASA-ES, ...]
  - OrganismAdapter     [Playwright → agrolink, calculadorarural]
  - GoogleDriveAdapter  [httpx → CEASA-RS Google Drive]
```

**Pipeline B tem Playwright e cobre 10+ CEASAs, mas NUNCA é chamado pelo ETL principal.**

### Causa Raiz do Gap 2024

| Problema | Impacto |
|----------|---------|
| `_resolver_motor()` registra apenas 2 engines | 0 fontes cobertas p/ 2024 |
| `DiscoveryEngine._executar_busca()` é stub | Passo 3 sempre retorna vazio |
| `SantoGraalAdapter` usa Playwright (select_option, fill, click) | Existe mas nunca é invocado |
| Nenhum adapter de CEASA registrado no orquestrador | PR, MG, ES, PE, RN, MS sem cobertura |
| 2024 em fact_precos_mensais = 420 linhas, 100% interpoladas | Zero dados reais de 2024 |

### Cobertura por Fonte (Snapshot)

| Fonte | Engine | Playwright? | Status |
|-------|--------|-------------|--------|
| CEAGESP (SP) | CeagespEngine | httpx | Funciona parcial |
| CONAB Pentaho | ConabApiEngine | httpx | API morta |
| CEASA-PR/MG/ES/PE/RN/MS | AgenticHtmlAdapter | httpx | Não conectado |
| CEASA-RS | GoogleDriveAdapter | httpx | Não conectado |
| CEPEA | SantoGraalAdapter | Playwright | Não conectado |
| Agrolink | OrganismAdapter | Playwright | Não conectado |

---

## Proposta: Scraper Target-List Driven (Consolidado de proposta_scraper_target_list.md)

**Problema:** Cobertura média de 25.5% em 2024-2025. 2024 = 0% real.

**Arquitetura:**
1. SmartRouter lê `logs/gaps_2024_2025.json` na inicialização
2. DiscoveryEngine prioriza gaps (produtos faltantes por UF/mês)
3. Micro-motor com fallback exponencial (5s → 10s → 20s)
4. Ciclo fechado: batch → recalc sazonalidade → re-audita → re-alimenta gaps

**Resultado:** Self-healing (gaps → scrapers → dados → baseline corrigido), zero desperdício (só rodam onde há lacunas), KPI rastreável.

---

## Dados de Validação CONAB (Snapshot: 2026-07-13)

- Total registros em fact_precos_mensais: **42.627**
  - is_interpolado=False: **40.555 (95.1%)**
  - is_interpolado=True: **2.072 (4.9%)**
- 28.426 registros novos da CONAB, preço médio R$ 10.00
- Cobertura por UF: SP (1.931), PR (1.692), RS (1.643), MG (1.531), SC (1.450)
- UFs com menos dados: PI, RO, AM, SE, AC, RR, AP (~7 meses cada)
- Produto mais caro: OLEO DE PEQUI (R$ 116.65/kg)
- Produto mais barato: LARANJA DE MESA LIMA (R$ 0.18/kg)
- Nenhum preço negativo ou zerado passou pelo filtro
- 0 divergências graves (>50%) entre preço real e média
