import { useQuery } from '@tanstack/react-query'
import { api } from '../services/api'
import type { SazonalidadeResponse } from '../types/domain'

export function useRegiaoResumo(regiaoId: string | null, ano?: number | null) {
  return useQuery({
    queryKey: ['regiao-resumo', regiaoId, ano],
    queryFn: async ({ signal }) => {
      if (!regiaoId) return null
      const params: Record<string, string | number> = { por_pagina: 500 }
      if (ano != null) params.ano = ano
      const { data } = await api.get<SazonalidadeResponse>(
        `/sazonalidade`,
        { params: { ...params, regiao: regiaoId }, signal },
      )
      return data
    },
    enabled: !!regiaoId,
    staleTime: 1000 * 60 * 5,
    gcTime: 1000 * 60 * 30,
    retry: 2,
    refetchOnWindowFocus: false,
  })
}
