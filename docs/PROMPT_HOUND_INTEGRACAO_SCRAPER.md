================================================================================
PROMPT: INTEGRAÇÃO HOUND-MCP COMO SUB-ENGINE PARALELA AUXILIAR
Projeto: quero_comprar_vg
Nível: Senior / Staff Engineer
Data: 2026-07-20
================================================================================

## CONTEXTO DO PROJETO

O projeto `quero_comprar_vg` possui um ecossistema scraper multi-camada
para coleta de cotações de hortifruti brasileiras (CEASA, CEPEA, HF Brasil,
CONAB, secretarias agrícolas estaduais). A stack atual:

- Camada Transport: patchright, camoufox, pydoll (stealth browsers)
- Camada HTTP: curl-cffi (TLS impersonation), httpx, aiohttp
- Camada NLP: spacy (NER), vaderSentiment, lxml, bs4
- Camada Orchestration: SelfHealingOrganism, ChallengeRouter, WafBypass
- Camada Dados: polars, pydantic, pyarrow

Arquitetura existente em: `pipeline/scraper/transport/`
Interface base: `StealthTransportEngine` (ABC) em `engine.py`

## OBJETIVO

Integrar o servidor MCP `hound-mcp` (versão 10.4.1, MIT) como engine
auxiliar paralela ao sistema scraper existente. O Hound será usado
APENAS para:

1. smart_search — descoberta automática de novas fontes de cotação
2. smart_fetch — fetch com bypass Cloudflare automático (fallback HTTP→browser)
3. smart_crawl — mapeamento de páginas de cotação em sites CEASA

O Hound NÃO será usado para:

- Extração de PDFs (já descartado)
- Extração de cotações (scrapers customizados são mais confiáveis)
- Substituir qualquer engine existente

## PREMISSAS TÉCNICAS

1. Hound é um servidor MCP (stdio), NÃO uma lib importável direto
2. Comunicação via MCP protocol (JSON-RPC over stdio) ou HTTP mode
3. O Hound expõe 6 ferramentas: smart_fetch, smart_search, smart_crawl,
   screenshot, cache_clear, version
4. O projeto usa Python 3.11+, async/await, Pydantic v2
5. Licença MIT — uso comercial permitido

## FILOSOFIA: SCRAPERS COMO PESQUISADOR HUMANO

O scraper auxiliar do Hound deve operar como um **pesquisador humano
experiente** que busca cotações de hortifruti na web. Não é um bot que
dispara queries automáticas — é um assistente que:

### Princípios de Comportamento

1. **Pensar antes de buscar**: o pesquisador não digita a mesma query 50
   vezes. Ele refina a busca baseado nos resultados anteriores. O scraper
   deve: executar uma query, analisar resultados, refinar a próxima query.

2. **Usar operadores como um humano experiente**: um pesquisador sabe que
   `site:gov.br` filtra fontes governamentais, que `"cotação hortifruti"`
   (com aspas) busca a frase exata, que `intext:CEASA` garante que o
   resultado fala sobre CEASA. O scraper deve usar esses operadores
   naturalmente — não querystrings genéricas.

3. **Respeitar o ritmo humano**: pauses entre queries (1.5s), pausa entre
   fases de busca (3s), não disparar 100 queries em 2 segundos. Isso
   reduz rate-limit e parece humano para os motores de busca.

4. **Avaliar como um humano**: quando vê um resultado, o pesquisador
   julga: "essa fonte parece confiável?" (.gov.br = sim, agregador
   duvidoso = não). O scraper deve ter filtros de qualidade que simulem
   esse julgamento.

5. **Explorar como um humano**: o pesquisador clica em um resultado,
   vê que o site tem mais páginas úteis, e continua explorando. O
   scraper deve usar `smart_crawl` para seguir links relevantes.

### O que NÃO fazer (anti-padrões)

