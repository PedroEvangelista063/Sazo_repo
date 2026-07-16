import { useQuery } from '@tanstack/react-query'
import { api } from '../services/api'
import type { RegiaoInfo } from '../types/domain'

export function useRegioes() {
  return useQuery({
    queryKey: ['regioes'],
    queryFn: async ({ signal }) => {
      const { data } = await api.get<{ regioes: RegiaoInfo[] }>(
        '/regioes',
        { signal },
      )
      return data.regioes
    },
    staleTime: 1000 * 60 * 60 * 24,
    gcTime: 1000 * 60 * 60 * 24 * 7,
  })
}
