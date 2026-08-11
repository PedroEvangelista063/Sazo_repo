import { describe, it, expect } from 'vitest'
import { temGradeCompleta } from '../utils/gradeCompleta'
import type { SazonalidadeNacionalItem } from '../types/domain'

function makeItem(meses: number[]): SazonalidadeNacionalItem {
  return {
    produto: 'TESTE',
    classificao_produto: null,
    categoria: null,
    total_ufs: 10,
    meses: meses.map((mes) => ({
      mes,
      status_cor: 'AMARELO',
      is_forecast: false,
      baseline_confianca: null,
      forecast_method: null,
      calculado_em: null,
    })),
  }
}

const MESES_COMPLETOS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]

describe('temGradeCompleta — filtro de grade de 12 meses', () => {
  it('aceita item com os 12 meses presentes', () => {
    expect(temGradeCompleta(makeItem(MESES_COMPLETOS))).toBe(true)
  })

  it('filtra item com 11 meses (ex: Abiu, sem mês 11)', () => {
    const semOnze = MESES_COMPLETOS.filter((m) => m !== 11)
    expect(temGradeCompleta(makeItem(semOnze))).toBe(false)
  })

  it('filtra item com grade muito curta (ex: Carapau, 2 meses)', () => {
    expect(temGradeCompleta(makeItem([2, 7]))).toBe(false)
  })

  it('filtra meses duplicados que não cobrem 1..12', () => {
    const duplicados = [1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12]
    expect(temGradeCompleta(makeItem(duplicados))).toBe(false)
  })

  it('filtra meses vazios e null', () => {
    expect(temGradeCompleta(makeItem([]))).toBe(false)
    expect(temGradeCompleta(null)).toBe(false)
    expect(temGradeCompleta(undefined)).toBe(false)
  })
})
