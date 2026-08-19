import type { BoletimFlowItem } from '../types/domain'

export interface ContagemRotas {
  produto: string
  quantidade: number
}

export interface ContagemUF {
  uf: string
  quantidade: number
}

export interface BoletimResumo {
  total: number
  produtosUnicos: number
  ufsEnvolvidas: number
  topProdutos: ContagemRotas[]
  origens: ContagemUF[]
  destinos: ContagemUF[]
}

export const RESUMO_VAZIO: BoletimResumo = {
  total: 0,
  produtosUnicos: 0,
  ufsEnvolvidas: 0,
  topProdutos: [],
  origens: [],
  destinos: [],
}

function incrementar(map: Map<string, number>, key: string): void {
  map.set(key, (map.get(key) ?? 0) + 1)
}

function topN<T extends { quantidade: number }>(
  map: Map<string, number>,
  n: number,
  toEntry: (k: string, v: number) => T,
): T[] {
  return [...map.entries()]
    .map(([key, value]) => toEntry(key, value))
    .sort((a, b) => b.quantidade - a.quantidade)
    .slice(0, n)
}

/**
 * Resume as rotas dos Boletins CONAB por região/UF selecionada.
 * Nul-safe: fluxos ausentes/indefinidos retornam RESUMO_VAZIO (estado CINZA).
 */
export function buildBoletimResumo(
  flows: BoletimFlowItem[] | undefined | null,
  regionUfs: string[] | undefined = undefined,
  selectedUf: string | null | undefined = null,
): BoletimResumo {
  if (!flows || flows.length === 0) return { ...RESUMO_VAZIO }

  const regionSet = regionUfs && regionUfs.length > 0 ? new Set(regionUfs) : null
  const filtered = flows.filter((f) => {
    if (selectedUf) {
      return f.origem_uf === selectedUf || f.destino_uf === selectedUf
    }
    if (regionSet) {
      return regionSet.has(f.origem_uf) || regionSet.has(f.destino_uf)
    }
    return true
  })

  if (filtered.length === 0) return { ...RESUMO_VAZIO }

  const produtos = new Map<string, number>()
  const origens = new Map<string, number>()
  const destinos = new Map<string, number>()
  const ufs = new Set<string>()

  for (const f of filtered) {
    const prod = f.produto || ''
    incrementar(produtos, prod)
    incrementar(origens, f.origem_uf)
    incrementar(destinos, f.destino_uf)
    ufs.add(f.origem_uf)
    ufs.add(f.destino_uf)
  }

  return {
    total: filtered.length,
    produtosUnicos: produtos.size,
    ufsEnvolvidas: ufs.size,
    topProdutos: topN(produtos, 3, (k, v) => ({ produto: k, quantidade: v })),
    origens: [...origens.entries()]
      .map(([uf, quantidade]) => ({ uf, quantidade }))
      .sort((a, b) => b.quantidade - a.quantidade),
    destinos: [...destinos.entries()]
      .map(([uf, quantidade]) => ({ uf, quantidade }))
      .sort((a, b) => b.quantidade - a.quantidade),
  }
}