- NÃO disparar a mesma query repetidamente (rate-limit garantido)
- NÃO usar queries genéricas como "preços de alimentos" (muito ruído)
- NÃO ignorar operadores de busca (perde precisão)
- NÃO pular validação de acessibilidade (URL morta não serve)
- NÃO confiar em um único backend de busca (viés de um motor)
- NÃO buscar sem plano (queries aleatórias = resultados aleatórios)

## ARQUITETURA PROPOSTA

```
pipeline/scraper/
├── hound/                          # NOVO módulo
│   ├── __init__.py
│   ├── client.py                   # Cliente MCP (stdio transport)
│   ├── models.py                   # Pydantic models para respostas Hound
│   ├── engines/
│   │   ├── __init__.py
│   │   ├── search_engine.py        # smart_search wrapper
│   │   ├── fetch_engine.py         # smart_fetch wrapper
│   │   └── crawl_engine.py         # smart_crawl wrapper
│   ├── adapters/
│   │   ├── __init__.py
│   │   ├── source_discovery.py     # Descoberta de fontes via search
│   │   ├── fallback_fetch.py       # Fallback anti-bot via fetch
│   │   └── site_mapper.py          # Mapeamento via crawl
│   ├── config.py                   # Configuração Hound
│   └── exceptions.py               # Exceções customizadas
└── transport/
    └── (existente — sem modificações)
```

## ESPECIFICAÇÃO DE COMPONENTES

### 1. HoundClient (`client.py`)

Responsabilidade: gerenciar o ciclo de vida do processo Hound e
comunicar via MCP protocol.

Requisitos:

- Spawn do processo `hound` via asyncio.create_subprocess_exec
- Comunicação JSON-RPC over stdio (MCP transport)
- Retry com backoff exponencial (3 tentativas)
- Timeout configurável por operação (default 30s)
- Health check periódico via tool "version"
- Graceful shutdown com cleanup do processo
- Modo HTTP alternativo: `hound --http --host 127.0.0.1 --port 8765`
  (preferido para produção — evita overhead de spawn por chamada)

Interface pública:

```python
class HoundClient:
    async def connect(self) -> None: ...
    async def call_tool(self, name: str, arguments: dict) -> dict: ...
    async def smart_search(self, query: str, **kwargs) -> SearchResponse: ...
    async def smart_fetch(self, url: str, **kwargs) -> FetchResponse: ...
    async def smart_crawl(self, url: str, **kwargs) -> CrawlResponse: ...
    async def close(self) -> None: ...
```

### 2. SearchEngine (`engines/search_engine.py`)

Responsabilidade: wrapper tipado para smart_search.

Parâmetros suportados:

- query: str (obrigatório — suporta operadores de busca avançados)
- page: int (0-10, default 0)
- freshness: Literal["day", "week", "month", "year"]
- site: str (filtro domínio — equivalente a `site:` na query)
- exclude_sites: list[str]
- language: str (default "pt-BR")
- location: str
- region: str

Operadores suportados na query (replicam busca humana):

| Operador | Exemplo | Efeito |
|----------|---------|--------|
| `"..."` | `"cotação hortifruti"` | Busca frase exata |
| `site:` | `site:gov.br` | Filtra por domínio/TLD |
| `intext:` | `intext:CEASA` | Termo no corpo do resultado |
| `inurl:` | `inurl:cotacao` | Termo na URL |
| `url:` | `url:ceagesp.gov.br` | Busca por URL parcial |
| `*` | `"cotação * CEASA"` | Wildcard para qualquer palavra |
| `-` | `cotação -pdf` | Exclui termo |
| `OR` | `CEASA OR CEPEA` | Alternativa entre termos |
| `AND` | `"cotação" AND "tomate"` | Ambos termos obrigatórios |
| `intitle:` | `intitle:cotação` | Termo no título |
| `filetype:` | `filetype:xls` | Filtra tipo de arquivo |

Retorno: SearchResponse com campos:

- results: list[SearchResult] (url, title, snippet, relevance_score,
  engines_consensus, source_type, is_official)
- related_queries: list[str]
- engine_blocked: list[str]

Uso principal:

