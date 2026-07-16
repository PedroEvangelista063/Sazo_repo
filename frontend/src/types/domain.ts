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
}

export interface RegiaoInfo {
  id: string
  nome: string
  ufs: string[]
  polos: PoloInfo[]
  total_ufs: number
}
