# Plano Técnico e de Produto — QUERO COMPRAR
> Versão 1.0 | Arquiteto: Staff Engineer | Data: 2026-06-23

---

## Executive Summary

O "QUERO COMPRAR" é um produto com um diferencial competitivo muito claro: **dados públicos de alta qualidade (CONAB) + granularidade municipal + UX ridiculamente simples**. A maioria dos concorrentes mostra preços do dia; nós mostramos se *vale a pena comprar hoje*. Essa virada conceitual — de informação para recomendação — é o que transforma dados agrícolas chatos em um app que a dona Maria usa na fila do caixa.

A arquitetura segue um princípio central: **backend pesado, frontend burro**. Todo o custo computacional (download, parsing, cálculo do índice, classificação do semáforo) acontece no pipeline de dados. A API entrega JSON pré-mastigado. O React apenas pinta a tela. Isso garante sub-500ms de resposta e Lighthouse ≥ 95 mesmo em 4G fraco.

A escolha tecnológica é deliberadamente conservadora e barata. Polars em vez de Spark (overkill absurdo para ~200MB de CSV). PostgreSQL em vez de BigQuery (DW para 50 mil linhas é canhão contra mosquito). FastAPI em vez de Django (performance async + zero boilerplate). Um servidor de €20/mês na Hetzner aguenta o MVP com folga. Escalar depois é mais fácil do que explicar para um investidor por que você gastou R$5.000/mês em infraestrutura antes de ter 100 usuários.

---

## Fase 1 — Engenharia de Dados: Ingestão, Processamento e Modelagem

### 1.1 Fontes de Dados CONAB

Dois arquivos `.txt` delimitados por `;`, atualizados mensalmente:

| Arquivo | URL | Granularidade |
|---|---|---|
| `PrecosMensalUF.txt` | `https://portaldeinformacoes.conab.gov.br/downloads/arquivos/PrecosMensalUF.txt` | Estado (UF) |
| `PrecosMensalMunicipio.txt` | `https://portaldeinformacoes.conab.gov.br/downloads/arquivos/PrecosMensalMunicipio.txt` | Município |

**O arquivo de Município é o ouro.** É ele que permite dizer "em Palmas-TO, a banana está na safra; em Araguaína-TO, não". Esse nível de localização é o diferencial competitivo real.

### 1.2 Estratégia de Ingestão — Sem Over-Engineering

**Escolha: GitHub Actions (cron) + script Python puro.**

Por quê não Airflow/Prefect/Dagster? Porque são plataformas para orquestrar dezenas de pipelines interdependentes. Para dois downloads mensais, é usar bazuca para matar formiga. O custo de manutenção de um servidor Airflow em uma startup é um salário de júnior.

**Alternativa de produção:** AWS EventBridge (cron) → Lambda → S3 → RDS. Custo: ~$2/mês.

**Lógica de download resiliente:**

```python
import httpx
import time
from pathlib import Path

URLS = {
    "uf": "https://portaldeinformacoes.conab.gov.br/downloads/arquivos/PrecosMensalUF.txt",
    "municipio": "https://portaldeinformacoes.conab.gov.br/downloads/arquivos/PrecosMensalMunicipio.txt",
}

def download_with_retry(url: str, dest: Path, retries: int = 3, timeout: int = 120) -> Path:
    for attempt in range(retries):
        try:
            with httpx.stream("GET", url, timeout=timeout, follow_redirects=True) as r:
                r.raise_for_status()
                with open(dest, "wb") as f:
                    for chunk in r.iter_bytes(chunk_size=65536):
                        f.write(chunk)
            return dest
        except (httpx.TimeoutException, httpx.HTTPStatusError) as e:
            if attempt == retries - 1:
                raise
            time.sleep(2 ** attempt)  # backoff exponencial
```

**Por que `httpx` e não `requests`?** Suporte nativo a streaming e async. Para arquivos que podem ter 50–200 MB, streaming evita OOM.

**Agendamento (GitHub Actions):**

```yaml
# .github/workflows/ingest.yml
on:
  schedule:
    - cron: '0 3 5 * *'  # 5º dia de cada mês, 03h UTC
  workflow_dispatch:       # disparo manual para emergências
jobs:
  ingest:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: pip install httpx polars psycopg2-binary
      - run: python pipeline/ingest.py
        env:
          DATABASE_URL: ${{ secrets.DATABASE_URL }}
```