- Descobrir URLs de CEASAs/secretarias que não estão no hardcoded
- Encontrar endpoints AJAX de sites que renderizam via JS
- Buscar cotações em fontes que não estão mapeadas

### 3. FetchEngine (`engines/fetch_engine.py`)

Responsabilidade: wrapper tipado para smart_fetch com workflow
HTTP→browser automático. Comporta-se como um humano acessando uma página:
primeiro tenta HTTP simples (como um navegador rápido), se bloqueado,
escalona para browser stealth (como um humano que abriu o site normalmente).

Parâmetros suportados:

- url: str (obrigatório)
- css_selector: str (filtro seletor CSS — "quero só a tabela")
- focus: str (extração BM25 — "me interessa só cotação de tomate")
- actions: list[Action] (click, fill, scroll, wait — "clicar em 'próxima página'")
- include_links: bool (extrair links classificados)
- cache_ttl: int (default 3600 — "não rebuscar a mesma página em 1h")

Comportamento humano simulado:

1. **Tenta HTTP primeiro** (~1s) — como um humano que colou a URL
2. **Se bloqueado (403/CF)** — abre browser stealth automaticamente
3. **Se tem JS** — espera render, como um humano que vê a página carregar
4. **Extrai conteúdo** — foca no que é relevante (focus)
5. **Classifica links** — separa navegação de conteúdo (como um humano que ignora menus)
6. **Cacheia resultado** — não rebusca a mesma página em 1h

Retorno: FetchResponse com campos:

- content: str (markdown)
- content_ok: bool
- next_action: str
- page_type: Literal["article", "list", "js_shell"]
- metadata: PageMetadata (title, description, site_name, published_time)
- links: list[ClassifiedLink]

Uso principal:

- Fallback quando Patchright customizado falha em Cloudflare
- Extração de tabelas de cotação via css_selector
- Fetch de páginas com JS rendering (CEAGESP, CEASA-SP)

### 4. CrawlEngine (`engines/crawl_engine.py`)

Responsabilidade: wrapper tipado para smart_crawl. Comporta-se como
um humano explorando um site: segue links relevantes, ignora menus,
para quando encontra o que procura.

Parâmetros suportados:

- url: str (obrigatório — URL inicial)
- max_pages: int (default 10 — "navegar no máximo 10 páginas")
- max_depth: int (default 2 — "não ir além de 2 cliques")
- focus: str (filtro de relevância — "só me interessa cotação")
- sitemap: Literal["auto", "true", "false"]
  - "auto": tenta sitemap.xml primeiro (como humano que procura mapa do site)
  - "true": usa sitemap obrigatoriamente
  - "false": crawl BFS ignorando sitemap
- discover_only: bool (só listar URLs, não buscar conteúdo)
- crawl_urls: list[str] (buscar só essas URLs específicas)

Comportamento humano simulado:

1. **Verifica sitemap.xml primeiro** — como um humano que procura "Sitemap" no rodapé
2. **Se não tem sitemap** — navega links como humano (best-first por relevância)
3. **Prioriza páginas de conteúdo** — ignora login, carrinho, contato
4. **Para quando encontra o que precisa** — não crawl infinito
5. **Detecta JS shell** — reporta honestamente "essa página precisa de JS"
6. **Respeita orçamento** — max_pages, max_depth, deadline

Retorno: CrawlResponse com campos:

- pages: list[CrawledPage] (url, content, content_ok, page_type, status)
- discover_only: list[str] (URLs descobertas sem fetch)
- next_action: str

Uso principal:

- Mapear todas as categorias de cotação em sites CEASA
- Descobrir URLs de download de arquivos estáticos (CSV/XLS)
- Crawl assistido de sites com estrutura desconhecida

### 5. SourceDiscovery (`adapters/source_discovery.py`)

Responsabilidade: usar smart_search para descobrir novas fontes
de cotação de hortifruti.

#### 5.1. Biblioteca de Operadores de Busca

O SourceDiscovery usa operadores de busca avançados para replicar
o comportamento de um pesquisador humano experiente. Operadores
suportados pelos backends keyless do Hound (DuckDuckGo, Brave, Yahoo, etc.):

