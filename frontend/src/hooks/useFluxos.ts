import { useQuery } from '@tanstack/react-query'
import { api } from '../services/api'
import type { FlowItem } from '../types/domain'

export function useFluxos() {
  return useQuery({
    queryKey: ['fluxos'],
    queryFn: async ({ signal }) => {
      const { data } = await api.get<{ data: FlowItem[]; total: number }>(
        '/fluxos',
        { signal },
      )
      return data.data
    },
    staleTime: 1000 * 60 * 60 * 24,
    gcTime: 1000 * 60 * 60 * 24 * 7,
  })
}

export function useFluxosPorRegiao(regiaoId: string | null) {
  const { data: fluxos } = useFluxos()

  if (!regiaoId || !fluxos) return []

  return fluxos.filter(
    (f) =>
      f.destino_regiao_id === regiaoId ||
      f.origem_uf === regiaoId.toUpperCase(),
  )
}
