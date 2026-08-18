# Sazo Brasil (Documentação Legada)

> ⚠️ **Este documento está desatualizado.** Consulte o [README.md](../README.md) na raiz do projeto para a versão mais recente.  
> Mantido apenas para referência histórica.

**Sua bússola de sazonalidade para a feira.**  
App B2C que revela a melhor época para comprar hortigranjeiros usando dados CONAB (2024-2026) e cotações CEASA. Economia real na feira e no supermercado — sem achismo, com dados.

---

## 🧠 A Ideia

Preço de alimento no Brasil não é loteria — é safra e entressafra. O **Sazo Brasil** traduz dados públicos CONAB (janela 2024-2026) em um semáforo visual que qualquer consumidor entende:

🟢 **Barato** (safra) → 🟡 **Normal** → 🔴 **Caro** (entressafra)

Zero reais na tela. Apenas a cor que o bolso precisa.

---

## 🏗️ Micro-Monorepo: Quatro Serviços, Um Propósito

```
sazo_brasil/
├── pipeline/     🚗 Garagem  — ETL Worker (Polars, Python 3.11+)
├── database/     🗄️ Despensa — PostgreSQL 17 (Supabase) (Medalhão raw→staging→mart)
├── backend/      🍳 Cozinha  — FastAPI + asyncpg (raw SQL, cache 24h)
├── frontend/     🛋️ Sala de Estar — PWA React 19 + Vite 6
└── docs/         📐 Plantas da Casa
```

Cada serviço vive no seu próprio ecossistema, respira PostgreSQL, e conversa via banco.

---

## 🚗 Garagem — Pipeline de Ingestão

Motor ETL que transforma _*LISTA*.txt_* da CONAB + cotações CEASA em dados prontos para consumo.

| Motor                    | O que faz                                                                                                                |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| `scraper/`               | Ecossistema de scrapers CONAB + CEASA: micro-motores, AutonomousOrchestrator, CircuitBreaker, adaptadores, fuzzy matcher |
| `scraper/main_runner.py` | Entry point Run and Die — executa ciclo completo de coleta                                                               |
| `scraper/persistence.py` | Ciclo medalhão via `executar_ciclo_medalhao` (SortingEngine + `sp_executar_carga_completa`)                              |
| `processor/`             | Esteira de triagem pós-coleta (SortingEngine, classificação)                                                             |
| `ingestao_conab.py`      | Pipeline medalhão CONAB: extract → transform → load                                                                      |
| `seasonality.py`         | Cálculo do IS (Índice de Sazonalidade) baseline + fallback                                                               |
| `ghost_dba_agent.py`     | Agente de autocura com LLM (polling 300s, self-heal, notificação)                                                        |
| `db_maintenance.py`      | "Gari" do banco: upsert scraper raw → staging + GC                                                                       |

**Regras de Ouro:**

- 🚫 **Nunca pandas** — Polars ou nada.
- 🚫 **Nunca INSERT linha por linha** — COPY ou `execute_values`.
- 🧠 Classificação por regex: `ALIMENTO_VAREJO` (vai pro app) vs `MAQUINARIO_FERRAMENTA`, `INSUMO_AGRICOLA`, etc. (fica fora).
- 🔄 Arquivos CONAB têm 4 variações de schema — `_ler_csv()` detecta automaticamente.

---

## 🗄️ Despensa — PostgreSQL 17 (Arquitetura Medalhão)

Camadas claras, responsabilidades separadas:

| Schema    | Função                                                                        |
| --------- | ----------------------------------------------------------------------------- |
| `raw`     | Dados como chegam — append-only, COPY direto                                  |
| `staging` | Dimensões + fato limpos. Anomalias >500% vão para `staging.precos_rejeitados` |
| `mart`    | Sazonalidade materializada para API (`vw_api_produtos_sazonalidade`)          |
| `ops`     | Observabilidade — monitorado pelo Ghost DBA                                   |

**Sazonalidade — Forecast v2 Ponderado (100% SQL):**

- Duas baselines permanentes: `sazonalidade_baseline_25_26` (primária, moda 2025-2026) e `sazonalidade_baseline_24_25` (fallback, moda 2024-2025)
- `baseline_ponderado`: FULL JOIN com CASE weighting — primary vence quando confiança ≥ 30, fallback × 0.5 usado como fallback
- SP principal: `sp_calcular_forecast_2026()` — ~1s para 19.933 projeções
- MV `vw_api_produtos_sazonalidade` (V14) com `is_forecast`, `baseline_confianca`, `forecast_method`

**Migrations:** 15 formais em `supabase/migrations/` (000001→000015), reconciliadas com Supabase remoto.

---

## 🍳 Cozinha — FastAPI (Backend B2C)