### 1.3 Tecnologia de Processamento — Polars, não Pandas, não Spark

**Escolha: Polars.**

- **vs Pandas:** Polars é 5–20x mais rápido em operações de groupby/join. Para arquivos de 100+ MB com groupby por produto + município + mês, a diferença é real. Além disso, Polars é lazy por padrão (execução adiada, otimização automática do plano de query).
- **vs DuckDB:** DuckDB é excelente para exploração SQL interativa, mas Polars é mais idiomático para pipelines Python lineares. Para este caso, Polars vence em legibilidade.
- **vs Spark:** Absurdo. Spark tem overhead de cluster. Para 200MB de CSV, Spark leva mais tempo para inicializar do que para processar.

**Leitura e limpeza dos arquivos:**

```python
import polars as pl

def load_conab_file(path: str) -> pl.DataFrame:
    df = pl.read_csv(
        path,
        separator=";",
        encoding="latin-1",          # arquivos governamentais raramente são UTF-8
        infer_schema_length=10000,
        ignore_errors=True,
    )
    # Normalizar nomes de colunas
    df = df.rename({c: c.strip().upper().replace(" ", "_") for c in df.columns})
    
    # Converter preço: "6,50" → 6.50
    df = df.with_columns(
        pl.col("PRECO").str.replace(",", ".").cast(pl.Float64, strict=False)
    )
    
    # Remover linhas sem preço ou sem produto
    df = df.filter(pl.col("PRECO").is_not_null() & pl.col("PRODUTO").is_not_null())
    
    return df
```

> **Armadilhas comuns com dados governamentais:**
> - Encoding Latin-1 (não UTF-8)
> - Separador decimal é vírgula, não ponto
> - Linhas de cabeçalho duplicadas no meio do arquivo
> - Meses faltando para municípios pequenos (normal — tratar com interpolação ou `null`)
> - Nomes de produtos inconsistentes ("Tomate" vs "TOMATE" vs "Tomate Salada")

### 1.4 A Matemática da Sazonalidade — O Coração do Projeto

**Índice de Sazonalidade (IS):**

O semáforo adota uma **banda de ±15%** em torno da referência (e não os ±10% comuns em modelos financeiros). Essa escolha reflete a volatilidade típica de hortifrutigranjeiros: variações de 10-15% são rotineiras (safra/entressafra, clima, logística), e usar uma banda mais estreita geraria falsos positivos (🟡 classificado como 🟢 ou 🔴).

```
IS(produto, localidade) = Preço_Atual / Preço_Referência
```

Onde `Preço_Referência` = média de 2025 (Ano Âncora Absoluto), ou fallback de 12 meses se o produto não existia em 2025.

- `IS < 0.85` → 🟢 **Verde** (preço ≥ 15% abaixo da referência → safra/barato)
- `0.85 ≤ IS ≤ 1.15` → 🟡 **Amarelo** (dentro da variação normal)
- `IS > 1.15` → 🔴 **Vermelho** (preço ≥ 15% acima da referência → entressafra/caro)

**Implementação Polars** (réplica da SP `sp_calcular_sazonalidade_baseline`):

```python
THRESHOLD_GREEN = 0.85
THRESHOLD_RED = 1.15

# Baseline 2025
base_2025 = (
    df.filter(pl.col("ano") == 2025)
    .group_by(["produto", "uf"])
    .agg(pl.col("preco_medio").mean().alias("preco_referencia_2025"))
)

# Último preço de cada produto+UF
ultimos = (
    df.sort(["produto", "uf", "ano", "mes"])
    .group_by(["produto", "uf"])
    .agg([
        pl.col("preco_medio").last().alias("preco_atual"),
        pl.col("ano").last().alias("ultimo_ano"),
        pl.col("mes").last().alias("ultimo_mes"),
    ])
)

# Fallback 12m (para produtos NOVOS sem 2025)
periodos = df.group_by(["produto", "uf"]).agg(
    (pl.col("ano") * 12 + pl.col("mes")).max().alias("ultimo_periodo")
)
fallback = df.join(periodos, on=["produto", "uf"], how="inner")
fallback = fallback.filter(
    (fallback["ano"] * 12 + fallback["mes"]) > (fallback["ultimo_periodo"] - 12)
)
fallback = fallback.group_by(["produto", "uf"]).agg(
    pl.col("preco_medio").mean().alias("preco_fallback_12m")
)

# Master join + semáforo
resultado = ultimos.join(base_2025, on=["produto", "uf"], how="left")
resultado = resultado.join(fallback, on=["produto", "uf"], how="left")
resultado = resultado.with_columns(
    pl.coalesce(pl.col("preco_referencia_2025"), pl.col("preco_fallback_12m"))
      .alias("preco_referencia"),
    pl.col("preco_referencia_2025").is_null().alias("usou_fallback_12m"),
)
razao = pl.col("preco_atual") / pl.col("preco_referencia")
resultado = resultado.with_columns(
    pl.when(pl.col("preco_referencia").is_null() | (pl.col("preco_referencia") == 0))
      .then(pl.lit("INSUFICIENTE"))
    .when(pl.col("preco_atual").is_null())
      .then(pl.lit("INSUFICIENTE"))
    .when(razao < THRESHOLD_GREEN).then(pl.lit("VERDE"))
    .when(razao > THRESHOLD_RED).then(pl.lit("VERMELHO"))
    .otherwise(pl.lit("AMARELO"))
    .alias("status_cor"),
)
```

