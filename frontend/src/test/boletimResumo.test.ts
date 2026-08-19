import { describe, it, expect } from 'vitest'
import { buildBoletimResumo, RESUMO_VAZIO } from '../utils/boletimResumo'
import type { BoletimFlowItem } from '../types/domain'

const fluxo = (over: Partial<BoletimFlowItem> = {}): BoletimFlowItem => ({
  id: 1,
  produto: 'milho',
  origem_uf: 'MT',
  destino_uf: 'PA',
  mes_referencia: 7,
  ano_referencia: 2026,
  ...over,
})

describe('buildBoletimResumo', () => {
  it('retorna RESUMO_VAZIO para flows nulos/vazios (estado CINZA)', () => {
    expect(buildBoletimResumo(null)).toEqual(RESUMO_VAZIO)
    expect(buildBoletimResumo(undefined)).toEqual(RESUMO_VAZIO)
    expect(buildBoletimResumo([])).toEqual(RESUMO_VAZIO)
  })

  it('agrega total, top produtos, origens e destinos', () => {
    const resumo = buildBoletimResumo([
      fluxo({ id: 1, produto: 'milho', origem_uf: 'MT', destino_uf: 'PA' }),
      fluxo({ id: 2, produto: 'milho', origem_uf: 'MT', destino_uf: 'GO' }),
      fluxo({ id: 3, produto: 'soja', origem_uf: 'BA', destino_uf: 'MT' }),
      fluxo({ id: 4, produto: 'soja', origem_uf: 'GO', destino_uf: 'MT' }),
    ])
    expect(resumo.total).toBe(4)
    expect(resumo.produtosUnicos).toBe(2)
    expect(resumo.ufsEnvolvidas).toBe(4)
    expect(resumo.topProdutos[0]).toEqual({ produto: 'milho', quantidade: 2 })
    expect(resumo.origens[0]).toEqual({ uf: 'MT', quantidade: 2 })
    expect(resumo.destinos[0]).toEqual({ uf: 'MT', quantidade: 2 })
  })

  it('filtra por região (regionUfs — origem OU destino)', () => {
    const flows = [
      fluxo({ id: 1, origem_uf: 'MT', destino_uf: 'PA' }),
      fluxo({ id: 2, origem_uf: 'SP', destino_uf: 'RJ' }),
    ]
    const resumo = buildBoletimResumo(flows, ['MT', 'PA', 'GO'])
    expect(resumo.total).toBe(1)
    expect(resumo.origens[0].uf).toBe('MT')
  })

  it('filtra por UF selecionada', () => {
    const flows = [
      fluxo({ id: 1, origem_uf: 'MT', destino_uf: 'PA' }),
      fluxo({ id: 2, origem_uf: 'SP', destino_uf: 'RJ' }),
    ]
    const resumo = buildBoletimResumo(flows, undefined, 'MT')
    expect(resumo.total).toBe(1)
    expect(resumo.destinos[0]).toEqual({ uf: 'PA', quantidade: 1 })
  })

  it('UF selecionada tem precedência sobre região', () => {
    const flows = [
      fluxo({ id: 1, origem_uf: 'MT', destino_uf: 'PA' }),
      fluxo({ id: 2, origem_uf: 'SP', destino_uf: 'MT' }),
    ]
    const resumo = buildBoletimResumo(flows, ['MT', 'PA', 'GO'], 'SP')
    expect(resumo.total).toBe(1)
    expect(resumo.destinos[0]).toEqual({ uf: 'MT', quantidade: 1 })
  })

  it('ordena por quantidade decrescente', () => {
    const resumo = buildBoletimResumo([
      fluxo({ id: 1, produto: 'soja', origem_uf: 'BA', destino_uf: 'MT' }),
      fluxo({ id: 2, produto: 'milho', origem_uf: 'MT', destino_uf: 'PA' }),
      fluxo({ id: 3, produto: 'milho', origem_uf: 'GO', destino_uf: 'MT' }),
      fluxo({ id: 4, produto: 'milho', origem_uf: 'MT', destino_uf: 'GO' }),
    ])
    expect(resumo.topProdutos.map((p) => p.produto)).toEqual(['milho', 'soja'])
  })

  it('retorna RESUMO_VAZIO quando filtros excluem tudo', () => {
    const resumo = buildBoletimResumo([fluxo({ origem_uf: 'MT' })], undefined, 'SP')
    expect(resumo).toEqual(RESUMO_VAZIO)
  })
})
