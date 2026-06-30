export type StatusCor = 'VERDE' | 'AMARELO' | 'VERMELHO' | 'INSUFICIENTE'
export type StatusOferta = 'OFERTA' | 'EQUILIBRADO' | 'ALTA' | 'INSUFICIENTE'

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
  preco_referencia: number | null
  preco_atual: number | null
  usou_fallback_12m: boolean
  status_cor: StatusCor
  status_oferta?: StatusOferta | null
  fonte: string
  categoria: string | null
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
