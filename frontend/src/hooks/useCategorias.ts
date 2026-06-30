import { useQuery } from '@tanstack/react-query'
import { api } from '../services/api'
import type { CategoriaListResponse } from '../types/domain'

export function useCategorias() {
  return useQuery({
    queryKey: ['categorias'],
    queryFn: async ({ signal }) => {
      const { data } = await api.get<CategoriaListResponse>('/categorias', { signal })
      return data.data
    },
    staleTime: 1000 * 60 * 60 * 24,
    gcTime: 1000 * 60 * 60 * 24,
  })
}
