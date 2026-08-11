import type { SazonalidadeNacionalItem } from '../types/domain'

const TODOS_OS_MESES: readonly number[] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]

/**
 * Quality Gate de grade (regra de apresentação): retorna `true` apenas se o
 * item da grade mensal cobre os 12 meses do ano — ou seja, todos os meses
 * 1..12 estão presentes em `item.meses`.
 *
 * Produtos com gap (ex: Carapau com 2 meses, Abiu com 11) são OCULTADOS da
 * listagem. É um filtro de exibição, não de API: o contrato de dados não muda.
 */
export function temGradeCompleta(
  item: Pick<SazonalidadeNacionalItem, 'meses'> | null | undefined,
): boolean {
  if (!item?.meses || item.meses.length < 12) return false
  const presentes = new Set(item.meses.map((m) => m.mes))
  return TODOS_OS_MESES.every((mes) => presentes.has(mes))
}
