import { useQuery } from '@tanstack/react-query'
import { api } from '../services/api'
import type { ProdutoVarejo } from '../types/domain'

export interface ProdutoComPreco extends ProdutoVarejo {
  preco_referencia: number | null
  preco_atual: number | null
  variacao_pct: number | null
  preco_mes_anterior: number | null
  tendencia_futura: 'QUEDA' | 'ALTA' | 'ESTAVEL' | null
}

export interface SazonalidadeComPrecoResponse {
  data: ProdutoComPreco[]
  total: number
  pagina: number
  por_pagina: number
}

const STALE_TIME = 1000 * 60 * 5
const GC_TIME = 1000 * 60 * 30

export function useSazonalidadeComPreco(
  uf: string = 'SP',
  categoria?: string | null,
  ano?: number | null,
  mes?: number | null,
  pagina: number = 1,
  por_pagina: number = 500
) {
  const hasUF = Boolean(uf && uf !== 'ALL')

  return useQuery<SazonalidadeComPrecoResponse, Error>({
    queryKey: ['sazonalidade-com-preco', hasUF ? uf : '__all__', categoria, ano, mes, pagina, por_pagina],
    queryFn: async ({ signal }) => {
      const params: Record<string, unknown> = { pagina, por_pagina }
      if (hasUF) params.uf = uf
      if (categoria) params.categoria = categoria
      if (ano != null) params.ano = ano
      if (mes != null) params.mes = mes

      const { data } = await api.get<SazonalidadeComPrecoResponse>('/sazonalidade/com-preco', {
        params,
        signal,
      })
      return data
    },
    enabled: hasUF,
    staleTime: STALE_TIME,
    gcTime: GC_TIME,
    retry: 2,
    refetchOnWindowFocus: false,
    refetchOnReconnect: true,
  })
}