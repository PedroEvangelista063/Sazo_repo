/**
 * api — Instância Axios compartilhada
 *
 * SRE principle: connection pooling é configurado uma vez e reutilizado
 * por todos os hooks. Timeout de 10s evita requests órfãos em rede 3G.
 * Cada hook (useSazonalidade, useMunicipios) importa esta instância,
 * mas a lógica de data-fetching, cache e transformação vive nos hooks.
 */
import axios from 'axios'

export const api = axios.create({
  baseURL: import.meta.env.VITE_API_URL ?? '/api/v1',
  timeout: 10000,
  headers: { 'Content-Type': 'application/json' },
})
