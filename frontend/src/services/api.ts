import axios from 'axios'
import { setTransparency } from './transparencyStore'
import type { BoletimFlowFilters, BoletimFlowListResponse } from '../types/domain'

export const api = axios.create({
  baseURL: import.meta.env.VITE_API_URL ?? 'http://localhost:8000/api/v1',
  // FASE 79 (P1-2): 20s — a 1ª carga do BR podia levar 13-16s (2x
  // _ultimo_refresh_mv_iso + agregacao pesada no Aiven), estourando o 10s
  // antigo com ERR_ABORTED. O retry: 2 do TanStack Query (main.tsx) segue
  // adequado para falhas transientes.
  timeout: 20000,
  headers: { 'Content-Type': 'application/json' },
})

// Captura os headers de transparência (X-Last-Refresh / X-Cache-Status) de
// qualquer resposta da API e alimenta o store do rodapé global. O axios
// normaliza os nomes de headers para minúsculas.
api.interceptors.response.use((response) => {
  const lastRefresh = response.headers['x-last-refresh']
  const cacheStatus = response.headers['x-cache-status']
  if (lastRefresh || cacheStatus) {
    setTransparency({
      lastRefresh: typeof lastRefresh === 'string' && lastRefresh ? lastRefresh : null,
      cacheStatus: cacheStatus === 'HIT' || cacheStatus === 'MISS' ? cacheStatus : null,
    })
  }
  return response
})

/**
 * Busca rotas dos Boletins Logísticos da CONAB (GET /api/v1/fluxos/boletins).
 * Filtros opcionais aplicados no servidor (produto/UF/ano/mês) + paginação.
 */
export async function getFluxosBoletins(
  params: BoletimFlowFilters = {},
  signal?: AbortSignal,
): Promise<BoletimFlowListResponse> {
  const { data } = await api.get<BoletimFlowListResponse>('/fluxos/boletins', {
    params: {
      limit: params.limit ?? 200,
      offset: params.offset ?? 0,
      ...(params.produto ? { produto: params.produto } : {}),
      ...(params.origemUf ? { origem_uf: params.origemUf.toUpperCase() } : {}),
      ...(params.destinoUf ? { destino_uf: params.destinoUf.toUpperCase() } : {}),
      ...(params.anoReferencia != null ? { ano_referencia: params.anoReferencia } : {}),
      ...(params.mesReferencia != null ? { mes_referencia: params.mesReferencia } : {}),
    },
    signal,
  })
  return data
}
