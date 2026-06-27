import { useMemo } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { api } from '../services/api'
import type { ProdutoVarejo, SazonalidadeResponse } from '../types/domain'

const STALE_TIME = 1000 * 60 * 60 * 12
const GC_TIME = 1000 * 60 * 60 * 24

type HortifrutiKey = readonly ['hortifruti', string | null, string | null]

const STATUS_ORDER: Record<string, number> = {
  VERDE: 0,
  AMARELO: 1,
  VERMELHO: 2,
  INSUFICIENTE: 3,
}

function sortByStatus(products: ProdutoVarejo[]): ProdutoVarejo[] {
  return [...products].sort(
    (a, b) => (STATUS_ORDER[a.status_cor] ?? 99) - (STATUS_ORDER[b.status_cor] ?? 99),
  )
}

export function useHortifruti(uf: string | null, municipio: string | null) {
  const query = useQuery({
    queryKey: ['hortifruti', uf, municipio] as const satisfies HortifrutiKey,
    queryFn: async ({ signal }) => {
      const { data } = await api.get<SazonalidadeResponse>(
        `/sazonalidade/${uf}/${municipio}`,
        { params: { categoria: 'ALIMENTO_VAREJO' }, signal },
      )
      return data
    },
    enabled: !!uf && !!municipio,
    staleTime: STALE_TIME,
    gcTime: GC_TIME,
    retry: 2,
    refetchOnWindowFocus: false,
    refetchOnReconnect: true,
  })

  const products = useMemo(
    () => sortByStatus(query.data?.data ?? []),
    [query.data?.data],
  )

  return { ...query, products }
}

export function usePrefetchHortifruti() {
  const queryClient = useQueryClient()
  return (uf: string, municipio: string) => {
    queryClient.prefetchQuery({
      queryKey: ['hortifruti', uf, municipio] as const satisfies HortifrutiKey,
      queryFn: async ({ signal }) => {
        const { data } = await api.get<SazonalidadeResponse>(
          `/sazonalidade/${uf}/${municipio}`,
          { params: { categoria: 'ALIMENTO_VAREJO' }, signal },
        )
        return data
      },
      staleTime: STALE_TIME,
      gcTime: GC_TIME,
    })
  }
}
