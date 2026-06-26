/**
 * useMunicipios — Custom Hook para listagem de municípios por UF
 *
 * SRE/Frontend principles:
 * - staleTime de 24h: lista de municípios é quasi-estática (muda apenas com nova base CONAB)
 * - gcTime de 24h: mantém resposta em cache mesmo após navegar para Dashboard,
 *   evitando nova requisição se usuário voltar ao LocationSelector
 * - Abstração total do endpoint: UI chama hook, não conhece axios nem query params
 */
import { useQuery } from '@tanstack/react-query'
import { api } from '../services/api'

interface MunicipioApiResponse {
  data: string[]
  total: number
}

interface UseMunicipiosResult {
  municipios: string[]
  isLoading: boolean
  isError: boolean
  error: Error | null
}

export function useMunicipios(uf: string | null): UseMunicipiosResult {
  const query = useQuery({
    queryKey: ['municipios', uf] as const,
    queryFn: async ({ signal }): Promise<string[]> => {
      const { data } = await api.get<MunicipioApiResponse>('/municipios', {
        params: { uf },
        signal,
      })
      return data.data
    },
    enabled: !!uf && uf.length === 2,
    staleTime: 1000 * 60 * 60 * 24,
    gcTime: 1000 * 60 * 60 * 24,
    retry: 2,
    refetchOnWindowFocus: false,
  })

  return {
    municipios: query.data ?? [],
    isLoading: query.isLoading,
    isError: query.isError,
    error: query.error,
  }
}
