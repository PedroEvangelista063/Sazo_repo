import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { api } from '../services/api'
import type { ProdutoVarejo, SazonalidadeResponse } from '../types/domain'

const STALE_TIME = 1000 * 60 * 5
const GC_TIME = 1000 * 60 * 30

const STATUS_ORDER: Record<string, number> = {
  VERDE: 0,
  AMARELO: 1,
  VERMELHO: 2,
}

function sortByStatus(products: ProdutoVarejo[]): ProdutoVarejo[] {
  return [...products].sort(
    (a, b) => (STATUS_ORDER[a.status_cor] ?? 99) - (STATUS_ORDER[b.status_cor] ?? 99),
  )
}

/**
 * Fetches sazonalidade data.
 * @param ano  optional year filter
 * @param mes  optional month filter — when set together with ano,
 *             triggers dynamic per-month computation on the backend.
 *
 * Returns:
 *  - `products`     – the actively displayed list (honors ano+mes when both set)
 *  - `allProducts`  – the full unfiltered snapshot (for calendar / filter chips)
 */
export function useHortifruti(uf: string = 'SP', ano?: number | null, mes?: number | null) {
  const hasFilter = ano != null && mes != null
  const hasUF = uf && uf !== 'ALL'

  const metaQuery = useQuery({
    queryKey: ['hortifruti-meta', hasUF ? uf : '__all__'],
    queryFn: async ({ signal }) => {
      const params: Record<string, unknown> = { por_pagina: 1000 }
      if (hasUF) params.uf = uf
      const { data } = await api.get<SazonalidadeResponse>(
        '/sazonalidade',
        { params, signal },
      )
      return data
    },
    staleTime: STALE_TIME,
    gcTime: GC_TIME,
    retry: 2,
    refetchOnWindowFocus: false,
    refetchOnReconnect: true,
  })

  const filterQuery = useQuery({
    queryKey: ['hortifruti-filter', hasUF ? uf : '__all__', ano, mes],
    queryFn: async ({ signal }) => {
      const params: Record<string, unknown> = { por_pagina: 1000, ano, mes }
      if (hasUF) params.uf = uf
      const { data } = await api.get<SazonalidadeResponse>(
        '/sazonalidade',
        { params, signal },
      )
      return data
    },
    enabled: hasFilter,
    staleTime: STALE_TIME,
    gcTime: GC_TIME,
    retry: 2,
    refetchOnWindowFocus: false,
    refetchOnReconnect: true,
  })

  const displayData = useMemo(() => {
    if (hasFilter && filterQuery.data?.data) return filterQuery.data.data
    return metaQuery.data?.data ?? []
  }, [hasFilter, filterQuery.data?.data, metaQuery.data?.data])

  const products = useMemo(() => sortByStatus(displayData), [displayData])
  const allProducts = useMemo(
    () => sortByStatus(metaQuery.data?.data ?? []),
    [metaQuery.data?.data],
  )

  return {
    products,
    allProducts,
    isLoading: metaQuery.isLoading || (hasFilter && filterQuery.isLoading && !metaQuery.data),
    isError: metaQuery.isError || filterQuery.isError,
    data: metaQuery.data ?? filterQuery.data,
  }
}