API RESTful enxuta que só serve o que o app precisa — nada mais.

| Rota                                             | Função                                                                           |
| ------------------------------------------------ | -------------------------------------------------------------------------------- |
| `GET /api/v1/sazonalidade`                       | Sazonalidade filtrada por UF, município, mês, produto, status_cor (+ `?regiao=`) |
| `GET /api/v1/sazonalidade/{uf}/{municipio}`      | Atalho por localidade                                                            |
| `GET /api/v1/sazonalidade/historico/{ano}/{mes}` | Série temporal                                                                   |
| `GET /api/v1/regioes`                            | Lista 5 regiões com UFs e polos CEASA                                            |
| `GET /api/v1/categorias`                         | Categorias de varejo                                                             |
| `GET /api/v1/ufs`                                | UFs disponíveis                                                                  |
| `GET /api/v1/municipios?uf=SP`                   | Municípios disponíveis                                                           |
| `GET /api/v1/admin/coletar-global`               | Coleta para todas as UFs                                                         |
| `GET /api/v1/stream/updates`                     | SSE para notificações em tempo real                                              |
| `GET /health`                                    | Health check                                                                     |

**Estratégia de Cache em Duas Camadas:**

- **Cache geral**: TTL 24h para requisições exatas
- **Cache imutável histórico** (`_HIST_CACHE_TTL = 86_400`): chave por dimensões `(ano, mês, UF, município, categoria)`. A computação mensal via `_compute_periodo_full()` (4 CTEs) roda uma vez. Filtros de produto/status_cor/paginação são servidos de memória via `_slice_periodo()`.

**Stack:** FastAPI + asyncpg + Pydantic V2 + rate limit 60 req/min + CORS.

---

## 🛋️ Sala de Estar — PWA React Mobile-First

Um app que funciona **na feira, no ônibus, no sinal 3G**.

### Experiência do Usuário Passo a Passo

```
👤 Entra → [SP ▼] [2026 ▼] → 🗓️ Clica num mês → 🛒 Filtra produtos → 🚦 Grid colorido
```

**1. Header Fixo**

```
┌──────────────────────────────────────────────┐
│ [📈] Sazonalidade                     [🌙] [📂] │
│      Preços de Alimentos — CONAB · SP         │
└──────────────────────────────────────────────┘
```

- Logo + título + subtítulo com UF
- 🌙/☀️ — alterna dark/light (hook `useTheme` com classe dark no `<html>` Tailwind)
- 📂 Categorias — texto em desktop, só ícone em mobile

**2. Seletor de Período**

```
[SP ▼] [2026 ▼]                              [42 itens]
┌────┬────┬────┬────┬────┬────┐ ← 4 colunas mobile, 12 desktop
│ 01 │ 02 │ 03 │ 04 │ 05 │ 06 │
│ Jan│ Fev│ Mar│ Abr│ Mai│ Jun│
├────┼────┼────┼────┼────┼────┤
│ 07 │ 08 │ 09 │ 10 │ 11 │ 12 │
│ Jul│ Ago│ Set│ Out│ Nov│ Dez│
└────┴────┴────┴────┴────┴────┘
```

- **Select UF** + **Select Ano** (shadcn/ui Select + Radix) — resetam mês e status ao trocar
- Grid de **12 botões** com `minHeight: 44px` (touch target): verde = com dados, cinza = sem, preenchido = selecionado
- Clique no mesmo mês **destoggle** → volta visão completa
- **Badge** verde (shadcn/ui badge) com contagem de itens visíveis

**3. Filtro por Produto**

```
[Abacate Avocado] [Abacate Breda] [Banana] [Batata] [+]
```

- Multi-select chips — toque alterna seleção
- Filtro AND com o mês selecionado

**4. Filtro por Status**

```
[Melhor Época] [Preço Normal] [Péssima Época] [✕]
```

- Apenas 1 ativo por vez. ✕ aparece para limpar

**5. Grid de Produtos** (Tailwind grid + shadcn/ui Card)

```
┌──────────┐  ┌──────────┐  ┌──────────┐
│    🥑    │  │    🍌    │  │    🥔    │
│Abacate   │  │Banana    │  │Batata    │
│Avocado   │  │Prata     │  │           │
│ ✅ Melhor│  │ ⚠ Normal │  │ ❌ Péssim│
└──────────┘  └──────────┘  └──────────┘
```

- 2 colunas mobile, 3 tablet, 4 desktop
- Ordenação: VERDE → AMARELO → VERMELHO
- Cada shadcn/ui Card: emoji 28px + nome + ícone status + borda colorida por status + nota de rodapé
- SpotlightCard com animação Framer Motion no hover

**6. Modal de Categorias** (shadcn/ui Dialog + Radix)

