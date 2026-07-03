import { useEffect, useRef } from 'react'
import { useQueryClient } from '@tanstack/react-query'

const SSE_ENDPOINT = '/api/v1/stream/updates'
const RECONNECT_BASE = 1000
const RECONNECT_MAX = 30_000

function sseUrl(): string {
  const apiUrl = import.meta.env.VITE_API_URL as string | undefined
  if (apiUrl) {
    const base = apiUrl.replace(/\/api\/v1\/?$/, '')
    return `${base}${SSE_ENDPOINT}`
  }
  return SSE_ENDPOINT
}

const QUERIES_TO_INVALIDATE: { queryKey: readonly unknown[] }[] = [
  { queryKey: ['hortifruti-meta'] },
  { queryKey: ['hortifruti-filter'] },
  { queryKey: ['categorias'] },
]

export function useDataStream() {
  const queryClient = useQueryClient()
  const esRef = useRef<EventSource | null>(null)
  const retryRef = useRef<number>(0)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => {
    let cancelled = false

    function connect() {
      if (cancelled) return

      esRef.current?.close()
      const url = sseUrl()
      const es = new EventSource(url, { withCredentials: false })
      esRef.current = es

      es.addEventListener('connected', () => {
        retryRef.current = 0
      })

      es.addEventListener('ETL_FINISHED', () => {
        for (const { queryKey } of QUERIES_TO_INVALIDATE) {
          queryClient.invalidateQueries({ queryKey })
        }
      })

      es.onerror = () => {
        es.close()
        esRef.current = null
        if (cancelled) return

        const delay = Math.min(
          RECONNECT_BASE * Math.pow(2, retryRef.current),
          RECONNECT_MAX,
        )
        retryRef.current += 1
        timerRef.current = setTimeout(connect, delay)
      }
    }

    connect()

    return () => {
      cancelled = true
      if (timerRef.current) clearTimeout(timerRef.current)
      esRef.current?.close()
    }
  }, [queryClient])
}