**Problema crítico: dados faltando para municípios pequenos.**

A CONAB nem sempre cobre todos os municípios em todos os meses. Estratégia de fallback:

1. **Dados insuficientes** → `INSUFICIENTE`: sem preço de 2025 E com menos de 3 meses de histórico nos últimos 12 meses.
2. **Fallback 12m**: para produtos que NÃO existiam em 2025, calcula a média dos ÚLTIMOS 12 MESES disponíveis como âncora provisória. A flag `usou_fallback_12m` permite que o frontend exiba "*Comparado aos últimos 12 meses".
3. **Produto sem nenhum histórico** → `INSUFICIENTE` — melhor não classificar do que classificar errado.

**Proteção contra distorções climáticas (ex: geada que dobra o preço do tomate):**

Usar **desvio padrão** como filtro de outlier antes do cálculo:

```python
# Remover outliers (Z-score > 3) antes de calcular médias
df = df.with_columns(
    pl.col("PRECO").mean().over(["MUNICIPIO_ID", "PRODUTO"]).alias("_mean"),
    pl.col("PRECO").std().over(["MUNICIPIO_ID", "PRODUTO"]).alias("_std"),
).filter(
    ((pl.col("PRECO") - pl.col("_mean")) / pl.col("_std")).abs() < 3.0
).drop(["_mean", "_std"])
```

Isso evita que um único preço absurdo (erro de digitação ou evento climático extremo) contamine a média anual.

### 1.5 Modelagem PostgreSQL — Arquitetura Medalhão

O schema segue o padrão medalhão (raw → staging → mart) com acesso via views materializadas.

**Organização:**

- **`raw`**: dados como chegam da CONAB (COPY direto, schema flexível)
- **`staging`**: dimensões + fato limpos. Anomalias >500% da média histórica vão para `staging.precos_rejeitados`
- **`mart`**: sazonalidade materializada. `mart.sazonalidade_produto` é a tabela âncora do semáforo. `mart.vw_api_produtos_sazonalidade` é a view materializada que alimenta a API
- **`ops`**: observabilidade monitorada pelo Ghost DBA (audit logs, controle de erros)

**Modelo híbrido de sazonalidade (baseline 2025 + fallback 12m):**

- Baseline primário: média do produto em 2025 (Ano Âncora Absoluto). Prevalece sempre que existir
- Fallback condicional: para produtos que NÃO existiam em 2025, média dos últimos 12 meses disponíveis (mínimo 3 meses de histórico)
- Flag `usou_fallback_12m` indica se a âncora veio do fallback (não de 2025)
- SP principal: `sp_calcular_sazonalidade_baseline()` com 4 CTEs (base_2025 → ultimos_precos → fallback_12m → master_join)

---

## Fase 2 — Arquitetura Backend (FastAPI)

### 2.1 Design dos Endpoints (Implementado)

```
GET /api/v1/sazonalidade?uf=SP&municipio=São Paulo&produto=tomate&status_cor=VERDE&ano=2026&mes=6
    → Lista produtos com filtros combinados (UF, município, produto, status_cor, ano, mês)
      Paginação: pagina=1&por_pagina=100 (max 500)
      Quando ano + mês são fornecidos, dispara computação dinâmica por mês
      (via 4 CTEs: precos_mes → baseline → fallback → semaforo)

GET /api/v1/sazonalidade/{uf}/{municipio}
    → Atalho por localidade (encaminha para o endpoint acima)

GET /api/v1/municipios?uf=SP
    → Lista de municípios disponíveis para uma UF (distinct da view materializada)

GET /api/v1/_internal/cache-clear
    → Limpa cache in-memory (uso interno do Ghost DBA)
```