| Operador | Função | Exemplo |
|----------|--------|---------|
| `site:` | Restringe a domínio/TLD | `site:gov.br` |
| `site:` + subdomínio | Restringe a subdomínio específico | `site:ceagesp.gov.br` |
| `intext:` | Termo deve aparecer no corpo do resultado | `intext:"cotação hortifruti"` |
| `inurl:` | Termo deve aparecer na URL | `inurl:cotacao` |
| `url:` | Busca exata por URL parcial | `url:ceagesp.gov.br/cotacoes` |
| `*` (wildcard) | Coringa para qualquer palavra | `"cotação * CEASA"` |
| `"..."` | Busca exata da frase | `"preço médio hortifruti"` |
| `-` (exclusão) | Exclui termo dos resultados | `cotação -download -pdf` |
| `filetype:` | Restringe tipo de arquivo | `filetype:xls` ou `filetype:csv` |
| `intitle:` | Termo deve estar no título | `intitle:cotação` |
| `after:` / `before:` | Filtro temporal (backends que suportam) | `after:2026-01-01` |

#### 5.2. Estratégias de Query (Replicação de Busca Humana)

Cada estratégia simula o que um pesquisador humano faria para
encontrar fontes de cotação. As queries são executadas em sequência
com pausa entre elas (simulando digitação humana).

**Fase 1 — Busca Ampla (Rede de Proteção)**

```python
QUERIES_FASE_1 = [
    # Busca geral por cotação + CEASA
    '"cotação hortifruti" CEASA',

    # Busca por tabela de preços em sites governamentais
    '"tabela de preços" hortifruti site:gov.br',

    # Busca por cotação regional
    '"cotação" "preço médio" verduras frutas',

    # Busca por produto específico (tomate como canário)
    '"cotação" tomate CEASA 2026',
]
```

**Fase 2 — Busca por UF (Geográfica)**

```python
UF_ALVO = ["SP", "MG", "PR", "SC", "RS", "GO", "BA", "CE", "DF"]

QUERIES_FASE_2 = [
    # Template: busca por UF específica
    '"cotação" hortifruti site:{uf}.gov.br',

    # Template: CEASA da UF
    '"CEASA" "cotação" site:ceasa.{uf_lower}.gov.br',

    # Template: secretaria agrícola da UF
    'secretaria agricultura "cotação" site:{uf_lower}.gov.br',

    # Template: instituto de pesquisa da UF
    '"IEA" OR "EMATER" OR "EPAGRI" "cotação" site:{uf_lower}.gov.br',
]
```

**Fase 3 — Busca por Fonte Conhecida (Expansão)**

```python
FONTES_SEMENTE = [
    "conab.gov.br",
    "cepea.esalq.usp.br",
    "ceagesp.gov.br",
    "hfbrasil.org.br",
]

QUERIES_FASE_3 = [
    # Buscar páginas vinculadas a fonte semente
    '"cotação" site:{fonte}',

    # Buscar citações da fonte em outros sites
    '"{fonte}" "cotação" hortifruti',

    # Buscar dados derivados/espelhados
    'intext:"fonte: {fonte}" cotação',
]
```

**Fase 4 — Busca por Arquivo Estático (CSV/XLS)**

```python
QUERIES_FASE_4 = [
    # XLS de cotação
    'cotação hortifruti filetype:xls site:gov.br',

    # CSV de preços
    '"tabela de preços" hortifruti filetype:csv',

    # Planilha CEASA
    'CEASA cotação filetype:xlsx',
]
```

**Fase 5 — Busca por Termos Alternativos (Sinônimos)**

```python
QUERIES_FASE_5 = [
    # Sinônimos que humanos usam
    '"preço do dia" hortifruti',
    '"feira livre" cotação',
    '"cesta básica" preços',
    '"mercado atacadista" verduras',
    '"SAC" OR "balcão" cotação hortifruti',
]
```

#### 5.3. Motor de Orquestração de Queries