```
Nível 1:          Nível 2:
┌──────────────┐  ┌──────────────┐
│ 🥩 CARNES 12 │  │ ← Categorias │
│ 🥬 HORTALI  8│  │              │
│ 🍇 FRUTAS  22│  │ [🍇Uva][🍊Laranja] │
│ ...          │  │ [🍌Banana]   │
└──────────────┘  └──────────────┘
```

- Drill-down: categoria → produtos (chips clicáveis)
- Scroll nativo, sem travamento

### Stack Frontend

| Tecnologia                    | Versão | Pra quê                                          |
| ----------------------------- | ------ | ------------------------------------------------ |
| React                         | 19     | Core UI                                          |
| Vite                          | 6      | Bundler + PWA plugin                             |
| shadcn/ui                     | —      | Radix primitives + CVA + tailwind-merge `cn()`   |
| TailwindCSS                   | 3.4    | Utility classes + dark mode via `class`          |
| TanStack Query                | 5      | Cache offline-first, stale-while-revalidate      |
| Zustand                       | 5      | Estado persistente do usuário                    |
| Framer Motion                 | 12     | Animações (AnimatePresence, motion components)   |
| Lucide React                  | —      | Ícones (TrendingUp, Layers, Sun, Moon, X, Salad) |
| Three.js / @react-three/fiber | —      | Visualizações 3D (Beams, BrasilMap)              |
| Recharts                      | —      | Gráficos                                         |
| Axios                         | —      | HTTP client                                      |

### Regras de Ouro do Frontend

- 🚫 **Nunca exibe R$** — só o semáforo. Zero preços na tela.
- 🚫 **Sem imagens** — emoji unicode exclusivamente.
- ⚡ Skeletons (shadcn/ui skeleton) no lugar de spinners.
- 📱 Mobile-first 100%. Touch targets ≥ 44×44px.
- 🌗 Dark mode via hook `useTheme` + classe `.dark` no `<html>` (Tailwind).
- 🧩 `manualChunks` no Vite: vendor-react, vendor-ui, vendor-icons, vendor-store, vendor-http.

**Offline:** Service Worker com CacheFirst para assets (30d), StaleWhileRevalidate para API de sazonalidade (7d), CacheFirst para municípios (24h). IndexedDB como cache persistente.

### Conexão em Tempo Real (SSE)

- `useDataStream()` conecta ao `/api/v1/stream/updates`
- Evento `ETL_FINISHED` invalida queries TanStack automaticamente
- Reconexão exponencial: 1s → 2s → 4s → ... → 30s max

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

| Camada   | Plataforma                   | Região    |
| -------- | ---------------------------- | --------- |
| Banco    | Supabase (PostgreSQL 17)     | us-east-1 |
| API      | Render (Web Service, Python) | Ohio      |
| Frontend | Vercel (SPA, PWA)            | Edge      |

Ambiente: Python 3.13+, PostgreSQL 17 via Supabase, Node 22.22.1+.

---

## 💻 Setup Local

```bash
# 1. Ambiente Python
python3 -m venv .venv
source .venv/bin/activate  # Linux/Mac
pip install -r backend/requirements.txt

# 2. Frontend
npm install && npm --prefix frontend install

# 3. .env
cp .env.example .env
# Configure backend/.env com as credenciais do Supabase

# 4. Rodar
npm run dev:backend   # FastAPI :8000
npm run dev:frontend  # Vite :5173
# ou:
npm run dev:all       # FastAPI + Vite
```

> **Nota:** O scraper é executado sob demanda via `npm run scrape:manual` em terminal separado. Em desenvolvimento, `npm run dev:all` levanta apenas backend + frontend.

### Pastas com Dependências npm (node_modules)

As seguintes pastas contêm dependências npm que **não são commitadas** (estão no `.gitignore`). Cada nova máquina deve instalar localmente:

| Pasta       | Comando       | O que instala                                                                         |
| ----------- | ------------- | ------------------------------------------------------------------------------------- |
| `./` (raiz) | `npm install` | Scripts de conveniência (`dev:all`, `dev:backend`, etc.)                              |
| `frontend/` | `npm install` | React, shadcn/ui, Vite, TanStack Query, Zustand, TailwindCSS, Framer Motion, Three.js |

**Ordem de instalação:**

```bash
# 1. Dependências da raiz (scripts de conveniência)
npm install

# 2. Dependências do frontend (React + Vite)
cd frontend && npm install
# ou
npm --prefix frontend install
```

> **⚠️ Importante:** Sempre rode `npm install` em **ambas as pastas**. A pasta `node_modules` não é versionada — cada máquina deve baixar suas próprias dependências.

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
npm run scrape:manual          # Coleta CEASA sob demanda (terminal separado)
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
