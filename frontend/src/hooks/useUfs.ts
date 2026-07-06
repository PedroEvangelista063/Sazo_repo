import { useQuery } from '@tanstack/react-query'
import { api } from '../services/api'

export function useUfs() {
  return useQuery({
    queryKey: ['ufs'],
    queryFn: async ({ signal }) => {
      const { data } = await api.get<{ data: string[]; total: number }>(
        '/ufs',
        { signal },
      )
      return data.data
    },
    staleTime: 1000 * 60 * 60,
    gcTime: 1000 * 60 * 60 * 24,
  })
}