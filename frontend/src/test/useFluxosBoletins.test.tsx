import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { ReactNode } from 'react'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { useFluxosBoletins } from '../hooks/useFluxosBoletins'
import { getFluxosBoletins } from '../services/api'

vi.mock('../services/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../services/api')>()
  return { ...actual, getFluxosBoletins: vi.fn() }
})

const mocked = vi.mocked(getFluxosBoletins)

function wrapper({ children }: { children: ReactNode }) {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, retryDelay: 0 } },
  })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

describe('useFluxosBoletins', () => {
  beforeEach(() => {
    mocked.mockReset()
  })

  it('chama getFluxosBoletins com os filtros e expõe os dados', async () => {
    mocked.mockResolvedValue({
      data: [
        {
          id: 1,
          produto: 'milho',
          origem_uf: 'MT',
          destino_uf: 'PA',
          mes_referencia: 7,
          ano_referencia: 2026,
        },
      ],
      total: 1,
      limit: 200,
      offset: 0,
    })

    const { result } = renderHook(
      () => useFluxosBoletins({ produto: 'milho', anoReferencia: 2026 }),
      {
        wrapper,
      },
    )

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data?.total).toBe(1)
    expect(result.current.data?.data[0].produto).toBe('milho')
    expect(mocked).toHaveBeenCalledWith(
      { produto: 'milho', anoReferencia: 2026 },
      expect.any(AbortSignal),
    )
  })

  it('propaga erro para isError (não quebra o app)', async () => {
    mocked.mockRejectedValue(new Error('boom'))

    const { result } = renderHook(() => useFluxosBoletins(), { wrapper })

    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(result.current.data).toBeUndefined()
  })

  it('envia os filtros para a API (chave de invalidação por filtro)', async () => {
    mocked.mockResolvedValue({ data: [], total: 0, limit: 200, offset: 0 })

    const { result } = renderHook(() => useFluxosBoletins({ produto: 'soja' }), { wrapper })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(mocked).toHaveBeenCalledWith({ produto: 'soja' }, expect.any(AbortSignal))
  })

  it('aplica defaults de paginação (limit 200 / offset 0)', async () => {
    mocked.mockResolvedValue({ data: [], total: 0, limit: 200, offset: 0 })

    const { result } = renderHook(() => useFluxosBoletins(), { wrapper })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(mocked).toHaveBeenCalledWith({}, expect.any(AbortSignal))
  })
})
