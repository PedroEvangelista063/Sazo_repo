import type { FlowItem, BoletimFlowItem } from '../types/domain'

/**
 * Fluxo unificado para exibição no RegiaoPanel.
 * Combina dados de `flows.json` (estático) e Boletins CONAB (PDFs)
 * em uma única representação para as seções "Recebe de" / "Envia para".
 */
export interface UnifiedFlowItem {
  id: string
  produto: string
  origem_uf: string
  destino_uf: string
  /** 'estatico' = flows.json | 'boletim' = CONAB PDF */
  fonte: 'estatico' | 'boletim'
  /** Tipo do fluxo estático (exportado/importado/autossuficiente), ausente no boletim */
  tipo?: string
  /** Cor do indicador (flows.json), ausente no boletim */
  cor_indicadora?: string
  /** Mês de referência (boletim), ausente no estático */
  mes_referencia?: number
  /** Ano de referência (boletim), ausente no estático */
  ano_referencia?: number
}

/**
 * Converte um FlowItem (estático) para UnifiedFlowItem.
 */
function fromStatic(f: FlowItem): UnifiedFlowItem {
  return {
    id: `static-${f.id}`,
    produto: f.item,
    origem_uf: f.origem_uf,
    destino_uf: f.destino_uf,
    fonte: 'estatico',
    tipo: f.tipo,
    cor_indicadora: f.cor_indicadora,
  }
}

/**
 * Converte um BoletimFlowItem (CONAB) para UnifiedFlowItem.
 */
function fromBoletim(f: BoletimFlowItem): UnifiedFlowItem {
  return {
    id: `boletim-${f.id}`,
    produto: f.produto,
    origem_uf: f.origem_uf,
    destino_uf: f.destino_uf,
    fonte: 'boletim',
    mes_referencia: f.mes_referencia,
    ano_referencia: f.ano_referencia,
  }
}

/**
 * Mescla fluxos estáticos e boletins CONAB em uma lista unificada,
 * deduplicando por (origem_uf, destino_uf, produto).
 * Prioriza o fluxo estático quando há duplicata (mantém tipo/cor).
 */
export function mergeFlows(
  staticFlows: FlowItem[] | undefined | null,
  boletimFlows: BoletimFlowItem[] | undefined | null,
): UnifiedFlowItem[] {
  const byKey = new Map<string, UnifiedFlowItem>()

  // 1. Indexar fluxos estáticos (prioridade)
  if (staticFlows) {
    for (const f of staticFlows) {
      const key = `${f.origem_uf}|${f.destino_uf}|${f.item}`
      byKey.set(key, fromStatic(f))
    }
  }

  // 2. Adicionar/complementar boletins CONAB
  if (boletimFlows) {
    for (const f of boletimFlows) {
      if (!f.produto) continue
      const key = `${f.origem_uf}|${f.destino_uf}|${f.produto}`
      if (!byKey.has(key)) {
        byKey.set(key, fromBoletim(f))
      }
      // Se já existe (estático), não sobrescreve — mantém tipo/cor do estático
    }
  }

  return [...byKey.values()]
}
