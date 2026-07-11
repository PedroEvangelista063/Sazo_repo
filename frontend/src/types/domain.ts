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