```python
class QueryOrchestrator:
    """Orquestra queries como um pesquisador humano faria."""

    # Delay entre queries (simula ritmo humano)
    INTER_QUERY_DELAY_S: float = 1.5

    # Delay entre fases (simula pausa para pensar)
    INTER_PHASE_DELAY_S: float = 3.0

    # Máximo de queries por fase (evita spam)
    MAX_QUERIES_PER_PHASE: int = 5

    async def execute_search_plan(
        self, ufs: list[str], fontes_semente: list[str]
    ) -> list[SearchResult]:
        """Executa o plano de busca completo."""
        all_results = []

        for phase_name, phase_queries in [
            ("ampla", QUERIES_FASE_1),
            ("regional", self._build_uf_queries(ufs)),
            ("fontes", self._build_fonte_queries(fontes_semente)),
            ("arquivos", QUERIES_FASE_4),
            ("sinonimos", QUERIES_FASE_5),
        ]:
            phase_results = await self._execute_phase(
                phase_name, phase_queries
            )
            all_results.extend(phase_results)

            # Pausa entre fases (humano para pra pensar)
            await asyncio.sleep(self.INTER_PHASE_DELAY_S)

        # Dedup + ranking por consensus
        return self._dedup_and_rank(all_results)
```

#### 5.4. Filtros de Qualidade

Após cada busca, os resultados passam por filtros que simulam
o julgamento humano ("essa fonte parece confiável?"):

```python
def filtrar_resultado(result: SearchResult) -> bool:
    """Filtro de qualidade — simula decisão humana."""
    checks = [
        # 1. É fonte oficial? (.gov.br, .edu.br)
        result.is_official,

        # 2. Relevância mínima
        result.relevance_score >= 0.7,

        # 3. Consenso entre backends (múltiplos motores concordam)
        result.engines_consensus >= 2,

        # 4. URL não é dead link (será validada depois)
        not any(
            err in result.url.lower()
            for err in ["404", "error", "maintenance", "manutencao"]
        ),

        # 5. Não é conteúdo duplicado/agregador
        result.source_type != "aggregator",

        # 6. Título indica conteúdo de cotação/preço
        any(
            kw in result.title.lower()
            for kw in ["cotação", "preço", "valor", "mercado", "feira"]
        ),
    ]
    return sum(checks) >= 4  # Pelo menos 4 de 6 checks passam
```

#### 5.5. Exemplos Reais de Queries com Operadores

Cada linha abaixo é uma query que o `SourceDiscovery` executaria.
OBS: estas são APENAS EXEMPLOS — o motor gera combinações dinâmicas
baseado nas UFs e fontes semente configuradas.

```
# ─── Busca Ampla ───
"cotação hortifruti" CEASA
"tabela de preços" hortifruti site:gov.br
"cotação" "preço médio" verduras frutas
"preço do dia" hortifruti site:ceagesp.gov.br
intext:"fonte: CEPEA" cotação

# ─── Busca por UF (SP) ───
"cotação" hortifruti site:sp.gov.br
"CEASA" "cotação" site:ceagesp.gov.br
"IEA" OR "SAA-SP" "cotação" site:sp.gov.br
intitle:cotação site:agricultura.sp.gov.br
inurl:cotacao site:sp.gov.br

# ─── Busca por UF (MG) ───
"CEASA" "cotação" site:ceasa.mg.gov.br
"EMATER" "preços" hortifruti site:mg.gov.br
"IEF" OR "SEAPA" cotação site:agricultura.mg.gov.br

# ─── Busca por Fonte Semente (CONAB) ───
"cotação" site:conab.gov.br
"CONAB" "preços" hortifruti -download
intext:"fonte: CONAB" cotação tomate

# ─── Busca por Fonte Semente (CEPEA) ───
"cotação" site:cepea.esalq.usp.br
"CEPEA" "indicador" hortifruti inurl:indicador

# ─── Busca por Arquivo Estático ───
cotação hortifruti filetype:xls site:gov.br
"tabela de preços" hortifruti filetype:csv
CEASA cotação filetype:xlsx -pdf

# ─── Busca por Sinônimos ───
"feira livre" cotação hortifruti
"cesta básica" preços verduras
"mercado atacadista" tomate cebola
"SAC" OR "balcão" cotação hortifruti site:gov.br

# ─── Busca Combinada (operadores mistos) ───
"cotação" AND "hortifruti" site:gov.br AND intext:tomate
"cotação" OR "preço" hortifruti site:ceasa.*.gov.br
inurl:cotacao OR inurl:precos hortifruti site:gov.br
"cotação" -download -pdf -excel site:gov.br intext:tomate
```

