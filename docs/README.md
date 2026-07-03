# QUERO COMPRAR

**Sua bússola de sazonalidade para a feira.**  
App B2C que revela a melhor época para comprar hortigranjeiros usando dados históricos da CONAB e cotações CEASA. Economia real na feira e no supermercado — sem achismo, com dados.

---

## 🧠 A Ideia

Preço de alimento no Brasil não é loteria — é safra e entressafra. O **QUERO COMPRAR** traduz 10+ anos de dados públicos CONAB em um semáforo visual que qualquer consumidor entende:

🟢 **Barato** (safra) → 🟡 **Normal** → 🔴 **Caro** (entressafra)

Zero reais na tela. Apenas a cor que o bolso precisa.

---

## 🏗️ Micro-Monorepo: Quatro Serviços, Um Propósito

```
quero_comprar_vg/
├── pipeline/     🚗 Garagem  — ETL Worker (Polars, Python 3.11+)
├── database/     🗄️ Despensa — PostgreSQL 16+ (Medalhão raw→staging→mart)
├── backend/      🍳 Cozinha  — FastAPI + asyncpg (raw SQL, cache 24h)
├── frontend/     🛋️ Sala de Estar — PWA React 18.3 + Vite 6
└── docs/         📐 Plantas da Casa
```

Cada serviço vive no seu próprio ecossistema, respira PostgreSQL, e conversa via banco.

---

## 🚗 Garagem — Pipeline de Ingestão

Motor ETL que transforma **LISTA*.txt** da CONAB + cotações CEASA em dados prontos para consumo.

| Motor | O que faz |
|---|---|
| `ingestao_conab.py` | Pipeline medalhão: extract → transform → load |
| `ingestao_conab_inteligente.py` | Leitura lazy Polars paralela + engine semântico regex |
| `seasonality.py` | Cálculo do IS (Índice de Sazonalidade) baseline 2025 + fallback 12m |
| `process_to_files.py` | ETL offline — salva em JSON/Parquet/SQL, sem PostgreSQL |
| `ghost_dba_agent.py` | Agente de autocura com LLM (polling 300s, self-heal, notificação) |
| `db_maintenance.py` | "Gari" do banco: upsert scraper raw → staging + GC 30 dias |
| `audit_local_db.py` | Auditoria de integridade: TXT locais × banco |
| `run_scraper_historico.py` | Runner de coleta CEASA multi-UF (asyncio, 4 em paralelo) |
| `scraper/` | Ecossistema de scrapers: engine, spider, adaptadores (HFBrasil, CEAGESP, Agrolink), fuzzy matcher, buscador de fontes |

**Regras de Ouro:**
- 🚫 **Nunca pandas** — Polars ou nada.
- 🚫 **Nunca INSERT linha por linha** — COPY ou `execute_values`.
- 🧠 Classificação por regex: `ALIMENTO_VAREJO` (vai pro app) vs `MAQUINARIO_FERRAMENTA`, `INSUMO_AGRICOLA`, etc. (fica fora).
- 🔄 Arquivos CONAB têm 4 variações de schema — `_ler_csv()` detecta automaticamente.

---

## 🗄️ Despensa — PostgreSQL 16+ (Arquitetura Medalhão)

Camadas claras, responsabilidades separadas:

| Schema | Função |
|---|---|
| `raw` | Dados como chegam — append-only, COPY direto |
| `staging` | Dimensões + fato limpos. Anomalias >500% vão para `staging.precos_rejeitados` |
| `mart` | Sazonalidade materializada para API (`vw_api_produtos_sazonalidade`) |
| `ops` | Observabilidade — monitorado pelo Ghost DBA |

**Sazonalidade — Baseline Híbrido 2025 + Fallback 12m:**
- Baseline primário: média do produto em **2025** (ano âncora absoluto)
- Fallback condicional: para produtos NOVOS (sem dados em 2025), média dos últimos 12 meses
- Semáforo: compara `preco_atual` contra `preco_referencia` (±15%)
- `usou_fallback_12m: true` → frontend exibe "*Comparado aos últimos 12 meses"
- SP principal: `sp_calcular_sazonalidade_baseline()` — 4 CTEs set-based
- MV `vw_api_produtos_sazonalidade` com UNIQUE INDEX para CONCURRENTLY

**Migrations:** 17 scripts versionados (01→17), do DDL medalhão ao `MOM seasonality`.

---

## 🍳 Cozinha — FastAPI (Backend B2C)

API RESTful enxuta que só serve o que o app precisa — nada mais.

| Rota | Função |
|---|---|
| `GET /api/v1/sazonalidade` | Sazonalidade filtrada por UF, município, mês, produto, status_cor |
| `GET /api/v1/sazonalidade/{uf}/{municipio}` | Atalho por localidade |
| `GET /api/v1/municipios?uf=SP` | Municípios disponíveis |
| `GET /api/v1/categorias` | Categorias de varejo |
| `GET /api/v1/_internal/cache-clear` | Limpa cache (API Key) |
| `GET /health` | Health check |

**Estratégia de Cache em Duas Camadas:**
- **Cache geral**: TTL 24h para requisições exatas
- **Cache imutável histórico** (`_HIST_CACHE_TTL = 86_400`): chave por dimensões `(ano, mês, UF, município, categoria)`. A computação mensal via `_compute_periodo_full()` (4 CTEs) roda uma vez. Filtros de produto/status_cor/paginação são servidos de memória via `_slice_periodo()`.

