# Plano de Implementação — Cadeia de Abastecimento Logístico

> **Baseado na** *Biblioteca de Referências: Cadeia de Abastecimento Logístico e Fluxos de Alimentos (Brasil)*
> **Projeto:** Quero Comprar — Sazonalidade de Hortigranjeiros
> **Data:** 2026-07-16

---

## Sumário

1. [Mapeamento: Biblioteca × Projeto Atual](#1-mapeamento-biblioteca--projeto-atual)
2. [Visão Geral dos Pacotes](#2-visão-geral-dos-pacotes)
3. [Pacote 1: Dados de Configuração + API](#3-pacote-1-dados-de-configuração--api)
4. [Pacote 2: Frontend — Types + Hooks](#4-pacote-2-frontend--types--hooks)
5. [Pacote 3: Frontend — Linhas de Fluxo no Mapa](#5-pacote-3-frontend--linhas-de-fluxo-no-mapa)
6. [Pacote 4: Frontend — Seção Fluxos no RegiaoPanel](#6-pacote-4-frontend--seção-fluxos-no-regiaopanel)
7. [Pacote 5: Frontend — Badge de Origem no ProductCard](#7-pacote-5-frontend--badge-de-origem-no-productcard)
8. [Pacote 6: Extensão do regions.json](#8-pacote-6-extensão-do-regionsjson)
9. [Ordem de Execução](#9-ordem-de-execução)

---

## 1. Mapeamento: Biblioteca × Projeto Atual

### Hierarquia Geográfica

| Biblioteca | Projeto Atual | Gap |
|---|---|---|
| Regiões (5) | ✅ `config/regions.json` | OK |
| UFs por região | ✅ `regions.json` | OK |
| Polos CEASA | ⚠️ 13 polos listados | Documento cita mais (Gurupi/TO, Anápolis/GO, Petrolina/PE, Vacaria/RS, etc.) |
| Papel no Sistema | ❌ Não existe | **Adicionar campo `papel`** em cada região e polo |

### Taxonomia de Produtos

| Categoria | Projeto | Observação |
|---|---|---|
| Hortifrúti | ✅ `dim_produto` | Já coberto |
| Carnes | ❌ Não no B2C | `classificao_produto` exclui INSUMO_AGRICOLA |
| Peixes | ❌ Não no B2C | Tambaqui/Pintado/Tilápia não existem |
| Grãos e Sementes | ⚠️ Parcial | Arroz, feijão, milho existem; soja é INSUMO_AGRICOLA |

### Matriz de Fluxos — ESSA É A GRANDE NOVIDADE

Nada disso existe no projeto hoje. **10 registros seed** conectando Origem → Destino → Item → Meses → Sazonalidade → Cor.

---

## 2. Visão Geral dos Pacotes

```
┌─────────────────────────────────────────────────────────────────┐
│                      PONTOS DE INSERÇÃO                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  A. config/flows.json (NOVO)                                     │
│     └── Seed dos 10 fluxos + espaço pra crescer                 │
│                                                                  │
│  B. backend -> NOVO endpoint GET /api/v1/fluxos                  │
│     └── Filtro por destino, origem, produto                      │
│     └── NOVO schema: FlowItem, FlowListResponse                  │
│                                                                  │
│  C. frontend -> BrasilMap.tsx (linhas de fluxo no mapa)         │
│     └── Quando seleciona TO, desenhar arcos:                    │
│         GO→TO (tomate), PE/BA→TO (manga), PR→TO (batata)        │
│     └── Cor do arco = cor_indicadora (azul = importado)         │
│     └── Arco verde (#059669) = autossuficiente (sem seta)       │
│                                                                  │
│  D. frontend -> RegiaoPanel.tsx (seção "Fluxos")                │
│     └── Abaixo dos polos CEASA: "Fluxos de Abastecimento"       │
│     └── Tabela: Item | Vem de | Período | Preço | Sazonalidade  │
│                                                                  │
│  E. frontend -> ProductCard.tsx (badge de origem)               │
│     └── Se produto tem fluxo conhecido: badge com UF de origem  │
│                                                                  │
│  F. config/regions.json (ATUALIZAR)                              │
│     └── Novos polos + campo papel                                │
└─────────────────────────────────────────────────────────────────┘
```

### Decisão Arquitetural

**Config-only + API (sem migration no banco):**

```
config/flows.json ─→ GET /api/v1/fluxos ─→ frontend hooks ─→ visualização
```

Motivos:
1. Dados de fluxo são **referenciais/conceituais**, não operacionais
2. Segue o padrão existente de `config/regions.json` → API → frontend
3. Zero risco de quebrar o pipeline ou o banco
4. Pode ser evoluído depois pra tabela no banco se precisar join com dados reais de preço

---

## 3. Pacote 1: Dados de Configuração + API

### 3.1 `config/flows.json` (NOVO)

```json
{
  "_metadata": {
    "descricao": "Matriz de fluxos de abastecimento logístico por produto",
    "versao": "1.0",
    "atualizado_em": "2026-07-16",
    "fontes": "Biblioteca de Referências: Cadeia de Abastecimento Logístico"
  },
  "fluxos": [
    {
      "id": 1, "item": "Tomate", "categoria": "Hortifrúti",
      "origem_uf": "GO", "origem_polo": "CEASA-GO",
      "destino_regiao_id": "norte", "destino_uf": "TO",
      "meses": [1,2,3,4,5,6,7,8,9,10,11,12],
      "sazonalidade": "baixa", "preco_referencial": "Médio",
      "cor_indicadora": "#1E3A8A", "tipo": "importado",
      "ano_referencia": 2026
    },
    {
      "id": 2, "item": "Manga", "categoria": "Hortifrúti",
      "origem_uf": "PE", "origem_polo": "Petrolina/Juazeiro",
      "destino_regiao_id": "norte", "destino_uf": "TO",
      "meses": [9,10,11,12],
      "sazonalidade": "alta", "preco_referencial": "Baixo",
      "cor_indicadora": "#1E3A8A", "tipo": "importado",
      "ano_referencia": 2026
    },
    {
      "id": 3, "item": "Melancia", "categoria": "Hortifrúti",
      "origem_uf": "TO", "origem_polo": "Lagoa da Confusão",
      "destino_regiao_id": "sudeste", "destino_uf": "SP",
      "meses": [6,7,8,9],
      "sazonalidade": "alta", "preco_referencial": "Baixo",
      "cor_indicadora": "#10B981", "tipo": "exportado",
      "ano_referencia": 2026
    },
    {
      "id": 4, "item": "Maçã", "categoria": "Hortifrúti",
      "origem_uf": "RS", "origem_polo": "Vacaria",
      "destino_regiao_id": "norte", "destino_uf": "TO",
      "meses": [3,4,5,6],
      "sazonalidade": "media", "preco_referencial": "Alto",
      "cor_indicadora": "#3B82F6", "tipo": "importado",
      "ano_referencia": 2026
    },
    {
      "id": 5, "item": "Carne Bovina", "categoria": "Carnes",
      "origem_uf": "TO", "origem_polo": "Araguaína",
      "destino_regiao_id": "norte", "destino_uf": "TO",
      "meses": [1,2,3,4,5,6,7,8,9,10,11,12],
      "sazonalidade": "nenhuma", "preco_referencial": "Baixo",
      "cor_indicadora": "#059669", "tipo": "autossuficiente",
      "ano_referencia": 2026
    },
    {
      "id": 6, "item": "Arroz", "categoria": "Grãos",
      "origem_uf": "TO", "origem_polo": "Formoso do Araguaia",
      "destino_regiao_id": "norte", "destino_uf": "TO",
      "meses": [1,2,3,4,5,6,7,8,9,10,11,12],
      "sazonalidade": "nenhuma", "preco_referencial": "Baixo",
      "cor_indicadora": "#059669", "tipo": "autossuficiente",
      "ano_referencia": 2026
    },
    {
      "id": 7, "item": "Batata", "categoria": "Hortifrúti",
      "origem_uf": "PR", "origem_polo": "CEASA Curitiba",
      "destino_regiao_id": "norte", "destino_uf": "TO",
      "meses": [1,2,3,4,5,6,7,8,9,10,11,12],
      "sazonalidade": "alta", "preco_referencial": "Alto",
      "cor_indicadora": "#1E3A8A", "tipo": "importado",
      "ano_referencia": 2026
    },
    {
      "id": 8, "item": "Tambaqui", "categoria": "Peixes",
      "origem_uf": "TO", "origem_polo": "Porto Nacional",
      "destino_regiao_id": "norte", "destino_uf": "TO",
      "meses": [1,2,3,4],
      "sazonalidade": "media", "preco_referencial": "Médio",
      "cor_indicadora": "#059669", "tipo": "autossuficiente",
      "ano_referencia": 2026
    },
    {
      "id": 9, "item": "Ovos", "categoria": "Proteína Animal",
      "origem_uf": "GO", "origem_polo": "Anápolis",
      "destino_regiao_id": "norte", "destino_uf": "TO",
      "meses": [1,2,3,4,5,6,7,8,9,10,11,12],
      "sazonalidade": "nenhuma", "preco_referencial": "Médio",
      "cor_indicadora": "#1E3A8A", "tipo": "importado",
      "ano_referencia": 2026
    },
    {
      "id": 10, "item": "Feijão", "categoria": "Grãos",
      "origem_uf": "MG", "origem_polo": "Unaí",
      "destino_regiao_id": "norte", "destino_uf": "TO",
      "meses": [1,2,3,4,5],
      "sazonalidade": "alta", "preco_referencial": "Alto",
      "cor_indicadora": "#3B82F6", "tipo": "importado",
      "ano_referencia": 2026
    }
  ]
}
```

### 3.2 `backend/app/api/v1/endpoints/fluxos.py` (NOVO)

```python
from fastapi import APIRouter, Query
import json
from pathlib import Path

from app.schemas.responses import FlowItem, FlowListResponse

router = APIRouter(tags=["fluxos"])

FLOWS_PATH = Path(__file__).parents[4] / "config" / "flows.json"


def _carregar_fluxos() -> list[dict]:
    with open(FLOWS_PATH, encoding="utf-8") as f:
        return json.load(f)["fluxos"]


@router.get("/fluxos", response_model=FlowListResponse)
async def listar_fluxos(
    destino_uf: str | None = Query(None, description="Filtrar por UF de destino"),
    origem_uf: str | None = Query(None, description="Filtrar por UF de origem"),
    item: str | None = Query(None, description="Filtrar por nome do produto"),
    destino_regiao: str | None = Query(None, description="Filtrar por ID da região de destino"),
    tipo: str | None = Query(None, description="Filtrar por tipo: importado, exportado, autossuficiente"),
):
    fluxos = _carregar_fluxos()

    if destino_uf:
        fluxos = [f for f in fluxos if f["destino_uf"] == destino_uf.upper()]
    if origem_uf:
        fluxos = [f for f in fluxos if f["origem_uf"] == origem_uf.upper()]
    if item:
        fluxos = [f for f in fluxos if item.lower() in f["item"].lower()]
    if destino_regiao:
        fluxos = [f for f in fluxos if f["destino_regiao_id"] == destino_regiao]
    if tipo:
        fluxos = [f for f in fluxos if f["tipo"] == tipo]

    return FlowListResponse(data=[FlowItem(**f) for f in fluxos], total=len(fluxos))
```

### 3.3 `backend/app/schemas/responses.py` — ADICIONAR NO FINAL

```python
class FlowItem(BaseModel):
    model_config = ConfigDict(frozen=True)

    id: int
    item: str
    categoria: str
    origem_uf: str
    origem_polo: str
    destino_regiao_id: str
    destino_uf: str
    meses: list[int]
    sazonalidade: Literal["nenhuma", "baixa", "media", "alta"]
    preco_referencial: Literal["Baixo", "Médio", "Alto"]
    cor_indicadora: str
    tipo: Literal["importado", "exportado", "autossuficiente"]
    ano_referencia: int


class FlowListResponse(BaseModel):
    model_config = ConfigDict(frozen=True)

    data: list[FlowItem]
    total: int
```

### 3.4 `backend/app/main.py` — ADICIONAR ROTA

```python
from app.api.v1.endpoints.fluxos import router as fluxos_router

# junto com os outros routers:
app.include_router(fluxos_router, prefix="/api/v1")
```

---

## 4. Pacote 2: Frontend — Types + Hooks

### 4.1 `frontend/src/types/domain.ts` — ADICIONAR

```typescript
export interface FlowItem {
  id: number
  item: string
  categoria: string
  origem_uf: string
  origem_polo: string
  destino_regiao_id: string
  destino_uf: string
  meses: number[]
  sazonalidade: 'nenhuma' | 'baixa' | 'media' | 'alta'
  preco_referencial: 'Baixo' | 'Médio' | 'Alto'
  cor_indicadora: string
  tipo: 'importado' | 'exportado' | 'autossuficiente'
  ano_referencia: number
}

export interface FlowListResponse {
  data: FlowItem[]
  total: number
}
```

### 4.2 `frontend/src/hooks/useFluxos.ts` (NOVO)

```typescript
import { useQuery } from '@tanstack/react-query'
import { api } from '@/services/api'
import type { FlowItem } from '@/types/domain'

interface UseFluxosParams {
  destino_uf?: string
  origem_uf?: string
  item?: string
  destino_regiao?: string
  tipo?: string
}

export function useFluxos(params: UseFluxosParams = {}) {
  const qs = new URLSearchParams()
  if (params.destino_uf) qs.set('destino_uf', params.destino_uf)
  if (params.origem_uf) qs.set('origem_uf', params.origem_uf)
  if (params.item) qs.set('item', params.item)
  if (params.destino_regiao) qs.set('destino_regiao', params.destino_regiao)
  if (params.tipo) qs.set('tipo', params.tipo)

  const query = qs.toString()
  const key = ['fluxos', params]

  return useQuery({
    queryKey: key,
    queryFn: async () => {
      const { data } = await api.get<{ data: FlowItem[]; total: number }>(
        `/api/v1/fluxos${query ? `?${query}` : ''}`
      )
      return data.data
    },
    staleTime: 24 * 60 * 60 * 1000,
    gcTime: 7 * 24 * 60 * 60 * 1000,
  })
}
```

---

## 5. Pacote 3: Frontend — Linhas de Fluxo no Mapa

### `BrasilMapProps` — ADICIONAR PROP

```typescript
interface BrasilMapProps {
  selectedRegion: string | null
  onRegionClick: (regionId: string) => void
  className?: string
  fluxos?: FlowItem[]   // <-- NOVO
}
```

### Funções auxiliares — ADICIONAR APÓS `UFS`

```typescript
function getUFCenter(uf: string): { cx: number; cy: number } | null {
  const found = UFS.find(u => u.uf === uf)
  return found ? { cx: found.cx, cy: found.cy } : null
}

function getRegiaoCenter(regiaoId: string): { x: number; y: number } {
  const ufs = UFS.filter(u => u.regiao === regiaoId)
  return {
    x: ufs.reduce((s, u) => s + u.cx, 0) / ufs.length,
    y: ufs.reduce((s, u) => s + u.cy, 0) / ufs.length,
  }
}
```

### Renderização de arcos — ADICIONAR ANTES DA LEGENDA (após o `</svg>`)

```tsx
{/* Arcos de fluxo de abastecimento */}
{fluxos?.map((fluxo) => {
  const origem = getUFCenter(fluxo.origem_uf)
  if (!origem) return null
  const dest = getRegiaoCenter(fluxo.destino_regiao_id)

  const midX = (origem.cx + dest.x) / 2
  const midY = Math.min(origem.cy, dest.y) - 50

  return fluxo.tipo !== 'autossuficiente' && (
    <g key={`flow-${fluxo.id}`}>
      {/* Linha tracejada animada */}
      <motion.path
        d={`M${origem.cx},${origem.cy} Q${midX},${midY} ${dest.x},${dest.y}`}
        fill="none"
        stroke={fluxo.cor_indicadora}
        strokeWidth={2}
        strokeOpacity={0.5}
        strokeDasharray="6 4"
        initial={{ pathLength: 0 }}
        animate={{ pathLength: 1 }}
        transition={{ duration: 1.5, ease: 'easeInOut' }}
        className="pointer-events-none"
      />
      {/* Seta no destino */}
      <polygon
        points={`${dest.x - 6},${dest.y - 4} ${dest.x},${dest.y} ${dest.x - 6},${dest.y + 4}`}
        fill={fluxo.cor_indicadora}
        fillOpacity={0.6}
        className="pointer-events-none"
      />
    </g>
  )
})}
```

### `SupermercadoView.tsx` — INTEGRAR FLUXOS NO MAPA

```typescript
import { useFluxos } from '@/hooks/useFluxos'

// dentro do componente:
const { data: fluxos } = useFluxos(
  selectedRegion ? { destino_regiao: selectedRegion } : {}
)

// no JSX do BrasilMap:
<BrasilMap
  selectedRegion={selectedRegion}
  onRegionClick={(id) => setSelectedRegion(selectedRegion === id ? null : id)}
  fluxos={fluxos}
/>
```

---

## 6. Pacote 4: Frontend — Seção Fluxos no RegiaoPanel

### `RegiaoPanelProps` — ADICIONAR PROP

```typescript
interface RegiaoPanelProps {
  // ... props existentes
  fluxos?: FlowItem[]   // <-- NOVO
}
```

### Seção de fluxos — ADICIONAR APÓS a lista de polos

```tsx
{fluxos && fluxos.length > 0 && (
  <div className="mt-4 space-y-2">
    <p className="text-[11px] font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide">
      Fluxos de Abastecimento
    </p>
    <div className="space-y-1">
      {fluxos.map((fluxo) => (
        <div
          key={fluxo.id}
          className="flex items-center gap-2 px-2.5 py-1.5 rounded-lg text-sm bg-gray-50 dark:bg-gray-700/30"
        >
          <span
            className="w-2.5 h-2.5 rounded-full shrink-0"
            style={{ backgroundColor: fluxo.cor_indicadora }}
          />
          <span className="font-medium text-gray-800 dark:text-gray-200">
            {fluxo.item}
          </span>
          <span className="text-gray-400 text-xs">
            {fluxo.tipo === 'autossuficiente'
              ? 'Produção local'
              : `Vem de ${fluxo.origem_uf} (${fluxo.origem_polo})`}
          </span>
          {fluxo.sazonalidade !== 'nenhuma' && (
            <span className="text-[10px] text-gray-400 ml-auto">
              {fluxo.meses.map(m => {
                const meses = ['Jan','Fev','Mar','Abr','Mai','Jun',
                               'Jul','Ago','Set','Out','Nov','Dez']
                return meses[m - 1]
              }).join(', ')}
            </span>
          )}
        </div>
      ))}
    </div>
  </div>
)}
```

### `SupermercadoView.tsx` — PASSAR FLUXOS PRO RegiaoPanel

```typescript
<RegiaoPanel
  regiao={regioes?.find((r) => r.id === selectedRegion) ?? null}
  produtos={regiaoResumo?.data ?? []}
  isLoading={regiaoLoading}
  isError={regiaoError}
  onClose={() => setSelectedRegion(null)}
  onPoloClick={handlePoloClick}
  fluxos={fluxos}
/>
```

---

## 7. Pacote 5: Frontend — Badge de Origem no ProductCard

### `ProductCardProps` — ADICIONAR PROP

```typescript
interface ProductCardProps {
  product: ProdutoVarejo
  isSelected?: boolean
  onToggle?: () => void
  fluxoOrigem?: FlowItem   // <-- NOVO
}
```

### Badge de origem — ADICIONAR ENTRE EMOJI E NOME

```typescript
{fluxoOrigem && (
  <span
    className="text-[9px] px-1.5 py-0.5 rounded-full font-medium mb-0.5"
    style={{
      backgroundColor: `${fluxoOrigem.cor_indicadora}18`,
      color: fluxoOrigem.cor_indicadora,
    }}
  >
    {fluxoOrigem.tipo === 'autossuficiente'
      ? '📍 Local'
      : `🚚 ${fluxoOrigem.origem_uf}`}
  </span>
)}
```

### `SupermercadoView.tsx` — RESOLVER FLUXO PRA CADA PRODUTO

```typescript
const fluxoMap = useMemo(() => {
  if (!fluxos || !fluxos.length) return {} as Record<string, FlowItem>
  const map: Record<string, FlowItem> = {}
  for (const f of fluxos) {
    map[f.item.toUpperCase()] = f
  }
  return map
}, [fluxos])

// no ProductCard:
<ProductCard
  product={p}
  fluxoOrigem={fluxoMap[p.nome_produto.toUpperCase()]}
  isSelected={selectedProducts.includes(p.nome_produto)}
  onToggle={() => ...}
/>
```

---

## 8. Pacote 6: Extensão do regions.json

### `config/regions.json` — ATUALIZAR

Substituir o conteúdo atual por:

```json
{
  "regioes": [
    {
      "id": "norte",
      "nome": "Norte",
      "papel": "transicao",
      "ufs": ["AC", "AM", "AP", "PA", "RO", "RR", "TO"],
      "polos": [
        { "nome": "Gurupi", "uf": "TO", "municipio": "Gurupi", "fonte_id": null, "papel": "distribuidor_local" },
        { "nome": "Palmas", "uf": "TO", "municipio": "Palmas", "fonte_id": null, "papel": "consumidor" },
        { "nome": "Araguaína", "uf": "TO", "municipio": "Araguaína", "fonte_id": null, "papel": "produtor_pecuaria" },
        { "nome": "Lagoa da Confusão", "uf": "TO", "municipio": "Lagoa da Confusão", "fonte_id": null, "papel": "produtor_graos" },
        { "nome": "Porto Nacional", "uf": "TO", "municipio": "Porto Nacional", "fonte_id": null, "papel": "produtor_pesca" },
        { "nome": "Manaus", "uf": "AM", "municipio": "Manaus", "fonte_id": null, "papel": "consumidor" },
        { "nome": "Belém", "uf": "PA", "municipio": "Belém", "fonte_id": null, "papel": "consumidor" }
      ],
      "total_ufs": 7
    },
    {
      "id": "nordeste",
      "nome": "Nordeste",
      "papel": "exportador_frutas",
      "ufs": ["AL", "BA", "CE", "MA", "PB", "PE", "PI", "RN", "SE"],
      "polos": [
        { "nome": "Petrolina/Juazeiro", "uf": "PE", "municipio": "Petrolina", "fonte_id": null, "papel": "exportador_nacional" },
        { "nome": "CEASA-PE", "uf": "PE", "municipio": "Recife", "fonte_id": "ceasa_pe", "papel": "distribuidor" },
        { "nome": "CEASA-BA", "uf": "BA", "municipio": "Salvador", "fonte_id": "ceasa_ba", "papel": "distribuidor" },
        { "nome": "CEASA-RN", "uf": "RN", "municipio": "Natal", "fonte_id": "ceasa_rn", "papel": "distribuidor" }
      ],
      "total_ufs": 9
    },
    {
      "id": "centro-oeste",
      "nome": "Centro-Oeste",
      "papel": "hub_central",
      "ufs": ["DF", "GO", "MS", "MT"],
      "polos": [
        { "nome": "CEASA-GO", "uf": "GO", "municipio": "Goiânia", "fonte_id": "ceasa_go", "papel": "hub_nacional" },
        { "nome": "Anápolis", "uf": "GO", "municipio": "Anápolis", "fonte_id": null, "papel": "polo_agroindustrial" },
        { "nome": "CEASA-DF", "uf": "DF", "municipio": "Brasília", "fonte_id": "ceasa_df", "papel": "consumidor" },
        { "nome": "IMEA-MT", "uf": "MT", "municipio": "Cuiabá", "fonte_id": "imea_mt", "papel": "produtor_graos" },
        { "nome": "CEASA-MS", "uf": "MS", "municipio": "Campo Grande", "fonte_id": "ceasa_ms", "papel": "distribuidor" },
        { "nome": "Unaí", "uf": "MG", "municipio": "Unaí", "fonte_id": null, "papel": "produtor_graos" }
      ],
      "total_ufs": 4
    },
    {
      "id": "sudeste",
      "nome": "Sudeste",
      "papel": "hub_consolidador",
      "ufs": ["ES", "MG", "RJ", "SP"],
      "polos": [
        { "nome": "CEAGESP", "uf": "SP", "municipio": "São Paulo", "fonte_id": "ceagesp", "papel": "hub_consolidador" },
        { "nome": "CEASA-MG", "uf": "MG", "municipio": "Contagem", "fonte_id": "ceasa_mg", "papel": "distribuidor" },
        { "nome": "CEASA-ES", "uf": "ES", "municipio": "Cariacica", "fonte_id": "ceasa_es", "papel": "distribuidor" },
        { "nome": "CEASA-RJ", "uf": "RJ", "municipio": "Rio de Janeiro", "fonte_id": null, "papel": "consumidor" }
      ],
      "total_ufs": 4
    },
    {
      "id": "sul",
      "nome": "Sul",
      "papel": "exportador_clima_frio",
      "ufs": ["PR", "RS", "SC"],
      "polos": [
        { "nome": "CEASA-PR", "uf": "PR", "municipio": "Curitiba", "fonte_id": "ceasa_pr", "papel": "distribuidor" },
        { "nome": "Vacaria", "uf": "RS", "municipio": "Vacaria", "fonte_id": null, "papel": "produtor_frutas_frio" },
        { "nome": "CEASA-RS", "uf": "RS", "municipio": "Porto Alegre", "fonte_id": "ceasa_rs", "papel": "distribuidor" }
      ],
      "total_ufs": 3
    }
  ]
}
```

### Ajuste no backend `regioes.py`

O schema `RegiaoInfo` precisa do campo `papel` e `PoloInfo` também:

```python
class PoloInfo(BaseModel):
    model_config = ConfigDict(frozen=True)
    nome: str
    uf: str
    municipio: str
    fonte_id: str | None
    papel: str | None = None  # <-- NOVO

class RegiaoInfo(BaseModel):
    model_config = ConfigDict(frozen=True)
    id: str
    nome: str
    papel: str | None = None  # <-- NOVO
    ufs: list[str]
    polos: list[PoloInfo]
    total_ufs: int
```

### Ajuste no frontend `domain.ts`

```typescript
export interface PoloInfo {
  nome: string
  uf: string
  municipio: string
  fonte_id: string | null
  papel?: string        // <-- NOVO
}

export interface RegiaoInfo {
  id: string
  nome: string
  papel?: string        // <-- NOVO
  ufs: string[]
  polos: PoloInfo[]
  total_ufs: number
}
```

---

## 9. Ordem de Execução

| # | Pacote | Arquivos | tipo |
|---|--------|----------|------|
| 1 | Pacote 6 | `config/regions.json` | UPDATE |
| 2 | Pacote 1 | `config/flows.json` | CREATE |
| 3 | Pacote 1 | `backend/app/schemas/responses.py` | UPDATE |
| 4 | Pacote 1 | `backend/app/api/v1/endpoints/fluxos.py` | CREATE |
| 5 | Pacote 1 | `backend/app/main.py` | UPDATE |
| 6 | Pacote 2 | `frontend/src/types/domain.ts` | UPDATE |
| 7 | Pacote 2 | `frontend/src/hooks/useFluxos.ts` | CREATE |
| 8 | Pacote 3 | `frontend/src/components/BrasilMap.tsx` | UPDATE |
| 9 | Pacote 4 | `frontend/src/components/RegiaoPanel.tsx` | UPDATE |
| 10 | Pacote 5 | `frontend/src/components/ProductCard.tsx` | UPDATE |
| 11 | Pacotes 3-4-5 | `frontend/src/pages/SupermercadoView.tsx` | UPDATE |

### Dependências

```
Pacote 6 (regions.json) → independente, pode ser primeiro
Pacote 1 (flows.json + API) → independente da frontend
Pacote 2 (types + hooks) → depende de Pacote 1 (API pronta)
Pacote 3 (mapa) → depende de Pacote 2
Pacote 4 (painel) → depende de Pacote 2
Pacote 5 (cards) → depende de Pacote 2
```

**Ordem sugerida**: Pacote 6 → Pacote 1 → Pacote 2 → Pacotes 3+4+5 (paralelo)

---

## Histórico

| Data | Versão | Descrição |
|------|--------|-----------|
| 2026-07-16 | 1.0 | Plano inicial — 6 pacotes, 11 arquivos |
