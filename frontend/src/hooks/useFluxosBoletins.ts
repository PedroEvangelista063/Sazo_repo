import { useQuery } from '@tanstack/react-query'
import { getFluxosBoletins } from '../services/api'
import type { BoletimFlowFilters } from '../types/domain'

const STALE_TIME = 1000 * 60 * 30 // 30min — boletins CONAB são mensais
const GC_TIME = 1000 * 60 * 60 * 24 // 24h

/**
 * Busca as rotas dos Boletins Logísticos da CONAB (Fase 5 — camada de sync).
 *
 * A queryKey inclui TODOS os filtros para que a troca de produto/mês/ano
 * dispare um novo fetch. Dados do boletim são estáveis (publicação mensal),
 * então staleTime alto (30min) evita refetch desnecessário.
 */
export function useFluxosBoletins(filters: BoletimFlowFilters = {}) {
  return useQuery({
    queryKey: [
      'fluxos-boletins',
      filters.produto ?? '',
      filters.origemUf ?? '',
      filters.destinoUf ?? '',
      filters.anoReferencia ?? '',
      filters.mesReferencia ?? '',
      filters.limit ?? 200,
      filters.offset ?? 0,
    ],
    queryFn: async ({ signal }) => getFluxosBoletins(filters, signal),
    staleTime: STALE_TIME,
    gcTime: GC_TIME,
    retry: 2,
    refetchOnWindowFocus: false,
    refetchOnReconnect: true,
  })
}
