/**
 * useSazonalidade — Custom Hook para dados de sazonalidade (React Query v5)
 *
 * SRE/Frontend principles:
 * - staleTime de 12h evita refetch desnecessário em dados que mudam 1x/mês
 * - gcTime de 24h retém dados no cache mesmo após componente desmontar (Offline-First)
 * - Prefetch aquece cache antes da navegação confirmada, zerando perceived latency
 * - useMemo evita reordenação da lista em cada render (estabilidade de referência)
 * - Separação de concerns: UI não conhece axios nem query keys
 */
import { useMemo } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { api } from '../services/api'
import type { SazonalidadeListResponse, ProductSeasonality } from '../types'
import { STATUS_ORDER } from '../types'

const STALE_TIME = 1000 * 60 * 60 * 12
const GC_TIME = 1000 * 60 * 60 * 24

type SazonalidadeQueryKey = readonly ['sazonalidade', string | null, string | null]

/**
 * Ordena produtos por status: VERDE (0) → AMARELO (1) → VERMELHO (2) → INSUFICIENTE (3).
 * A pure function é testável isoladamente sem React.
 */
function sortByStatus(products: ProductSeasonality[]): ProductSeasonality[] {
  return [...products].sort(
    (a, b) => (STATUS_ORDER[a.status_cor] ?? 99) - (STATUS_ORDER[b.status_cor] ?? 99),
  )
}

export function useSazonalidade(uf: string | null, municipio: string | null) {
  const query = useQuery({
    queryKey: ['sazonalidade', uf, municipio] as const satisfies SazonalidadeQueryKey,
    queryFn: async ({ signal }): Promise<SazonalidadeListResponse> => {
      const { data } = await api.get<SazonalidadeListResponse>(
        `/sazonalidade/${uf}/${municipio}`,
        { signal },
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

  /**
   * useMemo estabiliza a referência do array ordenado.
   * Sem ele, ProductGrid receberia uma nova prop a cada render do Dashboard,
   * causando re-renderização desnecessária de todos os ProductCards.
   */
  const sortedProducts = useMemo(
    () => sortByStatus(query.data?.data ?? []),
    [query.data?.data],
  )

  return {
    ...query,
    products: sortedProducts,
  }
}

export function usePrefetchSazonalidade() {
  const queryClient = useQueryClient()

  return (uf: string, municipio: string) => {
    if (!uf || !municipio) return

    queryClient.prefetchQuery({
      queryKey: ['sazonalidade', uf, municipio] as const satisfies SazonalidadeQueryKey,
      queryFn: async ({ signal }) => {
        const { data } = await api.get<SazonalidadeListResponse>(
          `/sazonalidade/${uf}/${municipio}`,
          { signal },
        )
        return data
      },
      staleTime: STALE_TIME,
      gcTime: GC_TIME,
    })
  }
}
