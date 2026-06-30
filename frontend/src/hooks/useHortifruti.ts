import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { api } from '../services/api'
import type { ProdutoVarejo, SazonalidadeResponse } from '../types/domain'

const STALE_TIME = 1000 * 60 * 60 * 12
const GC_TIME = 1000 * 60 * 60 * 24

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

export function useHortifruti() {
  const query = useQuery({
    queryKey: ['hortifruti'],
    queryFn: async ({ signal }) => {
      const { data } = await api.get<SazonalidadeResponse>(
        '/sazonalidade/SP/São Paulo',
        { signal },
      )
      return data
    },
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
