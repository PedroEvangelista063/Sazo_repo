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
export function useHortifruti(ano?: number | null, mes?: number | null) {
  const hasFilter = ano != null && mes != null

  const metaQuery = useQuery({
    queryKey: ['hortifruti-meta'],
    queryFn: async ({ signal }) => {
      const { data } = await api.get<SazonalidadeResponse>(
        '/sazonalidade',
        { params: { uf: 'SP', por_pagina: 500 }, signal },
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
    queryKey: ['hortifruti-filter', ano, mes],
    queryFn: async ({ signal }) => {
      const params: Record<string, unknown> = { uf: 'SP', por_pagina: 500, ano, mes }
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