#### 5.6. Workflow Completo

1. Gerar queries dinâmicas (Fases 1→5) baseadas em UFs e fontes semente
2. Executar queries com delay humano (1.5s entre queries, 3s entre fases)
3. Filtrar resultados com `filtrar_resultado()` (qualidade)
4. Deduplicar por domínio + path (mesma URL, fontes diferentes)
5. Validar acessibilidade via smart_fetch (verificar content_ok)
6. Salvar fontes descobertas em: `pipeline/scraper/config_fontes_descobertas.json`
7. Gerar relatório: `{"fontes": [...], "queries_executadas": N, "taxa_sucesso": X%}`

Integração com o existente:

- Alimentar `FONTES_CONHECIDAS` em `buscador_fontes.py` dinamicamente
- complementar a lista hardcoded com fontes descobertas

### 6. FallbackFetch (`adapters/fallback_fetch.py`)

Responsabilidade: usar smart_fetch como camada de fallback quando
os engines customizados falham.

Workflow:

1. Engine principal (Patchright/Camoufox/Pydoll) tenta fetch
2. Se falha (timeout, Cloudflare, WAF, erro 403/503):
   a. Log do erro com classe e mensagem
   b. Chamar HoundClient.smart_fetch(url, css_selector=...)
   c. Se content_ok == True → usar conteúdo retornado
   d. Se content_ok == False → next_action indica ação (retry, skip, etc.)
3. Integrar com SelfHealingOrganism como "fase 0.5" no pipeline:
   extract → [hound_fallback] → resolve_challenge → rotate_identity → ...

Ponto de integração:

- Monkey-patch ou subclass de `SelfHealingOrganism.harvest()`
- OU criar `EnhancedOrganism(SelfHealingOrganism)` que sobrescreve
  o método harvest com a camada Hound antes do loop existente

### 7. SiteMapper (`adapters/site_mapper.py`)

Responsabilidade: mapear estrutura de sites de cotação via smart_crawl.
Comporta-se como um humano que está explorando um site pela primeira vez
para entender onde estão os dados que precisa.

Workflow:

1. Input: URL base do site (ex: ceagesp.gov.br/cotacoes/)
2. Verificar sitemap.xml (procurar /sitemap.xml, /sitemap_index.xml)
3. Se não tem sitemap → crawl BFS com foco em:
   - URLs com palavras-chave: cotação, preço, produto, hortifruti, mercado
   - Path include: /cotacao, /precos, /produtos, /indicadores, /estatistica
   - Excluir: /login, /contato, /sobre, /blog, /news
4. Classificar URLs por tipo:
   - **listing**: página com múltiplas cotações (tabela, grid)
   - **detail**: página de cotação específica (produto individual)
   - **download**: arquivo estático (CSV, XLS, PDF)
   - **api**: endpoint JSON/API detectado
5. Salvar mapa em: `pipeline/scraper/site_maps/[dominio].json`

Exemplo de saída:

```json
{
  "dominio": "ceagesp.gov.br",
  "url_base": "https://ceagesp.gov.br/cotacoes/",
  "sitemap_encontrado": true,
  "total_urls": 47,
  "urls_por_tipo": {
    "listing": 6,
    "detail": 35,
    "download": 4,
    "api": 2
  },
  "urls_cotacao": [
    {"url": "/cotacoes/frutas/", "tipo": "listing", "relevancia": 0.95},
    {"url": "/cotacoes/legumes/", "tipo": "listing", "relevancia": 0.93},
    {"url": "/dados/cotacao-tomate.xlsx", "tipo": "download", "relevancia": 0.99}
  ]
}
```

