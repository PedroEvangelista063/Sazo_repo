export type StatusCor = 'VERDE' | 'AMARELO' | 'VERMELHO' | 'INSUFICIENTE'

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
  fonte: string
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