**Tipagem Pydantic (Implementada):**

```python
class SazonalidadeResponse(BaseModel):
    id_produto: int
    nome_produto: str
    icone_url: str | None = None
    uf: str
    municipio: str | None = None
    municipio_id: str | None = None
    ano: int
    mes: int
    data_referencia_atual: str       # "YYYY-MM"
    preco_referencia: float | None   # âncora: COALESCE(media 2025, fallback 12m)
    preco_atual: float | None        # último preço registrado
    usou_fallback_12m: bool          # True se âncora veio do fallback 12m
    status_cor: str                  # VERDE | AMARELO | VERMELHO | INSUFICIENTE
    fonte: str | None                # "municipio" | "uf"

class SazonalidadeListResponse(BaseModel):
    data: list[SazonalidadeResponse]
    total: int
    pagina: int
    por_pagina: int

class MunicipioListResponse(BaseModel):
    data: list[str]
    total: int
```

### 2.2 Otimização B2C — Cache e Connection Pooling

**Cache:** Implementado com cache in-memory thread-safe e TTL configurável (padrão 24h). Dispensa Redis no MVP — para o volume esperado de requisições B2C, o cache local é suficiente e elimina latência de rede.

**Estratégia dual-cache:**
- **Cache geral**: TTL 24h para requisições exatas (todos os filtros combinados).
- **Cache imutável histórico** (`_HIST_CACHE_TTL = 86_400`): chave apenas de dimensões (`saz_hist_{ano}_{mes}_{uf}_{municipio}_{categoria}`). A computação mensal completa é cacheada uma vez. Requisições com diferentes filtros de produto/status_cor/pagina são servidas de memória via `_slice_periodo()`, sem novas consultas ao banco.

```python
# backend/app/core/cache.py
import time
import threading
from collections import OrderedDict

class TTLCache:
    def __init__(self, capacity: int = 500):
        self._lock = threading.Lock()
        self._cache: OrderedDict[str, tuple[float, dict]] = OrderedDict()
        self._capacity = capacity

    def get(self, key: str) -> dict | None:
        with self._lock:
            if key not in self._cache:
                return None
            expires, value = self._cache[key]
            if time.monotonic() > expires:
                del self._cache[key]
                return None
            self._cache.move_to_end(key)
            return value

    def set(self, key: str, value: dict, ttl: int) -> None:
        with self._lock:
            self._cache[key] = (time.monotonic() + ttl, value)
            self._cache.move_to_end(key)
            if len(self._cache) > self._capacity:
                self._cache.popitem(last=False)
```

**Connection Pooling:** asyncpg com pool de 10–50 conexões, configurável via env.

```python
# backend/app/db/session.py
async def get_pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        settings = get_settings()
        _pool = await asyncpg.create_pool(
            settings.database_url,
            min_size=min(settings.pool_min_size, settings.pool_max_size // 2),
            max_size=min(settings.pool_max_size, 50),
            command_timeout=30,
        )
    return _pool
```

**Cache interno + asyncpg eliminam a dependência de Redis para o MVP.** Se houver necessidade futura, a migração para Redis é trivial — basta substituir o dicionário por uma chamada Redis.

---

## Fase 3 — Frontend React/PWA (Implementado)

### 3.1 Stack Decisão: Vite + React, NÃO Next.js

Diferente do plano inicial, o frontend foi implementado como **PWA puramente estático** com Vite + React 18, sem Next.js. Motivo:

- O app é uma tela única (Dashboard + LocationSelector). SSR não traz benefício real de LCP para um app transacional que depende de dados de API.
- PWA estático pode ser hospedado em S3/Cloudflare Pages por centavos, sem servidor Node.
- Service Worker + TanStack Query substituem qualquer benefício de SSR para dados dinâmicos.

### 3.2 Arquitetura de Componentes

