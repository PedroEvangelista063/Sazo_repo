# QUERO COMPRAR

App B2C que indica a melhor época para comprar produtos agrícolas usando dados históricos da CONAB.
Uma ferramenta desenhada para ajudar o consumidor a economizar na feira e no supermercado.

## Stack

| Camada | Tecnologia |
|---|---|
| Pipeline ETL | Python 3.11+, Polars, httpx, psycopg2 |
| Backend | FastAPI + asyncpg (Raw SQL) |
| Cache | In-memory thread-safe com TTL (24h) |
| Database | PostgreSQL 16+ (Arquitetura Medalhão) |
| Frontend | React 18 + Vite + PWA (Service Worker) |
| Estilização | Tailwind CSS 3.4 (utility-first) |
| Estado | Zustand com persist (localStorage) |
| API Data Fetching | TanStack Query v5 (stale-while-revalidate) |
| Autocura | Ghost DBA Agent (LLM-driven SQL repair) |

## 📱 Experiência do Usuário (Como Funciona)

O **QUERO COMPRAR** foi projetado para a dona de casa e o comprador de feira que querem economizar. A jornada é simples e intuitiva:

### 1. 📍 Onde você está?
Ao abrir o app (web ou PWA instalado), o usuário seleciona seu **Estado (UF)** e **Município**. A partir daí, toda a análise é personalizada para a realidade local — porque a sazonalidade muda de região para região.

### 2. 🛒 Monte sua lista
Na tela principal, o usuário escolhe os produtos que deseja consultar. Pode selecionar **vários itens ao mesmo tempo** com o botão **+ Adicionar**. O filtro é inteligente e focado nas categorias de varejo: hortifrutigranjeiros, pescados, flores e muito mais.

### 3. 📅 Escolha o mês
Com a lista pronta, o usuário define **qual mês** quer analisar — seja para planejar as compras da próxima semana ou para decidir quando estocar a despensa. O seletor de mês é rápido e responsivo.

### 4. 🚦 Resultado na hora
A tela reage instantaneamente: cada produto ganha um **semáforo de sazonalidade** que compara o preço do mês escolhido com a média histórica:

- 🟢 **Barato** — Muita Oferta / Safra — melhor época para comprar
- 🟡 **Equilibrado** — Preço normal
- 🔴 **Caro** — Baixa Oferta / Entressafra — evite ou compre pouco

### Offline? Sem problemas.
Por ser um **PWA (Progressive Web App)**, depois do primeiro acesso o aplicativo funciona mesmo sem internet. Os dados ficam em cache local (TanStack Query + Service Worker) e o usuário pode consultar a sazonalidade a qualquer momento, em qualquer lugar — na fila do banco, no ônibus ou na feira.

## Estrutura do Projeto

```
quero_comprar_vg/
├── pipeline/               # ETL: ingestão CONAB → IS → PostgreSQL / arquivos
│   ├── ingestao_conab.py   # Pipeline principal: extract → transform → load
│   ├── seasonality.py      # Cálculo do IS (baseline 2025 + fallback 12m)
│   ├── process_to_files.py # ETL offline: LISTA*.txt → JSON/Parquet/SQL
│   ├── ghost_dba_agent.py  # Agente de autocura com LLM
│   ├── audit_local_db.py   # Auditoria: TXT locais vs banco
│   ├── ingest.py           # Módulo auxiliar de download com httpx
│   └── tests/              # Testes unitários (validação, sazonalidade)
├── backend/                # FastAPI B2C
│   └── app/
│       ├── api/v1/
│       │   └── endpoints/
│       │       ├── produtos.py     # GET /api/v1/sazonalidade
│       │       ├── municipios.py   # GET /api/v1/municipios?uf=SP
│       │       └── internal.py     # GET/POST /api/v1/_internal/cache-clear
│       ├── core/           # config, cache, ratelimit
│       ├── db/             # conexão asyncpg (pool 10-50)
│       └── schemas/        # Pydantic V2 responses
├── frontend/               # PWA React + Vite Mobile-First
│   ├── src/
│   │   ├── store/          # Zustand: useUserStore (UF/Cidade)
│   │   ├── services/       # Axios + hooks TanStack Query
│   │   ├── components/     # ProductCard, LocationSelector
│   │   ├── pages/          # Dashboard
│   │   └── types.ts        # ProductSeasonality, UF_LIST, emojis
│   ├── vite.config.ts      # PWA plugin + proxy dev
│   └── tailwind.config.js  # Cores sazonais (verde/amarelo/vermelho)
├── database/               # DDLs + migrations + artefatos estáticos
│   └── processed_data/     # Output do ETL offline (auditoria, relatórios)
├── docs/                   # Documentação
└── .env.example            # Template de variáveis de ambiente
```

