import type { StatusCor } from '../types/domain'

export const STATUS_PALETA: readonly StatusCor[] = ['VERDE', 'AMARELO', 'VERMELHO'] as const

export function normalizarStatusCor(status: StatusCor | string | null | undefined): StatusCor {
  if (status === 'VERDE' || status === 'AMARELO' || status === 'VERMELHO') return status
  return 'AMARELO'
}