Uso:

- Atualizar periodicamente os endpoints dos scrapers
- Detectar mudanças de estrutura em sites governamentais
- Manter o `buscador_fontes.py` atualizado automaticamente
- Detectar novos endpoints de download (CSV/XLS) que surgem

## CONFIGURAÇÃO

### Configurar Hound

```bash
# Instalação
pip install hound-mcp[all]
playwright install chromium

# Verificação
hound --doctor

# Modo HTTP (recomendado para produção)
hound --http --host 127.0.0.1 --port 8765
```

### Variáveis de Ambiente

```env
# Opcional: proxy para busca (recomendado para uso pesado)
HOUND_SEARCH_PROXY=http://user:pass@proxy:port

# Opcional: timeout do browser idle (default 300s)
HOUND_BROWSER_IDLE_TIMEOUT=300

# Opcional: intervalo mínimo entre buscas ao mesmo engine
HOUND_SEARCH_MIN_INTERVAL=1.2
```

### Config do Projeto (`pipeline/scraper/hound/config.py`)

```python
from pydantic import BaseModel

class HoundConfig(BaseModel):
    # Conexão
    mode: Literal["stdio", "http"] = "http"
    http_host: str = "127.0.0.1"
    http_port: int = 8765
    command: str = "hound"  # para modo stdio

    # Timeouts
    connect_timeout_s: float = 10.0
    tool_timeout_s: float = 30.0
    crawl_timeout_s: float = 120.0

    # Search
    search_default_language: str = "pt-BR"
    search_min_relevance: float = 0.7
    search_min_consensus: int = 3
    search_max_results: int = 10

    # Fetch
    fetch_cache_ttl: int = 3600
    fetch_max_retries: int = 2

    # Crawl
    crawl_max_pages: int = 15
    crawl_max_depth: int = 2
    crawl_sitemap: str = "auto"
```

## INTEGRAÇÃO COM PIPELINE EXISTENTE

### Ponto de Entrada Principal

Criar `pipeline/scraper/hunt_adapter.py`:

```python
"""
Hound Adapter — integra Hound como engine auxiliar no pipeline de coleta.

Uso:
    async with HoundAdapter() as adapter:
        # Descobrir fontes
        fontes = await adapter.discover_sources(ufs=["SP", "MG", "PR"])

        # Fallback fetch
        content = await adapter.fallback_fetch(url, css_selector="table")

        # Mapear site
        site_map = await adapter.map_site("https://ceagesp.gov.br/cotacoes/")
"""
```

### Integração com `coletar_todas_fontes()` em `scraper_hortifruti.py`

O adapter NÃO modifica `coletar_todas_fontes()`. Em vez disso,
é chamado ANTES para enriquecer a lista de fontes:

```python
# Fluxo atual (sem Hound):
# 1. Coleta de HFBrasil + CEAGESP (hardcoded)
# 2. Salva no banco

# Fluxo com Hound (paralelo):
# 1. HoundAdapter.discover_sources() → fontes extras
# 2. Para cada fonte descoberta: fetch via Hound
# 3. Merge com resultados dos scrapers customizados
# 4. Salva no banco (deduplicado por url + data)
```

### Integração com `SelfHealingOrganism`

```python
class HoundEnhancedOrganism(SelfHealingOrganism):
    """SelfHealingOrganism com fallback Hound como fase intermediária."""

    async def harvest(self, url: str, ...) -> HarvestResult:
        # Fase 1: Tentar engine principal (comportamento original)
        result = await super().harvest(url, ...)

        if result.success:
            return result

        # Fase 2: Fallback Hound (novo)
        if self._hound_client:
            hound_result = await self._hound_client.smart_fetch(
                url, css_selector=self._extract_css_selector(url)
            )
            if hound_result.get("content_ok"):
                # Construir ExtractionResult a partir do conteúdo Hound
                extraction = self._build_extraction_from_hound(hound_result)
                result.success = True
                result.extraction = extraction
                result.state_history.append("hound_fallback_success")
                return result

        return result
```

