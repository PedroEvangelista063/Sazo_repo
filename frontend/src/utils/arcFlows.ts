import type { BoletimFlowItem } from '../types/domain'

export interface ArcPoint {
  uf: string
  cx: number
  cy: number
}

export interface BuiltArc<T> {
  from: ArcPoint
  to: ArcPoint
  flow: T
  isIncoming: boolean
}

export type PointMapLike = Map<string, ArcPoint> | Array<ArcPoint>

export function toPointMap(points: PointMapLike): Map<string, ArcPoint> {
  return points instanceof Map ? points : new Map(points.map((p) => [p.uf, p]))
}

/**
 * Constrói os arcos origem→destino a partir de uma lista de fluxos.
 * Qualquer fluxo cuja UF de origem/destino não exista no mapa é descartado
 * (null-safe) — nunca quebra com campos ausentes.
 */
export function buildArcs<T extends { origem_uf: string; destino_uf: string }>(
  flows: T[] | undefined | null,
  points: PointMapLike,
  filterUf: string | null | undefined = null,
): Array<BuiltArc<T>> {
  if (!flows || flows.length === 0) return []
  const pointMap = toPointMap(points)
  const hasFilter = filterUf != null && filterUf !== undefined && filterUf !== ''
  return flows
    .filter((f) => !hasFilter || f.origem_uf === filterUf || f.destino_uf === filterUf)
    .map((f) => {
      const from = pointMap.get(f.origem_uf)
      const to = pointMap.get(f.destino_uf)
      if (!from || !to || from.uf === to.uf) return null
      const isIncoming = hasFilter && f.destino_uf === filterUf
      return { from, to, flow: f, isIncoming }
    })
    .filter((x): x is BuiltArc<T> => x !== null)
}

/** Curva quadrática entre dois pontos do mapa (mesma curva do BrasilMap). */
export function arcPath(from: ArcPoint, to: ArcPoint, lift = 60): string {
  const mx = (from.cx + to.cx) / 2
  const my = (from.cy + to.cy) / 2 - lift
  return `M ${from.cx} ${from.cy} Q ${mx} ${my} ${to.cx} ${to.cy}`
}

/**
 * Tooltip de uma rota do boletim CONAB. Nul-safe: polo ausente cai para a UF.
 * Ex: "milho • SORRISO → MIRITITUBA • 07/2026"
 */
export function formatBoletimTooltip(f: BoletimFlowItem): string {
  const origem = f.origem_polo ?? f.origem_uf
  const destino = f.destino_polo ?? f.destino_uf
  const periodo = `${String(f.mes_referencia).padStart(2, '0')}/${f.ano_referencia}`
  return `${f.produto} • ${origem} → ${destino} • ${periodo}`
}