**Stack:** FastAPI + asyncpg + Pydantic V2 + rate limit 60 req/min + CORS.

---

## 🛋️ Sala de Estar — PWA React Mobile-First

Um app que funciona **na feira, no ônibus, no sinal 3G**.

### Jornada do Usuário em 4 Etapas

```
📍 Onde você está?  →  🛒 Monte sua lista  →  📅 Escolha o mês  →  🚦 Resultado na hora
```

1. **📍 Localização** — O usuário seleciona UF e município. A partir daí, tudo é regionalizado.
2. **🛒 Lista** — Seção colapsável com multi-select de produtos. Filtro inteligente focado em hortifrutigranjeiros.
3. **📅 Mês** — Chips de mês extraídos da API. Cada clique dispara computação dinâmica de sazonalidade.
4. **🚦 Resultado** — Grid de cartões com emoji + semáforo. Ordenação: 🟢 → 🟡 → 🔴.

### Stack Frontend

| Tecnologia | Pra quê |
|---|---|
| React 18.3 + Vite 6 | Core |
| TailwindCSS 3.4 | Utility-first, cores sazonais |
| Zustand 5 + idb-keyval | Estado persistente do usuário (UF/Cidade) |
| TanStack Query v5 | Cache offline-first, stale-while-revalidate |
| Service Worker (Workbox) | PWA, cache de API, assets, fontes |
| Axios | HTTP client |

### Regras de Ouro do Frontend

- 🚫 **Nunca exibe R$** — só o semáforo. Zero preços na tela.
- 🚫 **Sem imagens** — emoji unicode exclusivamente.
- ⚡ Skeletons no lugar de spinners.
- 📱 Mobile-first 100%.
- 🧩 `manualChunks` no Vite: vendor-react, vendor-icons, vendor-store, vendor-http.

**Offline:** Service Worker com CacheFirst para assets (30d), StaleWhileRevalidate para API de sazonalidade (7d), CacheFirst para municípios (24h). IndexedDB como cache persistente.

---

## 📦 Cache Imutável Histórico (Performance B2C)

O backend NUNCA consulta o banco duas vezes para a mesma combinação `(ano, mês, UF, município, categoria)` — não importa quantos usuários filtrem produtos diferentes.

```
Requisição → cache hit? → serve de memória (_slice_periodo)
           → cache miss? → _compute_periodo_full() → 4 CTEs no banco → cacheia → serve
```

---

## 🔍 Ghost DBA — Autocura com LLM

O `ghost_dba_agent.py` é um worker autônomo que:
- Poll o schema `ops` a cada 300s
- Detecta deadlocks, queries lentas, erros DDL
- Tenta correção via LLM (gera e executa SQL)
- Registra tudo em `ops.audit_llm_queries`
- Envia webhook em caso de falha

---

## 🚀 Deploy

| Camada | Plataforma | Região |
|---|---|---|
| Banco | Render (PostgreSQL free) | Ohio |
| API | Render (Web Service, Python) | Ohio |
| Frontend | Vercel (SPA, PWA) | Edge |

Ambiente: Python 3.11, PostgreSQL 16+, Node 20+.

---

## 💻 Setup Local

```bash
# 1. Ambiente Python
python -m venv .venv
.venv\Scripts\activate  # Windows
pip install -r pipeline/requirements.txt
pip install -r backend/requirements.txt

# 2. Frontend
npm install && npm --prefix frontend install

# 3. .env
cp .env.example .env  # configure DATABASE_URL

# 4. Rodar
npm run dev:backend   # FastAPI :8000
npm run dev:frontend  # Vite :5173
# ou:
npm run dev:all       # ambos + scraper
```

---

## 📊 Pipeline Offline (Sem Banco)

```bash
python -m pipeline.process_to_files
```

Gera em `database/processed_data/`:
```
01_raw/ → 02_cleaned/ → 03_categorized/ → 04_b2c_only/ → 05_aggregated/ → 06_seasonality/
                                                                                ↓
                                                                     sql/ + summary.json + ETL_REPORT.md
```

---

## ⚙️ Comandos Úteis

```bash
npm run scraper              # Coleta CEASA (4 concorrentes)
npm run build:frontend       # Build PWA
python backend/get_data_summary.py --verbose  # Health check do banco
python -m pipeline.audit_local_db              # Auditoria TXT × banco
```

---

## 🧪 Auditoria de Integridade

```bash
python -m pipeline.audit_local_db
# Exit 0 = ok, 1 = divergência
```

Compara linhas `ALIMENTO_VAREJO` nos TXT locais contra `staging.fact_precos_mensais` e testa o endpoint `/api/v1/sazonalidade`.

---

## 📐 Taxonomia do Projeto

O micro-monorepo segue a metáfora de uma **casa**:
- **Garagem** (pipeline/) — a máquina que transforma dados brutos em informação
- **Despensa** (database/) — onde os dados são armazenados e organizados
- **Cozinha** (backend/) — onde a API prepara os dados para servir
- **Sala de Estar** (frontend/) — onde o consumidor final aproveita

---

**Feito com dados públicos, amor ao开源, e a certeza de que comida não pode ser cara demais.**
