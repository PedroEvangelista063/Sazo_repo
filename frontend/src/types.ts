export interface ProductSeasonality {
  id_produto: number
  nome_produto: string
  icone_url: string | null
  uf: string
  municipio: string | null
  municipio_id: string | null
  ano: number
  mes: number
  preco_medio: number
  media_movel_12m: number | null
  indice_sazonalidade: number | null
  status_cor: 'VERDE' | 'AMARELO' | 'VERMELHO' | 'INSUFICIENTE'
  fonte: string
}

export interface SazonalidadeListResponse {
  data: ProductSeasonality[]
  total: number
  pagina: number
  por_pagina: number
}

export const STATUS_ORDER: Record<string, number> = {
  VERDE: 0,
  AMARELO: 1,
  VERMELHO: 2,
  INSUFICIENTE: 3,
}

export const PRODUTO_EMOJI: Record<string, string> = {
  ARROZ: '🍚',
  BANANA: '🍌',
  BATATA: '🥔',
  CAFE: '☕',
  CEBOLA: '🧅',
  CENOURA: '🥕',
  FEIJAO: '🫘',
  LARANJA: '🍊',
  LEITE: '🥛',
  MACA: '🍎',
  MANDIOCA: '🌿',
  MILHO: '🌽',
  OVO: '🥚',
  REPOLHO: '🥬',
  SOJA: '🫘',
  TOMATE: '🍅',
  UVA: '🍇',
  ALFACE: '🥬',
  BETERRA: '🥗',
  PIMENTAO: '🫑',
}

export const UF_LIST = [
  'AC', 'AL', 'AP', 'AM', 'BA', 'CE', 'DF', 'ES', 'GO',
  'MA', 'MT', 'MS', 'MG', 'PA', 'PB', 'PR', 'PE', 'PI',
  'RJ', 'RN', 'RS', 'RO', 'RR', 'SC', 'SP', 'SE', 'TO',
]

export function getProdutoEmoji(nome: string): string {
  const key = nome.toUpperCase().replace(/[^A-Z ]/g, '').trim().split(/\s+/)[0] ?? ''
  return PRODUTO_EMOJI[key] ?? '🛒'
}