```
App
└── Dashboard                ← Tela única, condicional
    ├── [sem localização] → LocationSelector (UF dropdown + city input com datalist)
    └── [com localização] → Header (localização + botão alterar)
                            └── ProductGrid (grid-cols-2 md:3 lg:4)
                                ├── ProductCard (status visual + emoji fallback)
                                └── ProductCardSkeleton (enquanto isLoading)
```

**User Journey:**
1. App abre → `useUserStore` checa localStorage
2. Sem localização salva → `LocationSelector` (fullscreen)
3. Seleciona UF → `useMunicipios(uf)` busca lista via API → `<datalist>` no input
4. Digita/autocomplete cidade → salva na store
5. Tela principal: seção colapsável "Monte sua Lista" com toggle via ChevronDown
6. Seleciona produtos → seção "Produtos Selecionados"/"Todos os Produtos" (também colapsável)
7. Clica em um mês → `useHortifruti(ano, mes)` dispara duas queries: `hortifruti-meta` (snapshot) + `hortifruti-filter` (dados do mês)
8. Loading → 8 `ProductCardSkeleton` pulsantes (grid)
9. Dados carregados → grid ordenado: VERDE (topo) → AMARELO → VERMELHO

### 3.3 O ProductCard e a Lógica de Cores (Implementado)

```tsx
// STATUS_MAP usado no ProductCard
const STATUS_MAP = {
  VERDE: {
    bg: 'bg-sazonal-verde-50',
    border: 'border-sazonal-verde-400',
    text: 'text-sazonal-verde-700',
    label: 'Melhor Época!',
    icon: <CheckCircle2 className="h-5 w-5 text-sazonal-verde-600" />,
    opacity: 'opacity-100',
  },
  AMARELO: {
    bg: 'bg-sazonal-amarelo-50',
    border: 'border-sazonal-amarelo-400',
    text: 'text-sazonal-amarelo-600',
    label: 'Preço Normal',
    icon: <AlertTriangle className="h-5 w-5 text-sazonal-amarelo-600" />,
    opacity: 'opacity-100',
  },
  VERMELHO: {
    bg: 'bg-sazonal-vermelho-50',
    border: 'border-sazonal-vermelho-400',
    text: 'text-sazonal-vermelho-600',
    label: 'Péssima Época',
    icon: <XCircle className="h-5 w-5 text-sazonal-vermelho-600" />,
    opacity: 'opacity-60',  // reduz opacidade para desincentivar clique
  },
}
```

Características implementadas no ProductCard:
- **Nunca mostra preços em R$** — apenas o label textual (Melhor Época! / Preço Normal / Péssima Época)
- **Emoji unicode apenas**: usa `PRODUTO_EMOJI` map (🍚, 🍌, etc.). Sem imagens (sem jpg, png, webp, svg, avif)
- **Seções colapsáveis**: "Monte sua Lista" e grid de produtos alternam com `ChevronDown` e rotação CSS
- **Skeleton view**: componente `ProductCardSkeleton` com `animate-pulse-soft` mantém o layout estável

### 3.4 Gerenciamento de Estado e Cache

```tsx
// Zustand store (persist no localStorage)
export const useUserStore = create<UserState>()(
  persist(
    (set) => ({
      uf: null,
      municipio: null,
      setLocation: (uf, municipio) => set({ uf, municipio }),
      clearLocation: () => set({ uf: null, municipio: null }),
    }),
    { name: 'qcomprar-user' },
  ),
)
```

```tsx
// TanStack Query — sazonalidade (dual-query, staleTime 12h)
export function useHortifruti(ano, mes) {
  const meta = useQuery({
    queryKey: ['hortifruti-meta', uf, municipio],
    queryFn: () => api.get(`/sazonalidade/${uf}/${municipio}`).then(r => r.data),
    enabled: !!uf && !!municipio,
    staleTime: 1000 * 60 * 60 * 12,
  })
  const filtro = useQuery({
    queryKey: ['hortifruti-filter', uf, municipio, ano, mes],
    queryFn: () => api.get(`/sazonalidade/${uf}/${municipio}`, { params: { ano, mes } }).then(r => r.data),
    enabled: !!uf && !!municipio && ano !== undefined && mes !== undefined,
    staleTime: 1000 * 60 * 60 * 12,
  })
  return { products: filtro.data ?? [], allProducts: meta.data ?? [] }
}

// TanStack Query — municipios (staleTime 24h)
export function useMunicipios(uf) {
  return useQuery({
    queryKey: ['municipios', uf],
    queryFn: () => api.get('/municipios', { params: { uf } }).then(r => r.data.data),
    enabled: !!uf && uf.length === 2,
    staleTime: 1000 * 60 * 60 * 24,  // 24h
  })
}
```

