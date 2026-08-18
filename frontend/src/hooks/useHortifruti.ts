import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { api } from '../services/api'
import type {
  ProdutoVarejo,
  SazonalidadeResponse,
  SazonalidadeNacionalResponse,
} from '../types/domain'

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
 * When uf='BR' and no month filter, uses /br-sazonalidade endpoint (12-month grid).
 * Otherwise uses the standard /sazonalidade endpoint.
 */
export function useHortifruti(uf: string = 'SP', ano?: number | null, mes?: number | null) {
  const hasFilter = ano != null && mes != null
  const hasUF = uf && uf !== 'ALL'
  const isBR = uf === 'BR'
  const isBRFull = isBR && !hasFilter

  // BR Nacional full view — 12-month sazonalidade
  const brSazonalidadeQuery = useQuery({
    queryKey: ['br-sazonalidade', ano],
    queryFn: async ({ signal }) => {
      const { data } = await api.get<SazonalidadeNacionalResponse>(
        '/sazonalidade/br-sazonalidade',
        { params: { ano, por_pagina: 1000 }, signal },
      )
      return data
    },
    enabled: isBRFull && ano != null,
    staleTime: STALE_TIME,
    gcTime: GC_TIME,
    retry: 2,
    refetchOnWindowFocus: false,
    refetchOnReconnect: true,
  })

  // Standard meta query (used for UF states and BR with month filter)
  const metaQuery = useQuery({
    queryKey: ['hortifruti-meta', hasUF ? uf : '__all__'],
    queryFn: async ({ signal }) => {
      const params: Record<string, unknown> = { por_pagina: 1000 }
      if (hasUF) params.uf = uf
      const { data } = await api.get<SazonalidadeResponse>('/sazonalidade', { params, signal })
      return data
    },
    enabled: !isBRFull,
    staleTime: STALE_TIME,
    gcTime: GC_TIME,
    retry: 2,
    refetchOnWindowFocus: false,
    refetchOnReconnect: true,
  })

  // Catálogo global (sem filtro de UF) — alimenta a busca do SearchResultsModal
  // em qualquer estado, inclusive BR sem mês, onde a metaQuery fica desabilitada.
  const allQuery = useQuery({
    queryKey: ['hortifruti-all'],
    queryFn: async ({ signal }) => {
      const { data } = await api.get<SazonalidadeResponse>('/sazonalidade', {
        params: { por_pagina: 1000 },
        signal,
      })
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
      const { data } = await api.get<SazonalidadeResponse>('/sazonalidade', { params, signal })
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
    if (!isBRFull && metaQuery.data?.data) return metaQuery.data.data
    return []
  }, [hasFilter, isBRFull, filterQuery.data?.data, metaQuery.data?.data])

  const products = useMemo(() => sortByStatus(displayData), [displayData])
  const allProducts = useMemo(() => sortByStatus(allQuery.data?.data ?? []), [allQuery.data?.data])

  const brSazonalidade = useMemo(() => {
    if (!isBRFull || !brSazonalidadeQuery.data?.data) return null
    return brSazonalidadeQuery.data.data
  }, [isBRFull, brSazonalidadeQuery.data?.data])

  const totalBR = brSazonalidadeQuery.data?.total ?? 0

  return {
    products,
    allProducts,
    brSazonalidade,
    totalBR,
    allIsLoading: allQuery.isLoading,
    allIsError: allQuery.isError,
    refetchAll: allQuery.refetch,
    isLoading: isBRFull
      ? brSazonalidadeQuery.isLoading
      : metaQuery.isLoading || (hasFilter && filterQuery.isLoading && !metaQuery.data),
    isError: isBRFull ? brSazonalidadeQuery.isError : metaQuery.isError || filterQuery.isError,
    data: metaQuery.data ?? filterQuery.data,
  }
}