## Configuração Inicial

```bash
# 1. Ambiente Python (Pipeline & Backend)
python -m venv .venv
source .venv/bin/activate  # Linux/Mac
pip install -r pipeline/requirements.txt
pip install -r backend/requirements.txt

# 2. Ambiente Frontend
cd frontend && npm install

# 3. Variáveis de ambiente
cp .env.example .env
# Edite .env com DATABASE_URL

# 4. Rodar (dois terminais)
uvicorn backend.app.main:app --reload --port 8000   # Backend
cd frontend && npm run dev                           # Frontend :5173
```

## Endpoints da API

| Método | Rota | Descrição |
|---|---|---|
| `GET` | `/api/v1/sazonalidade?uf=SP&municipio=...` | Lista produtos com filtros |
| `GET` | `/api/v1/sazonalidade/{uf}/{municipio}` | Atalho por localidade |
| `GET` | `/api/v1/municipios?uf=SP` | Lista municípios disponíveis |
| `GET` | `/api/v1/_internal/cache-clear` | Limpa cache (uso interno) |
| `GET` | `/health` | Health check |

## O Semáforo de Sazonalidade (Visão B2C)

O aplicativo **nunca exibe preços em R$** — apenas cores indicativas:

| Status | UX | Lógica (IS) |
|---|---|---|
| 🟢 **VERDE** | Melhor Época! | Preço < Média Anual (-15%) |
| 🟡 **AMARELO** | Preço Normal | Estabilizado na Média (±15%) |
| 🔴 **VERMELHO** | Péssima Época (Evite) | Preço > Média Anual (+15%) |
| ⚪ **INSUFICIENTE** | Sem Dados | Histórico < 6 meses |

## Pipeline ETL Offline (Sem Banco de Dados)

O script `pipeline/process_to_files.py` executa o mesmo pipeline de transformação do `ingestao_conab.py`, mas salva os resultados em **arquivos estáticos** — sem depender de PostgreSQL.

Ideal para:
- **Validação local** antes de subir para o banco
- **Auditoria** comparando saída do ETL vs banco de produção
- **CI/CD** que não tem acesso ao banco de dados
- **Geração de relatórios** estáticos (JSON navegável, Parquet para análise)

### Como rodar

```bash
python -m pipeline.process_to_files
```

Saída em `database/processed_data/`:

| Estágio | Descrição |
|---|---|
| `01_raw/` | Dados brutos por arquivo LISTA |
| `02_cleaned/` | Dados limpos (encoding, tipos, outliers) |
| `03_categorized/` | Classificados em ALIMENTO_VAREJO / B2B |
| `04_b2c_only/` | Apenas ALIMENTO_VAREJO (o que vai pro app) |
| `05_aggregated/` | Agregado mensal por produto+UF |
| `06_seasonality/` | Sazonalidade (semáforo 🟢🟡🔴) |
| `sql/` | Scripts INSERT prontos para PostgreSQL |
| `consolidated.parquet` | Todos os dados B2C em Parquet |
| `summary.json` | Resumo consolidado em JSON |
| `ETL_REPORT.md` | Relatório legível com estatísticas |

### Variação de formato CONAB

Os arquivos `LISTA*.txt` têm schemas inconsistentes: 9 ou 11 colunas, com ou sem cabeçalho. O motor detecta automaticamente os 4 casos via `_ler_csv()` — nenhuma configuração manual é necessária.

## PWA (Offline-First)

- Service Worker com `StaleWhileRevalidate` para dados da API
- Cache via TanStack Query + persistência local
- Ícone instalável no celular (Add to Home Screen)
- Funciona em conexões 3G