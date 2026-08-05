import axios from 'axios'
import { setTransparency } from './transparencyStore'

export const api = axios.create({
  baseURL: import.meta.env.VITE_API_URL ?? 'http://localhost:8000/api/v1',
  timeout: 10000,
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
