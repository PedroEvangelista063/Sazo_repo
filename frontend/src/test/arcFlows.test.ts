import { describe, it, expect } from 'vitest'
import { buildArcs, arcPath, formatBoletimTooltip, toPointMap } from '../utils/arcFlows'
import type { BoletimFlowItem } from '../types/domain'

const pontos = [
  { uf: 'MT', cx: 419.3, cy: 422.8 },
  { uf: 'PA', cx: 511.3, cy: 175.6 },
  { uf: 'BA', cx: 698.6, cy: 403.4 },
]

const fluxoBase = (over: Partial<BoletimFlowItem> = {}): BoletimFlowItem => ({
  id: 1,
  produto: 'milho',
  origem_uf: 'MT',
  origem_polo: 'SORRISO',
  destino_uf: 'PA',
  destino_polo: 'MIRITITUBA',
  mes_referencia: 7,
  ano_referencia: 2026,
  fonte: 'boletim-logistico-julho-2026',
  pagina: 4,
  ...over,
})

describe('buildArcs', () => {
  it('retorna [] para fluxos nulos/vazios', () => {
    expect(buildArcs(null, pontos)).toEqual([])
    expect(buildArcs([], pontos)).toEqual([])
    expect(buildArcs(undefined, pontos)).toEqual([])
  })

  it('constrói arco válido com from/to e isIncoming=false', () => {
    const [arc] = buildArcs([fluxoBase()], pontos)
    expect(arc).toBeDefined()
    expect(arc?.from.uf).toBe('MT')
    expect(arc?.to.uf).toBe('PA')
    expect(arc?.isIncoming).toBe(false)
    expect(arc?.flow.produto).toBe('milho')
  })

  it('marca isIncoming=true quando destino == UF filtrada', () => {
    const [arc] = buildArcs([fluxoBase()], pontos, 'PA')
    expect(arc?.isIncoming).toBe(true)
  })

  it('filtra por UF selecionada (origem OU destino)', () => {
    const flows = [
      fluxoBase({ id: 1, destino_uf: 'PA' }),
      fluxoBase({ id: 2, origem_uf: 'BA', destino_uf: 'MT' }),
    ]
    const arcs = buildArcs(flows, pontos, 'BA')
    expect(arcs.length).toBe(1)
    expect(arcs[0].flow.id).toBe(2)
  })

  it('descarta fluxos sem ponto no mapa e self-loops', () => {
    const flows = [
      fluxoBase({ id: 1, origem_uf: 'ZZ' }), // sem ponto
      fluxoBase({ id: 2, origem_uf: 'MT', destino_uf: 'MT' }), // self-loop
      fluxoBase({ id: 3 }),
    ]
    const arcs = buildArcs(flows, pontos)
    expect(arcs.length).toBe(1)
    expect(arcs[0].flow.id).toBe(3)
  })

  it('aceita Map como source de pontos', () => {
    const map = new Map(pontos.map((p) => [p.uf, p]))
    const [arc] = buildArcs([fluxoBase()], map)
    expect(arc?.from.cx).toBe(419.3)
  })

  it('toPointMap converte array em Map', () => {
    const map = toPointMap(pontos)
    expect(map.get('MT')).toEqual({ uf: 'MT', cx: 419.3, cy: 422.8 })
  })
})

describe('arcPath', () => {
  it('gera curva quadrática com lift padrão 60', () => {
    const d = arcPath({ uf: 'MT', cx: 0, cy: 0 }, { uf: 'PA', cx: 100, cy: 0 })
    expect(d).toBe('M 0 0 Q 50 -60 100 0')
  })
})

describe('formatBoletimTooltip', () => {
  it('usa polos quando presentes', () => {
    expect(formatBoletimTooltip(fluxoBase())).toBe('milho • SORRISO → MIRITITUBA • 07/2026')
  })

  it('faz fallback para UF quando polo ausente (null safety)', () => {
    expect(formatBoletimTooltip(fluxoBase({ origem_polo: null, destino_polo: null }))).toBe(
      'milho • MT → PA • 07/2026',
    )
    expect(
      formatBoletimTooltip(fluxoBase({ origem_polo: undefined, destino_polo: undefined })),
    ).toBe('milho • MT → PA • 07/2026')
  })

  it('padroniza mês com zero à esquerda', () => {
    expect(formatBoletimTooltip(fluxoBase({ mes_referencia: 3 }))).toBe(
      'milho • SORRISO → MIRITITUBA • 03/2026',
    )
  })
})
