export type StatusCor = 'VERDE' | 'AMARELO' | 'VERMELHO'

export interface ProdutoVarejo {
  id_produto: number
  nome_produto: string
  icone_url: string | null
  uf: string
  municipio: string | null
  municipio_id: string | null
  ano: number
  mes: number
  data_referencia_atual: string
  preco_estimado: boolean
  usou_fallback_12m: boolean
  status_cor: StatusCor
  fonte: string | null
  categoria: string | null
  is_forecast: boolean
  confianca_baseline: number | null
  tendencia_futura: 'QUEDA' | 'ALTA' | 'ESTAVEL' | null
  regiao: string | null
  // ── Transparência temporal (V17 — ano âncora real) ──
  ano_referencia?: number | null
  tipo_dado?: string | null
  mensagem_transparencia?: string | null
  is_dado_legado?: boolean
}

export interface Categoria {
  nome: string
  descricao: string | null
  total_produtos: number
  icone: string | null
}

export interface CategoriaListResponse {
  data: Categoria[]
  total: number
}

export interface SazonalidadeResponse {
  data: ProdutoVarejo[]
  total: number
  pagina: number
  por_pagina: number
}

export interface MunicipioResponse {
  data: string[]
  total: number
}

export interface MesSazonalidade {
  mes: number
  status_cor: StatusCor
  is_forecast: boolean
  baseline_confianca: number | null
  forecast_method: string | null
  calculado_em: string | null
  // ── Transparência temporal (V17 — ano âncora real) ──
  ano_referencia?: number | null
  tipo_dado?: string | null
  mensagem_transparencia?: string | null
  is_dado_legado?: boolean
}

export interface SazonalidadeNacionalItem {
  produto: string
  classificao_produto: string | null
  categoria: string | null
  meses: MesSazonalidade[]
  total_ufs: number
}

export interface SazonalidadeNacionalResponse {
  data: SazonalidadeNacionalItem[]
  total: number
  pagina: number
  por_pagina: number
}

// ── Regional types ──
export interface PoloInfo {
  nome: string
  uf: string
  municipio: string
  fonte_id: string | null
  papel?: string | null
}

export interface RegiaoInfo {
  id: string
  nome: string
  papel?: string | null
  ufs: string[]
  polos: PoloInfo[]
  total_ufs: number
}

// ── Fluxos de Abastecimento ──
export interface FlowItem {
  id: number
  item: string
  origem_uf: string
  origem_polo: string
  destino_regiao_id: string
  destino_uf: string
  meses: number[]
  sazonalidade: string
  preco_referencial: string
  tipo: string
  descricao_tipo?: string | null
  periodicidade?: string | null
  regiao_destino_nome?: string | null
  // Compatibilidade com componentes existentes (valores padrao)
  categoria?: string
  cor_indicadora?: string
  ano_referencia?: number
}

export interface FlowListResponse {
  data: FlowItem[]
  total: number
}

// ── Mapa ──
export interface UFCoords {
  uf: string
  x: number
  y: number
}

export interface ArcFlow {
  from: UFCoords
  to: UFCoords
  flow: FlowItem
}