### 3.5 Estratégia de Prefetch

Quando o usuário digita a cidade (≥3 caracteres), o `LocationSelector` dispara prefetch com debounce de 600ms:

```tsx
const handleCityChange = useCallback((value: string) => {
  setLocalCity(value)
  clearTimeout(debounceRef.current)
  debounceRef.current = setTimeout(() => doPrefetch(value), 600)
}, [doPrefetch])
```

Isso aquece o cache do TanStack Query e o Service Worker antes do submit.

### 3.6 Performance Mobile — PWA

**vite-plugin-pwa** configurado com:
- `StaleWhileRevalidate` para `/api/v1/sazonalidade` (cache por 24h no Service Worker)
- `globPatterns` para assets estáticos (JS/CSS/HTML)
- `display: standalone` + `orientation: portrait` para experiência de app nativo

**Tailwind config** com cores de negócio no lugar de nomes genéricos:
```js
colors: {
  sazonal: {
    verde:    { 50, 100, 400, 600, 700 },
    amarelo:  { 50, 100, 400, 600 },
    vermelho: { 50, 100, 400, 600 },
  },
}
```

**Metas Lighthouse:** Performance ≥ 95, LCP < 2.5s, CLS = 0, PWA instalável.

---

## Fase 4 — Cronograma MVP (6 Sprints)

| Sprint | Semana | Meta | Risco Principal | Mitigação |
|---|---|---|---|---|
| **1** | 1 | Download + parsing dos .txt CONAB. Limpeza Polars. Calculo IS. Script funcional localmente. | Formato do arquivo mudar sem aviso | Versionar os .txt baixados; alertar se schema mudar |
| **2** | 2 | Modelagem PostgreSQL. Carga dos dados processados. Script de ingestion end-to-end. | Dados faltando para muitos municípios | Implementar fallback UF imediatamente |
| **3** | 3 | FastAPI: endpoints `/locations` e `/products`. Testes com Postman/pytest. | Query lenta sem índice | Adicionar índices antes dos testes de carga |
| **4** | 4 | React: LocationSelector + ProductGrid + ProductCard com semáforo. Mobile-first. | Complexidade de estado (UF + Cidade + Mês) | Zustand desde o início; não improvisar com useState global |
| **5** | 5 | Cache in-memory TTL. PWA manifest + service worker. Emoji-only nos cards. Deploy (Hetzner/Fly.io). | Deploy com variáveis de ambiente erradas | Usar docker-compose com `.env.example` documentado |
| **6** | 6 | Busca full-text. Polish UX (skeletons, empty states, error states). Teste no celular real. Lighthouse ≥ 90. | Lighthouse falhar por assets grandes | Testar em 3G real desde Sprint 4; não deixar para o final |

**Maior gargalo do projeto:** A qualidade dos dados da CONAB. Municípios pequenos têm histórico incompleto. A solução de fallback hierárquico (município → UF) deve ser implementada no Sprint 2, não como "nice to have" futuro.

---

## Stack Definitiva (Resumo Executivo Técnico)

| Camada | Tecnologia | Alternativa Descartada | Motivo |
|---|---|---|---|
| Ingestão | GitHub Actions + httpx | Airflow, Prefect | Overkill para 2 arquivos/mês |
| Processamento | Polars | Spark, Dask | Spark = overhead absurdo para 200MB |
| Banco | PostgreSQL + OBT | BigQuery, Star Schema | DW analytics para OLTP é errado |
| Cache | In-memory (TTL thread-safe) | Redis, Memcached | Elimina latência de rede e dependência externa no MVP; migração trivial para Redis se necessário |
| Backend | FastAPI + asyncpg | Django, Flask | Performance async + Pydantic nativo |
| Frontend | Vite + React 18 + PWA | Next.js, CRA, Material-UI | PWA estático (S3/CF Pages); SSR não agrega para app de tela única |
| Imagens | Emoji unicode (PRODUTO_EMOJI map) | WebP/S3/Cloudinary | CDN desnecessário — emoji nativo é zero-latency, zero-custo, zero-manutenção |
| Hosting | Hetzner CX21 (€5/mês) | AWS EC2 t3.medium | 70% mais barato para o mesmo hardware |