## TESTES

### Testes Unitários

- `tests/test_hound_client.py`: mock do processo Hound, testar
  conexão, retry, timeout, graceful shutdown
- `tests/test_search_engine.py`: mock das respostas MCP, testar
  parsing dos resultados
- `tests/test_fetch_engine.py`: mock, testar fallback HTTP→browser
- `tests/test_source_discovery.py`: mock, testar filtragem por
  relevance_score e consensus

### Testes de Integração

- `tests/test_hound_integration.py`: testar com Hound real rodando
  (marcar com `@pytest.mark.hound` para skip em CI)
- Verificar que `hound --doctor` passa antes dos testes

### Testes de Contrato

- Verificar que as respostas MCP são parseáveis corretamente
- Verificar que timeouts são respeitados
- Verificar que o processo Hound é limpo corretamente em todos os paths

## MÉTRICAS DE SUCESSO

| Métrica | Target |
|---------|--------|
| Fontes descobertas via Hound/mês | +10 novas fontes |
| Taxa de sucesso do fallback Hound | > 70% |
| Latência média do smart_search | < 5s |
| Latência média do smart_fetch | < 10s |
| Overhead de memória (Hound process) | < 200MB |
| Zero regressões nos scrapers existentes | 100% |

## RISCOS E MITIGAÇÕES

| Risco | Mitigação |
|-------|-----------|
| Hound crasha durante operação | Retry + graceful degradation (scrapers originais continuam) |
| Rate-limit nos backends de busca | HOUND_SEARCH_PROXY + circuit breaker (já built-in no Hound) |
| Conflito de versão Patchright | Hound usa sua própria cópia via pip; isolamento por virtualenv |
| MCP protocol muda | Versions check no startup; fallback para HTTP mode |
| Overhead de memória | Hound fecha browser após 5min idle (configurável) |

## ENTREGÁVEIS

1. `pipeline/scraper/hound/` — módulo completo
2. `pipeline/scraper/hunt_adapter.py` — adapter de integração
3. `tests/test_hound_*.py` — suite de testes
4. `pipeline/scraper/config_hound.json` — config padrão
5. Atualização de `pipeline/requirements.txt` com `hound-mcp[all]`
6. Documentação de uso em `docs/hound-integration.md`

## COMANDO DE VALIDAÇÃO

```bash
# 1. Instalar Hound
pip install hound-mcp[all] && playwright install chromium

# 2. Verificar saúde
hound --doctor

# 3. Testar busca
hound  # inicia servidor MCP
# ou
hound --http --port 8765  # modo HTTP

# 4. Rodar testes do projeto
pytest tests/test_hound_* -v

# 5. Verificar integração
python -m pipeline.scraper.hunt_adapter --dry-run
```

## CONSTRAINTS

- NÃO modificar `StealthTransportEngine` ou seus subclasses
- NÃO modificar `SelfHealingOrganism` diretamente (usar herança)
- NÃO adicionar dependências MCP ao core do projeto
- NÃO remover nenhuma dependência existente
- Manter 100% de compatibilidade retroativa com o pipeline atual
- Hound roda como processo SEPARADO (nunca importar `master_fetch`
  diretamente no código do projeto)
- Toda comunicação com Hound via subprocess ou HTTP
- Logging: usar o logger existente do projeto, não o do Hound

## RESUMO DA ESTRATÉGIA

| Uso | Componente | Integração |
|-----|-----------|------------|
| **Descoberta de fontes** | `SourceDiscovery` | Alimenta `buscador_fontes.py` com fontes novas |
| **Fallback anti-bot** | `FallbackFetch` | `HoundEnhancedOrganism` como subclass do `SelfHealingOrganism` |
| **Mapeamento de sites** | `SiteMapper` | Atualiza endpoints dos scrapers automaticamente |

O Hound roda como **processo isolado** (nunca como lib importada),
mantendo o ecossistema existente intacto.
